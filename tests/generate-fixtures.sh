#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

OUTPUT_DIR=$1
mkdir -p "$OUTPUT_DIR"

depth=${DEPTH:-128}
wide=${WIDE:-2048}

{
    printf '%s\n\n/ {\n' '/dts-v1/;'
    i=0
    while [ "$i" -lt "$depth" ]; do
        printf '%*slevel-%s {\n' "$((i * 2 + 4))" '' "$i"
        i=$((i + 1))
    done
    printf '%*svalue = <0x12345678>;\n' "$((depth * 2 + 4))" ''
    i=$depth
    while [ "$i" -gt 0 ]; do
        i=$((i - 1))
        printf '%*s};\n' "$((i * 2 + 4))" ''
    done
    printf '};\n'
} >"$OUTPUT_DIR/generated-deep.dts"

{
    printf '%s\n\n/ {\n' '/dts-v1/;'
    i=0
    while [ "$i" -lt "$wide" ]; do
        printf '    node-%s { value = <%s>; };\n' "$i" "$i"
        i=$((i + 1))
    done
    printf '};\n'
} >"$OUTPUT_DIR/generated-wide.dts"
