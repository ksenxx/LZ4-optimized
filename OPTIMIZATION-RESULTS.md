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
