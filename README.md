# LIR — A Simple, Performance-First Systems Language

<p align="center">
  <b>Write simply. Compile natively. Measure every optimization.</b>
</p>

---

## What is LIR?

LIR is a systems-language project aiming to combine a small, approachable syntax with predictable memory use and highly optimized native code. Its long-term performance goal is to outperform C on selected, benchmarked workloads without sacrificing correctness or readability. That is a goal to prove with reproducible measurements—not a universal speed guarantee. The bootstrap compiler features zero-dependency direct emitters for Linux x86-64 ELF and `wasm32-wasi`, a portable in-process IR VM (`--backend=vm`), and a portable C11 backend (`--backend=c` / `--emit-c`) supporting ARM64, RISC-V, macOS, Windows, FreeBSD, and Linux; features listed as design goals in [Low-Level Language Specification](docs/LOW_LEVEL_LANGUAGE.md) distinguish design requirements from implemented features.

### Design principles

- **Zig-native implementation:** the checked-in bootstrap compiler and native code-generation pipeline are implemented in Zig. Direct `x86_64-linux` ELF64 and `wasm32-wasi` `.wasm` emitters require no external toolchain, while `--backend=c` / `--emit-c` lowers verified IR to strict C11 for cross-platform compilation (`cc` / `zig cc`) and `--backend=vm` runs programs directly in-process.
- **Readable language design:** syntax should stay small and consistent; unsupported features must fail explicitly rather than silently generating incorrect code.
- **Measured performance:** performance claims require repeatable benchmarks against equivalent C implementations, including correctness checks. No universal claim that LIR is faster than C is made.
- **Honest implementation status:** memory safety, compile-time execution, concurrency primitives, cross-compilation, and a stable standard library are not advertised as complete unless they are implemented and tested.

| Capability | Current status |
|---|---|
| Bootstrap compiler implementation | Zig (SSA IR + optimizer + x86-64 ELF, Wasm32-WASI, C11, and IR VM backends) |
| Native output | Zero-dependency Linux x86-64 ELF64 (`ET_EXEC`) & `wasm32-wasi` (`.wasm`); C11 cross-targets for ARM64/RISC-V/macOS/Windows/FreeBSD |
| External compiler required at runtime | No for `x86_64-linux`, `wasm32-wasi`, and `--backend=vm`; optional `cc`/`zig cc` for C11 cross-targets |
| Multi-paradigm features | Generics, ADTs (`Option`/`Result`), `match` + guards, expression `if`/`elif`/`else`, repeat arrays `[val; N]`, compound bitwise/shift ops (`&=`, `|=`, `^=`, `<<=`, `>>=`), `panic(...)`, closures, `trait`/`dyn Trait`, tuples, maps, list comprehensions, string interpolation, unions |
| Compile-time execution | `comptime` blocks/`fn`, `@size_of`, `@align_of`, `@type_name`, `@target_os`, `@target_arch`, `@target_ptr_bits` |
| Built-in concurrency | OS threads (`spawn`, `@thread_join`), channels (`@chan_*`), mutexes, atomics (`@atomic_add`, `@atomic_cas`) |
| Embedded standard library | Zero-wrapper `std::{core,io,os,sys,net,crypto,json,math,str,algo,testing}` with string helpers (`str_trim`, `str_to_upper`/`lower`, `str_index_of`, `str_repeat`), Shell sort / binary search / `gcd`/`lcm`/`pow`, `eprint`, `append_file`, RFC 8529 JSON escaping, unbiased `random_range`, constant-time primitives, saturating/checked math |
| Security & safety architecture | Compile-time UAF/double-free/defer-conflict/close/loop-leak analysis, compile-time heap/string/const-ptr bounds checks, `fn` pointer cast & thread entry validation, 32 KiB per-function stack frame budget, non-terminating spin-loop detection, strict W^X ELF64 (RX `.text`, R-only NX `.rodata`, RW NX `.bss`/stack), CSPRNG `getrandom` stack & heap header/overflow canaries, full zero-wipe on `free`, `<4096`/kernel-space pointer traps, coarse indirect-call CFI, `PROT_NONE` thread stack guard pages, HashDoS-keyed maps, shift traps, exhaustive `match`, strict `?` |
| Optimizer pipeline | `-O2` default on all CLI `build`/`run`/`test`/`check` invocations (`-O0` disables optional AST/IR optimizations; `-O1` is also honored): 2-pass function inlining (`<= 8` blocks, `<= 48` locals, `<= 56` insts), Cytron SSA `mem2reg`, unconditional power-of-2 strength reduction (`mul` -> `shl`, `udiv` -> `ushr`, `umod` -> `bit_and`, `* -1` -> `neg`), GVN, trap-safe LICM, DCE |
| Full borrow checker / embedded `no_std` | Planned (full lifetime borrow checking and bare-metal `no_std` remain future work) |
| Performance versus C | Must be established workload-by-workload with reproducible benchmarks |

## Comparison vs C, Rust, Zig, and Go

| Capability | C (C23) | Rust | Zig | Go | LIR (Current Bootstrap) |
|---|---|---|---|---|---|
| Direct native ELF/WASM without external linker | No | No (LLVM + lld) | Self-hosted | Go linker | **Yes** (`x86_64-linux` ELF64 & `wasm32-wasi` `.wasm`) |
| Generics (`fn<T>`, `struct<T>`) | No (`_Generic`) | Yes | Yes (`comptime`) | Yes | **Yes** (monomorphized) |
| Algebraic data types (`Option`/`Result` + `?`) | No | Yes | Error unions (`!T`) | Multi-return | **Yes** (`Option`/`Result`, `?`, `??`) |
| Expression-valued `if`/`elif`/`else` & `match` | Ternary only | Yes | Yes | No | **Yes** (`if`/`elif`/`else`, `match`) |
| Fixed arrays `[N]T` + `[val; N]` + bounds checks | Manual | Yes | Yes | `[N]T` | **Yes** (compile + runtime bounds + zero-fill) |
| Bitwise/shift compound ops (`&=`, `|=`, `^=`, `<<=`, `>>=`) | Yes | Yes | Yes | Yes | **Yes** (signed/unsigned + shift checks) |
| Compile-time execution (`comptime`) | `constexpr` | `const fn` | Yes | `const` only | **Yes** (`comptime` blocks & `fn`) |
| Built-in OS threads, channels, atomics | C11 / pthreads | `std::sync` / `mpsc` | `std.Thread` | Goroutines / chan | **Yes** (`spawn`, `@chan_*`, `@atomic_*`) |
| Built-in W^X + stack/heap canaries + zero-on-free | Flag-dependent | Flag-dependent | Debug/Safe | Runtime GC | **Yes** (always-on CSPRNG + W^X/NX + zero-wipe) |
| `panic(...)` + trap on null/div0/OOB/shift | UB by default | Panic | Safety-checked | Panic | **Yes** (stderr message + `ud2` trap + bounds checks) |
| Full lifetime borrow checker / GC | No | Borrow checker | Manual/arenas | Tracing GC | Compile-time UAF/leak/defer/bounds analysis (full borrow checker planned) |
| Multi-target architectures (ARM64/RISC-V/etc.) | Yes | Yes | Yes | Yes | **Yes** (`x86_64`/`aarch64`/`riscv64`/`wasm32` across Linux/macOS/Windows/WASI/FreeBSD) |

## Quick Start

The bootstrap compiler is built with **Zig 0.13.0** and runs on Linux, macOS, and Windows.

```bash
git clone https://github.com/sswweett00/ziglir.git
cd ziglir

# Build the compiler and run its unit tests
zig build -Doptimize=ReleaseFast
zig build test

# List supported cross-compilation targets and backends
./zig-out/bin/lir targets

# Compile and run natively or via portable IR VM / Wasm32-WASI / C11
./zig-out/bin/lir build tests/fixtures/test.lir -o /tmp/lir-example
/tmp/lir-example
./zig-out/bin/lir run examples/hello-world/src/main.lir --backend=vm
./zig-out/bin/lir build examples/hello-world/src/main.lir --target=wasm32-wasi -o /tmp/hello.wasm
./zig-out/bin/lir build examples/hello-world/src/main.lir --target=aarch64-macos -o /tmp/hello-mac

# Optional: generate a starter project
./zig-out/bin/lir init myproject
cd myproject
../zig-out/bin/lir check
../zig-out/bin/lir run
../zig-out/bin/lir test
../zig-out/bin/lir build
./myproject.out
```


See [Project workflows](docs/PROJECTS.md) for manifest settings, directory selection,
output paths, and the remaining application/ecosystem roadmap.

## Browser execution (initial bridge)

The existing Wasm output can run in a browser using the small WASI host in
`runtime/browser/wasi.mjs`. A button-driven LIR counter demonstrates argument
input and safe text output. DOM/events remain JavaScript; this is not yet a
full frontend framework or an HTTP server. See [Browser bridge](docs/BROWSER.md)
for build/run instructions, supported imports and execution limits.

## Development checks

```bash
zig build test
python3 tests/cli_test.py ./zig-out/bin/lir
# Requires a host C compiler and Node 22+ or Wasmtime
python3 tests/backend_test.py ./zig-out/bin/lir
python3 tests/core_test.py ./zig-out/bin/lir
python3 tests/call_test.py ./zig-out/bin/lir
python3 tests/project_test.py ./zig-out/bin/lir
python3 tests/browser_test.py ./zig-out/bin/lir
zig build run -- version
```

`lir init <name>` creates a **new directory** and refuses existing destinations;
it never overwrites an existing project. See [Bootstrap review](docs/REVIEW.md)
for the review scope, regression coverage, and remaining correctness priorities.

## Hello World

```lir
import core

fn main() -> i64 {
    println("Hello, World!")
    0
}
```

## New language extensions

The bootstrap now supports **`loop`**, **unary `+`**, right-associative integer
`**` exponentiation, and eight typed integer intrinsics:
`@rotl`, `@rotr`, `@bit_reverse`, `@is_power_of_two`, `@signum`,
`@wrapping_add`, `@wrapping_sub`, and `@wrapping_mul`.

```lir
fn main() -> i64 {
    let mut n = 0
    loop {
        n += 1
        if n == 3 { break }
    }
    printInt(2 ** 3 ** 2)       // 512
    printInt(@rotl(1, 3))      // 8
    printInt(@signum(-42))     // -1
    return 0
}
```

See [Language extensions](docs/LANGUAGE_EXTENSIONS.md) for exact type, overflow,
precedence, rotation, and trap semantics, restrictions, and executable examples.

## Typed tuple patterns

```lir
fn sum(pair: (i64, i64)) -> i64 {
    return match pair {
        (0, value) if value > 10 => value,
        (left, right) => left + right,
    }
}
```

Nested tuple patterns and guarded wildcards (`_ if condition => ...`) are
supported. Guards must be boolean, match result types must be compatible, and
inferred tuples retain integer widths and signedness. See
[Core language phases 1–2](docs/CORE_LANGUAGE.md) for the exact scope and restrictions.

Enum payload patterns also support recursive matching, including
`Some(7)`, `Event::Data((1..10, true))`, and
`Event::Nested(Inner::Number(number))`. Payload reads are gated by constructor
tags; refutable payloads do not falsely establish exhaustive variant coverage.
See `examples/enum-patterns.lir` for a runnable example.

## Named arguments and optional parameters

```lir
fn calculate(a: i64, b: i64 = 8, c: i64 = 3) -> i64 {
    return a * 100 + b * 10 + c
}
// Inside a function:
// calculate(1)             -> 183
// calculate(c: 9, a: 2)    -> 289
// calculate(2, c: 5)       -> 285
```

Direct free-function calls support named arguments and trailing scalar-constant
or string-literal defaults. Supplied arguments are evaluated once in source
order. This is **not C#/.NET compatibility**; see
[C# capability scope](docs/CSHARP_SCOPE.md) for restrictions and future work.

## Implemented Language Features

The snippets below compile and run natively with `./zig-out/bin/lir` (verified by `zig build test`). Full borrow checking remains planned work.

### Generics, `Option`/`Result`, `?` / `??`, and Pattern Matching

```lir
struct Box<T> { val: T }

fn half_even(x: i64) -> Option<i64> {
    if x % 2 == 0 { return Some(x / 2) }
    return None
}

fn double_half(x: i64) -> i64 {
    let h = half_even(x) ?? -1
    match h {
        n if n > 10 => n * 2,
        n => n,
    }
}
```

### Closures, Pipe Operator, Traits (`dyn Trait`), and Tuples/Maps

```lir
trait Scorer { fn score(&self) -> i64 }
fn eval_dyn(obj: dyn Scorer) -> i64 { return obj.score() }

fn main() -> i64 {
    let k = 10
    let add_k = |x: i64| -> i64 { return x + k }
    let res = 5 |> add_k
    let m = #{"answer": res}
    println("Result: {m[\"answer\"]}")
    0
}
```

### Concurrency (`spawn`, Channels, Atomics) and `comptime`

```lir
comptime fn table_size() -> i64 { return 6 * 7 }
const SIZE = table_size()

fn main() -> i64 {
    let ch = @chan_new(4)
    let th = spawn { @chan_send(ch, SIZE) }
    let result = @chan_recv(ch)
    @thread_join(th)
    @chan_close(ch)
    println("Result: {result}")
    0
}
```

### Zero-Wrapper Embedded Standard Library & Security Builtins

Importable with `import std::<module>` (or `import <module>`):

- **core** — `min_i64`, `max_i64`, `clamp_i64`, `abs_i64`, `signum`
- **io** — `eprint`, `eprintln`, `file_exists`, `file_size`, `read_file`, `write_file`, `append_file`
- **str** — `str_starts_with`, `str_ends_with`, `str_index_of`, `str_contains`, `str_trim`, `str_to_upper`, `str_to_lower`, `str_repeat`, `str_count`
- **algo** — `gcd_i64`, `lcm_i64`, `pow_i64`, `sort_array_i64`, `bsearch_array_i64`, `reverse_array_i64`, `sum_array_i64`
- **os** — `argc`, `argv`, `getenv`, `sleep_ms`, `now_ns`
- **sys** — `getpid`, `getppid`, `getuid`, `unlink_file`, `mkdir_dir`
- **net** — `htons`, `ipv4`, `tcp_socket`, `tcp_bind_listen`, `tcp_accept`, `tcp_connect`, `sock_send`, `sock_recv`, `sock_close`
- **crypto** — `random_u64`, `random_bytes`, `secure_zero`, `const_time_eq`, `const_time_str_eq`, `fnv1a_64`
- **json** — `json_quote`, `json_kv_str`, `json_kv_int`
- **math** — `pi`, `tau`, `e_const`, `abs_f`, `sqrt_f`, `sin_f`, `cos_f`, `floor_f`, `ceil_f`, `round_f`, `clamp_f`, `lerp`, `deg_to_rad`
- **testing** — `assert_true`, `assert_false`, `assert_eq_i64`, `assert_ne_i64`, `assert_eq_str` (plus `#[test]` + `lir test`)

Security builtins: `@random_u64`, `@random_bytes`, `@secure_zero`, `@const_time_eq`, `@checked_add`/`@checked_sub`/`@checked_mul`, `@popcount`/`@clz`/`@ctz`/`@bswap`, `@getenv`, `@sleep_ms`, `@read_u*`/`@write_u*` (null-trapped).

## Project Structure

```
myproject/
├── project.manifest     # Project configuration (JSON)
├── src/
│   ├── main.lir         # Entry point
│   ├── math.lir         # Math module
│   └── tests.lir        # Tests
└── build/               # Build output
```

## Standard Library

The intended standard library includes the following areas; implementation completeness must be verified against the current source and tests:

- **core** — Primitives, Option, Result, panic
- **collections** — Vec, HashMap, HashSet, Stack, Queue
- **io** — File I/O, string builder, path manipulation
- **net** — TCP sockets, HTTP client/server
- **json** — JSON parser and serializer
- **testing** — Test framework, assertions, benchmarks
- **crypto** — Hashing, encryption, random numbers
- **async** — Async/await runtime, channels, tasks

## Building from Source

```bash
# Clone the repository
git clone https://github.com/sswweett00/ziglir.git
cd ziglir

# Build and test the bootstrap compiler (requires Zig)
zig build
zig build test
```

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](docs/CONTRIBUTING.md) for guidelines.

## License

LIR is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Links

- [Language Specification](docs/SPEC.md)
- [Standard Library Documentation](docs/STDLIB.md)
- [Examples](examples/)
- [Benchmarks](bench/)
- [Roadmap](docs/ROADMAP.md)

---

<p align="center">
  <b>LIR — Clear syntax. Native performance. Evidence over promises.</b>
</p>
