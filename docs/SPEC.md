# LIR Language Specification v2.0

## Overview

LIR is a systems programming language designed for:
- **Zero-cost abstractions** — no runtime overhead
- **Memory safety without garbage collection** — ownership + borrowing
- **Fearless concurrency** — compile-time data race prevention
- **Native speed** — compiles to native machine code
- **Self-contained** — no external dependencies needed
- **Cross-platform** — Linux, macOS, Windows, WASM, embedded

## Design Principles

1. **Simplicity** — small, orthogonal features that compose well
2. **Performance** — every feature maps to efficient machine code
3. **Safety** — catch errors at compile time, not runtime
4. **Expressiveness** — write clear, maintainable code
5. **Portability** — write once, run anywhere

## Type System

### Primitive Types
```
i8, i16, i32, i64, i128    — signed integers
u8, u16, u32, u64, u128    — unsigned integers
f16, f32, f64, f128         — floating point
bool                        — true/false
char                        — Unicode code point
string                      — immutable UTF-8 string
void                        — no value
never                       — never returns (panic, infinite loop)
```

### Compound Types
```
[Type; N]           — fixed-size array
[]Type              — slice (pointer + length)
*Type               — raw pointer
*const Type         — immutable raw pointer
*mut Type           — mutable raw pointer
?type               — optional (null if not present)
!Type               — result (error or value)
(Type, Type, ...)   — tuple
fn(Args) -> Ret     — function pointer
```

### User-Defined Types
```
struct Name { fields... }       — product type
enum Name { variants... }       — sum type
trait Name { methods... }       — interface
type Alias = Type               — type alias
```

## Ownership System

LIR uses affine type system with ownership tracking:

```lir
fn main() {
    let s = "hello"          // s owns the string
    let t = s                // t takes ownership (s is moved)
    // print(s)              // ERROR: s was moved
    print(t)                 // OK: t is valid
}
```

### Borrowing
```lir
fn process(data: *const []i32) {   // immutable borrow
    print(data.len)
}

fn modify(data: *mut []i32) {      // mutable borrow
    data[0] = 42
}

// Rules:
// - Multiple immutable borrows allowed
// - Only one mutable borrow allowed
// - Cannot mix mutable and immutable borrows
// - Borrows cannot outlive the owner
```

### Lifetimes
```lir
fn longest<'a>(x: *const str, y: *const str) -> *const str {
    if x.len > y.len { x } else { y }
}
```

## Concurrency Model

### Threads
```lir
let handle = spawn {
    // runs on new thread
    compute()
}
let result = handle.join()
```

### Channels
```lir
let (tx, rx) = channel()
spawn { tx.send(compute()) }
let value = rx.recv()
```

### Async/Await
```lir
async fn fetch(url: string) -> Response {
    let response = await http.get(url)
    response
}

// Run async code
let result = runtime.block_on(fetch("https://example.com"))
```

### Data Race Prevention
```lir
// Compile-time error if data races detected
let data = Arc::new(Mutex::new(Vec::new()))
let data2 = data.clone()

spawn {
    let guard = data2.lock()
    guard.push(1)
}  // lock released here
```

## Error Handling

### Result Type
```lir
fn divide(a: f64, b: f64) -> !f64 {
    if b == 0.0 { return Err("division by zero") }
    Ok(a / b)
}

// Propagate errors
let result = try divide(10.0, 2.0)?
```

### Option Type
```lir
fn find(arr: []i32, value: i32) -> ?usize {
    for i, item in arr {
        if item == value { return Some(i) }
    }
    None
}

// Pattern matching
match find(arr, 42) {
    Some(idx) => print("Found at index: {idx}"),
    None => print("Not found"),
}
```

## Pattern Matching

```lir
match value {
    0 => print("zero"),
    1..=9 => print("single digit"),
    10 | 20 | 30 => print("special number"),
    n if n > 100 => print("big number"),
    _ => print("other"),
}
```

## Generics

```lir
struct Vec(T) {
    items: []T
    len: u64
    capacity: u64
}

impl Vec(T) {
    fn push(self: *mut Self, value: T) { ... }
    fn get(self: *const Self, index: u64) -> ?T { ... }
}

// Usage
let mut numbers = Vec(i32).init(alloc)
numbers.push(42)
```

## Compile-Time Execution

```lir
comptime fn fibonacci(n: u64) -> u64 {
    if n <= 1 { return n }
    fibonacci(n - 1) + fibonacci(n - 2)
}

// Computed at compile time
const TABLE_SIZE = fibonacci(10)  // = 55
let table = [TABLE_SIZE]u8
```

## Modules

```lir
// math.lir
pub fn add(a: i32, b: i32) -> i32 { a + b }
pub fn mul(a: i32, b: i32) -> i32 { a * b }

// main.lir
import math

fn main() -> i64 {
    print(math.add(2, 3))
    0
}
```

## Attributes

```lir
#[test]
fn test_add() {
    assertEq(add(2, 3), 5)
}

#[target(x86_64)]
fn fast_path() { ... }

#[inline(always)]
fn hot_function() { ... }

#[cold]
fn error_handler() { ... }
```

## String Interpolation

```lir
let name = "World"
println("Hello, {name}!")           // Hello, World!
println("2 + 3 = {2 + 3}")         // 2 + 3 = 5
println("Hex: {42:#x}")            // Hex: 0x2a
println("Bin: {42:#b}")            // Bin: 0b101010
```

## Defer

```lir
fn process() {
    let file = File.open("data.txt")?
    defer file.close()           // always runs when scope exits
    
    let data = file.readAll()?
    // process data...
}   // file.close() called here
```

## Memory Management

```lir
// Stack allocation (default)
let x = 42

// Heap allocation
let ptr = box 42              // Box(i32)
let shared = rc 42            // Rc(i32)
let atomic = arc 42           // Arc(i32)

// Manual allocation
let buf = allocator.alloc(u8, 1024)
defer allocator.free(buf)
```

## Syntax Summary

```
Keywords:    fn, let, mut, const, struct, enum, trait, impl,
             match, if, else, while, for, in, return, break,
             continue, defer, spawn, async, await, try, pub,
             mod, use, as, type, where, comptime, extern, unsafe

Operators:   + - * / % ** ++ 
             == != < > <= >=
             = += -= *= /= %=
             && || !
             & | ^ ~ << >>
             -> => |> <|
             .. ..=
             ? : :: . ,

Delimiters:  ( ) { } [ ] ; ,

Comments:    // line comment
             /* block comment */
             # hash comment
             /// doc comment
```

## Performance Features

1. **Zero-cost abstractions** — generics, iterators, closures compile to optimized code
2. **Compile-time evaluation** — constants, table generation, partial evaluation
3. **Inline assembly** — direct access to hardware
4. **SIMD intrinsics** — vectorized operations
5. **Cache-friendly data structures** — arrays of structs, not structs of arrays
6. **Branch prediction hints** — likely/unlikely annotations
7. **Tail call optimization** — guaranteed for self-recursive calls
8. **Escape analysis** — stack allocation when possible
9. **Lazy initialization** — static variables initialized on first use
10. **LTO-friendly** — whole-program optimization support

## Comparison with Other Languages

| Feature | LIR | Rust | Zig | Go | C++ |
|---------|-----|------|-----|-----|-----|
| Zero-cost abstractions | ✓ | ✓ | ✓ | ✗ | ✓ |
| Memory safety | ✓ | ✓ | Partial | ✓ | Partial |
| No GC | ✓ | ✓ | ✓ | ✗ | ✓ |
| Compile-time execution | ✓ | ✓ | ✓ | ✗ | ✗ |
| Built-in concurrency | ✓ | ✓ | ✗ | ✓ | ✗ |
| Self-contained build | ✓ | ✗ | ✓ | ✓ | ✗ |
| Cross-compilation | ✓ | ✓ | ✓ | ✓ | ✗ |
| Learning curve | Easy | Hard | Medium | Easy | Hard |
