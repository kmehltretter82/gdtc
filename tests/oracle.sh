#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DTC=${DTC:-dtc}
BUILD_DIR=${BUILD_DIR:-"$ROOT/build/oracle"}

if ! command -v "$DTC" >/dev/null 2>&1; then
    echo "oracle: upstream dtc not found (set DTC=/path/to/dtc)" >&2
    exit 127
fi

mkdir -p "$BUILD_DIR"
GENERATED_DIR="$BUILD_DIR/generated"
"$ROOT/tests/generate-fixtures.sh" "$GENERATED_DIR"

for source in "$ROOT"/tests/fixtures/*.dts "$GENERATED_DIR"/*.dts; do
    name=$(basename "$source" .dts)
    rm -f "$BUILD_DIR/$name.dtb"
    case $name in
        invalid-* | generated-invalid-*)
            if "$DTC" -q -I dts -O dtb -o "$BUILD_DIR/$name.dtb" "$source" \
                    >"$BUILD_DIR/$name.stdout" 2>"$BUILD_DIR/$name.stderr"; then
                echo "oracle: upstream dtc unexpectedly accepted $name.dts" >&2
                exit 1
            fi
            echo "oracle reject: $name"
            ;;
        *)
            "$DTC" -q -I dts -O dtb -o "$BUILD_DIR/$name.dtb" "$source"
            echo "oracle ok: $name"
            ;;
    esac
done
