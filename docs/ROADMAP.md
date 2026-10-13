# LIR Roadmap

## Architecture and release gates

The implementation sequence and mandatory correctness/performance gates are specified in [Compiler Architecture](COMPILER_ARCHITECTURE.md). The complete low-level language contract (including pointer/memory semantics, ABI/layout, hardware facilities, safety modes, tooling, and release gates) is in [Low-Level Language Specification](LOW_LEVEL_LANGUAGE.md). Roadmap checkboxes are not evidence of correctness by themselves: mark an item complete only after its tests run successfully in CI and the behavior is integrated end-to-end.

Release blockers include unchecked capacity/offset arithmetic, process termination from reusable compiler stages, silent acceptance of unsupported syntax, invalid IR reaching code generation, incorrect ABI/register/stack behavior, and non-atomic executable output.

Recent bootstrap hardening (not yet validated by a local Zig test run): unsupported top-level declarations and non-`i64` parameter/return/struct-field annotations now fail closed; AST source-span access uses overflow-safe range validation. These changes reduce silent miscompilation risk but do not constitute a complete type checker. The IR string table now checks both entry and byte capacities before writes, deduplicates only validated ranges, and causes compilation to fail explicitly on overflow. A structural IR verifier now runs before native code generation and checks function/source ranges, block and instruction counts, branch targets, string references, call argument bounds, and struct layout. Regression tests cover malformed branch and string references. CI had exposed a test-module name-shadowing compile error; the import alias was corrected, but the latest run must confirm the full set of changes.

## Phase 1: Core Language (bootstrap implementation; completion not yet verified)
- [x] Lexer with zero allocations
- [x] Pratt parser for expressions
- [ ] Complete type system with enforced ownership and borrow checking
- [x] x86-64 native codegen
- [x] ELF binary output
- [ ] Production-complete standard library (core, io, json, os)
- [x] Build system (lir build/run/test/init)
- [x] JSON-based project manifest

## Phase 2: Complete Compiler (Q1 2026)
- [ ] Full type checker with borrow checking (required before claiming ownership safety)
- [ ] Lifetime inference
- [ ] Generic type instantiation
- [ ] Trait object dispatch
- [ ] Pattern matching codegen
- [ ] String interpolation codegen
- [ ] Lambda/closure codegen
- [ ] Error propagation (try/catch)
- [ ] Defer statement codegen

## Phase 3: Advanced Optimizer (Q2 2026)
- [ ] SSA-based IR
- [ ] Global value numbering
- [ ] Loop invariant code motion
- [ ] Inline expansion
- [ ] Tail call optimization
- [ ] Escape analysis
- [ ] Vectorization (SIMD)
- [ ] Profile-guided optimization

## Phase 4: Concurrency (Q3 2026)
- [ ] Green threads (coroutines)
- [ ] Channel implementation
- [ ] Arc/Mutex for shared state
- [ ] Data race detection (compile-time)
- [ ] Async/await runtime
- [ ] Work-stealing scheduler
- [ ] Lock-free data structures

## Phase 5: Cross-Platform (Q4 2026)
- [ ] macOS Mach-O backend
- [ ] Windows PE/COFF backend
- [ ] WASM backend
- [ ] ARM64 backend
- [ ] RISC-V backend
- [ ] Embedded targets (no_std)
- [ ] WASI support

## Phase 6: Ecosystem (2027)
- [ ] Package manager (lir pkg)
- [ ] Package registry (crates.io equivalent)
- [ ] Language server (LSP)
- [ ] VS Code extension
- [ ] IntelliJ plugin
- [ ] Documentation generator
- [ ] REPL
- [ ] Playground (web-based)

## Phase 7: Advanced Features (2027+)
- [ ] Comptime reflection
- [ ] DSL support (macros)
- [ ] Effect system
- [ ] Algebraic effects
- [ ] Dependent types (optional)
- [ ] Proof assistant integration
- [ ] Formal verification

## Performance and Usability Goals

These are engineering targets, not verified claims about the current compiler. Record baseline measurements before changing the optimizer, and keep each optimization only when correctness tests pass and benchmarks show a repeatable improvement.

| Metric | Goal | Verification |
|--------|------|--------------|
| Runtime speed | Beat optimized C on selected workloads; remain competitive on the full suite | Same algorithm, same inputs, equivalent safety/overflow semantics, optimized builds, repeated runs, report median and variance |
| Compile speed | Improve throughput without weakening diagnostics or correctness | Benchmark cold and warm builds separately; report LOC/s and wall time |
| Binary size | Keep small programs compact without sacrificing runtime speed | Compare stripped release binaries and disclose target/flags |
| Memory use | Avoid hidden allocations and unnecessary copies | Measure peak RSS and allocation counts on identical workloads |
| Startup latency | Keep short-lived CLI programs responsive | Measure process startup separately from steady-state throughput |
| Learnability | Small core syntax, consistent rules, useful diagnostics | Beginner tasks, examples, and error-recovery tests |

### Required optimization workflow

1. Establish a reproducible baseline against a recent, optimizing C compiler (for example, Clang or GCC) using documented flags and identical workloads.
2. Include microbenchmarks and representative programs; prevent dead-code elimination from invalidating results and verify outputs for every implementation.
3. Run multiple repetitions, report median and spread, and test both debug and release configurations.
4. Inspect generated assembly for claimed low-level wins; measure compile time, binary size, and memory alongside runtime.
5. Never claim “faster than C” universally. State exactly which workload, hardware, compiler versions, flags, and correctness constraints support each result.

## Language Design Principles

1. **Simplicity first** — Prefer a small set of consistent rules over many special cases.
2. **Easy to read and write** — Infer obvious local types; require annotations where inference would be ambiguous or obscure.
3. **Performance by construction** — Predictable layouts, explicit allocation control, and abstractions that optimize away when possible.
4. **Safety without hidden costs** — Enforce ownership and borrowing in the type checker; do not claim safety until checks are implemented and tested.
5. **Optimize from evidence** — Use benchmarks, generated-code inspection, and regression tests rather than intuition alone.
6. **Portability through backends** — Keep language semantics separate from target-specific code generation.
7. **Honest status** — Clearly distinguish implemented, partial, and planned features.
