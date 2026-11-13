# Implemented language extensions

These features are implemented in the Zig bootstrap frontend and lowered to
portable IR. The execution matrix checks Linux x86-64 native ELF, IR VM, host C11,
and wasm32-wasi at `-O0`, `-O1`, and `-O2`. This does not establish support for
all target architectures or constitute a complete language-safety guarantee.

## Unconditional loops

```lir
let mut count = 0
loop {
    count += 1
    if count == 2 { continue }
    if count == 5 { break }
}
```

`loop` is now a reserved keyword. It is a statement lowered to `while true` and
uses the existing loop-scope semantics for `break`, `continue`, `return`, and
`defer`. Nested loops are supported. Loop values, labeled exits, and `break value`
are not added by this change. Existing spin-loop diagnostics still apply.

## Unary plus

`+expression` is numeric identity, supported for integer and floating-point
operands, including constant expressions. It does not convert a string or bool
to a number. It evaluates its operand once. Unary signs bind less tightly than
exponentiation and more tightly than multiplication.

```lir
const count = +12
let temperature: f64 = +1.5
```

## Integer exponentiation

```lir
printInt(2 ** 3 ** 2)  // 512: right-associative
printInt(-2 ** 2)      // -4: exponentiation precedes unary minus
printInt((-2) ** 3)    // -8
printInt(2 * 3 ** 2)   // 18
const limit = 3 ** 4   // 81: constant evaluation is supported
```

Both operands must be `i64`. Floating-point power and implicit width/signedness
conversions are not supported. Operands are evaluated once, base before exponent.
The exponent must be nonnegative: a statically known negative exponent is a
compile-time error; a dynamic negative exponent traps at runtime. Trap exit codes
and messages remain backend-specific, but execution must not succeed.

The result is computed modulo 2^64 and interpreted as signed `i64`, consistently
at compile time and runtime. `0 ** 0` is defined as `1`. Exponentiation by squaring
requires at most 63 iterations for a nonnegative `i64` exponent; it does not loop
once per exponent value. There is no `**=` operator in this release.

## Eight integer intrinsics

All arguments must be `i64`. Except for the boolean predicate, results are `i64`.
Use explicit casts when passing other integer widths or signedness. Bit-pattern
operations interpret the input as 64 bits, not as an arbitrarily wide integer.

| Intrinsic | Behavior |
|---|---|
| `@rotl(value, count)` | Rotate the 64-bit pattern left by `count & 63` |
| `@rotr(value, count)` | Rotate the 64-bit pattern right by `count & 63` |
| `@bit_reverse(value)` | Reverse all 64 bits |
| `@is_power_of_two(value)` | `bool`: true only for positive signed powers of two |
| `@signum(value)` | `-1`, `0`, or `1` according to signed value |
| `@wrapping_add(a, b)` | Sum modulo 2^64, interpreted as signed `i64` |
| `@wrapping_sub(a, b)` | Difference modulo 2^64, interpreted as signed `i64` |
| `@wrapping_mul(a, b)` | Product modulo 2^64, interpreted as signed `i64` |

Rotation by 0 or a multiple of 64 is identity; negative counts normalize in the
same way (`@rotr(1, -1)` is `2`). Neither rotation generates an illegal shift by
64. `@bit_reverse(1)` is MIN_I64. `@is_power_of_two(0)` and
`@is_power_of_two(MIN_I64)` are false. Arguments are evaluated exactly once,
left-to-right, even when lowering uses a value multiple times.

These intrinsics are runtime expressions that can be optimized through normal
IR passes. Support for evaluating arbitrary intrinsic calls in `const` or
`comptime` contexts is not introduced by this change; the power operator and
unary plus have explicit constant-evaluator integration.

## Regression coverage

```sh
zig build
python3 tests/backend_test.py ./zig-out/bin/lir
python3 tests/cli_test.py ./zig-out/bin/lir
zig build test
```

The backend suite requires a host C compiler and Node 22+ or Wasmtime. It now
runs nine positive fixtures at three optimization levels on four backends
(108 executions), plus 12 dynamic-negative-exponent trap checks. Numeric expected
values include independent Python integer/bit-pattern calculations, not merely
agreement between LIR backends. Diagnostics cover invalid operand types, argument
counts, negative constant exponents, and malformed loop syntax. Generated test
programs and compiler outputs live in temporary directories.

Runnable examples:

- `examples/loop-control.lir`
- `examples/integer-power.lir`
- `examples/integer-intrinsics.lir`

The float identity example exposed a pre-existing native `printFloat` bug: the
printer freed a pointer eight bytes into its allocation. The native printer now
passes the allocation base to `free`, preserving heap-header validation rather
than disabling its trap.
