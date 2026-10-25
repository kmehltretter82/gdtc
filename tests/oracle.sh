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

for source in "$ROOT"/tests/fixtures/*.dts; do
    name=$(basename "$source" .dts)
    case $name in
        invalid-*) continue ;;
    esac
    "$DTC" -I dts -O dtb -o "$BUILD_DIR/$name.dtb" "$source"
    "$DTC" -I dtb -O dts -o /dev/null "$BUILD_DIR/$name.dtb"
    echo "oracle ok: $name"
done

for source in "$GENERATED_DIR"/*.dts; do
    name=$(basename "$source" .dts)
    "$DTC" -I dts -O dtb -o "$BUILD_DIR/$name.dtb" "$source"
    "$DTC" -I dtb -O dts -o /dev/null "$BUILD_DIR/$name.dtb"
    echo "oracle ok: $name"
done

for source in "$ROOT"/tests/fixtures/invalid-*.dts; do
    name=$(basename "$source" .dts)
    rm -f "$BUILD_DIR/$name.dtb"
    if "$DTC" -I dts -O dtb -o "$BUILD_DIR/$name.dtb" "$source" \
            >"$BUILD_DIR/$name.stdout" 2>"$BUILD_DIR/$name.stderr"; then
        echo "oracle: upstream dtc unexpectedly accepted $name.dts" >&2
        exit 1
    fi
    echo "oracle reject: $name"
done
