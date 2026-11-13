# Core language phases 1–2: typed and recursive patterns

This is an incremental implementation, not parity with C++, Java, Rust, Go,
Elixir, Odin, or Python. Complete generic argument/lifetime inference, ownership
checking, and recursive ADT exhaustiveness remain separate projects.

## New patterns

Tuple patterns use the existing tuple syntax and support nesting, literals,
wildcards, and immutable bindings:

```lir
fn describe(value: ((i64, bool), string)) -> i64 {
    return match value {
        ((1, true), "ready") => 100,
        ((number, _), text) if text == "ready" => number,
        ((_, _), _) => -1,
    }
}
```

The scrutinee is evaluated once. Fields use the existing eight-byte-slot tuple
layout. Bindings are available to that arm's guard and body only, retain their
field types, and are not available after the match. Duplicate binding names in
one pattern are errors. Existing local names and global constants retain the
pre-existing value-pattern meaning; they are not silently shadowed by bindings.

Patterns must have the same tuple shape as their scrutinee. An entirely
irrefutable tuple pattern, e.g. `(a, _)`, counts as a catch-all. The exhaustiveness
checker does not attempt product-space proofs: `(true, _)` and `(false, _)` alone
still need an irrefutable fallback.

## Recursive enum payload patterns

```lir
enum Inner { Number(i64), Empty }
enum Event { Nested(Inner), Data((i64, bool)), Stop }

fn read(event: Event) -> i64 {
    return match event {
        Event::Nested(Inner::Number(0)) => 100,
        Event::Nested(Inner::Number(n)) if n > 10 => n,
        Event::Nested(_) => -1,
        Event::Data((1..10, true)) => 1,
        Event::Data((number, _)) => number,
        Event::Stop => 0,
    }
}
```

Nested patterns are type-checked against the corresponding payload field. The
lowered control flow verifies each constructor tag before loading any of that
constructor's payloads. Failed inner matches continue to the next outer arm;
bindings become available only after the whole pattern matches.

The parser accepts integer ranges inside tuple fields and constructor arguments,
not only at the top level. Ranges remain compile-time-bounded integer patterns;
`1..10` excludes 10, whereas `1..=10` includes it. These are pattern-context rules,
not new general-purpose range values.

Coverage is deliberately conservative: a constructor contributes full variant
coverage only when **every** payload pattern is irrefutable. `Some(7)` does not
cover every `Some`; `Some(n)` and `Some(_)` do. Even a set of specific patterns
that a human can prove exhaustive may still require a fallback. Guarded arms
never contribute coverage. Full recursive ADT coverage proofs are not claimed.

These extensions apply to normal runtime matching. The limited compile-time
interpreter is not expanded into a full ADT evaluator by this change.

## Guarded wildcards

```lir
fn sign(value: i64) -> i64 {
    return match value {
        _ if value < 0 => -1,
        _ if value == 0 => 0,
        _ => 1,
    }
}
```

`_ if condition` is now a normal, ordered, guarded arm. Its condition must be
`bool`; guarded patterns never establish exhaustiveness. An unguarded `_` or
`else` must be last, and duplicate default arms are rejected instead of silently
replacing an earlier arm. Use `_ if`, not `else if`, in match syntax.

## Stronger type and structural checks

- Match guards must be boolean.
- Patterns must be compatible with their scrutinee type. Matching an integer
  against a string or an enum variant from another type is rejected.
- Value-producing arms must be compatible with the first non-diverging arm's
  result type. A branch that definitely returns or otherwise diverges does not
  constrain the result type. Mixing a void arm and a value arm is an error.
  This is deliberately not a new, general-purpose least-upper-bound inference
  algorithm.
- Enum payload patterns must have the declared arity and compatible field types.
  They support literals, bindings, wildcards, tuples, nested enum constructors,
  and constant integer ranges. Payload matching and binding are recursive.
- Bindings in `p1 | p2` alternatives are rejected until common binding-set and
  path-sensitive lowering support is implemented. Binding-free alternatives
  retain their existing behavior.
- Range patterns require compatible integer bounds that are compile-time
  constants. Unsigned ranges now use unsigned IR comparisons, including values
  above MAX_I64.
- Tuple destructuring declarations require a tuple with exactly the same arity.
- Inferred tuples preserve integer widths/signedness and all type metadata
  representable by the existing type-spec machinery instead of defaulting most
  fields to i64. Tuples exceeding the existing eight-field descriptor capacity
  fail explicitly. Nested tuple compatibility is checked recursively.

These changes intentionally reject some programs previously accepted with unsafe
or misleading behavior. They do not add named fields, rest patterns, array/slice
patterns or full recursive ADT coverage analysis.

## Regression gates

```sh
zig build -Doptimize=ReleaseFast
python3 tests/core_test.py ./zig-out/bin/lir
python3 tests/backend_test.py ./zig-out/bin/lir
python3 tests/cli_test.py ./zig-out/bin/lir
zig build test
```

The core suite runs three executable fixtures through native ELF, IR VM, host C11,
and wasm32-wasi at O0/O1/O2 (36 executions), and checks 31 invalid programs for
both failure and the relevant diagnostic. It requires a C compiler and Node 22+
or Wasmtime, like the backend suite. It runs in CI alongside existing tests.

Examples:

- `examples/tuple-patterns.lir`: nested tuple matching, literals, bindings,
  boolean/string fields, guarded fallthrough, guarded wildcards.
- `examples/typed-match.lir`: explicit generic identity, Option payload bindings,
  u8-preserving tuple inference, high unsigned ranges, and returning arms mixed
  with value arms.

- `examples/enum-patterns.lir`: literal/range payloads, nested constructors,
  tuples inside payloads, string payload matching, guard fallthrough, and safe
  skipping of fields belonging to unmatched variants.

## Next core-language work

1. Normalize pattern representation instead of reusing expression AST shapes.
2. Extend the conservative payload coverage model to prove unions of payload
   subspaces (e.g. `A(true)` plus `A(false)`), with independently checked tests.
3. Implement binding-set unification for alternative patterns.
4. Improve generic inference from typed locals, nested generic calls, and
   contextual Option/Result constructors. Nested calls such as
   `identity(Some(11))` are not established as supported by this phase; explicit
   generic arguments and typed constructor-returning helpers remain useful.
5. Unify tuple, closure, function, and branch type joins before claiming complete
   inference, then add lifetime/borrow analysis as a separately tested subsystem.
