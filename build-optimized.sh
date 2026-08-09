#!/bin/bash
# build-optimized.sh — reproduce the winning speed-optimized build of lz4.
#
# Winning configuration (measured with `./lz4 -b1 -i3` on silesia.tar, enwik8,
# calgary.tar): -O3 -march=native -mtune=native -flto + gcc PGO (two-stage:
# -fprofile-generate, train on the three corpora, rebuild with -fprofile-use).
# See /home/ksen/LZ4-ks-bench/results-buildopt.md for all measured numbers.
#
# No .c/.h source files and no Makefiles are modified: all flags are injected
# through the CFLAGS environment variable, which programs/Makefile and
# lib/Makefile fold into USERCFLAGS and also use at link time.
#
# PGO profile matching: build/make/multiconf.make caches objects under
# cachedObjs/<md5-of-flags>/, and gcc names .gcda files after the object
# path.  Stage 1 (-fprofile-generate) and stage 3 (-fprofile-use) use
# different CFLAGS, hence different hashes and object paths, so stage 3
# would find no profiles (12 -Wmissing-profile warnings, no PGO applied).
# Fix: override the makefile's HASH_FUNC variable on the command line
# (make ... HASH_FUNC=pgo) so both stages compile at the identical object
# path cachedObjs/pgo/*.o and the .gcda lookups match.  The script verifies
# this by requiring zero missing-profile diagnostics in the stage-3 log.
#
# Output: optimized CLI at /home/ksen/LZ4-ks/lz4 (copied from programs/lz4)
#         optimized libs (liblz4.a, liblz4.so*) in /home/ksen/LZ4-ks/lib
set -eu

REPO="$(cd "$(dirname "$0")" && pwd)"
NATIVE="-O3 -march=native -mtune=native -flto"
PGODIR="$REPO/pgo-profile-data"
JOBS="$(nproc 2>/dev/null || echo 4)"

# Training corpora for PGO. Fall back to a generated sample if missing.
CORPORA=""
for f in /home/ksen/LZ4-ks-bench/silesia.tar \
         /home/ksen/LZ4-ks-bench/enwik8 \
         /home/ksen/LZ4-ks-bench/calgary.tar; do
    [ -f "$f" ] && CORPORA="$CORPORA $f"
done
if [ -z "$CORPORA" ]; then
    echo "WARNING: benchmark corpora not found; training PGO on /usr/bin/* sample"
    cat /usr/bin/* 2>/dev/null | head -c 50000000 > "$REPO/pgo-train.sample" || true
    # Hardening: guarantee a non-empty training sample (an empty sample would make
    # stage 2 exit with `Error 12: no data to bench` and abort under `set -eu`).
    if [ ! -s "$REPO/pgo-train.sample" ]; then
        echo "WARNING: /usr/bin sample empty; using a self-generated data sample"
        # Deterministic 16 MB mixed-content sample, always available.
        { cat "$REPO"/README.md "$REPO"/lib/*.c "$REPO"/lib/*.h "$REPO"/programs/*.c 2>/dev/null; } \
            | head -c 16000000 > "$REPO/pgo-train.sample" || true
    fi
    if [ ! -s "$REPO/pgo-train.sample" ]; then
        # Absolute last resort: still non-empty so the bench never fails.
        printf 'lz4 pgo training fallback sample\n' > "$REPO/pgo-train.sample"
    fi
    CORPORA="$REPO/pgo-train.sample"
fi

echo "=== Stage 1/3: instrumented build (-fprofile-generate) ==="
rm -rf "$PGODIR"
mkdir -p "$PGODIR"
make -C "$REPO" clean > /dev/null
# HASH_FUNC=pgo pins the object cache directory to cachedObjs/pgo/ for both
# PGO stages so the .gcda file names (derived from object paths) match.
CFLAGS="$NATIVE -fprofile-generate=$PGODIR" \
    make -C "$REPO/programs" -j"$JOBS" lz4-release HASH_FUNC=pgo

echo "=== Stage 2/3: PGO training run ==="
for f in $CORPORA; do
    "$REPO/programs/lz4" -b1 -i1 "$f" > /dev/null
done

echo "=== Stage 3/3: optimized rebuild (-fprofile-use) ==="
make -C "$REPO" clean > /dev/null
STAGE3_LOG="$REPO/stage3-build.log"
CFLAGS="$NATIVE -fprofile-use=$PGODIR -fprofile-correction" \
    make -C "$REPO/programs" -j"$JOBS" lz4-release HASH_FUNC=pgo 2>&1 \
    | tee "$STAGE3_LOG"
if grep -q "missing-profile" "$STAGE3_LOG"; then
    echo "ERROR: stage 3 emitted -Wmissing-profile diagnostics; PGO profiles" >&2
    echo "did not match the stage-3 object paths. Aborting." >&2
    exit 1
fi
echo "PGO verified: zero -Wmissing-profile diagnostics in stage 3."
rm -f "$STAGE3_LOG"

# Libraries: the CLI training profiles are named after the CLI object paths
# and cannot match the lib build's own object paths, so the libraries get no
# PGO (training them would require an instrumented library consumer).  They
# are built honestly with native+LTO only.
CFLAGS="$NATIVE" make -C "$REPO/lib" -j"$JOBS" all

cp -f "$REPO/programs/lz4" "$REPO/lz4"
rm -f "$REPO/pgo-train.sample"
rm -rf "$PGODIR"

echo ""
echo "Optimized binary: $REPO/lz4"
echo "Optimized libs:   $(ls "$REPO"/lib/liblz4.a "$REPO"/lib/liblz4.so* 2>/dev/null | tr '\n' ' ')"
"$REPO/lz4" --version
