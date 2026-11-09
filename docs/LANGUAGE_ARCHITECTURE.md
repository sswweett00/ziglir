# LIR / Ziglir Language Architecture

**Status: target architecture, not an implementation claim.** This document defines what must exist before LIR can be called a complete, dependable systems programming language. The current Zig bootstrap compiler is a partial implementation; the implementation ledger in [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) is authoritative for what currently works.

## 1. Product and compatibility contract

LIR is a statically typed, ahead-of-time compiled systems language. Its design priorities, in order, are:

1. Correct and deterministic language semantics.
2. Explicit resource, memory, and ABI behavior.
3. Useful diagnostics and a stable developer workflow.
4. Portable source semantics with independently validated target backends.
5. Performance measured against equivalent programs, never promised by syntax alone.

The compiler is implemented in Zig. The language implementation must not silently delegate compilation to GCC, Clang, LLVM, or another compiler. Target-specific assemblers/linkers may be optional tools only when the target contract explicitly documents them; the baseline native backend must own instruction selection, encoding, relocations, and object/executable layout.

**Compatibility policy**
- A released language version has a versioned grammar, type rules, standard-library API, and target ABI contract.
- A breaking semantic change requires a language-version increment and migration notes.
- Compiler implementation version and language version are distinct.
- Experimental syntax is gated behind an explicit feature flag and is never silently accepted as stable syntax.
- Unsupported syntax, target features, intrinsics, and ABI combinations fail with a source diagnostic before output creation.
- Reproducible builds record compiler version, language version, target triple, optimization mode, and relevant feature flags.

## 2. Language core

### 2.1 Lexical and syntactic rules

The language must specify UTF-8 source handling, byte offsets, Unicode identifier policy, line endings, comments, escapes, numeric literal grammar, operator precedence/associativity, semicolon/newline behavior, and error recovery. The lexer must always make progress on malformed input and preserve exact source spans.

The parser must produce either a complete AST or recoverable diagnostics. It must not skip unknown declarations or turn malformed syntax into a plausible but different program. Grammar changes require parser acceptance tests, rejection tests, and diagnostic snapshots.

### 2.2 Types

The initial stable type set should be intentionally small and complete:

- Integers: `i8/i16/i32/i64/i128`, `u8/u16/u32/u64/u128`, `isize`, `usize`.
- Floating point: `f32`, `f64`; additional formats only after target-independent semantics and backend support exist.
- `bool`, `void`, `never`, `char`, and UTF-8 string/slice types with explicitly defined representation.
- Fixed arrays `[N]T`, slices `[]T`, tuples, function types, and raw pointers.
- Structs, tagged enums, unions, opaque/extern types, and aliases.
- Explicit `Option(T)` and `Result(T, E)` library/compiler types with specified layout and control-flow semantics.

Every expression must have a resolved type before machine lowering. The checker must validate declarations, name resolution, visibility, field access, call signatures, return paths, casts, operators, generic constraints, and control-flow joins. Type inference may infer local bindings, but it must not guess across ambiguous numeric, pointer, or generic conversions.

Implicit numeric widening is allowed only where its exact behavior is specified. Narrowing, signedness changes, float/integer conversion, pointer/integer conversion, and bit reinterpretation are explicit. No implicit nullable raw pointer exists.

### 2.3 Integer and floating-point semantics

For every integer operator, specify overflow behavior. Provide distinct checked, wrapping, and (if desired) saturating operations; do not let optimizer mode silently change the result. Specify division by zero, signed minimum divided by -1, invalid shift counts, out-of-range casts, and compile-time overflow.

Floating-point behavior must document IEEE expectations, NaN comparisons, signed zero, rounding, fused operations, and fast-math opt-ins. A backend may not apply transformations that violate the selected semantic mode.

### 2.4 Control flow and functions

Stable core control flow: blocks, `if/else`, loops, `break`, `continue`, and `return`. Function declarations have explicit parameter and result types in public interfaces. The language must define evaluation order, short-circuit behavior, recursion, stack exhaustion behavior, and whether tail calls are guaranteed or merely optimized opportunistically.

Every basic block in IR has exactly one terminator. All reachable paths must satisfy the function return contract. `never` values cannot be used as ordinary values.

Pattern matching, closures, async functions, and compile-time execution are staged extensions; each needs formal typing and lowering rules before becoming stable.

## 3. Memory model and safety

### 3.1 Storage and allocation

The language distinguishes:
- Value storage and initialization state.
- Stack/local storage, static storage, caller-provided buffers, and heap allocations.
- Owning values, borrowed references, and raw pointers.
- Single-object pointers, many-item pointers, and slices (pointer plus length).

Allocation is explicit through allocator values or APIs. No mandatory garbage collector and no hidden heap allocation are permitted in the core language. Allocation failure behavior is explicit and testable. The standard library must offer allocator interfaces without baking a particular allocator into the language ABI.

### 3.2 Ownership and borrowing

The intended safe profile uses affine ownership:
- An owning value has one live owner unless a type explicitly implements safe shared ownership.
- Moving a value invalidates the previous binding.
- Immutable borrows may alias; mutable borrows are exclusive.
- A borrow cannot outlive its owner.
- References cannot escape through returns, globals, aggregates, or closures unless lifetime checking proves the relationship.
- Destructors and `defer` execute exactly once, in reverse acquisition order, on all normal and error exits.

The implementation must start with conservative lexical lifetimes and explicit annotations where inference is ambiguous. More advanced non-lexical lifetime inference is a later optimization of the type checker, not a reason to weaken the initial rules.

### 3.3 Unsafe boundary

Raw pointer arithmetic, arbitrary address access, unchecked casts, inline assembly, and operations with unverifiable preconditions require an explicit `unsafe` block/function. Unsafe does not disable ordinary type checking. Every unsafe API documents its preconditions, aliasing rules, alignment, lifetime, and ownership obligations.

### 3.4 Safety modes

- **DebugSafe:** bounds, initialization, alignment, and integer checks enabled; rich diagnostics.
- **ReleaseSafe:** safety checks retained; optimizations enabled subject to language semantics.
- **ReleaseFast:** may omit only explicitly documented dynamic checks; compile-time validation and type/ownership rules remain mandatory.
- **Freestanding:** no implicit runtime startup or standard library; user supplies entry point and platform contracts.

A build mode must never change the meaning of a well-defined program.

## 4. Data layout, ABI, and foreign interfaces

The language defines target-independent layout concepts and a per-target ABI document:
- Field ordering, padding, alignment, enum tags, array layout, slice layout, and zero-sized types.
- Compile-time size/alignment/offset queries and layout assertions.
- Explicit `extern`, `packed`, and alignment annotations with validation.
- LIR-native and C calling conventions for the first supported target.
- Parameter/return classification, aggregate passing, stack alignment, callee/caller-saved registers, variadic restrictions, symbol naming, visibility, and unwind behavior.
- Exported functions and external declarations with explicit ABI annotations.

No ABI feature is stable until both directions are tested: LIR calling foreign code and foreign code calling exported LIR functions. ABI tests compare offsets, sizes, alignments, and call behavior against small reference C fixtures where available.

## 5. Concurrency and atomics

Concurrency is a library/runtime capability built on explicit language contracts, not merely syntax sugar.

The initial memory model must specify:
- Atomic integer/pointer types and supported operations.
- Relaxed, acquire, release, acquire-release, and sequentially consistent ordering where the target supports them.
- Happens-before relationships and data-race definition.
- Thread-safe ownership transfer and restrictions on sending references across threads.
- Volatile semantics as observability for device/external memory; volatile is not atomic and does not create synchronization.

Threads, channels, task executors, async/await, mutexes, condition variables, and lock-free containers are separate milestones. A compile-time data-race-freedom claim is allowed only after the ownership/type system and all relevant unsafe/FFI escape hatches are accounted for. Never claim that arbitrary unsafe code is race-free.

## 6. Modules, packages, and build model

### 6.1 Modules

A module has a canonical source identity, explicit imports, visibility rules, and deterministic initialization behavior. The compiler builds an import graph, detects cycles according to documented rules, resolves names before type checking, and prevents path traversal outside declared source/package roots unless explicitly configured.

Imports are resolved relative to a package/module root, not the process working directory. Duplicate module identities and ambiguous names are errors. Build output paths are normalized and must not overwrite source files.

### 6.2 Package manifest and dependency resolution

The manifest schema is versioned and validates:
- Package name/version, entry point, source roots, targets, build modes.
- Dependency source, exact version/range, checksum or immutable revision.
- Feature flags and optional dependencies.
- Build scripts only if a restricted, explicit execution model is later approved.

Dependency resolution must be deterministic and lockfile-backed. Downloads require integrity verification; cache writes are atomic; path and symlink traversal are constrained. The compiler must not execute dependency code merely to resolve metadata.

### 6.3 CLI contract

Stable commands: `build`, `run`, `check`, `test`, `init`, `version`, `target list`, and `help`. Formatting, documentation, package management, and language-server commands are introduced when implemented.

CLI requirements:
- Stable exit codes and stdout/stderr contract.
- `--target`, `--optimize`, `--diagnostic-format`, and output selection.
- No shell interpolation of user-controlled paths/arguments.
- Build to a temporary sibling file, fsync where supported, then atomically rename on success.
- Failed compilation never leaves a success-looking executable.
- `run` uses a unique, permission-restricted temporary output and propagates child exit status/signal.

## 7. Standard library and runtime

The standard library is layered so freestanding programs can avoid runtime dependencies:

1. **core:** primitives, Option/Result, panic/abort, assertions, formatting traits/contracts.
2. **mem:** allocators, slices, byte buffers, ownership-aware containers.
3. **collections:** vector, string builder, map/set, deque, heap.
4. **io:** reader/writer abstractions, files, paths, buffered I/O.
5. **os:** environment, process, clocks, filesystem and system interfaces per target.
6. **net:** sockets and protocol implementations, optional by target.
7. **encoding:** UTF-8, JSON, binary codecs.
8. **sync:** atomics, locks, channels, threads, task runtime.
9. **testing:** test discovery, assertions, fixtures, deterministic test output.
10. **crypto:** only audited, documented primitives; no home-grown cryptography.

Every public API documents allocation, ownership, error behavior, thread-safety, and target support. The compiler and core library must not have circular build dependencies.

## 8. Compiler architecture

The intended compiler is a sequence of explicit, independently testable stages:

```text
CLI / Build Graph
      |
Source Manager + Diagnostics
      |
Lexer -> Parser -> AST validation
      |
Module Graph + Name Resolution
      |
Type Checker + Ownership / Lifetime Checker
      |
Typed HIR (target independent)
      |
Canonical CFG IR + IR Verifier
      |
Optimization Pass Manager + Verify-after-pass
      |
Machine IR
      |
Instruction Selection + ABI Lowering
      |
Liveness + Register Allocation + Spill Insertion
      |
Frame Layout + Encoding + Relocations
      |
Object / ELF Writer -> Atomic Artifact Publish
```

### 8.1 Frontend invariants

- Source spans use checked byte offsets and map to line/column lazily.
- Diagnostics are structured values; reusable compiler stages never terminate the process.
- Every parser loop has a progress guarantee.
- Name resolution is complete before type checking.
- Unsupported syntax produces an error; no silent AST elision.
- Resource limits are explicit, checked before writes, and surfaced as diagnostics.

### 8.2 Typed HIR and IR

HIR retains source-level types, symbols, and ownership facts. Lowering to IR makes control flow explicit. The IR must specify:
- Value types, signedness, constants, and operation overflow mode.
- Basic blocks, terminators, branch targets, and predecessor/successor relations.
- Function signatures, calling convention, effects, and call clobbers.
- Memory operations, aliasing/volatile/atomic semantics, and pointer provenance where required.
- Source locations for diagnostics and debug mapping.

The verifier checks IDs/ranges, types, dominance/use-def validity, block terminators, branch targets, call signatures, local/stack bounds, memory operation alignment, and target-independent invariants. Run it after lowering and after every optimization pass in debug/test configurations.

### 8.3 Optimization

Start with semantics-preserving local passes: constant folding, algebraic simplification under exact overflow rules, dead-code elimination, and control-flow simplification. Later passes may include SSA construction, GVN, inlining, loop transforms, escape analysis, and vectorization.

Each pass declares required/provided invariants and observable effects. Differential tests compare optimized and unoptimized results. Performance changes require repeatable benchmarks and generated-code inspection.

### 8.4 Backend and executable writer

Machine lowering handles register classes, liveness, register allocation, spills, stack frames, ABI argument/return placement, call clobbers, instruction constraints, branch relaxation, and relocations. The object writer validates every offset, size, alignment, symbol, segment, and relocation with checked arithmetic.

The initial supported backend remains Linux x86-64 ELF. Other targets are separate backends, not a flag that changes the output header. A target is supported only after compiling, linking or loading, and executing conformance fixtures on that target.

## 9. Diagnostics and developer tools

Diagnostics have stable codes, severity, primary/secondary spans, notes, and optional fix suggestions. Human and machine-readable formats are supported. Error recovery must avoid cascades where possible but must never allow invalid state into code generation.

Tooling milestones:
- Formatter with stable formatting rules.
- Test runner with test discovery and isolated test execution.
- LSP with incremental parsing, diagnostics, completion, go-to-definition, and references.
- Documentation generator from source comments.
- Debug information and source-level stack traces.
- REPL only after incremental compilation and state semantics are designed.

## 10. Verification and quality gates

A feature is complete only when its syntax, semantics, diagnostics, implementation, docs, and tests agree.

Required test layers:
1. Lexer/parser positive, negative, fuzz, and malformed-input progress tests.
2. Name-resolution/type-checker positive and negative tests.
3. Ownership/lifetime escape and aliasing tests.
4. IR verifier unit tests and malformed-IR fuzzing.
5. Per-pass optimizer differential tests.
6. ABI/layout/FFI conformance fixtures.
7. ELF/object validation and disassembly checks.
8. End-to-end execution tests for generated programs.
9. CLI failure, permissions, path traversal, output atomicity, and child-process tests.
10. Standard-library API and cross-target conformance suites.

CI must run debug and optimized builds, unit tests, integration tests, static analysis/format checks, and a small deterministic benchmark smoke suite. Fuzzing and long-running benchmarks may run on scheduled workflows.

Benchmark reports include CPU, OS, Zig/compiler versions, flags, input, warm-up, repetitions, median and dispersion, compile time, runtime, binary size, and peak RSS. Compare equivalent semantics and verify outputs. Never generalize one benchmark into a universal speed claim.

## 11. Ordered implementation gates

### Gate 0 — Reproducible baseline
Pin the Zig toolchain, make CI deterministic, run the existing test suite, record current behavior, and remove generated binaries/large fixtures from version control where appropriate.

### Gate 1 — Compiler reliability
Replace process exits in reusable stages with structured errors; eliminate unchecked fixed-capacity writes and arithmetic; add source-span validation; make output publication atomic; add malformed-input fuzz tests.

### Gate 2 — Semantic foundation
Add symbol tables, module graph, duplicate/unresolved-name diagnostics, complete expression typing, function signature/call checking, return-path analysis, and explicit numeric semantics. Codegen accepts typed HIR only.

### Gate 3 — Verifiable IR and backend
Define typed CFG IR, block terminators, use-def/dominance checks, pass manager, ABI lowering, liveness, register allocation, spill insertion, relocations, and execution-based backend tests.

### Gate 4 — Safe systems core
Implement ownership/move analysis, borrow/alias checks, conservative lifetimes, defer/drop elaboration, bounds/alignment/init checks, and unsafe boundaries. Publish a memory model and test all escape paths.

### Gate 5 — Usable language and library
Complete modules, package/lockfile, stable CLI, core/mem/io/collections/testing libraries, formatter, docs, and diagnostics. Establish semver and compatibility tests.

### Gate 6 — Platform expansion
Add targets one at a time: each needs ABI docs, target-specific backend, linker/object validation, runtime tests, and CI hardware/emulation coverage. Prioritize aarch64 Linux before additional OS formats unless project requirements dictate otherwise.

### Gate 7 — Advanced capabilities
Generics/traits, compile-time execution, closures, pattern matching, atomics/concurrency, async runtime, SIMD, and profile-guided optimization. Each is independently feature-gated until conformance tests pass.

## 12. Definition of “complete”

LIR can be called a complete **initial stable systems language** only when Gates 0–5 are closed for the declared target, the stable language subset is documented, all mandatory CI gates pass, and no advertised core syntax is silently ignored. It can be called cross-platform or concurrency-safe only after the corresponding target/concurrency gates pass.

“Complete” does not mean every possible feature (dependent types, proof assistants, macros, or every CPU) exists. It means the published stable language is coherent, implementable, tested end-to-end, and honest about its boundaries.
