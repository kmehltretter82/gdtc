# gdtc

`gdtc` is an experimental, memory-safe implementation of the Device Tree
Compiler in [Goose](https://aardappel.github.io/goose/). Its primary purpose is
to verify Goose on a real systems-programming workload with an existing,
well-tested compatibility oracle.

This is not yet a replacement for upstream `dtc`. The current executable is the
first vertical slice: it parses a useful subset of Device Tree Source and emits
a version 17 flattened device tree blob.

## Current support

- `/dts-v1/;` source files, including repeated headers
- dtc's lexer exactly: start conditions, longest-match tokenization, escape
  decoding, integer literal suffixes, and dtc's treatment of a NUL or
  non-ASCII byte outside a string as the end of input
- nested nodes, unit addresses, escaped names, boolean properties, strings,
  string lists, cell lists, byte strings, character literals, and
  `/bits/ 8`, `16`, `32`, and `64` cell widths
- 64-bit `/memreserve/` entries
- parenthesized 64-bit integer expressions with dtc's precedence and wrapping
- multiple labels per node, `&label` and `&{/absolute/path}` phandle
  references, and explicit `phandle` and `linux,phandle` properties
- repeated `/ { ... };` definitions, `&label { ... };` and
  `&{/path} { ... };` merges, `/delete-property/`, `/delete-node/`, and
  top-level `/delete-node/ &ref;`, all with dtc's in-place merge semantics
- the dtc checks that can reject a tree (duplicate nodes, properties and
  labels, name characters, `name` properties, explicit phandles, and
  unresolved references) and the fixups that change its blob (redundant
  `name` properties, tree-order phandle allocation)
- dtc's parser stack limit: input that exhausts bison's stack is rejected
  with "memory exhausted" at exactly the same depth
- the boot CPU guessed from `/cpus`, `-b`, `-q`, `-i`
- `-I dts`, `-O dtb`, `-o FILE`, input files, and standard input/output
- deterministic DTB output compatible with upstream `dtc`

Constructs that dtc accepts and gdtc does not yet implement are reported as
`unsupported: <feature>` rather than misparsed. `--report-unsupported` lists
every such feature in a file instead of stopping at the first; the corpus
harness uses it to rank the missing features. Decompilation, overlays, other
output formats, and dtc's warnings remain to be implemented.
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

Merging follows dtc's livetree: an incoming property replaces a colliding one
by being spliced into its list position, and deleted entries stay linked but
marked, so a later definition revives them in place. References inside
property values are fixed-size markers that point back into the source text;
the fixup pass walks the final tree in order, so phandles are allocated in
exactly dtc's order. Labels and phandles are indexed by open-addressing tables
that grow by rebuilding behind themselves in grow-only arrays, so no reference
into them is ever invalidated.

This deliberately exercises Goose's unusual strengths rather than copying the
allocation structure of the C implementation.

## License

GPL-2.0-or-later. See [`LICENSE`](LICENSE).
