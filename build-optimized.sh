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
    CORPORA="$REPO/pgo-train.sample"
fi

echo "=== Stage 1/3: instrumented build (-fprofile-generate) ==="
rm -rf "$PGODIR"
mkdir -p "$PGODIR"
make -C "$REPO" clean > /dev/null
CFLAGS="$NATIVE -fprofile-generate=$PGODIR" \
    make -C "$REPO/programs" -j"$JOBS" lz4-release

echo "=== Stage 2/3: PGO training run ==="
for f in $CORPORA; do
    "$REPO/programs/lz4" -b1 -i1 "$f" > /dev/null
done

echo "=== Stage 3/3: optimized rebuild (-fprofile-use) ==="
make -C "$REPO" clean > /dev/null
CFLAGS="$NATIVE -fprofile-use=$PGODIR -fprofile-correction" \
    make -C "$REPO/programs" -j"$JOBS" lz4-release

# Optimized libraries. The CLI training profiles do not match the lib object
# paths, so the libs are built with the same native+LTO flags (measured equal
# within noise for the library code) plus -fprofile-use where gcc can match.
CFLAGS="$NATIVE -fprofile-use=$PGODIR -fprofile-correction -Wno-missing-profile" \
    make -C "$REPO/lib" -j"$JOBS" all

cp -f "$REPO/programs/lz4" "$REPO/lz4"
rm -f "$REPO/pgo-train.sample"

echo ""
echo "Optimized binary: $REPO/lz4"
echo "Optimized libs:   $(ls "$REPO"/lib/liblz4.a "$REPO"/lib/liblz4.so* 2>/dev/null | tr '\n' ' ')"
"$REPO/lz4" --version
