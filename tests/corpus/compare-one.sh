#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Compile Linux device tree sources with dtc and gdtc and classify each one.
# Called by linux.sh with LINUX, WORK, GDTC, DTC and HOSTCC in the
# environment and paths relative to $LINUX as arguments.
set -u

INC="$LINUX/scripts/dtc/include-prefixes"
for rel in "$@"; do
    key=$(printf '%s' "$rel" | tr '/' '_')
    dir="$WORK/$key"
    mkdir -p "$dir"
    src="$LINUX/$rel"
    pre="$dir/pre.dts"

    # scripts/Makefile.dtbs: dtc_cpp_flags and cmd_dtc, minus the
    # dependency file and the warning-only -W flags.
    if ! "$HOSTCC" -E -nostdinc -I "$INC" -undef -D__DTS__ \
            -x assembler-with-cpp -o "$pre" "$src" 2>"$dir/cpp.err"; then
        detail=$(head -n 1 "$dir/cpp.err" | tr '\t' ' ' | cut -c1-200)
        printf '%s\tcpp-error\t-\t-\t-\t-\t-\t%s\n' "$rel" "$detail" >"$WORK/lines/$key.tsv"
        rm -rf "$dir"
        continue
    fi
    srcdir=$(dirname "$src")

    "$DTC" -q -I dts -O dtb -o "$dir/dtc.dtb" -i "$srcdir" -i "$INC" "$pre" \
        >/dev/null 2>"$dir/dtc.err"
    dtc_rc=$?
    "$GDTC" -q -I dts -O dtb -o "$dir/gdtc.dtb" -i "$srcdir" -i "$INC" "$pre" \
        >/dev/null 2>"$dir/gdtc.err"
    gdtc_rc=$?

    dtc_sum=-
    gdtc_sum=-
    [ "$dtc_rc" = 0 ] && dtc_sum=$(sha256sum <"$dir/dtc.dtb" | cut -c1-64)
    [ "$gdtc_rc" = 0 ] && gdtc_sum=$(sha256sum <"$dir/gdtc.dtb" | cut -c1-64)

    missing=-
    detail=-
    if [ "$gdtc_rc" != 0 ]; then
        # List every unsupported construct, not just the first.
        report=$("$GDTC" --report-unsupported -i "$srcdir" -i "$INC" "$pre" 2>/dev/null |
            sed -n 's/^unsupported: *//p' | tr ' ' ',')
        [ -n "$report" ] && missing=$report
        detail=$(grep -v '^$' "$dir/gdtc.err" | head -n 1 | tr '\t' ' ' | cut -c1-200)
    elif [ "$dtc_rc" != 0 ]; then
        detail=$(grep -v '^$' "$dir/dtc.err" | grep -iv '^warning' | head -n 1 | tr '\t' ' ' | cut -c1-200)
    fi

    if [ "$dtc_rc" = 0 ] && [ "$gdtc_rc" = 0 ]; then
        if cmp -s "$dir/dtc.dtb" "$dir/gdtc.dtb"; then class=identical; else class=different; fi
    elif [ "$dtc_rc" != 0 ] && [ "$gdtc_rc" != 0 ]; then
        class=both-reject
        detail=$(grep -v '^$' "$dir/dtc.err" | grep -iv '^warning' | head -n 1 | tr '\t' ' ' | cut -c1-200)
    elif [ "$dtc_rc" != 0 ]; then
        class=gdtc-accepts
    elif [ "$missing" != - ]; then
        class=unsupported
    else
        class=gdtc-error
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$class" "$dtc_rc" "$gdtc_rc" \
        "$missing" "$dtc_sum" "$gdtc_sum" "$detail" >"$WORK/lines/$key.tsv"
    case $class in
        identical | unsupported | both-reject | cpp-error) rm -rf "$dir" ;;
    esac
done
