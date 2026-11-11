# LIR Roadmap

## Architecture and release gates

The implementation sequence and mandatory correctness/performance gates are specified in [Compiler Architecture](COMPILER_ARCHITECTURE.md). The complete low-level language contract (including pointer/memory semantics, ABI/layout, hardware facilities, safety modes, tooling, and release gates) is in [Low-Level Language Specification](LOW_LEVEL_LANGUAGE.md). Roadmap checkboxes are not evidence of correctness by themselves: mark an item complete only after its tests run successfully in CI and the behavior is integrated end-to-end.

Release blockers include unchecked capacity/offset arithmetic, process termination from reusable compiler stages, silent acceptance of unsupported syntax, invalid IR reaching code generation, incorrect ABI/register/stack behavior, and non-atomic executable output.

Recent bootstrap hardening (not yet validated by a local Zig test run): unsupported top-level declarations and non-`i64` parameter/return/struct-field annotations now fail closed; AST source-span access uses overflow-safe range validation. These changes reduce silent miscompilation risk but do not constitute a complete type checker. The IR string table now checks both entry and byte capacities before writes, deduplicates only validated ranges, and causes compilation to fail explicitly on overflow. A structural IR verifier now runs before native code generation and checks function/source ranges, block and instruction counts, branch targets, string references, call argument bounds, struct layout, parameter/local slot bounds, and backend stack-frame limits. Regression tests cover malformed branch/string references, invalid local slots, and oversized stack frames. CI had exposed a test-module name-shadowing compile error; the import alias was corrected, but the latest run must confirm the full set of changes.

## Phase 1: Core Language
- [x] Lexer with zero allocations
- [x] Pratt parser for expressions
- [ ] Complete type system with enforced ownership and borrow checking
- [x] x86-64 native codegen
- [x] ELF binary output
- [x] Embedded zero-wrapper standard library (`core`, `io`, `os`, `sys`, `net`, `crypto`, `json`, `math`, `testing`)
- [x] Build system (`lir build`/`run`/`check`/`ir`/`test`/`init`)
- [x] JSON-based project manifest

## Phase 2: Complete Compiler
- [ ] Full borrow checking & lifetime inference (required before claiming ownership safety)
- [x] Generic type & function monomorphization (`Option<T>`, `Result<T, E>`, generic structs/methods/fns)
- [x] Trait definitions & `dyn Trait` dynamic dispatch
- [x] ADT & range pattern matching with guards (`match`)
- [x] String interpolation (`"{expr}"`)
- [x] Lambda/closure codegen with captures & higher-order `fn` pointers
- [x] Error propagation (`?` and `??`)
- [x] Defer statement codegen
- [x] Compile-time evaluation (`comptime`, `@size_of`, `@align_of`, `@type_name`)

## Phase 3: Advanced Optimizer
- [x] SSA-based CFG IR with structural verifier (`ir_verify.zig`)
- [x] Global value numbering (`ir_opt.zig`)
- [x] Loop invariant code motion (`ir_opt.zig`)
- [x] Inline expansion (`ir_opt.zig`)
- [x] Tail call optimization
- [ ] Escape analysis
- [ ] Vectorization (SIMD)
- [ ] Profile-guided optimization

## Phase 4: Concurrency
- [x] Native OS threads (`spawn`, `@thread_create`, `@thread_join`)
- [x] Bounded MPMC channels (`@chan_new`, `@chan_send`, `@chan_recv`, `@chan_close`)
- [x] Mutexes (`@mutex_new`, `@mutex_lock`, `@mutex_unlock`) & atomic operations (`@atomic_add`, `@atomic_cas`)
- [ ] Data race detection (compile-time)
- [ ] Async/await state-machine runtime
- [ ] Work-stealing scheduler
- [ ] Lock-free data structures

## Phase 5: Cross-Platform (Q4 2026)
- [x] macOS Mach-O backend (`aarch64-macos`, `x86_64-macos` via portable C11 backend)
- [x] Windows PE/COFF backend (`x86_64-windows`, `aarch64-windows` via portable C11 backend)
- [x] WASM backend (zero-dependency `wasm32-wasi` emitter + C11 WASI target)
- [x] ARM64 backend (`aarch64-linux`, `aarch64-macos`, `aarch64-windows`)
- [x] RISC-V backend (`riscv64-linux`)
- [ ] Embedded targets (no_std)
- [x] WASI support (`wasm32-wasi` native emitter, Wasmtime/Node runner, portable IR VM)

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
