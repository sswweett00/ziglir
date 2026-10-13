# Ziglir Compiler Architecture: Correctness First, Performance by Evidence

## Mission

Ziglir is a compiler written in Zig that directly emits native machine code. The compiler must not depend on GCC, Clang, LLVM, or another compiler as a hidden implementation layer. Its first supported target remains Linux x86-64 ELF until another backend has its own conformance suite.

The design optimizes in this order:

1. Preserve language semantics and reject invalid programs.
2. Make compiler invariants explicit and checkable.
3. Produce deterministic, inspectable output.
4. Optimize only transformations with correctness evidence.
5. Measure compile time, runtime, memory, and binary size independently.

No engineering process can prove a general compiler has zero defect probability. The goal is to make incorrect output difficult to introduce, easy to detect, and impossible to silently treat as a successful build.

## Target pipeline

```text
Source bytes
  -> Lexer (source spans + structured diagnostics)
  -> Parser (bounded AST + recovery)
  -> Name resolution
  -> Type checking and semantic validation
  -> Typed, canonical IR
  -> IR verifier
  -> Optimization pipeline (each pass preserves verified invariants)
  -> Lowered machine IR (explicit control flow, ABI, and stack effects)
  -> Register allocation / spilling
  -> x86-64 instruction selection and encoding
  -> Relocation and range validation
  -> ELF layout validation
  -> Atomic output write
```

The existing implementation has only part of this pipeline. Do not label later stages complete until they exist and have tests. In particular, parser acceptance is not semantic validation, and producing bytes is not proof those bytes implement the source program.

## Stage contracts

### 1. Source and diagnostics

- Every token stores a source span and starting line/column.
- Invalid characters, malformed strings, malformed numeric separators, and integer overflow are hard errors.
- Diagnostics are data returned by compiler APIs; parsing and code generation must not call process-exit routines.
- Recovery must always advance the cursor or terminate at EOF. Add a progress invariant to parser loops.
- Capacity exhaustion is a structured error, never a partially valid AST or executable.

### 2. Parsing and semantic analysis

- Parsing constructs syntax only; it must not silently decide types or pretend unsupported syntax is valid.
- Resolve every identifier and function reference before machine-code generation.
- Reject duplicate declarations, unknown names, invalid argument counts, invalid return paths, invalid control-flow targets, and unsupported constructs explicitly.
- Type checking must precede optimizations that rely on types.
- Until ownership and borrowing checks exist, do not promise memory safety or ownership safety.
- AST and symbol-table capacity limits must be explicit, checked before writes, and tested at limit-1, limit, and limit+1.

### 3. Canonical IR

Use a documented, typed IR with explicit basic blocks and terminators. Every block must end in exactly one terminator; every branch target must exist; each value must have one definition if using SSA; every use must be dominated by its definition; function calls must obey a defined calling convention.

Before and after each optimization pass, run the IR verifier in debug/test builds. Release builds may disable expensive duplicate checks only after inputs have been validated and verifier coverage is strong. An invalid IR is a compiler bug and must stop code generation.

Do not add speculative optimizations to the current ad-hoc IR. First define semantics for integer overflow, division edge cases, shifts, booleans, pointer arithmetic, and undefined behavior. Optimizations must preserve those semantics exactly.

### 4. Optimization strategy

Implement in small, independently testable steps:

1. Constant folding with checked arithmetic and explicit overflow semantics.
2. Local simplification and dead-code elimination.
3. Control-flow simplification and unreachable-block removal.
4. SSA construction, dominance, and verified sparse conditional constant propagation.
5. Liveness analysis and register allocation.
6. Target-aware instruction selection and peephole rules.
7. Optional inlining, loop transforms, and vectorization only after profiling shows a real bottleneck.

Every optimization rule needs:
- A written precondition and semantic justification.
- Positive and negative unit tests.
- Differential tests against an unoptimized build.
- Randomized or generated programs where feasible.
- A benchmark showing repeatable benefit.
- A simple way to disable the pass when diagnosing miscompilations.

Never optimize by assuming signed overflow cannot occur unless the language specification explicitly grants that assumption. Never fold expressions with side effects, traps, or unspecified semantics as if they were pure.

### 5. Machine-code backend

- Define the System V AMD64 ABI contract centrally: argument registers, return registers, caller/callee-saved registers, stack alignment, red-zone policy, and call-clobber set.
- Use a single instruction encoder with checked buffer writes and typed register/operand representations; avoid scattered raw byte emission where possible.
- Track stack depth and alignment through every control-flow edge. At a merge, incoming stack states must agree.
- Register allocation must use liveness information and correct spill slots. A virtual register must never alias another live value's storage.
- Validate all branch displacements and relocation ranges before patching. Out-of-range branches must be expanded or rejected, never truncated.
- Verify function entry/exit paths restore the stack and callee-saved registers.
- Generate only supported instructions and reject unsupported IR operations rather than emitting placeholders.

### 6. ELF output and file safety

- Validate all section/program-header offsets, sizes, alignments, entry points, and output-buffer lengths before writing.
- Use checked arithmetic for every size and offset computation.
- Do not return a successful artifact after any encoder, relocation, or layout error.
- Write to a temporary file, check every write and close result, then atomically rename to the destination. A failed compilation must not leave a new partial executable.
- Set executable permissions only after a complete output is successfully written.
- Test generated ELF headers and loadable segments independently of running the output.

### 7. Performance architecture

Prioritize structural wins over fragile micro-optimizations:

- Keep tokenization allocation-free where it remains simple and correct.
- Use arenas for per-compilation AST, IR, and temporary metadata; release the entire arena at compilation end.
- Avoid allocating large fixed arrays on the host stack. Allocate large compiler state from a per-compilation arena or heap with explicit error handling.
- Use compact integer IDs and contiguous arrays for tokens, blocks, instructions, and symbols.
- Avoid repeated name scans: build symbol tables and resolve names once.
- Avoid repeated whole-module walks when an incremental worklist suffices.
- Use a linear-scan allocator first if it is simpler and correct; evaluate graph coloring only when benchmarks justify its complexity.
- Add parallel compilation only at module boundaries with deterministic diagnostics and no shared mutable compiler state.
- Treat cache behavior, instruction count, and compile-time cost as measurable hypotheses, not assumptions.

Do not claim that stack spilling, register allocation, SSA, or a fast path is complete merely because a data structure exists. Completion requires tests and runtime evidence.

## Correctness gates

A change is not complete until relevant gates pass:

1. **Unit tests:** lexer, parser, semantic analysis, IR, encoder, relocation, and ELF layout.
2. **Boundary tests:** every fixed-capacity structure at its boundary and just beyond it.
3. **Negative tests:** malformed source must fail nonzero and must not produce a successful output file.
4. **Differential tests:** optimized and unoptimized outputs agree on program results and observable behavior.
5. **Runtime tests:** generated executables run with expected exit codes, stdout, and stderr.
6. **ABI tests:** nested calls, more arguments than register arguments, recursion, stack alignment, and callee-saved register preservation.
7. **Fuzzing:** arbitrary bytes for lexer/parser and generated valid programs for compiler passes; crashes, hangs, and silent miscompiles are failures.
8. **Reproducibility:** same source, compiler revision, and target produce deterministic output unless nondeterminism is explicitly documented.
9. **CI matrix:** Debug and ReleaseFast; tests must run on every push and pull request.
10. **Performance gate:** a performance change must not regress correctness, compile-time memory, or unrelated benchmark workloads without an explicit trade-off.

For every discovered miscompile, preserve the source as a regression fixture.

## Performance measurement

Compare against a recent optimizing C compiler using equivalent algorithms, input sizes, integer overflow behavior, and observable outputs. Report CPU, OS, compiler versions, flags, warm-up policy, number of repetitions, median, dispersion, binary size, compile time, and peak RSS. Prevent dead-code elimination and verify every result. Do not use one microbenchmark to claim general superiority over C.

Track at minimum:
- Compiler wall time and source throughput.
- Peak resident memory and allocation count.
- Generated code size.
- Runtime throughput and startup latency.
- Number of spills, loads/stores, branches, and dynamic instructions where measurement tools permit.

Keep a baseline artifact and compare on stable runners. Use broad regression thresholds and repeat suspicious results before failing CI.

## Implementation order

### Gate A — Stabilize the existing compiler
- Make every compiler stage return structured errors; remove process termination from reusable compiler modules.
- Add progress guards and capacity checks to every fixed-size table and every write.
- Make output creation atomic and ensure failures cannot leave a success-looking executable.
- Add boundary and negative tests; run the full CI suite.

### Gate B — Establish semantics
- Document the implemented LIR subset and integer semantics.
- Add name resolution, duplicate-name checks, argument validation, and type checking.
- Reject unsupported syntax before IR lowering.

### Gate C — Make IR verifiable
- Specify the IR and control-flow invariants.
- Add a verifier and run it around every optimization pass.
- Add differential tests with optimizations enabled and disabled.

### Gate D — Improve generated code
- Centralize ABI and instruction encoding.
- Add correct liveness analysis, register allocation, and spill handling.
- Validate stack alignment, call clobbers, branch ranges, and relocations.
- Add disassembly and execution-based regression tests.

### Gate E — Optimize by evidence
- Establish C comparison benchmarks and LIR baselines.
- Add one optimization at a time, retaining only correctness-proven improvements.
- Profile real programs before attempting inlining, vectorization, or parallel compilation.

## Definition of done

A feature is complete only when its semantics are documented, errors are explicit, tests cover positive/negative/boundary cases, CI passes, and its implementation is integrated end-to-end. A compiler is not production-ready merely because it builds, emits ELF, or passes a few example programs.
