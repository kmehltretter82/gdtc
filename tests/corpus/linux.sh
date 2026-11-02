#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Stage 6 corpus qualification against a pinned Linux release: preprocess
# every arch/*/boot/dts/**/*.dts the way the kernel's build does, compile the
# result with upstream dtc and with gdtc, and record one line per file.
#
#   tests/corpus/linux.sh            # uses build/gdtc and dtc from PATH
#   GDTC=... DTC=... JOBS=8 tests/corpus/linux.sh
#
# Writes $CORPUS_DIR/results.tsv (the comparison log) and, with
# UPDATE_RESULTS=1, copies it to tests/corpus/linux-$LINUX_TAG.tsv and
# regenerates docs/corpus.md.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
LINUX_TAG=v7.3
LINUX_COMMIT=c03c1a14507dfaf8b856c2608f9ac216021fc222
LINUX_URL=${LINUX_URL:-https://github.com/torvalds/linux.git}
CORPUS_DIR=${CORPUS_DIR:-"$ROOT/build/corpus"}
GDTC=${GDTC:-"$ROOT/build/gdtc"}
DTC=${DTC:-dtc}
HOSTCC=${HOSTCC:-gcc}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
LINUX="$CORPUS_DIR/linux"

for tool in "$DTC" "$HOSTCC" git python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "corpus: $tool not found" >&2
        exit 127
    fi
done
if [ ! -x "$GDTC" ]; then
    echo "corpus: $GDTC not built (run make build)" >&2
    exit 127
fi

# A shallow, blobless clone with only the device tree sources, the bindings
# headers they include, and the include-prefixes symlink farm the kernel's
# cpp invocation searches.
if [ ! -d "$LINUX/.git" ]; then
    mkdir -p "$CORPUS_DIR"
    git clone --quiet --depth 1 --branch "$LINUX_TAG" --filter=blob:none \
        --no-checkout "$LINUX_URL" "$LINUX"
    git -C "$LINUX" sparse-checkout init --no-cone
    printf '%s\n' '/arch/*/boot/dts/' '/include/dt-bindings/' \
        '/scripts/dtc/include-prefixes/' >"$LINUX/.git/info/sparse-checkout"
    git -C "$LINUX" checkout --quiet "$LINUX_TAG"
    # Some binding headers are symlinks into include/uapi. Check out the
    # targets of every dangling symlink, once.
    (cd "$LINUX" && find arch/*/boot/dts include/dt-bindings \
            scripts/dtc/include-prefixes -type l) | while read -r link; do
        target=$(realpath -m "$LINUX/$link")
        [ -e "$target" ] || printf '/%s\n' "${target#"$LINUX"/}"
    done | LC_ALL=C sort -u >>"$LINUX/.git/info/sparse-checkout"
    git -C "$LINUX" read-tree -mu HEAD
fi
head=$(git -C "$LINUX" rev-parse HEAD)
if [ "$head" != "$LINUX_COMMIT" ]; then
    echo "corpus: $LINUX is at $head, expected $LINUX_TAG ($LINUX_COMMIT)" >&2
    exit 1
fi

WORK="$CORPUS_DIR/work"
rm -rf "$WORK"
mkdir -p "$WORK/lines"
(cd "$LINUX" && find arch -path 'arch/*/boot/dts/*' -name '*.dts' | LC_ALL=C sort) \
    >"$CORPUS_DIR/files.txt"
echo "corpus: $(wc -l <"$CORPUS_DIR/files.txt" | tr -d ' ') files from Linux $LINUX_TAG," \
    "$($DTC --version | head -n 1), $JOBS jobs" >&2

export LINUX WORK GDTC DTC HOSTCC
xargs -P "$JOBS" -n 16 "$ROOT/tests/corpus/compare-one.sh" <"$CORPUS_DIR/files.txt"

{
    printf 'file\tclass\tdtc\tgdtc\tmissing\tdtc_sha256\tgdtc_sha256\tdetail\n'
    LC_ALL=C sort "$WORK"/lines/*.tsv
} >"$CORPUS_DIR/results.tsv"

python3 -I "$ROOT/tests/corpus/summarize.py" "$CORPUS_DIR/results.tsv" \
    "$LINUX_TAG" "$LINUX_COMMIT" "$($DTC --version | head -n 1)" >"$CORPUS_DIR/corpus.md"
if [ "${UPDATE_RESULTS:-0}" = 1 ]; then
    cp "$CORPUS_DIR/results.tsv" "$ROOT/tests/corpus/linux-$LINUX_TAG.tsv"
    cp "$CORPUS_DIR/corpus.md" "$ROOT/docs/corpus.md"
fi
sed -n '/^## Summary/,/^## /p' "$CORPUS_DIR/corpus.md" | sed '$d'
