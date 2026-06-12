// metal_nonce_finder.mm
//
// SHA-256d nonce searcher on Apple Silicon GPU via Metal.
// Called by stratum_miner.py / gbt_miner.py.
//
// Build:
//   clang++ -std=c++17 -O3 -fobjc-arc \
//       -framework Foundation -framework Metal -framework IOKit \
//       -o metal_nonce_finder metal_nonce_finder.mm
//
// Two run modes:
//
//   1) One-shot (back-compat with smoke tests):
//      metal_nonce_finder \
//          --header-prefix <160 hex chars: 80-byte block header>
//          --target        <64 hex chars: 32-byte BE target>
//          --start-nonce   <uint32 decimal>
//          --count         <uint64 decimal: how many nonces to scan>
//          [--per-dispatch <uint32; 0 or omitted = auto-tune>]
//          [--threadgroup  <uint32; 0 or omitted = auto-tune>]
//
//   2) Persistent (preferred; eliminates per-batch fork + Metal recompile):
//      metal_nonce_finder --persistent
//      Reads one JSON job per line on stdin:
//          {"header_prefix": "<160 hex>", "target": "<64 hex>",
//           "start_nonce": N, "count": M}
//      Writes one JSON result per line on stdout:
//          {"found": true,  "nonce": N, "hash": "<64 hex BE>",
//           "checked": N, "elapsed_ms": M, "hashrate": H}
//          {"found": false, "checked": N, "elapsed_ms": M, "hashrate": H}
//      Exits cleanly on stdin EOF.
//
// Auto-tuning:
//   - GPU core count is queried via IOKit (AGXAccelerator / gpu-core-count).
//   - Threadgroup defaults to a round multiple of threadExecutionWidth that
//     fits the SHA-256d kernel's register pressure (typically 256).
//   - per-dispatch defaults to a value that gives ~50-100 ms per dispatch on
//     the detected hardware (scaled by core count, with a floor and ceiling).
//   - Two MTLCommandBuffers are pipelined to keep the GPU saturated while
//     the host prepares the next dispatch.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
#include <inttypes.h>

// ---------------------------------------------------------------------------
// Metal kernel source (compiled at runtime via newLibraryWithSource:).
// ---------------------------------------------------------------------------
static NSString * const kMetalSource = @R"METAL(
#include <metal_stdlib>
using namespace metal;

constant uint K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

constant uint H0[8] = {
    0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
    0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
};

inline uint rotr32(uint x, uint n) { return (x >> n) | (x << (32 - n)); }
inline uint bswap32_u(uint x) {
    return ((x & 0x000000FFu) << 24) | ((x & 0x0000FF00u) << 8)
         | ((x & 0x00FF0000u) >> 8)  | ((x & 0xFF000000u) >> 24);
}

inline void sha256_compress(thread uint h[8], thread const uint w_in[16]) {
    uint w[64];
    for (uint i = 0; i < 16; i++) w[i] = w_in[i];
    for (uint i = 16; i < 64; i++) {
        uint s0 = rotr32(w[i-15], 7) ^ rotr32(w[i-15], 18) ^ (w[i-15] >> 3);
        uint s1 = rotr32(w[i-2], 17) ^ rotr32(w[i-2], 19) ^ (w[i-2] >> 10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    uint a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], hh=h[7];
    for (uint i = 0; i < 64; i++) {
        uint S1 = rotr32(e,6) ^ rotr32(e,11) ^ rotr32(e,25);
        uint ch = (e & f) ^ ((~e) & g);
        uint t1 = hh + S1 + ch + K[i] + w[i];
        uint S0 = rotr32(a,2) ^ rotr32(a,13) ^ rotr32(a,22);
        uint mj = (a & b) ^ (a & c) ^ (b & c);
        uint t2 = S0 + mj;
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
}

// Block header is 80 bytes = chunk1 (64 B) + chunk2 (16 B).
// chunk1 = version(4 LE) | prev(32) | merkle[0..28] - midstate precomputed on CPU.
// chunk2 = merkle[28..32] | ntime(4 LE) | nbits(4 LE) | nonce(4 LE).
//
// In SHA-256 word terms (big-endian inside each 4-byte word):
//   tail_words[0] = chunk2 bytes  0.. 3   (merkle tail)
//   tail_words[1] = chunk2 bytes  4.. 7   (ntime)
//   tail_words[2] = chunk2 bytes  8..11   (nbits)
//   w[3]         = chunk2 bytes 12..15   (nonce, varies per thread)
// Then SHA-256 padding for an 80-byte message fills the rest of this 64-byte chunk.

kernel void sha256d_search(
    constant uint *midstate    [[buffer(0)]],   // 8 uint32 (SHA-256 state after chunk1)
    constant uint *tail_words  [[buffer(1)]],   // 3 uint32 (chunk2 bytes 0..11 as BE words)
    constant uint *target_be   [[buffer(2)]],   // 8 uint32, BE, target_be[0] most-significant
    constant uint &start_nonce [[buffer(3)]],
    device atomic_uint *result_flag  [[buffer(4)]],   // 0 = none yet
    device atomic_uint *result_nonce [[buffer(5)]],
    device uint *result_hash         [[buffer(6)]],   // 8 uint32 (BE "display" order)
    uint gid [[thread_position_in_grid]]
){
    uint nonce_val = start_nonce + gid;

    uint w[16];
    w[0] = tail_words[0];
    w[1] = tail_words[1];
    w[2] = tail_words[2];
    // The 4 bytes of nonce are little-endian in the header on the wire.
    // SHA-256 reads each 4-byte word big-endian, so w[3] = bswap32(nonce_le_value).
    w[3] = bswap32_u(nonce_val);
    w[4] = 0x80000000u;             // SHA-256 padding start
    w[5] = 0; w[6] = 0; w[7] = 0;
    w[8] = 0; w[9] = 0; w[10] = 0; w[11] = 0;
    w[12] = 0; w[13] = 0; w[14] = 0;
    w[15] = 640u;                   // 80 bytes * 8 bits

    uint h[8];
    for (uint i = 0; i < 8; i++) h[i] = midstate[i];
    sha256_compress(h, w);

    // Second SHA-256: input = first 32-byte hash, total 32 bytes.
    uint w2[16];
    for (uint i = 0; i < 8; i++) w2[i] = h[i];
    w2[8]  = 0x80000000u;
    w2[9]  = 0; w2[10] = 0; w2[11] = 0;
    w2[12] = 0; w2[13] = 0; w2[14] = 0;
    w2[15] = 256u;                  // 32 bytes * 8 bits

    uint h2[8];
    for (uint i = 0; i < 8; i++) h2[i] = H0[i];
    sha256_compress(h2, w2);

    // Bitcoin "display hash" = byte-reverse of natural SHA-256 output.
    // If natural output bytes are B0..B31 (h2[0] BE-packed = B0..B3, ...),
    // then display_be[i] (as uint32 BE) = bswap32(h2[7 - i]).
    // Compare display_be[i] with target_be[i] from MSB to LSB.
    bool below = false;
    bool decided = false;
    for (uint i = 0; i < 8; i++) {
        uint d = bswap32_u(h2[7 - i]);
        if (!decided) {
            if (d < target_be[i])      { below = true;  decided = true; }
            else if (d > target_be[i]) { below = false; decided = true; }
        }
    }
    if (!decided) below = true;     // equal counts as valid

    if (below) {
        uint expected = 0u;
        if (atomic_compare_exchange_weak_explicit(
                result_flag, &expected, 1u,
                memory_order_relaxed, memory_order_relaxed)) {
            atomic_store_explicit(result_nonce, nonce_val, memory_order_relaxed);
            for (uint i = 0; i < 8; i++) {
                result_hash[i] = bswap32_u(h2[7 - i]);
            }
        }
    }
}
)METAL";

// ---------------------------------------------------------------------------
// GPU introspection: detect the number of GPU cores via IOKit so we can
// size dispatches without the user telling us which Apple chip we're on.
// Returns 0 if unknown.
// ---------------------------------------------------------------------------
static uint32_t detect_gpu_core_count(void) {
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("AGXAccelerator"),
                                     &iter) != KERN_SUCCESS) {
        return 0;
    }
    uint32_t cores = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iter))) {
        CFTypeRef cf = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane,
            CFSTR("gpu-core-count"), kCFAllocatorDefault,
            kIORegistryIterateRecursively);
        if (cf) {
            if (CFGetTypeID(cf) == CFNumberGetTypeID()) {
                int32_t v = 0;
                CFNumberGetValue((CFNumberRef)cf, kCFNumberSInt32Type, &v);
                if (v > 0) cores = (uint32_t)v;
            }
            CFRelease(cf);
        }
        IOObjectRelease(service);
        if (cores > 0) break;
    }
    IOObjectRelease(iter);
    return cores;
}

// ---------------------------------------------------------------------------
// CPU helpers: hex parsing + SHA-256 (for midstate precompute).
// ---------------------------------------------------------------------------
static int parseHex(const char *hex, uint8_t *out, size_t out_len) {
    size_t n = strlen(hex);
    if (n != out_len * 2) return -1;
    for (size_t i = 0; i < out_len; i++) {
        unsigned int v;
        if (sscanf(hex + 2*i, "%2x", &v) != 1) return -1;
        out[i] = (uint8_t)v;
    }
    return 0;
}

static const uint32_t K_CPU[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
};

static inline uint32_t rotr_cpu(uint32_t x, uint32_t n){ return (x>>n)|(x<<(32-n)); }

static void sha256_compress_cpu(uint32_t h[8], const uint8_t block[64]) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[i*4] << 24) | ((uint32_t)block[i*4+1] << 16)
             | ((uint32_t)block[i*4+2] << 8) | (uint32_t)block[i*4+3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr_cpu(w[i-15],7) ^ rotr_cpu(w[i-15],18) ^ (w[i-15]>>3);
        uint32_t s1 = rotr_cpu(w[i-2],17) ^ rotr_cpu(w[i-2],19) ^ (w[i-2]>>10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = rotr_cpu(e,6) ^ rotr_cpu(e,11) ^ rotr_cpu(e,25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = hh + S1 + ch + K_CPU[i] + w[i];
        uint32_t S0 = rotr_cpu(a,2) ^ rotr_cpu(a,13) ^ rotr_cpu(a,22);
        uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + mj;
        hh=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
}

static double monotime() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------
int main(int argc, const char *argv[]) {
@autoreleasepool {
    const char *hexHeader = NULL;
    const char *hexTarget = NULL;
    uint32_t startNonce = 0;
    uint64_t totalCount = 1ull << 24;
    uint64_t perDispatch_user = 0;        // 0 = auto-tune
    uint32_t threadgroupSize_user = 0;    // 0 = auto-tune
    bool persistent = false;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if      (!strcmp(a, "--header-prefix") && i+1<argc) hexHeader = argv[++i];
        else if (!strcmp(a, "--target")        && i+1<argc) hexTarget = argv[++i];
        else if (!strcmp(a, "--start-nonce")   && i+1<argc) startNonce = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(a, "--count")         && i+1<argc) totalCount = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(a, "--per-dispatch")  && i+1<argc) perDispatch_user = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(a, "--threadgroup")   && i+1<argc) threadgroupSize_user = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(a, "--persistent"))                persistent = true;
        else if (!strcmp(a, "--help") || !strcmp(a, "-h")) {
            fprintf(stderr,
                "metal_nonce_finder: SHA-256d nonce search on Apple Silicon GPU\n"
                "\n"
                "One-shot:\n"
                "  --header-prefix <160 hex chars (80 bytes)>\n"
                "  --target        <64 hex chars (32 bytes BE)>\n"
                "  --start-nonce   <uint32>\n"
                "  --count         <uint64>\n"
                "  --per-dispatch  <uint64; 0 or omit = auto>\n"
                "  --threadgroup   <uint32; 0 or omit = auto>\n"
                "\n"
                "Persistent (preferred):\n"
                "  --persistent  read one job JSON per line on stdin,\n"
                "                emit one result JSON per line on stdout.\n"
                "                Auto-tunes per-dispatch and threadgroup once at startup.\n");
            return 0;
        }
        else { fprintf(stderr, "metal_nonce_finder: unknown arg: %s\n", a); return 2; }
    }

    // ---------------- Metal setup (one time) ----------------
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { fprintf(stderr, "Metal device not available\n"); return 3; }

    NSError *err = nil;
    MTLCompileOptions *opts = [MTLCompileOptions new];
    opts.fastMathEnabled = YES;
    id<MTLLibrary> lib = [device newLibraryWithSource:kMetalSource options:opts error:&err];
    if (!lib) { fprintf(stderr, "Metal compile error: %s\n", err.description.UTF8String); return 3; }

    id<MTLFunction> fn = [lib newFunctionWithName:@"sha256d_search"];
    if (!fn) { fprintf(stderr, "kernel sha256d_search not found\n"); return 3; }

    id<MTLComputePipelineState> pipe =
        [device newComputePipelineStateWithFunction:fn error:&err];
    if (!pipe) { fprintf(stderr, "pipeline error: %s\n", err.description.UTF8String); return 3; }

    NSUInteger maxTPB = pipe.maxTotalThreadsPerThreadgroup;
    NSUInteger tew    = pipe.threadExecutionWidth;
    uint32_t gpu_cores = detect_gpu_core_count();

    // Auto-tune threadgroup. The pipeline's
    // maxTotalThreadsPerThreadgroup is what the GPU itself reports as the
    // largest threadgroup our SHA-256d kernel can fit given its register
    // pressure (typically 576 on the M2 family). Empirically that gives
    // the best throughput; smaller threadgroups leave compute on the
    // table. Always round down to a multiple of threadExecutionWidth (32).
    uint32_t threadgroup;
    if (threadgroupSize_user == 0) {
        uint32_t want = (uint32_t)maxTPB;
        if (tew > 0) {
            want = (want / (uint32_t)tew) * (uint32_t)tew;
            if (want == 0) want = (uint32_t)tew;
        }
        if (want == 0) want = 256;     // last-resort fallback
        threadgroup = want;
    } else {
        threadgroup = threadgroupSize_user;
        if ((NSUInteger)threadgroup > maxTPB) threadgroup = (uint32_t)maxTPB;
    }

    // Auto-tune per-dispatch. We want a dispatch big enough to hide host
    // overhead but small enough to remain responsive. Heuristic:
    //   per_dispatch ~ gpu_cores * 2M nonces, clamped to [4M, 64M].
    // M2 (10 GPU cores) -> 20M, snapped to 16M; M2 Max (~32 cores) -> 64M;
    // unknown core count -> 16M (matches the previous static default).
    uint32_t per_dispatch;
    if (perDispatch_user == 0) {
        uint32_t cores_eff = gpu_cores ? gpu_cores : 8;
        uint64_t pd = (uint64_t)cores_eff * (1u << 21);  // 2M nonces / GPU core
        if (pd < (1u << 22)) pd = (1u << 22);   // floor:  4M
        if (pd > (1u << 26)) pd = (1u << 26);   // ceil : 64M
        per_dispatch = (uint32_t)pd;
    } else {
        per_dispatch = (uint32_t)perDispatch_user;
        if (per_dispatch == 0) per_dispatch = 1u << 24;
    }

    fprintf(stderr,
            "[metal] device=\"%s\" gpu_cores=%u threadExecutionWidth=%lu "
            "maxTPT=%lu threadgroup=%u per_dispatch=%u (%.1fM)%s\n",
            device.name.UTF8String,
            gpu_cores,
            (unsigned long)tew,
            (unsigned long)maxTPB,
            threadgroup,
            per_dispatch,
            per_dispatch / 1048576.0,
            (perDispatch_user == 0 || threadgroupSize_user == 0) ? " [auto]" : "");
    fflush(stderr);

    id<MTLCommandQueue> q = [device newCommandQueue];

    // Pre-allocate the parameter buffers (rewritten per-job in persistent mode).
    id<MTLBuffer> bMid  = [device newBufferWithLength:32
                                              options:MTLResourceStorageModeShared];
    id<MTLBuffer> bTail = [device newBufferWithLength:12
                                              options:MTLResourceStorageModeShared];
    id<MTLBuffer> bTgt  = [device newBufferWithLength:32
                                              options:MTLResourceStorageModeShared];
    // Two ping-pong slots for result buffers so we can keep up to two
    // command buffers in flight at once.
    id<MTLBuffer> bFlag[2];
    id<MTLBuffer> bNon[2];
    id<MTLBuffer> bHash[2];
    for (int i = 0; i < 2; i++) {
        bFlag[i] = [device newBufferWithLength:sizeof(uint32_t)
                                       options:MTLResourceStorageModeShared];
        bNon[i]  = [device newBufferWithLength:sizeof(uint32_t)
                                       options:MTLResourceStorageModeShared];
        bHash[i] = [device newBufferWithLength:32
                                       options:MTLResourceStorageModeShared];
    }

    // -----------------------------------------------------------------------
    // run_search: scan [start_nonce, start_nonce + total_count) for a hash
    // <= target. Two MTLCommandBuffers are kept in flight (the just-encoded
    // one is dispatched while we wait on the previous one's result), which
    // saturates the GPU instead of leaving it idle during host bookkeeping.
    // Prints exactly one JSON line on stdout for the result.
    // -----------------------------------------------------------------------
    auto run_search = [&](const uint8_t header[80], const uint8_t target[32],
                          uint32_t start_nonce, uint64_t total_count) {
        uint32_t midstate[8] = {
            0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
            0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
        };
        sha256_compress_cpu(midstate, header);

        uint32_t tail_words[3];
        for (int i = 0; i < 3; i++) {
            tail_words[i] = ((uint32_t)header[64 + i*4]     << 24)
                          | ((uint32_t)header[64 + i*4 + 1] << 16)
                          | ((uint32_t)header[64 + i*4 + 2] <<  8)
                          | ((uint32_t)header[64 + i*4 + 3]);
        }

        uint32_t target_be[8];
        for (int i = 0; i < 8; i++) {
            target_be[i] = ((uint32_t)target[i*4]     << 24)
                         | ((uint32_t)target[i*4 + 1] << 16)
                         | ((uint32_t)target[i*4 + 2] <<  8)
                         | ((uint32_t)target[i*4 + 3]);
        }

        memcpy(bMid.contents,  midstate,   32);
        memcpy(bTail.contents, tail_words, 12);
        memcpy(bTgt.contents,  target_be,  32);

        double t0 = monotime();
        uint64_t committed = 0;
        uint64_t done = 0;
        int slot = 0;

        id<MTLCommandBuffer> prev_cb = nil;
        int prev_slot = -1;
        uint64_t prev_batch = 0;

        bool found = false;
        uint32_t found_nonce = 0;
        uint32_t found_hash[8] = {0};

        while (committed < total_count) {
            uint64_t left = total_count - committed;
            uint32_t batch = (uint32_t)((left < per_dispatch) ? left : per_dispatch);
            uint32_t batch_start = (uint32_t)(start_nonce + (uint32_t)committed);

            *(uint32_t*)bFlag[slot].contents = 0;

            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pipe];
            [enc setBuffer:bMid  offset:0 atIndex:0];
            [enc setBuffer:bTail offset:0 atIndex:1];
            [enc setBuffer:bTgt  offset:0 atIndex:2];
            [enc setBytes:&batch_start length:sizeof(uint32_t) atIndex:3];
            [enc setBuffer:bFlag[slot] offset:0 atIndex:4];
            [enc setBuffer:bNon[slot]  offset:0 atIndex:5];
            [enc setBuffer:bHash[slot] offset:0 atIndex:6];

            uint32_t tg_size = threadgroup;
            if (tg_size > batch) tg_size = batch;
            MTLSize grid = MTLSizeMake(batch, 1, 1);
            MTLSize tg   = MTLSizeMake(tg_size, 1, 1);
            [enc dispatchThreads:grid threadsPerThreadgroup:tg];
            [enc endEncoding];
            [cb commit];

            committed += batch;

            // After committing the new CB, drain the *previous* one. This
            // keeps two CBs in flight and means the GPU is processing while
            // the host is computing the next dispatch's parameters.
            if (prev_cb) {
                [prev_cb waitUntilCompleted];
                done += prev_batch;
                if (*(uint32_t*)bFlag[prev_slot].contents) {
                    found = true;
                    found_nonce = *(uint32_t*)bNon[prev_slot].contents;
                    memcpy(found_hash, bHash[prev_slot].contents, 32);
                    [cb waitUntilCompleted];      // don't leave the new one dangling
                    done += batch;
                    prev_cb = nil;
                    break;
                }
            }

            prev_cb = cb;
            prev_slot = slot;
            prev_batch = batch;
            slot = 1 - slot;
        }

        if (!found && prev_cb) {
            [prev_cb waitUntilCompleted];
            done += prev_batch;
            if (*(uint32_t*)bFlag[prev_slot].contents) {
                found = true;
                found_nonce = *(uint32_t*)bNon[prev_slot].contents;
                memcpy(found_hash, bHash[prev_slot].contents, 32);
            }
        }

        double dt = monotime() - t0;
        uint64_t hps = dt > 0 ? (uint64_t)((double)done / dt) : 0;
        if (found) {
            char hexHash[65]; hexHash[64] = 0;
            for (int i = 0; i < 8; i++) snprintf(hexHash + i*8, 9, "%08x", found_hash[i]);
            printf("{\"found\": true, \"nonce\": %u, \"hash\": \"%s\","
                   " \"checked\": %llu, \"elapsed_ms\": %.3f, \"hashrate\": %llu}\n",
                   found_nonce, hexHash,
                   (unsigned long long)done, dt * 1000.0,
                   (unsigned long long)hps);
        } else {
            printf("{\"found\": false, \"checked\": %llu, \"elapsed_ms\": %.3f, \"hashrate\": %llu}\n",
                   (unsigned long long)done, dt * 1000.0, (unsigned long long)hps);
        }
        fflush(stdout);
    };

    // -----------------------------------------------------------------------
    // Persistent mode: one job per stdin line, one result per stdout line.
    // -----------------------------------------------------------------------
    if (persistent) {
        char *line = NULL;
        size_t cap = 0;
        ssize_t n;
        while ((n = getline(&line, &cap, stdin)) > 0) {
            @autoreleasepool {
                NSData *d = [NSData dataWithBytes:line length:(NSUInteger)n];
                NSError *jerr = nil;
                id parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:&jerr];
                if (![parsed isKindOfClass:[NSDictionary class]]) {
                    printf("{\"error\": \"bad_json\"}\n"); fflush(stdout); continue;
                }
                NSDictionary *job = (NSDictionary *)parsed;
                id hp = job[@"header_prefix"];
                id tg = job[@"target"];
                id sn = job[@"start_nonce"];
                id cn = job[@"count"];
                if (![hp isKindOfClass:[NSString class]] ||
                    ![tg isKindOfClass:[NSString class]] ||
                    ![sn isKindOfClass:[NSNumber class]] ||
                    ![cn isKindOfClass:[NSNumber class]]) {
                    printf("{\"error\": \"missing_fields\"}\n"); fflush(stdout); continue;
                }
                uint8_t header[80], target[32];
                if (parseHex([(NSString*)hp UTF8String], header, 80) != 0 ||
                    parseHex([(NSString*)tg UTF8String], target, 32) != 0) {
                    printf("{\"error\": \"bad_hex\"}\n"); fflush(stdout); continue;
                }
                uint32_t sNonce = [(NSNumber*)sn unsignedIntValue];
                uint64_t count  = [(NSNumber*)cn unsignedLongLongValue];
                if (count == 0) {
                    printf("{\"error\": \"zero_count\"}\n"); fflush(stdout); continue;
                }
                run_search(header, target, sNonce, count);
            }
        }
        free(line);
        return 0;
    }

    // -----------------------------------------------------------------------
    // One-shot mode (back-compat with smoke tests / manual invocations).
    // -----------------------------------------------------------------------
    if (!hexHeader || !hexTarget) {
        fprintf(stderr,
                "metal_nonce_finder: --header-prefix and --target are required "
                "(or use --persistent)\n");
        return 2;
    }
    uint8_t header[80];
    if (parseHex(hexHeader, header, 80) != 0) {
        fprintf(stderr, "metal_nonce_finder: bad --header-prefix (need 160 hex chars)\n");
        return 2;
    }
    uint8_t target[32];
    if (parseHex(hexTarget, target, 32) != 0) {
        fprintf(stderr, "metal_nonce_finder: bad --target (need 64 hex chars)\n");
        return 2;
    }
    run_search(header, target, startNonce, totalCount);
    return 0;
}
}
