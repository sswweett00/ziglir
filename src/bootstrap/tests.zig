// LIR Compiler — Unit Tests
// Tests for lexer, parser, and codegen

const std = @import("std");
const main = @import("main.zig");

fn compileSource(source: []const u8) ![]u8 {
    // Exercise the same AST -> IR -> ELF pipeline used by the production CLI.
    // Tests must not silently validate the legacy AST code generator instead.
    var compiler = main.Compiler.init(source, "<test>");
    const output = try compiler.compile();
    defer std.heap.page_allocator.free(output);

    return try std.testing.allocator.dupe(u8, output);
}

test "lexer tokenizes basic LIR" {
    const source =
        \\fn main() -> i64 {
        \\    println("Hello, World!")
        \\    0
        \\}
    ;
    var lexer = main.Lexer.init(source);
    lexer.tokenize();

    // Should have tokens: fn, main, (, ), ->, i64, {, println, (, string, ), newline, 0, newline, }, eof
    try std.testing.expect(lexer.token_count > 10);
    try std.testing.expectEqual(main.TokenKind.kw_fn, lexer.get(0).kind);
    try std.testing.expectEqual(main.TokenKind.identifier, lexer.get(1).kind);
}

test "lexer get handles out of bounds index" {
    const source = "let x = 42";
    var lexer = main.Lexer.init(source);
    lexer.tokenize();

    try std.testing.expect(lexer.token_count > 0);
    const valid_tok = lexer.get(0);
    try std.testing.expectEqual(main.TokenKind.kw_let, valid_tok.kind);

    // Test idx == token_count
    const eof_at_count = lexer.get(lexer.token_count);
    try std.testing.expectEqual(main.TokenKind.eof, eof_at_count.kind);
    try std.testing.expectEqual(@as(u32, 0), eof_at_count.start);
    try std.testing.expectEqual(@as(u32, 0), eof_at_count.len);
    try std.testing.expectEqual(@as(u32, 0), eof_at_count.line);

    // Test idx > token_count
    const eof_beyond = lexer.get(lexer.token_count + 100);
    try std.testing.expectEqual(main.TokenKind.eof, eof_beyond.kind);
    try std.testing.expectEqual(@as(u32, 0), eof_beyond.start);
    try std.testing.expectEqual(@as(u32, 0), eof_beyond.len);
    try std.testing.expectEqual(@as(u32, 0), eof_beyond.line);

    // Test un-tokenized lexer (token_count == 0)
    const uninit_lexer = main.Lexer.init(source);
    const eof_uninit = uninit_lexer.get(0);
    try std.testing.expectEqual(main.TokenKind.eof, eof_uninit.kind);
    try std.testing.expectEqual(@as(u32, 0), eof_uninit.start);
    try std.testing.expectEqual(@as(u32, 0), eof_uninit.len);
    try std.testing.expectEqual(@as(u32, 0), eof_uninit.line);
}

test "lexer recognizes all operator tokens" {
    const source = "+ - * / % == != < > <= >= = += -= *= /= && || !";
    var lexer = main.Lexer.init(source);
    lexer.tokenize();

    const expected = [_]main.TokenKind{
        .plus,     .minus,   .star,      .slash,    .percent,
        .eq,       .ne,      .lt,        .gt,       .le,
        .ge,       .assign,  .plus_eq,   .minus_eq, .star_eq,
        .slash_eq, .and_and, .pipe_pipe, .bang,
    };
    for (expected, 0..) |k, i| {
        try std.testing.expectEqual(k, lexer.get(@intCast(i)).kind);
    }
}

test "lexer records token start line for multiline strings" {
    const source =
        \\"first
        \\second" value
    ;
    var lexer = main.Lexer.init(source);
    lexer.tokenize();

    try std.testing.expectEqual(main.TokenKind.string_literal, lexer.get(0).kind);
    try std.testing.expectEqual(@as(u32, 1), lexer.get(0).line);
    try std.testing.expectEqual(main.TokenKind.identifier, lexer.get(1).kind);
    try std.testing.expectEqual(@as(u32, 2), lexer.get(1).line);
}

test "lexer flags unterminated strings" {
    const source = "\\\"unterminated";
    var lexer = main.Lexer.init(source);
    lexer.tokenize();

    try std.testing.expect(lexer.invalid);
    try std.testing.expectEqual(@as(u32, 1), lexer.invalid_line);
}

test "lexer flags unknown characters instead of treating them as EOF" {
    const source = "fn main() { $ }";
    var lexer = main.Lexer.init(source);
    lexer.tokenize();

    try std.testing.expect(lexer.invalid);
    try std.testing.expectEqual(@as(u32, 1), lexer.invalid_line);
}

test "parser parses function declaration" {
    const source =
        \\fn add(a: i64, b: i64) -> i64 {
        \\    return a + b
        \\}
    ;
    var lexer = main.Lexer.init(source);
    lexer.tokenize();

    var ast = main.AST.init();
    var parser = main.Parser{ .lex = &lexer, .pos = 0, .ast = &ast, .src = source };
    parser.parse();

    // Param nodes are emitted before the fn_decl node; find it
    var fn_idx: ?u32 = null;
    for (0..ast.count) |i| {
        if (ast.nodes[i].kind == .fn_decl) {
            fn_idx = @intCast(i);
            break;
        }
    }
    try std.testing.expect(fn_idx != null);
    const f = ast.nodes[fn_idx.?];
    try std.testing.expectEqualStrings("add", parser.src[f.text_start..][0..f.text_len]);
    try std.testing.expectEqual(@as(i64, 2), f.int_val); // param count
}

test "codegen produces ELF header" {
    const elf = try compileSource(
        \\fn main() -> i64 {
        \\    return 42
        \\}
    );
    defer std.testing.allocator.free(elf);

    try std.testing.expect(elf.len >= 64);
    try std.testing.expectEqual(@as(u8, 0x7F), elf[0]);
    try std.testing.expectEqual(@as(u8, 'E'), elf[1]);
    try std.testing.expectEqual(@as(u8, 'L'), elf[2]);
    try std.testing.expectEqual(@as(u8, 'F'), elf[3]);
    try std.testing.expectEqual(@as(u8, 2), elf[4]); // 64-bit
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, elf[16..18], .little)); // ET_EXEC
    try std.testing.expectEqual(@as(u16, 62), std.mem.readInt(u16, elf[18..20], .little)); // EM_X86_64
}

test "variables, loops and functions compile" {
    const elf = try compileSource(
        \\fn fib(n: i64) -> i64 {
        \\    if n <= 1 { return n }
        \\    return fib(n - 1) + fib(n - 2)
        \\}
        \\
        \\fn main() {
        \\    let mut i = 0
        \\    let mut sum = 0
        \\    while i < 10 {
        \\        if i % 2 == 0 { sum += i }
        \\        elif i > 7 { break }
        \\        else { sum -= 1 }
        \\        i += 1
        \\    }
        \\    printInt(sum)
        \\    printInt(fib(10))
        \\    let ok = sum < 100 and !(sum == 0)
        \\    let not_ok = false or sum > 1000
        \\    if ok and !not_ok { printInt(1) }
        \\}
    );
    defer std.testing.allocator.free(elf);

    // ELF magic + entry point present
    try std.testing.expectEqual(@as(u8, 0x7F), elf[0]);
    try std.testing.expect(elf.len > 200);
}

test "string operations compile" {
    const elf = try compileSource(
        \\fn main() {
        \\    let s = @string_new("Hello, World!", 13)
        \\    let len = @string_len(s)
        \\    printInt(len)
        \\    let sub = @string_sub(s, 7, 5)
        \\    printInt(@string_len(sub))
        \\    if @string_eq(sub, "World") { printInt(1) }
        \\}
    );
    defer std.testing.allocator.free(elf);
    try std.testing.expect(elf.len > 500);
}

test "array operations compile" {
    const elf = try compileSource(
        \\fn main() {
        \\    let arr = @array_new(5, 8)
        \\    @array_set(arr, 0, 10)
        \\    @array_set(arr, 1, 20)
        \\    @array_set(arr, 2, 30)
        \\    printInt(@array_len(arr))
        \\    printInt(@array_get(arr, 0))
        \\    printInt(@array_get(arr, 2))
        \\}
    );
    defer std.testing.allocator.free(elf);
    try std.testing.expect(elf.len > 500);
}

test "struct declaration compiles" {
    const elf = try compileSource(
        \\struct Point {
        \\    x: i64
        \\    y: i64
        \\}
        \\
        \\fn main() {
        \\    printInt(42)
        \\}
    );
    defer std.testing.allocator.free(elf);
    try std.testing.expect(elf.len > 100);
}

test "optimizer: constant folding compiles" {
    const elf = try compileSource(
        \\fn main() {
        \\    let x = 3 + 4
        \\    let y = 10 * 2
        \\    let z = 100 / 5
        \\    printInt(x + y + z)
        \\}
    );
    defer std.testing.allocator.free(elf);
    try std.testing.expectEqual(@as(u8, 0x7F), elf[0]);
}

test "optimizer: algebraic simplification compiles" {
    const elf = try compileSource(
        \\fn main() {
        \\    let x = 42
        \\    let a = x + 0
        \\    let b = 0 + x
        \\    let c = x * 1
        \\    let d = 1 * x
        \\    let e = x - 0
        \\    let f = x * 0
        \\    printInt(a + b + c + d + e + f)
        \\}
    );
    defer std.testing.allocator.free(elf);
    try std.testing.expectEqual(@as(u8, 0x7F), elf[0]);
}

test "optimizer: dead code elimination compiles" {
    const elf = try compileSource(
        \\fn main() {
        \\    return 0
        \\    let x = 999
        \\    let y = 888
        \\    printInt(x + y)
        \\}
    );
    defer std.testing.allocator.free(elf);
    try std.testing.expectEqual(@as(u8, 0x7F), elf[0]);
}

test "optimizer: boolean simplification compiles" {
    const elf = try compileSource(
        \\fn main() {
        \\    let x = 42
        \\    let a = true and x > 0
        \\    let b = false or x > 0
        \\    let c = true or x > 0
        \\    let d = false and x > 0
        \\    if a { printInt(1) }
        \\}
    );
    defer std.testing.allocator.free(elf);
    try std.testing.expectEqual(@as(u8, 0x7F), elf[0]);
}

test "optimizer: ternary simplification compiles" {
    const elf = try compileSource(
        \\fn main() {
        \\    let x = true ? 42 : 99
        \\    let y = false ? 42 : 99
        \\    printInt(x + y)
        \\}
    );
    defer std.testing.allocator.free(elf);
    try std.testing.expectEqual(@as(u8, 0x7F), elf[0]);
}

test "optimizer: if-condition constant folding compiles" {
    const elf = try compileSource(
        \\fn main() {
        \\    if true {
        \\        printInt(42)
        \\    }
        \\    if false {
        \\        printInt(99)
        \\    } else {
        \\        printInt(0)
        \\    }
        \\}
    );
    defer std.testing.allocator.free(elf);
    try std.testing.expectEqual(@as(u8, 0x7F), elf[0]);
}

test "optimizer: strength reduction compiles" {
    const elf = try compileSource(
        \\fn main() {
        \\    let x = 5
        \\    let a = x * 8
        \\    let b = x * 4
        \\    printInt(a + b)
        \\}
    );
    defer std.testing.allocator.free(elf);
    try std.testing.expectEqual(@as(u8, 0x7F), elf[0]);
}

test "optimizer: while false eliminated compiles" {
    const elf = try compileSource(
        \\fn main() {
        \\    while false {
        \\        printInt(999)
        \\    }
        \\    printInt(42)
        \\}
    );
    defer std.testing.allocator.free(elf);
    try std.testing.expectEqual(@as(u8, 0x7F), elf[0]);
}


test "codegen uses disp32 for stack slots beyond signed disp8 range" {
    const source =
        \\fn seed() -> i64 {
        \\    return 1
        \\}
        \\
        \\fn main() {
        \\    let v0 = seed()
        \\    let v1 = v0 + 1
        \\    let v2 = v1 + 1
        \\    let v3 = v2 + 1
        \\    let v4 = v3 + 1
        \\    let v5 = v4 + 1
        \\    let v6 = v5 + 1
        \\    let v7 = v6 + 1
        \\    let v8 = v7 + 1
        \\    let v9 = v8 + 1
        \\    let v10 = v9 + 1
        \\    let v11 = v10 + 1
        \\    let v12 = v11 + 1
        \\    let v13 = v12 + 1
        \\    let v14 = v13 + 1
        \\    let v15 = v14 + 1
        \\    let v16 = v15 + 1
        \\    let v17 = v16 + 1
        \\    let v18 = v17 + 1
        \\    let v19 = v18 + 1
        \\    let v20 = v19 + 1
        \\    printInt(v20)
        \\}
    ;
    const elf = try compileSource(source);
    defer std.testing.allocator.free(elf);

    // Slot 17 is at rbp-136, which cannot be encoded as a signed disp8.
    const store_disp32 = [_]u8{ 0x48, 0x89, 0x85, 0x78, 0xFF, 0xFF, 0xFF };
    const load_disp32 = [_]u8{ 0x48, 0x8B, 0x85, 0x78, 0xFF, 0xFF, 0xFF };
    try std.testing.expect(std.mem.indexOf(u8, elf, &store_disp32) != null);
    try std.testing.expect(std.mem.indexOf(u8, elf, &load_disp32) != null);
}
