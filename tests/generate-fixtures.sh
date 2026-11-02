#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

OUTPUT_DIR=$1
mkdir -p "$OUTPUT_DIR"

depth=${DEPTH:-128}
wide=${WIDE:-2048}

nested() {
    levels=$1
    printf '%s\n\n/ {\n' '/dts-v1/;'
    i=0
    while [ "$i" -lt "$levels" ]; do
        printf '%*slevel-%s {\n' "$((i * 2 + 4))" '' "$i"
        i=$((i + 1))
    done
    printf '%*svalue = <0x12345678>;\n' "$((levels * 2 + 4))" ''
    i=$levels
    while [ "$i" -gt 0 ]; do
        i=$((i - 1))
        printf '%*s};\n' "$((i * 2 + 4))" ''
    done
    printf '};\n'
}

parens() {
    count=$1
    printf '%s\n\n/ {\n    value = <' '/dts-v1/;'
    i=0
    while [ "$i" -lt "$count" ]; do printf '('; i=$((i + 1)); done
    printf '1'
    i=0
    while [ "$i" -lt "$count" ]; do printf ')'; i=$((i + 1)); done
    printf '>;\n};\n'
}

nested "$depth" >"$OUTPUT_DIR/generated-deep.dts"

{
    printf '%s\n\n/ {\n' '/dts-v1/;'
    i=0
    while [ "$i" -lt "$wide" ]; do
        printf '    node-%s { value = <%s>; };\n' "$i" "$i"
        i=$((i + 1))
    done
    printf '};\n'
} >"$OUTPUT_DIR/generated-wide.dts"

# dtc's bison parser holds at most 10000 states. 3329 nested nodes fit and
# 3330 exhaust it, as do 9988 parentheses. gdtc must agree on both sides of
# each limit, and report much deeper input as dtc does instead of
# overflowing its own native stack.
nested 3329 >"$OUTPUT_DIR/generated-stack-limit.dts"
nested 3330 >"$OUTPUT_DIR/generated-invalid-stack-depth.dts"
nested 20000 >"$OUTPUT_DIR/generated-invalid-deep-nesting.dts"
parens 9987 >"$OUTPUT_DIR/generated-paren-limit.dts"
parens 9988 >"$OUTPUT_DIR/generated-invalid-paren-depth.dts"
parens 100000 >"$OUTPUT_DIR/generated-invalid-deep-parens.dts"
