# LIR Low-Level Language Specification and Implementation Contract

Status: **design contract / implementation backlog**. This document does not claim that features are already implemented. A feature becomes supported only when parsing, semantic validation, code generation, diagnostics, tests, and documentation agree.

## 1. Product contract

LIR is intended to be a compiled, low-level systems language implemented by the Zig-based LIR compiler. It must emit native object/executable code directly through LIR backends, not silently delegate compilation to GCC, Clang, LLVM, or another compiler. The first supported target remains Linux x86-64 ELF until additional targets have independent conformance tests.

The language must provide predictable layout and execution, explicit control over resource use, useful safety checks, and an opt-in route to unsafe machine-level operations. It must not promise that every program is memory-safe or that generated code can never contain defects.

## 2. Core type system

Required primitive types:

- Signed and unsigned fixed-width integers: `i8/i16/i32/i64/i128` and `u8/u16/u32/u64/u128`, plus target-sized `isize/usize`.
- IEEE floating-point `f32/f64`; `bool`; `void`; never-confusable `char`/byte types; and explicitly specified string/slice types.
- Arrays with compile-time length, slices with runtime length, tuples where useful, enums with explicit or inferred integer tags, structs, unions, and opaque types.
- Optional values and result/error values must have specified layout and control-flow semantics; no implicit nullable raw pointers.
- Explicit casts and checked conversions. Truncating, sign-changing, pointer/integer, and reinterpretation casts must be explicit operations.

Acceptance criteria: type-check every expression before code generation; reject mismatched types, invalid casts, unresolved names, duplicate declarations, invalid return paths, and unsupported operations with source-spanned diagnostics. No unsupported construct may be silently skipped.

## 3. Pointer and memory model

Required pointer forms and operations:

- Single-object pointers, raw/many-item pointers, optional pointers, immutable and mutable references, and slices with explicit length.
- Pointer arithmetic only in documented unsafe contexts unless proven bounds-safe by the compiler.
- Explicit address-of, dereference, pointer casts, integer-address conversion, alignment queries, and alignment assumptions.
- A clear distinction between uninitialized storage, initialized values, zeroed storage, and invalid/unreachable states.
- Explicit allocation APIs and allocator parameters; no hidden garbage collector or mandatory runtime.
- Stack allocation, fixed-size arrays, caller-provided buffers, arenas, pools, and custom allocators can be expressed without hidden heap allocation.
- `defer`/scope cleanup must have deterministic LIFO semantics, including early returns and error exits.
- `volatile` access for device memory and externally observable memory; volatile is not an atomicity guarantee.
- Atomic types and operations with a documented memory-order model. Unsupported target operations must fail at compile time or use a documented legal lowering.

Safety profile:
- Safe code checks bounds, alignment, initialization, integer overflow where required by the chosen mode, and lifetime/aliasing rules that the compiler actually implements.
- `unsafe` marks the boundary for raw pointer arithmetic, arbitrary address access, inline assembly, and other operations whose preconditions cannot be proven.
- Provide explicit build modes: Debug/Safe (checks enabled), ReleaseSafe (checks retained), and ReleaseFast (only checks whose removal is documented). Optimization must never change defined program semantics.

## 4. Deterministic data layout and ABI

Required features:

- Default struct layout with documented alignment and padding rules.
- `extern struct/union` for a specified foreign ABI; `packed struct` for exact bit layout; explicit field alignment and explicit enum tag type.
- Compile-time size, alignment, field-offset, and bit-size queries.
- Layout assertions that fail compilation when an ABI contract is violated.
- Explicit function calling conventions: LIR-native and C ABI at minimum for the initial target.
- Exported symbols, external declarations, symbol visibility, name mangling rules, variadic foreign calls only when correctly supported, and a stable rule for aggregate arguments/returns.
- A documented stack alignment rule, callee/caller-saved register contract, red-zone policy, unwind/debug metadata policy, and return-value convention per target.

No ABI feature is considered supported until tests cover calls both from LIR to foreign code and from foreign code into exported LIR functions.

## 5. Hardware-level facilities

Required low-level facilities, introduced incrementally and gated by target support:

- Inline assembly with explicit input/output operands, clobber sets, volatility, and target constraints; reject malformed or unsupported constraints.
- CPU feature detection and target-feature selection, with runtime dispatch only when the program explicitly requests it.
- SIMD/vector types and intrinsics with defined lane types, alignment, and fallback policy.
- Atomic read/write, compare-exchange, read-modify-write, fences, and memory orderings.
- Bit operations, rotates, overflow-reporting arithmetic, endian conversion, and explicit unaligned loads/stores.
- MMIO-compatible volatile loads/stores and target-specific barriers. Never imply that a volatile access is atomic.
- OS system-call interfaces as target-specific libraries/examples, not portable language semantics.
- Freestanding entry points, no-default-runtime builds, explicit linker scripts, custom sections, symbol retention, and static/no-stdlib linking where the target supports them.
- Interrupt/exception entry attributes only for targets whose calling convention and code-generation rules are fully implemented.

## 6. Compile-time and abstraction features

- Compile-time constants and evaluation with bounded execution, diagnostics, and deterministic semantics.
- Generic functions/types with compile-time parameters and monomorphization as the initial implementation strategy.
- Type aliases, modules, imports, visibility, and explicit external interfaces.
- Traits/interfaces and implementations only after method resolution and coherence/conflict rules are specified.
- No mandatory object runtime, dynamic dispatch, RTTI, exception runtime, or hidden allocation. Any dynamic dispatch must be explicit and have a documented representation.
- Intrinsics are compiler-recognized, typed, target-gated operations—not ordinary identifiers that can silently become unresolved calls.

## 7. Integer, arithmetic, and optimization semantics

Every integer operation must specify overflow behavior. The implementation must distinguish wrapping, checked, saturating (if provided), and undefined/invalid operations. Division by zero, signed minimum divided by -1, invalid shift widths, and out-of-range conversions must have defined diagnostic/runtime behavior for each build mode.

Optimizer rules:
- Only transform verified IR.
- Preserve signedness, overflow semantics, aliasing, volatile/atomic effects, call effects, and control-flow behavior.
- Do not remove or reorder observable operations.
- Run IR verification after lowering and after each optimization pass in compiler-debug/test builds.
- Add regression tests for every optimizer bug and differential tests against a simple reference evaluator where possible.

## 8. Native compiler pipeline and backend contract

Required pipeline:

1. Source manager and lexer with byte offsets, line/column mapping, and malformed-input recovery.
2. Parser that either produces a complete valid syntax tree or diagnostics; no silent skipping of declarations.
3. Name resolution and module/import graph validation.
4. Complete type checking and target-independent semantic validation.
5. Typed, canonical IR with explicit effects and control-flow terminators.
6. IR verifier: valid IDs, types, block targets, terminators, dominance/use-def rules where applicable, and valid call signatures.
7. Semantics-preserving optimization passes.
8. Machine IR, liveness analysis, register allocation with spilling, calling-convention lowering, and stack-frame layout.
9. Instruction encoding with range/relocation validation.
10. Object/ELF writer with checked arithmetic, segment/section validation, deterministic output, and atomic file replacement.
11. Runtime execution tests for generated binaries; malformed or unsupported programs must not produce a successful output artifact.

The current bootstrap target is Linux x86-64 ELF. Do not label other targets supported until each has a complete backend and end-to-end tests.

## 9. Tooling required for production use

- Stable CLI: build, run, check, test, fmt (when formatter exists), version, target listing, and diagnostic/JSON diagnostic modes.
- Exit codes and stderr/stdout behavior documented and tested.
- Reproducible builds, clear versioning, source locations in diagnostics, and no panics for user input.
- Unit, parser recovery, semantic-negative, IR-verifier, optimizer, ABI, ELF validation, integration, fuzz, and regression tests.
- CI for debug and optimized configurations; test generated executables, not only compiler exit codes.
- Benchmarks that compare equivalent results, record compiler versions/flags/CPU, use repeated runs, and measure compile time, runtime, binary size, and peak memory.
- Documentation for the language grammar, ABI, memory model, safety modes, target support, standard library, examples, and feature status.

## 10. Release gates

A feature is not production-ready until all relevant gates pass:

1. Grammar and semantic rules documented.
2. Positive and negative tests added.
3. Malformed input cannot crash the compiler or write a misleading output.
4. IR invariants and target constraints are checked.
5. Generated code is executed in integration tests.
6. ABI and layout are checked against a reference where applicable.
7. Debug and optimized builds pass CI.
8. Feature status in README/spec is accurate.

## 11. Implementation order

1. Make the current subset honest and fail-closed: stop silently skipping `enum`, `trait`, `impl`, `mod`, `const`, `type`, `extern`, or unsupported syntax.
2. Establish source spans, structured diagnostics, parser recovery, name resolution, and a real semantic/type-checking phase.
3. Verify canonical IR and make code generation reject any invalid or unsupported IR operation.
4. Complete integer semantics, local variables, functions, control flow, arrays/slices, and pointer rules end to end.
5. Implement deterministic layout and the initial C ABI, with executable interop tests.
6. Implement safe/unsafe boundaries, allocator APIs, defer semantics, and no-runtime/freestanding mode.
7. Add atomics, volatile/MMIO, SIMD, inline assembly, and target intrinsics one capability at a time.
8. Add generics and compile-time evaluation after type checking and resource limits are reliable.
9. Complete register allocation/spilling, relocations, debug/unwind metadata, and reproducible performance benchmarks.
10. Add another target only after the target-independent semantic contract and backend conformance suite are stable.

The priority is a small, fully implemented and testable low-level core—not a large keyword list whose constructs are ignored by the compiler.


## 12. Proposed low-level syntax and keyword surface

The bootstrap lexer now recognizes the following additional reserved words:

| Keyword | Intended meaning | Implementation status |
|---|---|---|
| `unsafe` | Explicit scope for operations whose safety cannot be proven | Lexer only; parser, semantic rules, and codegen are not implemented |
| `volatile` | Observable memory access for device/MMIO use | Lexer only; memory-ordering and target semantics are not implemented |
| `asm` | Inline assembly with explicit constraints and clobbers | Lexer only; not executable syntax |
| `align` | Explicit alignment declaration or expression | Lexer only; layout validation is not implemented |
| `packed` | Packed aggregate layout | Lexer only; ABI and unaligned-access rules are not implemented |
| `union` | Explicit overlapping storage | Lexer only; type checking and layout are not implemented |
| `unreachable` | Assert that control flow cannot reach a point | Lexer only; semantics are not implemented |
| `as` | Explicit cast syntax | Lexer only; cast validation is not implemented |
| `isize`, `usize` | Target-pointer-width signed and unsigned integers | Lexed as type keywords; target-aware layout and codegen are not implemented |
| `i128`, `u128` | 128-bit signed and unsigned integers | Lexed as type keywords; arithmetic and ABI support are not implemented |
| `never` | Uninhabited return/control-flow type | Lexer only; type-system support is not implemented |

These words are reserved by the lexer but are **not yet supported language features**. Until each feature has parser, semantic-analysis, IR, backend, diagnostics, and end-to-end tests, the compiler must reject its use rather than silently accept it or emit incorrect machine code.

Intended syntax sketches (design examples only; currently not compilable):

```lir
unsafe {
    // raw pointer arithmetic and other explicitly unsafe operations
}

const DEVICE: usize = 0xF000_0000;
volatile write32(DEVICE, 1);

asm("pause"); // final design must specify operands, constraints, clobbers, and ABI rules

struct CacheLine align(64) {
    packed: u64
}

union Word {
    signed: i64,
    unsigned: u64
}

fn checked_cast(x: i64) -> i32 {
    return x as i32;
}
```

The syntax sketches are not a promise of current support. Before implementation, settle precedence, grammar, layout, aliasing, volatile semantics, and target-dependent type widths in the specification.
