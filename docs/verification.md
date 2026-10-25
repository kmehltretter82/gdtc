# Goose verification plan

The project is successful only when it is a useful compatibility implementation,
not merely when a demonstration file compiles. Upstream `dtc` is the behavioral
oracle and the Devicetree Specification defines the external format.

## Language properties under test

| Goose property | How gdtc exercises it | Evidence |
|---|---|---|
| Variable-size ADTs | Nodes and properties share one compact `Item..` pool | Compiler acceptance and pool-size benchmarks |
| Stable references during growth | Earlier children are linked after later pool pushes | Deep/wide tree conformance tests |
| Narrow pool-relative references | `first` and `next` are `Item..&<u32 in items>?` | Compiler acceptance and successful traversal during conformance tests |
| In-place construction | Parsed strings and values are built directly into pool variants | Compiler diagnostics plus generated-C inspection |
| Scope-based reclamation | Planned per-document pool in batch mode | Repeated batch/RSS benchmark |
| Checked byte access | Lexer and DTB encoder use bounded Goose arrays | Malformed corpus and sanitizer runs |
| Long-distance error returns | Nested parser failures return from `parse` | Negative syntax tests |
| Recursive traversal | Parsing and flattening nested nodes | Deep tree tests up to the supported nesting limit |

The default generated stress corpus contains a 128-level tree and a tree with
2,048 sibling nodes. `DEPTH` and `WIDE` can raise those sizes without changing
the checked-in fixtures.

## Compatibility stages

1. **Core DTS to DTB**
   Nodes, properties, strings, cells, bytes, comments, version-17 header and
   structure/string blocks. Every accepted fixture must match upstream `dtc`
   byte-for-byte.
2. **Complete scalar syntax**
   Character literals and 8/16/32/64-bit `/bits/` values are implemented.
   Integer expression operators are implemented as well. Labels on values,
   `/incbin/`, and source includes remain. (`/memreserve/` is already supported
   by the core stage.)
3. **Tree resolution**
   Multiple labels per node, label/absolute-path phandle references, explicit
   phandles, repeated-root merges, label/absolute-path target merges, and
   deletion directives within fragments are implemented. Property/value
   labels, `-@` symbols/fixups, aliases, and
   omitted-if-unused nodes remain.
4. **Checks and diagnostics**
   Port upstream structural/semantic checks and maintain a diagnostic
   compatibility matrix. Add stable JSON diagnostics as an extension.
5. **Reverse and alternate formats**
   DTB input, DTS output, ASM output, and overlay application. YAML is optional
   because it introduces an external library boundary.
6. **Corpus qualification**
   Upstream dtc tests, all applicable Linux DTS/DTSI sources after preprocessing,
   malformed/fuzzed DTBs, and cross-endian fixtures.

## Required gates

- `goose check` and optimized/debug native builds succeed.
- Every supported positive fixture is byte-identical to upstream `dtc`.
- Every supported negative fixture fails without producing output.
- Sampled truncations of a valid source fail through parser diagnostics under a
  checked debug build, never through a bounds-check abort.
- Upstream `dtc` accepts every blob emitted by gdtc.
- Round trips preserve the canonical device tree.
- Fuzzing produces no memory-safety failure or accepted structurally invalid DTB.
- Benchmarks report time, peak RSS, and output equality; performance claims are
  not made before those results exist.

## Current status

The Stage 1 implementation and the implemented portions of Stages 2 and 3 are
present. With Goose v2026.3, the current harness typechecks and builds optimized
and checked-debug executables, byte-matches upstream `dtc` for 12 checked-in
positive fixtures plus two generated stress trees, and cleanly rejects all 15
checked-in negative fixtures. The stdin/stdout path and sampled truncated-input
error paths pass as well.
