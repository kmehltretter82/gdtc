#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
GOOSE=${GOOSE:-goose}
DTC=${DTC:-dtc}
BUILD_DIR=${BUILD_DIR:-"$ROOT/build/test"}
ORACLE_DIR="$BUILD_DIR/oracle"
EXPECTED="$ROOT/tests/expected-errors.txt"
GOOSE_HOME=${GOOSE_HOME:-"$BUILD_DIR/goose-home"}
export GOOSE_HOME

if ! command -v "$DTC" >/dev/null 2>&1; then
    echo "tests: upstream dtc not found (set DTC=/path/to/dtc)" >&2
    exit 127
fi

BUILD_DIR="$ORACLE_DIR" DTC="$DTC" "$ROOT/tests/oracle.sh"

if ! command -v "$GOOSE" >/dev/null 2>&1; then
    echo "tests: Goose compiler not found (set GOOSE=/path/to/goose)" >&2
    exit 127
fi

mkdir -p "$BUILD_DIR"
"$GOOSE" check "$ROOT/src/gdtc.goose"
"$GOOSE" build -o "$BUILD_DIR/gdtc" "$ROOT/src/gdtc.goose"
"$GOOSE" build --debug -o "$BUILD_DIR/gdtc-debug" "$ROOT/src/gdtc.goose"

compare_source() {
    source=$1
    name=$(basename "$source" .dts)
    "$BUILD_DIR/gdtc" -I dts -O dtb -o "$BUILD_DIR/$name.got.dtb" "$source"
    if ! cmp "$ORACLE_DIR/$name.dtb" "$BUILD_DIR/$name.got.dtb"; then
        echo "tests: DTB differs for $name" >&2
        "$DTC" -I dtb -O dts -o "$BUILD_DIR/$name.ref.roundtrip.dts" "$ORACLE_DIR/$name.dtb" || true
        "$DTC" -I dtb -O dts -o "$BUILD_DIR/$name.got.roundtrip.dts" "$BUILD_DIR/$name.got.dtb" || true
        diff -u "$BUILD_DIR/$name.ref.roundtrip.dts" "$BUILD_DIR/$name.got.roundtrip.dts" || true
        exit 1
    fi
    # Wherever upstream dtc can read back its own blob, it must read ours.
    if "$DTC" -q -I dtb -O dts -o /dev/null "$ORACLE_DIR/$name.dtb" 2>/dev/null; then
        "$DTC" -q -I dtb -O dts -o /dev/null "$BUILD_DIR/$name.got.dtb"
    fi
    echo "ok: $name"
}

expect_failure() {
    source=$1
    name=$(basename "$source" .dts)
    output="$BUILD_DIR/$name.dtb"
    diagnostic=$(awk -F '\t' -v n="$name" '$1 == n { print $2; exit }' "$EXPECTED")
    if [ -z "$diagnostic" ]; then
        echo "tests: $name.dts has no entry in tests/expected-errors.txt" >&2
        exit 1
    fi

    rm -f "$output"
    if "$BUILD_DIR/gdtc-debug" -I dts -O dtb -o "$output" "$source" \
            >"$BUILD_DIR/$name.stdout" 2>"$BUILD_DIR/$name.stderr"; then
        echo "tests: $name.dts unexpectedly succeeded" >&2
        exit 1
    fi
    if [ -e "$output" ]; then
        echo "tests: failed compilation of $name.dts left an output file" >&2
        exit 1
    fi
    if ! grep -F -- "$diagnostic" "$BUILD_DIR/$name.stderr" >/dev/null; then
        echo "tests: $name.dts produced the wrong diagnostic" >&2
        cat "$BUILD_DIR/$name.stderr" >&2
        exit 1
    fi
    echo "ok: $name"
}

for source in "$ROOT"/tests/fixtures/*.dts "$ORACLE_DIR"/generated/*.dts; do
    case $(basename "$source" .dts) in
        invalid-* | generated-invalid-*) expect_failure "$source" ;;
        *) compare_source "$source" ;;
    esac
done

# Exercise the streaming path separately: input from stdin and binary output to
# stdout must be identical to both file mode and upstream dtc.
"$BUILD_DIR/gdtc" -I dts -O dtb - \
    <"$ROOT/tests/fixtures/basic.dts" >"$BUILD_DIR/basic.pipe.dtb"
cmp "$ORACLE_DIR/basic.dtb" "$BUILD_DIR/basic.pipe.dtb"
echo "ok: stdin-stdout"

"$BUILD_DIR/gdtc-debug" -I dts -O dtb -o "$BUILD_DIR/basic.debug.dtb" \
    "$ROOT/tests/fixtures/basic.dts"
cmp "$ORACLE_DIR/basic.dtb" "$BUILD_DIR/basic.debug.dtb"
echo "ok: debug-build"

# Sample prefixes of every positive fixture at roughly 16 points each. Under
# the checked debug build a prefix that dtc rejects must take the diagnostic
# path, never a bounds-check abort, and leave no output behind; a prefix that
# dtc accepts must compile to the same blob.
mkdir -p "$BUILD_DIR/truncation"
cut="$BUILD_DIR/truncation/input.dts"
for truncate_source in "$ROOT"/tests/fixtures/*.dts; do
    case $(basename "$truncate_source") in invalid-*) continue ;; esac
    truncate_size=$(wc -c <"$truncate_source" | tr -d ' ')
    truncate_step=$((truncate_size / 16 + 1))
    truncate_at=0
    while [ "$truncate_at" -lt "$truncate_size" ]; do
        dd if="$truncate_source" of="$cut" bs=1 count="$truncate_at" 2>/dev/null
        rm -f "$BUILD_DIR/truncation/output.dtb" "$BUILD_DIR/truncation/ref.dtb"
        if "$DTC" -q -I dts -O dtb -o "$BUILD_DIR/truncation/ref.dtb" "$cut" \
                >/dev/null 2>&1; then
            "$BUILD_DIR/gdtc-debug" -o "$BUILD_DIR/truncation/output.dtb" "$cut"
            if ! cmp -s "$BUILD_DIR/truncation/ref.dtb" "$BUILD_DIR/truncation/output.dtb"; then
                echo "tests: $truncate_source cut at byte $truncate_at differs from dtc" >&2
                exit 1
            fi
        else
            if "$BUILD_DIR/gdtc-debug" -o "$BUILD_DIR/truncation/output.dtb" "$cut" \
                    >"$BUILD_DIR/truncation/stdout" 2>"$BUILD_DIR/truncation/stderr"; then
                echo "tests: $truncate_source cut at byte $truncate_at unexpectedly succeeded" >&2
                exit 1
            fi
            if [ -e "$BUILD_DIR/truncation/output.dtb" ]; then
                echo "tests: $truncate_source cut at byte $truncate_at left an output file" >&2
                exit 1
            fi
            if ! grep -F "gdtc:" "$BUILD_DIR/truncation/stderr" >/dev/null; then
                echo "tests: $truncate_source cut at byte $truncate_at did not fail cleanly" >&2
                cat "$BUILD_DIR/truncation/stderr" >&2
                exit 1
            fi
        fi
        truncate_at=$((truncate_at + truncate_step))
    done
done
echo "ok: truncated-input sweep"
