# LIR — A Simple, Performance-First Systems Language

<p align="center">
  <b>Write simply. Compile natively. Measure every optimization.</b>
</p>

---

## What is LIR?

LIR is a systems-language project aiming to combine a small, approachable syntax with predictable memory use and highly optimized native code. Its long-term performance goal is to outperform C on selected, benchmarked workloads without sacrificing correctness or readability. That is a goal to prove with reproducible measurements—not a universal speed guarantee. The checked-in bootstrap compiler currently targets Linux x86-64 ELF; features listed as design goals are not necessarily implemented yet.

### Design principles

- **Zig-native implementation:** the checked-in bootstrap compiler and native code-generation pipeline are implemented in Zig. LIR is not merely a syntax wrapper around GCC, Clang, LLVM, or another language compiler.
- **Direct native output:** the current bootstrap targets Linux x86-64 ELF and emits machine code itself.
- **Readable language design:** syntax should stay small and consistent; unsupported features must fail explicitly rather than silently generating incorrect code.
- **Measured performance:** performance claims require repeatable benchmarks against equivalent C implementations, including correctness checks. No universal claim that LIR is faster than C is made.
- **Honest implementation status:** memory safety, compile-time execution, concurrency primitives, cross-compilation, and a stable standard library are not advertised as complete unless they are implemented and tested.

| Capability | Current status |
|---|---|
| Bootstrap compiler implementation | Zig |
| Native output | Linux x86-64 ELF |
| External compiler required at runtime | No; the compiler emits the target code itself |
| C ABI / foreign-function interface | Not yet a complete, stable contract |
| Memory-safety guarantees | Not yet complete |
| Compile-time execution | Not yet complete |
| Built-in concurrency | Not yet complete |
| Cross-compilation | Not yet complete |
| Stable standard library | Not yet complete |
| Performance versus C | Must be established workload-by-workload with reproducible benchmarks |

## Quick Start

The bootstrap compiler is built with **Zig 0.13.0** and currently targets Linux x86-64.

```bash
git clone https://github.com/sswweett00/ziglir.git
cd ziglir

# Build the compiler and run its unit tests
zig build -Doptimize=ReleaseFast
zig build test

# Compile and run a checked-in example
./zig-out/bin/lir build tests/fixtures/test.lir -o /tmp/lir-example
/tmp/lir-example

# Optional: generate a starter project
./zig-out/bin/lir init myproject
cd myproject
../zig-out/bin/lir build src/main.lir -o myproject
./myproject
```


## Hello World

```lir
import core

fn main() -> i64 {
    println("Hello, World!")
    0
}
```

## Language design examples

The examples below illustrate intended syntax and are **not a promise that every feature currently compiles**. The implemented subset is defined by the compiler, tests, and [language specification](docs/SPEC.md).

### Ownership and memory safety (planned; not enforced comprehensively yet)

```lir
fn main() {
    let s = "hello"      // s owns the string
    let t = s             // t takes ownership (s is moved)
    print(t)              // OK: t is valid
    // print(s)           // Compile error: s was moved
}
```

### Concurrency (planned; not implemented as a stable feature)

```lir
import core

fn main() {
    let (tx, rx) = channel()
    
    spawn {
        tx.send(compute())
    }
    
    let result = rx.recv()
    println("Result: {result}")
}
```

### Compile-time execution (planned; not implemented)

```lir
comptime fn fibonacci(n: u64) -> u64 {
    if n <= 1 { return n }
    fibonacci(n - 1) + fibonacci(n - 2)
}

const TABLE_SIZE = fibonacci(10)  // Computed at compile time!
```

### Pattern matching (planned; not implemented)

```lir
match value {
    0 => print("zero"),
    1..=9 => print("single digit"),
    10 | 20 | 30 => print("special"),
    n if n > 100 => print("big"),
    _ => print("other"),
}
```

### Generics (planned language capability)

```lir
struct Vec(T) {
    items: []T
    len: u64
}

impl Vec(T) {
    fn push(self: *mut Self, value: T) { ... }
    fn get(self: *const Self, idx: u64) -> ?T { ... }
}

let mut nums = Vec(i32).init(alloc)
nums.push(42)
```

### Error Handling (planned language capability)

```lir
fn divide(a: f64, b: f64) -> !f64 {
    if b == 0.0 { return Err("division by zero") }
    Ok(a / b)
}

// Propagate errors with try
let result = try divide(10.0, 2.0)?
```

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
