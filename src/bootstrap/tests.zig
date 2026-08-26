// LIR Compiler — Unit Tests
// Tests for lexer, parser, and codegen

const std = @import("std");
const main = @import("main.zig");

fn compileSource(source: []const u8) ![]u8 {
    var lexer = main.Lexer.init(source);
    lexer.tokenize();

    var ast = main.AST.init();
    var parser = main.Parser{ .lex = &lexer, .pos = 0, .ast = &ast, .src = source };
    parser.parse();

    var cg = main.Codegen.init(source, &ast);
    cg.compile();
    cg.patchStrings();

    var output: [262144]u8 = undefined;
    const size = cg.generateELF(&output);

    const result = try std.testing.allocator.alloc(u8, size);
    @memcpy(result, output[0..size]);
    return result;
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

test "lexer recognizes all operator tokens" {
    const source = "+ - * / % == != < > <= >= = += -= *= /= && || !";
    var lexer = main.Lexer.init(source);
    lexer.tokenize();

    const expected = [_]main.TokenKind{
        .plus,     .minus, .star,   .slash,   .percent,
        .eq,       .ne,    .lt,     .gt,      .le,
        .ge,       .assign, .plus_eq, .minus_eq, .star_eq,
        .slash_eq, .and_and, .pipe_pipe, .bang,
    };
    for (expected, 0..) |k, i| {
        try std.testing.expectEqual(k, lexer.get(@intCast(i)).kind);
    }
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
