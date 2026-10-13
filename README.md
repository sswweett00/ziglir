# LIR — A Simple, Performance-First Systems Language

<p align="center">
  <b>Write simply. Compile natively. Measure every optimization.</b>
</p>

---

## What is LIR?

LIR is a systems-language project aiming to combine a small, approachable syntax with predictable memory use and highly optimized native code. Its long-term performance goal is to outperform C on selected, benchmarked workloads without sacrificing correctness or readability. That is a goal to prove with reproducible measurements—not a universal speed guarantee. The checked-in bootstrap compiler currently targets Linux x86-64 ELF; features listed as design goals are not necessarily implemented yet.

### Why LIR?

| Feature | LIR | Rust | Zig | Go | C++ |
|---------|:---:|:----:|:---:|:--:|:---:|
| Zero-cost abstractions | ✅ | ✅ | ✅ | ❌ | ✅ |
| Memory safety (no GC) | ✅ | ✅ | Partial | ❌ | Partial |
| Compile-time execution | ✅ | ✅ | ✅ | ❌ | Partial |
| Built-in concurrency | ✅ | ✅ | ❌ | ✅ | ❌ |
| Self-contained build | ✅ | ❌ | ✅ | ✅ | ❌ |
| Cross-compilation | ✅ | ✅ | ✅ | ✅ | ❌ |
| Learning curve | **Easy** | Hard | Medium | Easy | Hard |
| Binary size | **Tiny** | Medium | Tiny | Large | Large |
| Startup time | **Instant** | Instant | Instant | Slow | Instant |

## Quick Start

```bash
# Install (just download the binary — no dependencies!)
git clone https://github.com/sswweett00/ziglir.git
cd ziglir

# Create a new project
lir init myproject
cd myproject

# Build and run
lir build
lir run

# Run tests
lir test
```

## Hello World

```lir
import core

fn main() -> i64 {
    println("Hello, World!")
    0
}
```

## Features

### Memory Safety Without Garbage Collection

```lir
fn main() {
    let s = "hello"      // s owns the string
    let t = s             // t takes ownership (s is moved)
    print(t)              // OK: t is valid
    // print(s)           // Compile error: s was moved
}
```

### Concurrency (design direction; implementation status varies)

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

### Compile-Time Execution (planned language capability)

```lir
comptime fn fibonacci(n: u64) -> u64 {
    if n <= 1 { return n }
    fibonacci(n - 1) + fibonacci(n - 2)
}

const TABLE_SIZE = fibonacci(10)  // Computed at compile time!
```

### Pattern Matching (planned language capability)

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
