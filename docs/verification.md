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
   Character literals, 8/16/32/64-bit `/bits/` values, integer literal
   suffixes, parenthesized integer expressions, `/include/`, and cpp line
   markers are implemented. The lexer follows dtc-lexer.l rule for rule.
   Labels on values and `/incbin/` remain. (`/memreserve/` is already
   supported by the core stage.)
3. **Tree resolution**
   Multiple labels per node, labels on merge targets, label, absolute-path
   and label-relative phandle and path references, explicit phandles,
   repeated-root merges, label/path target merges, deletion directives, and
   `/omit-if-no-ref/` are implemented. Property/value labels and `-@`
   symbols/fixups remain.
4. **Checks and diagnostics**
   Every upstream check that can reject a tree (the ERROR checks of
   checks.c) is implemented, as are the fixups that change the blob, and
   bison's stack limit is reproduced exactly. dtc's warnings remain; maintain
   a diagnostic compatibility matrix and add stable JSON diagnostics as an
   extension.
5. **Reverse and alternate formats**
   DTB input, DTS output, ASM output, and overlay application. YAML is optional
   because it introduces an external library boundary.
6. **Corpus qualification**
   Upstream dtc tests, all applicable Linux DTS/DTSI sources after preprocessing,
   malformed/fuzzed DTBs, and cross-endian fixtures. `make corpus` runs the
   Linux part: a shallow sparse checkout of a pinned release, every
   `arch/*/boot/dts/**/*.dts` preprocessed with the kernel's cpp flags, and
   both compilers on each result. The per-file log and the ranking of missing
   features are in [`corpus.md`](corpus.md).

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

The Stage 1 implementation and the implemented portions of Stages 2 to 4 and 6
are present. With Goose v2026.3, the current harness typechecks and builds
optimized and checked-debug executables, byte-matches upstream `dtc` 1.7.0 for
35 checked-in positive fixtures plus four generated trees, and rejects all 38
checked-in and four generated negative fixtures with the expected diagnostic
under the checked-debug build. The stdin/stdout path passes, and every sampled
prefix of every positive fixture either matches `dtc` or fails through a
diagnostic, as `dtc` does.

### Linux corpus

All 3672 `.dts` files of Linux v7.3 compile byte-identically to `dtc` 1.7.0,
both with `dtc`'s defaults and with the kernel's `-b 0`; the logs with both
blobs' SHA-256 are `tests/corpus/linux-v7.3.tsv` and
`tests/corpus/linux-v7.3-b0.tsv`, and [`corpus.md`](corpus.md) has the summary.
110 files differ between the two runs because `dtc` guesses a nonzero boot CPU
from `/cpus` by default.

The first run of the harness ranked the features gdtc was missing by how many
files each one unblocks. They were implemented in that order:

| Commit | Feature | Files needing it | Byte-identical after |
|---|---|---:|---:|
| 35baf42 | (baseline) | | 0 |
| 7487b48 | cpp line markers | 3672 | 105 |
| 581b870 | path references in property values | 3526 | 2947 |
| 46d2dbe | `/omit-if-no-ref/` | 395 | 3325 |
| aaf4399 | `/include/` | 252 | 3577 |
| c6a4f4e | a label on a merge target | 80 | 3657 |
| 2132f55 | label-relative paths, `&{label/path}` | 15 | 3672 |

No file needs property or value labels, `/incbin/`, or `/plugin/`. The kernel
also passes `-@` when building a base tree for overlays; gdtc does not
implement `-@` yet, so the corpus compares the trees without symbols.
