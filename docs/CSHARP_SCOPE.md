# C#-inspired capabilities: implemented scope and missing runtime

LIR is a native systems-language compiler, not a C# compiler or a .NET runtime.
It cannot currently run C# source, load CLR assemblies, or use the .NET Base Class
Library. This phase adds a bounded language feature; it does not establish C#
compatibility or parity with every C# operation.

## Implemented: named arguments and optional parameters

```lir
const BASE = 4

fn calculate(a: i64, b: i64 = BASE * 2, c: i64 = 3) -> i64 {
    return a * 100 + b * 10 + c
}

fn main() -> i64 {
    printInt(calculate(1))             // 183
    printInt(calculate(c: 9, a: 2))    // 289
    printInt(calculate(2, c: 5))       // 285
    return 0
}
```

### Contract

- Supported on statically resolved, direct **free-function calls**. Function
  pointers/closures, methods, trait dispatch, enum constructors, and builtins
  do not accept named arguments in this phase; unsupported forms are diagnosed.
- Parameter names are case-sensitive declaration names. Unknown names,
  duplicates, positional/named collisions, missing required parameters, and
  excess arguments are errors. Types are checked against the named destination,
  not the argument's source position.
- Positional arguments must precede all named arguments. This is an intentionally
  smaller rule than all combinations accepted by modern C#.
- Supplied argument expressions are evaluated exactly once, left to right in
  **source order**, then their values are placed in parameter order. Reordering
  labels must not reorder side effects.
- Parameters with defaults must be trailing. Defaults are type-checked at the
  declaration, even if no caller omits them.
- Defaults accept scalar compile-time constant expressions or string literals.
  Integer, boolean, and f64 defaults are exercised by the execution tests. They
  cannot invoke runtime functions, allocate containers, or depend on parameter
  values. Default expressions are resolved in declaration/global context, not
  against caller locals. Imported defaults retain their source context.
- Defaults are substituted at direct call sites. The function ABI and parameter
  count are unchanged. Function values still require the full positional
  signature; defaults are not attached to an indirect function value.
- Methods and entry-point `main` parameters cannot declare defaults in this
  phase. The existing limit of eight parameters/arguments still applies.
- Simple generic inference now associates supplied named arguments with the
  right declaration parameter before inference. This does not solve general
  nested or constraint-driven generic inference.
- Named/defaulted calls are explicitly rejected when the limited scalar
  compile-time evaluator attempts to execute them. This prevents early folding
  from bypassing semantic validation. A `const` value can still be used as a
  default expression; invoking an optional-parameter function in `const` or
  `comptime` evaluation is a separate, unsupported capability.

Example: `examples/named-arguments.lir`.

## Regression gate

```sh
zig build -Doptimize=ReleaseFast
python3 tests/call_test.py ./zig-out/bin/lir
```

The test suite checks two fixtures across native ELF, IR VM, host C11 and
wasm32-wasi at O0/O1/O2 (24 executions), plus 20 invalid programs. Fixtures cover
source-order side effects, omitted parameters, mixed positional/named calls,
string/bool/float defaults, simple generic name-based inference, and imported
defaults that must not capture caller variables. A C toolchain and Node 22+ or
Wasmtime are required, as for the existing backend matrix. CI runs this gate.

## Capabilities still needed for a C#-scale environment

These are future design/integration tasks, not implemented checkboxes:

| Area | Remaining work |
|---|---|
| Object model | Classes, reference identity, inheritance, virtual methods, access rules, properties, indexers, events |
| Managed runtime | GC, root tracking, object layouts, runtime type identity, safe managed references |
| Exceptions | Typed exceptions, stack unwinding, catch/finally, interaction with defer and FFI |
| Async/iteration | Task model, async state machines, await, cancellation, iterators/yield, async streams |
| Type system | Overloads, generic constraints/variance, richer inference, nullable flow analysis, richer interfaces |
| Dynamic facilities | Reflection metadata, dynamic binding, runtime code loading, attributes |
| Standard ecosystem | Collections and query APIs, Unicode/text, time, networking/TLS, database and serialization APIs |
| .NET interoperability | A deliberate CLR backend or separately designed bridge; assembly loading, marshaling, runtime deployment |
| Tooling | Package resolution, language server, debugger/source mapping, formatting, production diagnostics |

Some existing LIR facilities (traits, closures, generics, Option/Result, threads,
pattern matching) address related use cases, but they are not drop-in substitutes
for the corresponding C# or .NET semantics. Runtime and object-model decisions
must precede a credible promise of ecosystem-wide parity.
