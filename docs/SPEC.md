# LIR Language Specification

**Specification status: evolving design contract.** This document is not evidence that all described language features are already implemented. The current compiler support is tracked in [Implementation Status](IMPLEMENTATION_STATUS.md); the full target design and implementation sequence are in [Language Architecture](LANGUAGE_ARCHITECTURE.md).

## Language identity

LIR is intended to be a statically typed, ahead-of-time compiled systems programming language with explicit memory/resource control, predictable data layout, and native code generation. The compiler bootstrap is written in Zig. The initial supported target is Linux x86-64 ELF.

The design separates three concepts:
- **Language contract:** source syntax and target-independent semantics.
- **Compiler support:** the subset accepted and correctly implemented by a particular compiler release.
- **Target support:** the ABI, object format, runtime facilities, and conformance status for a target triple.

A feature is stable only when all three are documented and tested.

## Core language direction

The stable core is designed around:
- Fixed-width signed/unsigned integers, `isize/usize`, `f32/f64`, `bool`, `char`, `void`, and `never`.
- Arrays, slices, structs, tagged enums, tuples, function values, and explicit raw pointers.
- Static typing with conservative local inference and explicit conversions.
- Deterministic evaluation order and specified integer overflow behavior.
- Explicit allocation and a documented distinction between owning values, borrows, and raw pointers.
- Structured error handling using explicit result/optional values.
- Modules with deterministic import resolution and explicit visibility.
- An explicit unsafe boundary for operations whose safety cannot be established statically.

## Memory-safety direction

The intended safe profile is affine: moves invalidate the previous owner; immutable borrows may alias; mutable borrows are exclusive; and references cannot outlive their owners. These are design requirements, not current compiler guarantees. No program may be described as memory-safe merely because it uses pointer-shaped types or because the compiler emits native code.

## Native and low-level direction

The first target contract is Linux x86-64 ELF. Struct layout, alignment, calling conventions, register/stack rules, symbol naming, atomics, volatile operations, inline assembly, and FFI must be specified per target and validated with executable conformance tests.

## Extensions

Generics, traits, pattern matching, closures, compile-time execution, concurrency, async/await, SIMD, and additional targets are staged extensions. Their examples in documentation are illustrative until accepted by the compiler and covered by tests.

## Normative implementation references

- [Language Architecture](LANGUAGE_ARCHITECTURE.md) — complete target architecture, semantic rules, compiler pipeline, runtime, tooling, security, and release gates.
- [Implementation Status](IMPLEMENTATION_STATUS.md) — verified status of the checked-in compiler.
- [Compiler Architecture](COMPILER_ARCHITECTURE.md) — compiler internals and backend plan.
- [Low-Level Language Contract](LOW_LEVEL_LANGUAGE.md) — memory, pointer, ABI, and hardware-level requirements.
- [Roadmap](ROADMAP.md) — ordered implementation gates.

When documents conflict, the implementation-status file describes current behavior; the language architecture defines the intended target. Neither overrides executable tests.
