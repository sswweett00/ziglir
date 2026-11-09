# LIR Roadmap

This roadmap is ordered by dependency, not calendar promises. A milestone is complete only when its acceptance criteria pass in CI and the implementation-status ledger is updated.

The full target is defined in [Language Architecture](LANGUAGE_ARCHITECTURE.md). Current capabilities are listed in [Implementation Status](IMPLEMENTATION_STATUS.md).

## Gate 0 — Reproducible baseline
- [ ] Pin Zig toolchain and CI environment.
- [ ] Run and record current unit/integration test results.
- [ ] Add a baseline corpus of valid and invalid source programs.
- [ ] Remove generated binaries and oversized transient test artifacts from source control.
- [ ] Establish compiler version, language version, and target triple reporting.

**Exit:** clean reproducible build and test run from a fresh checkout.

## Gate 1 — Compiler reliability
- [ ] Structured diagnostics with source spans and stable error codes.
- [ ] No process termination from reusable compiler stages.
- [ ] Checked arithmetic and capacity validation at every fixed buffer/table boundary.
- [ ] Lexer/parser progress guarantees and malformed-input fuzz tests.
- [ ] Atomic output publication; failed builds leave no executable artifact.
- [ ] CLI path, permission, and child-process failure tests.

**Exit:** malformed or adversarial input cannot crash the compiler, corrupt memory, or produce a success-looking artifact.

## Gate 2 — Complete semantic frontend
- [ ] Symbol tables, scopes, visibility, duplicate-name and unresolved-name diagnostics.
- [ ] Deterministic module graph and import resolution.
- [ ] Typed HIR and complete expression/type checking.
- [ ] Function signature, argument, return-path, field, cast, and control-flow validation.
- [ ] Fully specified integer overflow, shift, division, and conversion semantics.
- [ ] Negative tests for every rejected semantic rule.

**Exit:** code generation consumes only fully type-checked HIR; unsupported syntax fails closed.

## Gate 3 — Verified IR and native backend
- [ ] Typed CFG IR with explicit block terminators and effects.
- [ ] Verifier for types, branch targets, dominance/use-def, call signatures, and memory invariants.
- [ ] Verify after lowering and after each optimization pass in test/debug builds.
- [ ] Pass manager and differential optimized/unoptimized tests.
- [ ] Machine IR, liveness analysis, physical register allocation, spill insertion.
- [ ] Complete ABI lowering, call-clobber handling, stack alignment, relocations, and branch-range validation.
- [ ] ELF structural validation and end-to-end execution fixtures.

**Exit:** backend output conforms to the documented x86-64 ABI and passes runtime/ABI integration tests.

## Gate 4 — Safe systems core
- [ ] Initialization-state and bounds-checking rules.
- [ ] Ownership/move analysis.
- [ ] Borrow exclusivity and conservative lifetime analysis.
- [ ] Escape analysis for returned/stored references.
- [ ] Deterministic defer/drop elaboration on every exit path.
- [ ] Explicit unsafe boundary and documented safety preconditions.
- [ ] DebugSafe and ReleaseSafe conformance tests.

**Exit:** the safe subset has a tested memory model; unsafe operations are explicit and auditable.

## Gate 5 — Stable developer experience and library
- [ ] Stable module/package manifest and lockfile.
- [ ] Deterministic dependency resolution, checksum validation, and path traversal defenses.
- [ ] CLI build/run/check/test/init with documented exit codes.
- [ ] Core, memory, collections, IO, OS, encoding, and testing libraries.
- [ ] Formatter, documentation generator, debug information, and source-level diagnostics.
- [ ] Compatibility tests and versioned language/stdlib contracts.

**Exit:** initial stable language release for Linux x86-64, with no advertised core feature lacking end-to-end tests.

## Gate 6 — Additional targets
Each target is independent and must include ABI docs, backend, object format, runtime, CI, and conformance fixtures.
- [ ] Linux AArch64 ELF.
- [ ] macOS AArch64/x86-64 Mach-O.
- [ ] Windows x86-64 PE/COFF.
- [ ] WASM/WASI.
- [ ] RISC-V and freestanding/embedded profiles.

## Gate 7 — Advanced language/runtime features
- [ ] Generic functions and types with monomorphization.
- [ ] Traits/interfaces with coherence and dispatch rules.
- [ ] Exhaustive pattern matching.
- [ ] Closures and capture semantics.
- [ ] Bounded compile-time execution.
- [ ] Atomics, threads, channels, and synchronization primitives.
- [ ] Async/await runtime and task scheduling.
- [ ] SIMD and target-feature dispatch.
- [ ] PGO, inlining, loop transforms, and advanced optimization.

Each feature remains experimental until its type rules, safety contract, code generation, diagnostics, and tests are complete.

## Performance policy

Performance is a measured property, not a roadmap checkbox. Benchmark equivalent programs with equivalent overflow and safety semantics. Record CPU, OS, compiler versions, flags, input sizes, warm-up, repetitions, median/dispersion, compile time, runtime, binary size, and peak memory. Verify outputs and inspect generated code for low-level claims. Never claim universal superiority over C.

## Release definition

The initial stable release requires Gates 0–5 for the declared target. Cross-platform, memory-safe, race-free, async, and SIMD claims require their own gates and conformance evidence. Features that are not implemented remain clearly marked as planned or unsupported.
