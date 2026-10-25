#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
GOOSE=${GOOSE:-goose}
DTC=${DTC:-dtc}
BUILD_DIR=${BUILD_DIR:-"$ROOT/build/test"}
ORACLE_DIR="$BUILD_DIR/oracle"
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
        "$DTC" -I dtb -O dts -o "$BUILD_DIR/$name.ref.roundtrip.dts" "$ORACLE_DIR/$name.dtb"
        "$DTC" -I dtb -O dts -o "$BUILD_DIR/$name.got.roundtrip.dts" "$BUILD_DIR/$name.got.dtb"
        diff -u "$BUILD_DIR/$name.ref.roundtrip.dts" "$BUILD_DIR/$name.got.roundtrip.dts" || true
        exit 1
    fi
    "$DTC" -I dtb -O dts -o /dev/null "$BUILD_DIR/$name.got.dtb"
    echo "ok: $name"
}

for source in "$ROOT"/tests/fixtures/*.dts; do
    name=$(basename "$source" .dts)
    case $name in
        invalid-*) continue ;;
    esac
    compare_source "$source"
done

for source in "$ORACLE_DIR"/generated/*.dts; do
    compare_source "$source"
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

# Sample every prefix of a valid source at roughly 32 points. Each truncated
# input must take the checked parser-error path, not abort on a bounds check or
# leave a partial DTB behind.
truncate_source="$ROOT/tests/fixtures/basic.dts"
truncate_size=$(wc -c <"$truncate_source" | tr -d ' ')
truncate_step=$((truncate_size / 32 + 1))
truncate_at=0
mkdir -p "$BUILD_DIR/truncation"
while [ "$truncate_at" -lt "$truncate_size" ]; do
    dd if="$truncate_source" of="$BUILD_DIR/truncation/input.dts" \
        bs=1 count="$truncate_at" 2>/dev/null
    rm -f "$BUILD_DIR/truncation/output.dtb"
    if "$BUILD_DIR/gdtc-debug" -o "$BUILD_DIR/truncation/output.dtb" \
            "$BUILD_DIR/truncation/input.dts" \
            >"$BUILD_DIR/truncation/stdout" 2>"$BUILD_DIR/truncation/stderr"; then
        echo "tests: truncated input at byte $truncate_at unexpectedly succeeded" >&2
        exit 1
    fi
    if [ -e "$BUILD_DIR/truncation/output.dtb" ]; then
        echo "tests: truncated input at byte $truncate_at left an output file" >&2
        exit 1
    fi
    if ! grep -F "gdtc:" "$BUILD_DIR/truncation/stderr" >/dev/null; then
        echo "tests: truncated input at byte $truncate_at did not fail cleanly" >&2
        cat "$BUILD_DIR/truncation/stderr" >&2
        exit 1
    fi
    truncate_at=$((truncate_at + truncate_step))
done
echo "ok: truncated-input sweep"

expect_failure() {
    name=$1
    diagnostic=$2
    source="$ROOT/tests/fixtures/$name.dts"
    output="$BUILD_DIR/$name.dtb"

    rm -f "$output"
    if "$BUILD_DIR/gdtc" -I dts -O dtb -o "$output" "$source" \
            >"$BUILD_DIR/$name.stdout" 2>"$BUILD_DIR/$name.stderr"; then
        echo "tests: $name.dts unexpectedly succeeded" >&2
        exit 1
    fi
    if [ -e "$output" ]; then
        echo "tests: failed compilation of $name.dts left an output file" >&2
        exit 1
    fi
    if ! grep -F "$diagnostic" "$BUILD_DIR/$name.stderr" >/dev/null; then
        echo "tests: $name.dts produced the wrong diagnostic" >&2
        cat "$BUILD_DIR/$name.stderr" >&2
        exit 1
    fi
    echo "ok: $name"
}

expect_failure invalid-property-order "properties must precede child nodes"
expect_failure invalid-undefined-label "undefined label missing"
expect_failure invalid-byte-array "expected a two-digit byte"
expect_failure invalid-cell-width "/bits/ width must be 8, 16, 32, or 64"
expect_failure invalid-duplicate-label "duplicate label same"
expect_failure invalid-duplicate-phandle "duplicate phandle 1"
expect_failure invalid-delete-target "delete target not found: missing"
expect_failure invalid-division-by-zero "division by zero in integer expression"
expect_failure invalid-integer-overflow "unsigned integer is outside 64 bits"
expect_failure invalid-mismatched-phandle "mismatching phandle and linux,phandle properties"
expect_failure invalid-merge-target "merge target not found: missing"
expect_failure invalid-path-reference "undefined path /missing"
expect_failure invalid-phandle-length "phandle property must contain exactly one cell"
expect_failure invalid-phandle-value "invalid value in phandle property"
expect_failure invalid-unterminated-comment "unterminated block comment"
