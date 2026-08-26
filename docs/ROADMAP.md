# LIR Roadmap

## Phase 1: Core Language ✅ (Current)
- [x] Lexer with zero allocations
- [x] Pratt parser for expressions
- [x] Type system with ownership
- [x] x86-64 native codegen
- [x] ELF binary output
- [x] Standard library (core, io, json, os)
- [x] Build system (lir build/run/test/init)
- [x] JSON-based project manifest

## Phase 2: Complete Compiler (Q1 2026)
- [ ] Full type checker with borrow checking
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

## Performance Goals

| Metric | Target | Status |
|--------|--------|--------|
| Compile speed | >100K LOC/s | 🔄 In progress |
| Binary size | <10KB hello world | ✅ Achieved |
| Startup time | <1ms | ✅ Achieved |
| Runtime performance | Within 5% of C | 🔄 In progress |
| Memory usage | <2x C | 🔄 In progress |

## Language Design Principles

1. **Simplicity** — Small, orthogonal features
2. **Performance** — Every feature maps to efficient code
3. **Safety** — Catch errors at compile time
4. **Expressiveness** — Clear, maintainable code
5. **Portability** — Write once, run anywhere
6. **Self-contained** — No external dependencies
