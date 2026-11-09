# Implementation Status

This file describes the checked-in bootstrap implementation, not the intended language design. It must be updated alongside code changes. A feature is not marked complete solely because its syntax appears in a design document or example.

## Verified repository facts

- The compiler bootstrap is written in Zig.
- The current build script builds a `lir` executable and a unit-test target.
- The current native backend is Linux x86-64 ELF.
- The compiler pipeline includes lexer, parser, AST optimizer, IR generation, structural IR verification, native code generation, and ELF output.
- The IR verifier is currently structural and partial. It checks selected source ranges, counts, branch targets, string references, call argument bounds, struct layout, local/parameter slots, and stack-frame limits. It is not a complete typed-IR verifier and does not establish SSA dominance, comprehensive type consistency, or full use-def validity.
- The current backend maps virtual registers to stack slots. This is not a liveness-based physical register allocator.
- The current IR and frontend use bounded/fixed-capacity structures in several places. Capacity failures must remain explicit and must never permit out-of-bounds writes.

## Status matrix

| Area | Status | What is required before calling it complete |
|---|---|---|
| Zig bootstrap/build | Implemented baseline | Pinned toolchain and reproducible CI |
| Lexer/parser | Partial | Complete grammar, recovery, fuzzing, diagnostics |
| Name resolution | Partial / incomplete | Symbol tables, imports, duplicate and unresolved-name checks |
| Static type system | Incomplete | Typed HIR and full expression/signature/control-flow checking |
| Ownership/borrowing | Not implemented as a complete enforced system | Move analysis, alias rules, lifetime checking, escape tests |
| IR generation | Partial | Typed CFG IR with explicit terminators and complete invariants |
| IR verifier | Partial structural verifier | Type, dominance, use-def, terminator, and effect checks |
| Optimizer | Basic | Defined arithmetic semantics, verified pass manager, differential tests |
| Native x86-64 codegen | Partial implementation | ABI conformance, register allocation, spill logic, relocation validation |
| Physical register allocation | Not implemented | Liveness, allocation, spill insertion, call-clobber handling |
| ELF output | Implemented baseline | Full structural validation, atomic output, integration coverage |
| Runtime / standard library | Partial | Stable contracts, allocator-aware APIs, target matrix, tests |
| Modules/package manager | Incomplete | Deterministic module graph, lockfile, integrity and path security |
| Concurrency/async | Not implemented as stable features | Memory model, atomics, ownership transfer, runtime and stress tests |
| Cross-platform | Not implemented | Independent backend and conformance suite per target |
| Formatter/LSP/debugger | Not implemented as stable tools | Tool-specific acceptance tests |

## Known design/implementation mismatches to keep visible

- Ownership, borrowing, lifetimes, data-race freedom, async/await, compile-time execution, generic monomorphization, and cross-compilation are design goals, not current guarantees.
- Language examples are illustrative unless a matching end-to-end test proves that the current compiler accepts and correctly executes them.
- The current structural IR verifier must not be described as a full verifier.
- Stack-backed virtual registers must not be described as register allocation.
- The current ELF backend must not be described as cross-platform native code generation.

## Required status update rule

For each feature, record one of: **Implemented**, **Partial**, **Experimental**, **Planned**, or **Unsupported**. “Implemented” requires:
1. A documented semantic contract.
2. Positive, negative, and boundary tests.
3. Integration through the complete compiler pipeline.
4. Runtime/ABI validation where applicable.
5. Passing CI on the declared target and build modes.

If any requirement regresses, downgrade the status until repaired.
