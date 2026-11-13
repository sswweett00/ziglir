# Bootstrap review and development priorities

## Scope

This review examined the bootstrap build, CLI, project scaffolding, compiler driver,
IR verifier, test infrastructure, and published implementation claims. It is not a
complete security audit of the roughly 40,000-line bootstrap or a certification of
backend parity. Features in the roadmap still require end-to-end evidence.

## Implemented improvements

- `zig build run -- <args>` now forwards arguments to the compiler.
- `lir init demo` creates `demo/project.manifest` and `demo/src/main.lir`, matching
  the Quick Start instructions, instead of writing into the current directory.
- Initialization refuses existing directories (including empty ones), files,
  unsafe names, and `.` / `..`. It uses exclusive file creation and removes its
  newly created project directory if creation fails. Existing projects are never
  intentionally overwritten. This is not a sandbox against a malicious process
  concurrently modifying the parent directory.
- `check`, `ir`, and `test` reject extra positional arguments; `ir` rejects
  unknown options; `init` rejects extra arguments. `run` deliberately retains
  program-argument forwarding; use `--` to explicitly separate program arguments.
- Added isolated starter-project unit tests and a Python standard-library CLI
  regression suite, wired into CI. Tests exercise metadata, argument errors,
  generated-project checking, VM execution, native/C emission, and preservation
  of an existing artifact on compilation failure.

## Run the checks

Use Zig 0.13.0 and Python 3:

```sh
zig build
zig build test
python3 tests/cli_test.py ./zig-out/bin/lir
python3 tests/backend_test.py ./zig-out/bin/lir
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build run -- version
```

The unit suite executes Linux ELF artifacts and is currently Linux-oriented.
The CLI regression suite uses a temporary directory and a 30-second subprocess
limit; compiler paths are resolved before changing the working directory.

## Next priorities (not implemented by this change)

1. **Backend semantic parity:** expand differential native/VM/C/Wasm tests for
   signed division, overflow, shifts, arrays, strings, traps, and call ABI. A file
   being emitted successfully does not establish equivalent execution semantics.
2. **Optimization coverage:** CLI `build`, `run`, and `test` now honor `-O0`
   instead of silently promoting it to `-O2`. Continue extending the optimization
   matrix to advanced features and error paths before making performance claims.
3. **IR verification:** structural verification is present, but needs a systematic
   audit of register definitions/dominance, phi predecessor correspondence,
   terminators, call signatures, and consistency with backend frame limits.
4. **Safety claims:** full ownership/lifetime checking is explicitly unfinished.
   Audit each README safety claim with positive and negative runtime tests for
   each backend before treating it as a language-wide guarantee.
5. **Portable testing:** separate Linux ELF execution tests from portable frontend
   tests; add macOS/Windows host build and execution jobs before promising parity.
6. **Project system:** connect manifest consumption, dependency resolution, and
   test discovery to the bootstrap CLI. Scaffolding a manifest is not evidence of
   a complete package manager.
7. **Version consistency:** CLI reports 2.2.0 while build.zig.zon reports 2.0.0;
   select a release version policy and derive both from a single source.

Avoid adding more syntax before these correctness gates and reproducible
performance baselines are established.

## Second development pass: optimization and execution parity

- Removed silent `-O0` promotion from `build`, `run`, and `test`. The default
  remains `-O2`; semantic checks and mandatory lowering still run at `-O0`.
- Added `tests/backend_test.py`: four independent expected-output fixtures run on
  native ELF, IR VM, C11, and Wasm at `-O0`, `-O1`, and `-O2` (48 executions).
  Coverage includes recursion, nonzero return status, signed division/remainder,
  shifts, branches, loop-carried values, strings, and indexed arrays.
- Added a separate IR comparison regression that distinguishes `-O0` from `-O2`
  and checks `build --emit-ir -O0` against `ir -O0`. Output equivalence alone
  would not detect silently substituted optimization levels.
- The Wasm matrix exposed a Node runner bug: `wasi.start()` returned the program's
  exit status, but the JS runner discarded it. The runner now assigns that result
  to `process.exitCode`, so nonzero status reaches the calling shell. This was
  reproduced at all three optimization levels and the matrix passes after the fix.
- CI installs Node 22 and runs the backend matrix. A C toolchain and Node 22+ or
  Wasmtime are required locally. These are selected correctness fixtures, not a
  proof of complete backend parity or a performance benchmark.

## Third development pass: language features

Implemented `loop` statements, numeric unary plus, right-associative i64 `**`,
and eight integer intrinsics. See [Language extensions](LANGUAGE_EXTENSIONS.md)
for exact contracts and intentional restrictions. Runtime power uses bounded
exponentiation by squaring with a negative-exponent trap; constant evaluation
and AST folding share the wrapping-power helper. All new operations lower to
existing IR, so no backend-specific opcode implementations are required.

The backend matrix now has nine positive fixtures (108 executions), 12 negative
runtime exponent checks, and compile-time diagnostics for invalid uses. A native
float-print interior-pointer free discovered during testing was also corrected.

## Fourth development pass: selected core-language phase

Added nested tuple patterns, typed arm-local bindings, and guarded wildcards.
Strengthened match result/guard/pattern checks, enum payload arity validation,
range typing and unsigned comparisons, tuple destructuring arity, inferred tuple
metadata, and recursive tuple compatibility. Unsupported alternative bindings and
non-binding enum payload patterns now fail explicitly rather than being silently
miscompiled. See [Core language phase 1](CORE_LANGUAGE.md) for compatibility
changes, tests, and remaining generic-inference work.

Validation for this phase: 91/91 Debug unit tests; 24 core fixture executions and
25 negative frontend cases; existing backend and CLI suites. The core execution
matrix also passes using Zig's C compiler. This is not a full borrow-checker or
complete type-inference implementation.

## Fifth development pass: recursive enum payload patterns

Replaced binding-only enum payload analysis with recursive, field-typed pattern
analysis. Literal, tuple, nested constructor, and constant integer range payloads
are supported. IR lowering gates payload field loads on a successful constructor
tag comparison and recursively binds names only in a fully matched arm.

Constructor exhaustiveness now depends on irrefutable payloads: a pattern such as
`Some(7)` cannot cover the entire Some variant. The coverage model deliberately
remains conservative rather than attempting a full pattern-space solver.

The core suite now runs three fixtures (36 backend/optimization executions) and
31 negative frontend cases. The new fixture also exercises range endpoints,
failed nested guards, string payloads, and payload-free unmatched variants.
Validation: 91/91 Debug unit tests, core/backend/CLI Python suites, and the core
matrix with Zig's C compiler all passed. See CORE_LANGUAGE.md for the current
contract; earlier pass descriptions above are historical snapshots.

## Sixth development pass: C#-inspired call ergonomics

Added named arguments and trailing constant-default parameters for direct free
functions. Semantic resolution records argument-to-parameter mappings without
reordering source evaluation; IR lowering evaluates supplied arguments once in
source order, then arranges values and fills omitted defaults. Imported defaults
are resolved in declaration context. Simple generic inference also resolves
named arguments to declaration parameters before inferring their types.

Unsupported named call categories and nonconstant/ill-typed defaults fail
explicitly. Extended calls are rejected during scalar compile-time evaluation
rather than being folded before semantic checks. This is deliberately not a CLR,
.NET library bridge, managed object model, or claim of full C# compatibility.

Validation: 91/91 Debug unit tests; 24 call-suite backend/optimization executions;
20 invalid call/default programs; existing core/backend/CLI suites. The new call
matrix also passes using Zig's C compiler. See CSHARP_SCOPE.md for contracts,
limitations, and the missing runtime/ecosystem capabilities.

## Seventh pass: manifest-driven project foundation

Added typed, size-limited manifest loading and consistent optional file/directory
selection for build/run/check/ir/test. Project output names derive from the
validated manifest name; explicit file and output paths retain their contracts.
The starter now shares a library between main and an independent test entry.
Unknown/invalid settings fail closed; legacy metadata does not execute scripts,
resolve dependencies or enforce permissions. Path validation is lexical, not a
sandbox. Missing project tests produce an error instead of running main.

The project integration suite covers all four execution backends, custom nested
entries/imports, argument forwarding, generated artifacts, manifest failures and
single-file compatibility. See PROJECTS.md for scope and remaining milestones.

## Eighth pass: browser execution bridge

Added an opt-in JavaScript host for the emitter's seven existing WASI imports,
without changing the compiler's WASI target or CLI execution semantics. Validates
memory ranges, preserves streaming Unicode, uses only Web Crypto randomness,
and distinguishes intentional exits from traps. The counter example executes
actual LIR arithmetic on each DOM event; DOM and events remain explicit JS glue.
The host is synchronous, single-use and not a resource sandbox. Node-based
conformance tests and real O0/O1/O2 compiler-output tests supplement existing
backend/project regressions; no browser UI automation is claimed.
