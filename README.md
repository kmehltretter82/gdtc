# gdtc

`gdtc` is an experimental, memory-safe implementation of the Device Tree
Compiler in [Goose](https://aardappel.github.io/goose/). Its primary purpose is
to verify Goose on a real systems-programming workload with an existing,
well-tested compatibility oracle.

This is not yet a replacement for upstream `dtc`. The current executable is the
first vertical slice: it parses a useful subset of Device Tree Source and emits
a version 17 flattened device tree blob.

## Current support

- `/dts-v1/;` source files
- nested nodes, including unit addresses
- boolean properties
- quoted strings and string lists
- cell lists with decimal, hexadecimal, octal, and character values
- byte arrays
- 64-bit `/memreserve/` entries
- multiple labels per node and `&label`/`&{/absolute/path}` references in
  32-bit cell lists
- explicit `phandle` and `linux,phandle` properties, including validation and
  collision-free automatic allocation
- character literals and `/bits/ 8`, `16`, `32`, and `64` cell widths
- 64-bit unary, arithmetic, shift, comparison, bitwise, logical, and ternary
  expressions with `dtc` precedence and wrapping behavior
- repeated `/ { ... };` definitions and `&label { ... };` node merges
- absolute `&{/node/path} { ... };` merge targets
- `/delete-property/` and `/delete-node/` within merge fragments, plus top-level
  `/delete-node/ &label;` and `/delete-node/ &{/absolute/path};`
- `//` and `/* ... */` comments
- `-I dts`, `-O dtb`, `-o FILE`, input files, and standard input/output
- deterministic DTB output compatible with upstream `dtc`

Labels on properties or values, includes, `/incbin/`, overlays,
decompilation, and the upstream warning/check system remain to be implemented.
The compatibility gates and planned order are recorded in
[`docs/verification.md`](docs/verification.md).

## Building

Install the verified [Goose v2026.3 release](https://github.com/aardappel/goose/releases/tag/v2026.3),
then run:

```sh
make build
```

The Makefile automatically uses `.goose-toolchain/goose` when that executable
exists, and otherwise looks for `goose` on `PATH`. An explicit compiler can be
selected with `make GOOSE=/path/to/goose build`.

This creates `build/gdtc`. To compile a tree:

```sh
build/gdtc -I dts -O dtb -o board.dtb board.dts
```

## Testing

The conformance harness requires both `goose` and upstream `dtc`:

```sh
make test
```

Without Goose installed, the upstream fixture contract can still be checked:

```sh
make oracle
```

For every supported fixture, it typechecks and builds optimized and checked
debug versions of the Goose program,
compiles the DTS with both implementations, compares the DTBs byte-for-byte,
and asks upstream `dtc` to parse the Goose-produced blob.

## Why this shape tests Goose

The parsed document is held in one grow-only pool of variable-size enum values.
Each node or property occupies only its own payload size, owns its name/value
inline, and links to siblings and children with four-byte references relative
to the `items` pool. Goose checks that these links can only target that pool,
while growing it does not invalidate them. The current CLI uses one
process-lifetime pool; a later batch mode will move that pool into a per-document
scope to measure constant-time reclamation directly.

Forward label/path references are kept in a second packed, variable-size fixup
array whose typed references point into the growing AST pool. A final resolution
pass validates explicit phandles, discards fixups from overwritten tree data,
and patches only the properties that survive merging and deletion.

This deliberately exercises Goose's unusual strengths rather than copying the
allocation structure of the C implementation.

## License

GPL-2.0-or-later. See [`LICENSE`](LICENSE).
