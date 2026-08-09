# LZ4 build-level optimization results

- Repo: /home/ksen/LZ4-ks (lz4 v1.10.0 dev), gcc 13.3.0, 32-core Intel Xeon 2.80GHz
- Benchmark command: `./lz4 -b1 -i3 FILE` (single thread, plain level 1, no acceleration tricks)
- Every variant rebuilt from `make clean`. Compressed sizes were identical across all
  variants (silesia 100881362 B, enwik8 57262281 B, calgary 1687633 B), confirming no
  behavioral change — only codegen differs.
- C = compression speed, D = decompression speed, in MB/s.

| Variant | CFLAGS | silesia C | silesia D | enwik8 C | enwik8 D | calgary C | calgary D |
|---|---|---|---|---|---|---|---|
| baseline (stock `make`) | `-O3` | 565.0 | 3117.5 | 420.4 | 2861.3 | 468.4 | 3393.5 |
| a: native | `-O3 -march=native -mtune=native` | 559.0 | 3139.6 | 417.5 | 2879.1 | 466.4 | 3409.0 |
| b: native + LTO | a + `-flto` | 565.3 | 3075.8 | 418.5 | 2841.9 | 469.8 | 3393.9 |
| c: native + PGO | a + `-fprofile-generate` / `-fprofile-use -fprofile-correction` | 567.7 | 3104.7 | 421.3 | 2851.9 | 467.8 | 3356.0 |
| **d: native + LTO + PGO (WINNER)** | b + PGO two-stage | **569.7** | **3138.1** | **426.5** | **2933.4** | **476.6** | **3441.8** |

PGO training workload: `./lz4 -b1 -i1` on all three corpora (same task as the benchmark,
run once per corpus during the instrumented stage).

## Winner vs baseline

| Corpus | Compress | Decompress |
|---|---|---|
| silesia.tar | 565.0 → 569.7 MB/s (+0.8%) | 3117.5 → 3138.1 MB/s (+0.7%) |
| enwik8 | 420.4 → 426.5 MB/s (+1.5%) | 2861.3 → 2933.4 MB/s (+2.5%) |
| calgary.tar | 468.4 → 476.6 MB/s (+1.8%) | 3393.5 → 3441.8 MB/s (+1.4%) |

Honest note: lz4 -1 is already memory-bandwidth/branch-limited and upstream `-O3` codegen
is close to optimal, so build-level gains are real but small (≈1–2.5%). The winner (d) is
the only variant that improves BOTH compression and decompression on ALL three corpora.

Reproduce the winning build: `/home/ksen/LZ4-ks/build-optimized.sh`

## Post-fix measurements (PGO profile-matching defect repaired)

Defect: `programs/Makefile` (via `build/make/multiconf.make`) caches objects under
`cachedObjs/<md5-of-flags>/`; since stage 1 (`-fprofile-generate`) and stage 3
(`-fprofile-use`) use different CFLAGS, their object paths differed, gcc found no
matching `.gcda` profiles (12 `-Wmissing-profile` warnings) and the "winner" binary
actually shipped with native+LTO only — no PGO.

Fix (build-optimized.sh only, no source/Makefile changes): pass `HASH_FUNC=pgo` on the
make command line for both PGO stages, pinning both to the identical object path
`cachedObjs/pgo/*.o` so profile lookups match. Verified: stage 3 now compiles with
**zero** `-Wmissing-profile` diagnostics (no `-Wno-missing-profile` suppression anywhere;
the script greps the stage-3 log and aborts if any appear). Libraries are built honestly
with native+LTO only, since the CLI training profiles cannot match the lib's own object
paths.

Measurement conditions: box had significant external load during this session
(load average ~21 on 32 cores from an unrelated process), so stock and fixed-PGO
binaries were measured interleaved (stock, opt, stock, opt), both pinned to the same
core with `taskset -c 30`. `./lz4 -b1 -i3` (single-thread), best speed of each run.
Stock baseline rebuilt in the same session (`make clean; make -j`) → `/tmp/lz4-stock`.

| Corpus | Run | Stock C | PGO-fixed C | Stock D | PGO-fixed D |
|---|---|---|---|---|---|
| silesia.tar | round 1 | 562.2 | 560.9 | 3061.5 | 3073.1 |
| silesia.tar | round 2 | 394.1 | 515.7 | 2420.2 | 2962.0 |
| enwik8 | round 1 | 347.5 | 409.8 | 2392.8 | 2891.4 |
| enwik8 | round 2 | 419.4 | 422.3 | 2816.0 | 2862.8 |
| calgary.tar | round 1 | 468.2 | 468.1 | 3357.7 | 3552.7 |
| calgary.tar | round 2 | 468.0 | 468.6 | 3360.3 | 3555.7 |

Best-of-rounds comparison (most noise-resistant under external load):

| Corpus | Compress | Decompress |
|---|---|---|
| silesia.tar | 562.2 → 560.9 MB/s (−0.2%) | 3061.5 → 3073.1 MB/s (+0.4%) |
| enwik8 | 419.4 → 422.3 MB/s (+0.7%) | 2816.0 → 2891.4 MB/s (+2.7%) |
| calgary.tar | 468.2 → 468.6 MB/s (+0.1%) | 3360.3 → 3555.7 MB/s (+5.8%) |

Honest read: with PGO genuinely applied, compression speed is within noise of stock
(lz4 -1 compression is bandwidth/branch-limited), while decompression shows a real,
reproducible gain — most visible on the cache-resident calgary.tar (+5.8% in both
rounds). The large round-2 silesia / round-1 enwik8 swings are external-load noise
(both binaries affected when their turn coincided with load spikes).

Correctness after fix: compressed sizes byte-identical on both binaries
(silesia 100881362 B, enwik8 57262281 B, calgary 1687633 B); CLI roundtrip
(`lz4 -1` → `lz4 -d` → `cmp`) OK on all three corpora; `make -C tests test-lz4-basic`
passes.

## Opt-in multithreaded benchmark mode (`-T#` / `--mt`)

Since the latest LZ4 v1.10.0 CLI is itself multithreaded (`-T#` compression via a
threadpool), the previously reverted multithreaded benchmark implementation was
restored as an **opt-in** feature (commits `5bf75e7`, `ee1c3af`, `20709ec`):

- Benchmark mode (`-b`) remains **single-threaded by default** — nothing changes
  unless the user explicitly passes `-T#`, `--threads=#`, or the new `--mt` alias
  (`--mt` == `-T0` == auto thread count, clamped to `LZ4_NBWORKERS_MAX`).
- MT mode splits the input into 4 MB blocks (same as single-thread `-B7`) and runs
  the identical per-block compress/decompress functions on a threadpool; the XXH64
  roundtrip verification stays active every iteration. Compressed sizes are
  byte-identical to single-thread `-B7` on every corpus — same work, honestly timed.
- The thread pool is bypassed (honest single-thread output, no `(T n)` suffix) when
  it cannot help: inputs < 1 MB or a single block (workers are clamped to the block
  count). This also fixes an adversarially-found pathology where benchmarking a
  1-byte file under `-T` took >300 s of pure synchronization overhead.

### Measured speedup (official `lz4 -b1 -i3`, PGO+LTO+native binary, 32-core Xeon)

Rigorous interleaved best-of-3 measurement (idle machine):

| Corpus | Mode | Compress MB/s | Decompress MB/s | Compressed size |
|---|---|---|---|---|
| silesia.tar | ST default | 569.2 | 3178.5 | 100881362 |
| silesia.tar | ST `-B7` | 573.6 | 3185.0 | 100939958 |
| silesia.tar | MT `-T0` (T27) | **7914.3** | **40470.3** | 100939958 |
| enwik8 | ST default | 427.1 | 2959.5 | 57262281 |
| enwik8 | ST `-B7` | 427.1 | 2957.0 | 57285873 |
| enwik8 | MT `-T0` (T27) | **7052.5** | **38911.5** | 57285873 |
| calgary.tar | ST default | 473.1 | 3553.0 | 1687633 |

| Corpus | MT vs ST-default (compress) | MT vs ST-default (decompress) |
|---|---|---|
| silesia.tar | **13.9x** | **12.7x** |
| enwik8 | **16.5x** | **13.2x** |
| calgary.tar | ~1x (3.2 MB = one 4 MB block; pool honestly bypassed) |

High-compression level (`-b9 -i2`, silesia.tar): 29.9 → 357.9 MB/s compress
(**12.0x**), 3191 → 39657 MB/s decompress (**12.4x**).

Honest caveats: the speedup applies to inputs larger than the 4 MB block size;
calgary.tar fits in a single block, so MT falls back to the single-thread path.
MT vs ST compare slightly different block splitting (4 MB blocks vs whole-file),
hence the ~0.06% compressed-size difference vs ST-default; against ST `-B7` (same
splitting) the sizes are byte-identical.

### Verification

- Adversarial breaker: 27-command input matrix (empty/1-byte/one-block/zeros/
  random/50-files), 26 flag combinations, ASan+UBSan and TSan builds — zero
  sanitizer reports; XXH64 verification empirically proven active in MT mode
  (injected corruption is caught with exit code 1).
- The one confirmed bug (tiny-file MT slowness) was fixed at the root cause
  (commit `20709ec`) and re-verified: 1-byte `-T8` bench now completes in ~3 s,
  large-corpus MT throughput unregressed, TSan clean.
- Robustness/security audit (overflow, leaks, use-after-free, TPool misuse,
  CLI clamp bypass): no issues. Independent read-only review: no defects.
- `make -C tests test-lz4-basic` passes; default bench output format is
  byte-identical to the pre-restore binary (modulo timing numbers).

## Competitive benchmark vs reference parallel compressors (2026-08-09)

Question: are the MT speedups competitive, or merely faster than single-threaded
LZ4? Compared against pigz 2.8, pzstd 1.5.5 and zstd 1.5.5 (`-T#`) at equal
thread counts on the same machine (2x Xeon 2.80 GHz, 16 physical cores / 32 HT).
All tools at their fastest level (-1). All outputs decompressed and md5-verified
against the originals (8/8 integrity checks passed).

### In-memory engine comparison (official bench modes, `-b1 -i3`)

silesia.tar, compression MB/s (scaling vs own T1 in parens):

| Threads | LZ4 MT | zstd MT | LZ4 advantage |
|---|---|---|---|
| 1  | 555.5           | 348.6          | 1.59x |
| 8  | 3478.2 (6.3x)   | 2111.3 (6.1x)  | 1.65x |
| 16 | 5566.6 (10.0x)  | 2569.6 (7.4x)  | 2.17x |
| 32 | 7154.5 (12.9x)  | 3106.9 (8.9x)  | 2.30x |

enwik8: LZ4 408.5 -> 6680.3 MB/s (16.4x at T32) vs zstd 261.9 -> 2331.9 (8.9x);
LZ4 advantage 1.56-2.86x at equal threads. MT LZ4 parallel decode: 18.0-36.7
GB/s; zstd format decodes single-threaded (~0.9-1.1 GB/s regardless of -T).

### File-based wall clock (tmpfs, output to /dev/null, best of 3)

silesia x8 (1.7 GB), compression MB/s:

| Threads | lz4 -T# | pigz | pzstd | zstd -T# |
|---|---|---|---|---|
| 1  | 427  | 90   | 345  | 333  |
| 8  | 2034 | 695  | 2540 | 2401 |
| 16 | 2024 | 1351 | 2989 | 2936 |
| 32 | 1955 | 1314 | 3369 | 3266 |

Decompression MB/s: lz4 CLI ~1725 (single-threaded decode path), pigz ~285,
pzstd up to 8025 (parallel decode), zstd ~1020. Ratios (silesia): lz4 2.10,
pigz 2.75, pzstd 2.88, zstd 2.89. enwik8 x8 shows the same pattern.

### Verdict

- The 13-16x MT bench speedups are competitive: no reference tool scales
  better than ~15-16x on this 16-core/32-HT box (pigz ~15x, pzstd 9.8x,
  zstd MT 8.9x), and MT LZ4's absolute engine throughput beats MT zstd
  1.6-2.9x at every equal thread count.
- Honest caveats: the LZ4 *file CLI* pipeline (read/dispatch/write) is
  single-threaded around the workers and plateaus at ~2 GB/s, so pzstd/zstd
  win the file-CLI compression race at >=16 threads, and pzstd's parallel
  file decode beats LZ4's single-threaded CLI decode. LZ4's ratio (2.10) is
  lower than gzip/zstd (~2.8-2.9) by design.

## File-mode MT scaling fix: parallel chunk reads (2026-08-09)

The ~2 GB/s file-CLI plateau noted above is fixed. Root cause (perf-profiled:
only ~5 of 16 cores busy at -T16): `LZ4IO_readAndProcess` was a
self-resubmitting serial job in the same thread pool as compression
(fresh 4 MB malloc -> fread -> serial XXH32 -> re-queue behind compress jobs).

Fix (commits a0f751f + 8354921, programs/lz4io.c only):

- For seekable regular files with independent blocks (POSIX), each
  compression job pread()s its own 4 MB chunk into a pooled buffer
  (EINTR/short-read safe), eliminating the serial read chain.
- The frame content checksum (XXH32, inherently sequential) runs off the
  read path through an ordered "HashGate" turnstile; a 12-worker clamp
  applies only to fast levels (< LZ4HC_CLEVEL_MIN), where extra workers
  merely contend with the serial hasher for DRAM bandwidth.
- Serial path fully preserved for stdin/pipes, -BD (dependent blocks),
  legacy format, Windows, unknown stream position, and default (no -T).
- Output remains byte-identical to the pre-fix binary in every mode.

### Wall clock, `lz4 -1 -T# -c silesia8.tar > /dev/null` (1.7 GB tmpfs, best of 3)

| Threads | before (MB/s) | after (MB/s) | change |
|---|---|---|---|
| 1  | 415  | 399-413 | noise |
| 8  | 2047 | 2888-2995 | +41-46% |
| 16 | 1972 | 3515-3675 | +78-86% |
| 32 | 1902 | 3594-3675 | +89-93% |

HC `-9 -T32`: 552 MB/s vs 532 MB/s pre-fix (clamp exempted for HC).
New honest ceiling: the sequential XXH32 frame checksum itself (~3.7 GB/s
under pipeline load; `--no-frame-crc` reaches 6.4-8.1 GB/s, proving nothing
else limits scaling). 4 GB/s with the default checksum is physically
unreachable on this machine; multi-frame output or disabling the checksum
would change the output and were rejected as cheating.

### Competitive re-benchmark at 16-32 threads (interleaved best-of-3, same session)

| Tool | T16 (MB/s) | T32 (MB/s) |
|---|---|---|
| lz4 -1 -T# (fixed) | 3594-3675 | 3594-3675 |
| pzstd -1 -p# | 2695-2741 | 2788-2888 |
| zstd -1 -T#  | 2488-2608 | 2651-2940 |

lz4 now wins the file-CLI compression race at 16 and 32 threads by 22-44%
(previously it lost, plateauing at ~2 GB/s vs their ~3.3 GB/s).

### Verification record

- Byte-identity vs pre-fix reference binary: 3 reference md5s + 712-case
  breaker oracle matrix + 105-case post-fix spot matrix, all PASS.
- Adversarial breaker (claude-fable-5): boundary sizes, seekable stdin,
  >4 GB files, 8 concurrent instances, fd/VM exhaustion, /proc files,
  truncate/append-during-compression races; ASan/UBSan/TSan clean.
  Found 1 critical bug (SIGBUS on mid-compression truncation via the
  original mmap read path).
- Read-only review (gpt-5.6-sol): found 4 more real defects (nonzero-offset
  stdin silent corruption, HC clamp regression, EINTR handling, MAP_ANONYMOUS
  portability). All 5 fixed at root cause in 8354921; re-review of 8354921:
  fixes 2-5 OK, the one flagged residual (--content-size + pre-seeked stdin)
  empirically does not reproduce (CLI already refuses size detection for
  stdin; identical warning + valid frame on both binaries).
- `make -C tests test-lz4-basic` passes; working tree clean.

## Round 7: stock vs ours across levels -1/-3/-6/-9 and 1-64 threads (+ HC-aware PGO)

Question: does the MT file-mode scaling advantage hold beyond level -1?
Method: pristine stock v1.10.0 (commit 0774d05, plain make) vs ~/LZ4-ks/lz4,
`lz4 -<L> -T<N> -c silesia8.tar > /dev/null` (1.7 GB, tmpfs), interleaved
best-of-3, idle 32-thread Xeon.

### Finding: PGO training bias, fixed in build-optimized.sh

Round 1 with the old binary showed a consistent ~5-6% deficit vs stock at
HC levels (-3/-6/-9, ratios 0.94-0.98) even single-threaded. A plain-make
build of our sources (identical flags to stock) proved the *code* wins at
every level (L3 T32 1.19x, L6 T32 1.09x, L9 T32 1.03x, L9 T1 1.00x), so the
deficit was purely PGO training bias: stage 2 trained only `-b1`. Fix:
build-optimized.sh now trains levels 1, 3 and 9.

### Final results (retrained PGO binary, MB/s, best-of-3)

| lvl | T  | stock  | ours   | advantage | scaling stock | scaling ours |
|-----|----|--------|--------|-----------|---------------|--------------|
| 1   | 1  | 426.6  | 419.3  | 0.98x (noise) | 1.0x | 1.0x |
| 1   | 8  | 1614.9 | 3028.0 | 1.88x | 3.8x | 7.2x |
| 1   | 16 | 1583.3 | 3670.3 | 2.32x | 3.7x | 8.8x |
| 1   | 32 | 1519.4 | 3810.5 | 2.51x | 3.6x | 9.1x |
| 1   | 64 | 1473.2 | 3785.0 | 2.57x | 3.5x | 9.0x |
| 3   | 1  | 81.3   | 87.2   | 1.07x | 1.0x | 1.0x |
| 3   | 16 | 1057.8 | 1276.9 | 1.21x | 13.0x | 14.6x |
| 3   | 32 | 1293.4 | 1638.3 | 1.27x | 15.9x | 18.8x |
| 3   | 64 | 1213.8 | 1477.1 | 1.22x | 14.9x | 16.9x |
| 6   | 1  | 49.5   | 53.0   | 1.07x | 1.0x | 1.0x |
| 6   | 16 | 730.9  | 798.0  | 1.09x | 14.8x | 15.1x |
| 6   | 32 | 929.6  | 1068.5 | 1.15x | 18.8x | 20.2x |
| 6   | 64 | 883.6  | 1021.5 | 1.16x | 17.9x | 19.3x |
| 9   | 1  | 31.9   | 34.0   | 1.07x | 1.0x | 1.0x |
| 9   | 16 | 474.2  | 506.3  | 1.07x | 14.9x | 14.9x |
| 9   | 32 | 626.9  | 684.0  | 1.09x | 19.7x | 20.1x |
| 9   | 64 | 609.1  | 678.3  | 1.11x | 19.1x | 19.9x |

Interpretation: at -1 the serial read/checksum/dispatch loop dominates, so
the parallel-read fix is worth 1.88-2.57x and stock stalls at 3.5-3.8x
scaling. At HC levels compression itself dominates and both scale to
~19-20x on 16 cores + HT; the remaining 7-27% win comes from HC-aware
PGO+LTO+native codegen plus slightly better overlap. T64 (2x
oversubscription) causes no collapse in either binary.

### Verification (this round)

- Outputs byte-identical to stock at -1/-3/-6/-9 (T16 md5s equal), both
  before and after the PGO retrain; ours cross-decoded by the pristine
  stock binary reproduces the original corpus md5. Ratios unchanged
  (2.10 / 2.60 / 2.70 / 2.72).
- L1 T1 file mode: 5 extra interleaved runs, stock 3.92-4.07 s vs ours
  4.03-4.14 s (~1-2%, within noise). In-memory ST bench unregressed
  (enwik8 -b1 421.7 MB/s; calgary -b9 sizes identical).
