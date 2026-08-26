// LIR Compiler — Complete Pipeline
// Compiles LIR source code to native x86-64 Linux ELF executables
// Uses raw Linux syscalls for zero-dependency file I/O
//
// Usage: lir build <file.lir> [-o output]
//        lir run <file.lir>
//        lir init [name]

const std = @import("std");

// Linux syscall numbers (x86-64)
const SYS_read: u64 = 0;
const SYS_write: u64 = 1;
const SYS_open: u64 = 2;
const SYS_close: u64 = 3;
const SYS_lseek: u64 = 8;
const SYS_exit: u64 = 60;

fn syscall3(num: u64, a1: u64, a2: u64, a3: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
    );
}

fn sysWrite(fd: u64, buf: [*]const u8, len: u64) i64 {
    return @intCast(syscall3(SYS_write, fd, @intFromPtr(buf), len));
}

fn sysOpen(path: [*]const u8, flags: u64, mode: u64) i64 {
    return @intCast(syscall3(SYS_open, @intFromPtr(path), flags, mode));
}

fn sysClose(fd: u64) void {
    _ = syscall3(SYS_close, fd, 0, 0);
}

fn sysRead(fd: u64, buf: [*]u8, len: u64) i64 {
    return @intCast(syscall3(SYS_read, fd, @intFromPtr(buf), len));
}

fn sysLseek(fd: u64, offset: i64, whence: u64) i64 {
    return @intCast(syscall3(SYS_lseek, fd, @as(u64, @bitCast(offset)), whence));
}

fn sysExit(code: u64) noreturn {
    _ = syscall3(SYS_exit, code, 0, 0);
    unreachable;
}

fn printStr(s: []const u8) void {
    _ = sysWrite(1, s.ptr, s.len);
}

fn printErr(s: []const u8) void {
    _ = sysWrite(2, s.ptr, s.len);
}

fn readFile(path: []const u8, buf: []u8) ?usize {
    const fd: i64 = sysOpen(path.ptr, 0, 0);
    if (fd < 0) return null;
    const file_fd: u64 = @intCast(fd);
    const size = sysLseek(file_fd, 0, 2);
    if (size < 0) {
        sysClose(file_fd);
        return null;
    }
    _ = sysLseek(file_fd, 0, 0);
    const read_size: u64 = @intCast(size);
    const to_read = if (read_size > buf.len) buf.len else read_size;
    const n = sysRead(file_fd, buf.ptr, to_read);
    sysClose(file_fd);
    if (n < 0) return null;
    return @intCast(n);
}

fn writeFile(path: []const u8, data: []const u8) bool {
    const fd: i64 = sysOpen(path.ptr, 0x241, 0o644); // O_WRONLY|O_CREAT|O_TRUNC
    if (fd < 0) return false;
    const file_fd: u64 = @intCast(fd);
    var written: u64 = 0;
    while (written < data.len) {
        const n = sysWrite(file_fd, data.ptr + written, data.len - written);
        if (n <= 0) {
            sysClose(file_fd);
            return false;
        }
        written += @intCast(n);
    }
    sysClose(file_fd);
    return true;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn printUsize(val: usize) void {
    var buf: [20]u8 = undefined;
    var v = val;
    var i: usize = 20;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (v > 0 and i > 0) {
            i -= 1;
            buf[i] = @truncate('0' + (v % 10));
            v /= 10;
        }
    }
    printStr(buf[i..20]);
}

// ════════════════════════════════════════════════════════════════════════════
// CLI
// ════════════════════════════════════════════════════════════════════════════

pub fn main() !void {
    const cmdline_fd: i64 = sysOpen("/proc/self/cmdline", 0, 0);
    var cmdline: [2048]u8 = undefined;
    var cmdline_len: usize = 0;
    if (cmdline_fd >= 0) {
        const n = sysRead(@intCast(cmdline_fd), &cmdline, 2048);
        if (n > 0) cmdline_len = @intCast(n);
        sysClose(@intCast(cmdline_fd));
    }

    var args: [16][]const u8 = undefined;
    var arg_count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < cmdline_len and arg_count < 16) : (i += 1) {
        if (cmdline[i] == 0) {
            if (i > start) {
                args[arg_count] = cmdline[start..i];
                arg_count += 1;
            }
            start = i + 1;
        }
    }

    if (arg_count < 2) {
        printUsage();
        return;
    }

    const command = args[1];
    if (eql(command, "help")) {
        printUsage();
    } else if (eql(command, "version")) {
        printStr("lir 2.1.0\n");
    } else if (eql(command, "build")) {
        if (arg_count < 3) {
            printErr("Error: usage: lir build <file.lir> [-o output]\n");
            sysExit(1);
        }
        cmdBuild(args[2..arg_count]);
    } else if (eql(command, "run")) {
        if (arg_count < 3) {
            printErr("Error: usage: lir run <file.lir>\n");
            sysExit(1);
        }
        cmdRun(args[2..arg_count]);
    } else if (eql(command, "init")) {
        const name = if (arg_count >= 3) args[2] else "myproject";
        cmdInit(name);
    } else {
        printErr("Unknown command: ");
        printErr(command);
        printErr("\nRun 'lir help' for usage.\n");
        sysExit(1);
    }
}

fn printUsage() void {
    printStr(
        \\LIR Compiler v2.1.0
        \\
        \\Usage: lir <command> [options]
        \\
        \\Commands:
        \\  build <file.lir>    Compile LIR source to native executable
        \\  run <file.lir>      Compile and run
        \\  init [name]         Create a new project
        \\  help                Show this help
        \\  version             Show version
        \\
        \\Examples:
        \\  lir build main.lir
        \\  lir run main.lir
        \\  lir init myproject
        \\
    );
}

// ════════════════════════════════════════════════════════════════════════════
// Build Command
// ════════════════════════════════════════════════════════════════════════════

fn cmdBuild(args: []const []const u8) void {
    const input_file = args[0];
    var output_file: []const u8 = "a.out";

    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        if (eql(args[idx], "-o") and idx + 1 < args.len) {
            output_file = args[idx + 1];
            idx += 1;
        }
    }

    var src_buf: [1024 * 1024]u8 = undefined;
    const src_len = readFile(input_file, &src_buf) orelse {
        printErr("Error: cannot read '");
        printErr(input_file);
        printErr("'\n");
        sysExit(1);
    };
    const source = src_buf[0..src_len];

    var compiler = Compiler.init(source, input_file);
    const result = compiler.compile() catch |err| {
        printErr("Compilation error: ");
        printErr(@errorName(err));
        printErr("\n");
        sysExit(1);
    };

    if (!writeFile(output_file, result)) {
        printErr("Error: cannot write '");
        printErr(output_file);
        printErr("'\n");
        sysExit(1);
    }

    // chmod 755
    _ = syscall3(0x5A, @intFromPtr(output_file.ptr), 0o755, 0);

    printStr("Compiled ");
    printStr(input_file);
    printStr(" -> ");
    printStr(output_file);
    printStr(" (");
    printUsize(result.len);
    printStr(" bytes)\n");
}

fn cmdRun(args: []const []const u8) void {
    const input_file = args[0];
    const tmp_out = "/tmp/lir_out";

    var src_buf: [1024 * 1024]u8 = undefined;
    const src_len = readFile(input_file, &src_buf) orelse {
        printErr("Error: cannot read '");
        printErr(input_file);
        printErr("'\n");
        sysExit(1);
    };
    const source = src_buf[0..src_len];

    var compiler = Compiler.init(source, input_file);
    const result = compiler.compile() catch |err| {
        printErr("Compilation error: ");
        printErr(@errorName(err));
        printErr("\n");
        sysExit(1);
    };

    if (!writeFile(tmp_out, result)) {
        printErr("Error: cannot write temp file\n");
        sysExit(1);
    }
    _ = syscall3(0x5A, @intFromPtr(tmp_out.ptr), 0o755, 0);

    // Fork + exec
    const pid = syscall3(56, 0, 0, 0); // sys_fork
    if (pid == 0) {
        _ = syscall3(59, @intFromPtr(tmp_out.ptr), 0, 0); // sys_execve
        sysExit(1);
    } else {
        _ = syscall3(61, pid, 0, 0); // sys_wait4
    }
}

fn cmdInit(name: []const u8) void {
    printStr("Initializing project '");
    printStr(name);
    printStr("'...\n");

    var manifest_buf: [512]u8 = undefined;
    var pos: usize = 0;
    const parts = [_][]const u8{
        "{\n  \"name\": \"",
        name,
        "\",\n  \"version\": \"0.1.0\",\n  \"entry\": \"main.lir\",\n  \"source_dir\": \"src\"\n}\n",
    };
    for (parts) |part| {
        for (part) |ch| {
            if (pos < manifest_buf.len) {
                manifest_buf[pos] = ch;
                pos += 1;
            }
        }
    }
    _ = writeFile("project.manifest", manifest_buf[0..pos]);

    const main_src =
        \\// Main entry point
        \\import core
        \\
        \\fn main() -> i64 {
        \\    println("Hello from LIR!")
        \\    0
        \\}
        \\
    ;
    _ = writeFile("src/main.lir", main_src);

    printStr("Created project.manifest\nCreated src/main.lir\n\nNext: lir build src/main.lir\n");
}

// ════════════════════════════════════════════════════════════════════════════
// LEXER
// ════════════════════════════════════════════════════════════════════════════

pub const TokenKind = enum(u8) {
    // Literals
    int_literal, float_literal, string_literal, char_literal, identifier,
    // Keywords
    kw_fn, kw_let, kw_mut, kw_const, kw_struct, kw_enum, kw_trait,
    kw_impl, kw_match, kw_if, kw_else, kw_while, kw_for, kw_in,
    kw_return, kw_break, kw_continue, kw_defer, kw_pub, kw_mod,
    kw_use, kw_import, kw_type, kw_extern, kw_self,
    kw_true, kw_false, kw_null, kw_comptime, kw_try, kw_panic, kw_elif,
    kw_i8, kw_i16, kw_i32, kw_i64, kw_u8, kw_u16, kw_u32, kw_u64,
    kw_f32, kw_f64, kw_bool, kw_string, kw_void,
    // Operators
    plus, minus, star, slash, percent,
    eq, ne, lt, gt, le, ge,
    assign, plus_eq, minus_eq, star_eq, slash_eq,
    amp, pipe, caret, tilde, bang, and_and, pipe_pipe,
    arrow, fat_arrow, dot_dot, colon_colon, star_star,
    // Delimiters
    lparen, rparen, lbrace, rbrace, lbracket, rbracket,
    semicolon, colon, comma, dot, at, hash, question,
    // Special
    newline, eof,
};

fn isTypeKeyword(kind: TokenKind) bool {
    return switch (kind) {
        .kw_i8, .kw_i16, .kw_i32, .kw_i64,
        .kw_u8, .kw_u16, .kw_u32, .kw_u64,
        .kw_f32, .kw_f64, .kw_bool, .kw_string, .kw_void,
        => true,
        else => false,
    };
}

pub const Token = struct {
    kind: TokenKind,
    start: u32,
    len: u32,
    line: u32,
};

pub const Lexer = struct {
    src: []const u8,
    pos: u32,
    line: u32,
    tokens: [4096]Token,
    token_count: u32,

    pub fn init(source: []const u8) Lexer {
        return .{
            .src = source,
            .pos = 0,
            .line = 1,
            .tokens = undefined,
            .token_count = 0,
        };
    }

    fn peek(self: *const Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn peekNext(self: *const Lexer) u8 {
        if (self.pos + 1 >= self.src.len) return 0;
        return self.src[self.pos + 1];
    }

    fn advance(self: *Lexer) u8 {
        const ch = self.peek();
        if (ch == '\n') self.line += 1;
        self.pos += 1;
        return ch;
    }

    fn emit(self: *Lexer, kind: TokenKind, start: u32) void {
        if (self.token_count < self.tokens.len) {
            self.tokens[self.token_count] = .{
                .kind = kind,
                .start = start,
                .len = self.pos - start,
                .line = self.line,
            };
            self.token_count += 1;
        }
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const ch = self.peek();
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                _ = self.advance();
            } else if (ch == '\n') {
                break;
            } else if (ch == '/' and self.peekNext() == '/') {
                while (self.pos < self.src.len and self.peek() != '\n') _ = self.advance();
            } else if (ch == '#') {
                while (self.pos < self.src.len and self.peek() != '\n') _ = self.advance();
            } else {
                break;
            }
        }
    }

    pub fn tokenize(self: *Lexer) void {
        while (self.pos < self.src.len) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) break;

            const start = self.pos;
            const ch = self.peek();

            // Numbers
            if (ch >= '0' and ch <= '9') {
                while (self.pos < self.src.len and ((self.peek() >= '0' and self.peek() <= '9') or self.peek() == '.' or self.peek() == '_'))
                    _ = self.advance();
                const has_dot = std.mem.indexOfScalar(u8, self.src[start..self.pos], '.') != null;
                self.emit(if (has_dot) .float_literal else .int_literal, start);
                continue;
            }

            // Identifiers/keywords
            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_') {
                _ = self.advance();
                while (self.pos < self.src.len and
                    ((self.peek() >= 'a' and self.peek() <= 'z') or
                    (self.peek() >= 'A' and self.peek() <= 'Z') or
                    (self.peek() >= '0' and self.peek() <= '9') or
                    self.peek() == '_'))
                    _ = self.advance();
                const word = self.src[start..self.pos];
                self.emit(keywordOrIdent(word), start);
                continue;
            }

            // Strings
            if (ch == '"') {
                _ = self.advance();
                while (self.pos < self.src.len and self.peek() != '"') {
                    if (self.peek() == '\\') _ = self.advance();
                    if (self.pos < self.src.len) _ = self.advance();
                }
                if (self.pos < self.src.len) _ = self.advance();
                self.emit(.string_literal, start);
                continue;
            }

            // Operators / delimiters
            _ = self.advance();
            const kind: TokenKind = switch (ch) {
                '+' => if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .plus_eq;
                } else .plus,
                '-' => if (self.peek() == '>') blk: {
                    _ = self.advance();
                    break :blk .arrow;
                } else if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .minus_eq;
                } else .minus,
                '*' => if (self.peek() == '*') blk: {
                    _ = self.advance();
                    break :blk .star_star;
                } else if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .star_eq;
                } else .star,
                '/' => if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .slash_eq;
                } else .slash,
                '%' => .percent,
                '=' => if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .eq;
                } else if (self.peek() == '>') blk: {
                    _ = self.advance();
                    break :blk .fat_arrow;
                } else .assign,
                '!' => if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .ne;
                } else .bang,
                '<' => if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .le;
                } else .lt,
                '>' => if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .ge;
                } else .gt,
                '&' => if (self.peek() == '&') blk: {
                    _ = self.advance();
                    break :blk .and_and;
                } else .amp,
                '|' => if (self.peek() == '|') blk: {
                    _ = self.advance();
                    break :blk .pipe_pipe;
                } else .pipe,
                '^' => .caret,
                '~' => .tilde,
                '?' => .question,
                '@' => .at,
                '#' => .hash,
                '(' => .lparen,
                ')' => .rparen,
                '{' => .lbrace,
                '}' => .rbrace,
                '[' => .lbracket,
                ']' => .rbracket,
                ';' => .semicolon,
                ':' => if (self.peek() == ':') blk: {
                    _ = self.advance();
                    break :blk .colon_colon;
                } else .colon,
                ',' => .comma,
                '.' => .dot,
                '\n' => .newline,
                else => .eof,
            };
            self.emit(kind, start);
        }
        self.emit(.eof, self.pos);
    }

    fn keywordOrIdent(word: []const u8) TokenKind {
        const kws = [_]struct { []const u8, TokenKind }{
            .{ "fn", .kw_fn },       .{ "let", .kw_let },     .{ "mut", .kw_mut },       .{ "const", .kw_const },
            .{ "struct", .kw_struct }, .{ "enum", .kw_enum }, .{ "trait", .kw_trait },   .{ "impl", .kw_impl },
            .{ "match", .kw_match },   .{ "if", .kw_if },       .{ "else", .kw_else },     .{ "while", .kw_while },
            .{ "for", .kw_for },       .{ "in", .kw_in },       .{ "return", .kw_return }, .{ "break", .kw_break },
            .{ "continue", .kw_continue }, .{ "defer", .kw_defer }, .{ "pub", .kw_pub },   .{ "mod", .kw_mod },
            .{ "import", .kw_import }, .{ "type", .kw_type },   .{ "extern", .kw_extern }, .{ "self", .kw_self },
            .{ "true", .kw_true },     .{ "false", .kw_false }, .{ "null", .kw_null },     .{ "comptime", .kw_comptime },
            .{ "try", .kw_try },       .{ "panic", .kw_panic }, .{ "elif", .kw_elif },
            .{ "and", .and_and },      .{ "or", .pipe_pipe },
            .{ "i8", .kw_i8 },   .{ "i16", .kw_i16 }, .{ "i32", .kw_i32 }, .{ "i64", .kw_i64 },
            .{ "u8", .kw_u8 },   .{ "u16", .kw_u16 }, .{ "u32", .kw_u32 }, .{ "u64", .kw_u64 },
            .{ "f32", .kw_f32 }, .{ "f64", .kw_f64 }, .{ "bool", .kw_bool },
            .{ "string", .kw_string }, .{ "void", .kw_void },
        };
        for (kws) |entry| {
            if (eql(word, entry[0])) return entry[1];
        }
        return .identifier;
    }

    fn text(self: *const Lexer, tok: Token) []const u8 {
        return self.src[tok.start..][0..tok.len];
    }

    pub fn get(self: *const Lexer, idx: u32) Token {
        if (idx >= self.token_count) return .{ .kind = .eof, .start = 0, .len = 0, .line = 0 };
        return self.tokens[idx];
    }
};

// ════════════════════════════════════════════════════════════════════════════
// PARSER
// ════════════════════════════════════════════════════════════════════════════

pub const NodeKind = enum {
    fn_decl,
    block,
    return_stmt,
    expr_stmt,
    let_stmt,
    assign_stmt,
    if_stmt,
    while_stmt,
    break_stmt,
    continue_stmt,
    call_expr,
    binary_expr,
    unary_expr,
    identifier,
    int_literal,
    string_literal,
};

pub const ASTNode = struct {
    kind: NodeKind,
    line: u32,
    // child0: primary child (body, condition, callee, left operand, etc.)
    // child1: next statement in block chain OR right operand OR next param
    // child2: else branch / fn body
    child0: u32 = 0,
    child1: u32 = 0,
    child2: u32 = 0,
    op: u8 = 0,
    int_val: i64 = 0,
    text_start: u32 = 0,
    text_len: u32 = 0,
};

pub const AST = struct {
    nodes: [4096]ASTNode,
    count: u32,
    // Statement chains: stmt_chains[node_idx] = next statement in the block,
    // 0 = end of chain. Separate from child1 to avoid collision with
    // if_stmt.child1 (then block) and while_stmt.child1 (body).
    stmt_chains: [4096]u32,

    /// Index 0 is reserved as a sentinel ("null") so that real nodes
    /// never alias the empty-link value.
    pub fn init() AST {
        var ast = AST{ .nodes = undefined, .count = 1, .stmt_chains = @splat(0) };
        ast.nodes[0] = .{ .kind = .identifier, .line = 0 };
        return ast;
    }

    fn addNode(self: *AST, kind: NodeKind, line: u32) u32 {
        const idx = self.count;
        self.nodes[idx] = .{ .kind = kind, .line = line };
        self.count += 1;
        return idx;
    }
};

pub const Parser = struct {
    lex: *const Lexer,
    pos: u32,
    ast: *AST,
    src: []const u8,

    fn peek(self: *const Parser) Token {
        return self.lex.get(self.pos);
    }

    fn advance(self: *Parser) Token {
        const t = self.peek();
        if (t.kind != .eof) self.pos += 1;
        return t;
    }

    fn match(self: *const Parser, kind: TokenKind) bool {
        return self.peek().kind == kind;
    }

    fn expect(self: *Parser, kind: TokenKind) Token {
        const t = self.peek();
        if (t.kind != kind) {
            printErr("Parse error at line ");
            printUsize(t.line);
            printErr(": expected ");
            printErr(@tagName(kind));
            printErr(", got ");
            printErr(@tagName(t.kind));
            printErr("\n");
            sysExit(1);
        }
        return self.advance();
    }

    fn skipNewlines(self: *Parser) void {
        while (self.match(.newline)) _ = self.advance();
    }

    fn skipBalancedBraces(self: *Parser) void {
        var depth: i32 = 0;
        while (!self.match(.eof)) {
            const k = self.peek().kind;
            _ = self.advance();
            if (k == .lbrace) depth += 1;
            if (k == .rbrace) {
                depth -= 1;
                if (depth <= 0) break;
            }
            if (depth == 0 and (k == .newline or k == .semicolon)) break;
        }
    }

    pub fn parse(self: *Parser) void {
        while (!self.match(.eof)) {
            self.skipNewlines();
            if (self.match(.eof)) break;
            if (self.match(.kw_fn)) {
                _ = self.parseFnDecl();
            } else if (self.match(.kw_import) or self.match(.kw_use)) {
                while (!self.match(.newline) and !self.match(.eof)) _ = self.advance();
            } else if (self.match(.kw_struct) or self.match(.kw_enum) or
                self.match(.kw_trait) or self.match(.kw_impl) or self.match(.kw_mod))
            {
                // Tolerant skipping of declarations whose codegen isn't ready
                while (!self.match(.lbrace) and !self.match(.newline) and !self.match(.eof)) _ = self.advance();
                if (self.match(.lbrace)) self.skipBalancedBraces();
            } else if (self.match(.kw_const) or self.match(.kw_type)) {
                while (!self.match(.newline) and !self.match(.semicolon) and !self.match(.eof)) _ = self.advance();
            } else if (self.match(.kw_pub)) {
                // pub fn ... handled by consuming pub then re-dispatching
                _ = self.advance();
                continue;
            } else {
                _ = self.parseExpr();
            }
            self.skipNewlines();
        }
    }

    fn parseFnDecl(self: *Parser) u32 {
        const tok = self.expect(.kw_fn);
        const name = self.expect(.identifier);

        _ = self.expect(.lparen);
        // Parameters: chain of identifier nodes linked via child1
        var first_param: u32 = 0;
        var last_param: u32 = 0;
        var param_count: u32 = 0;
        while (!self.match(.rparen) and !self.match(.eof)) {
            if (param_count > 0) _ = self.expect(.comma);
            if (self.match(.rparen)) break;
            const ptok = self.expect(.identifier);
            if (self.match(.colon)) {
                _ = self.advance();
                // Skip type expression up to , or )
                while (!self.match(.comma) and !self.match(.rparen) and !self.match(.eof)) _ = self.advance();
            }
            const pnode = self.ast.addNode(.identifier, ptok.line);
            self.ast.nodes[pnode].text_start = ptok.start;
            self.ast.nodes[pnode].text_len = ptok.len;
            if (first_param == 0) {
                first_param = pnode;
            } else {
                self.ast.nodes[last_param].child1 = pnode;
            }
            last_param = pnode;
            param_count += 1;
        }
        _ = self.expect(.rparen);
        // Return type: consume tokens up to body or newline
        if (self.match(.arrow)) {
            _ = self.advance();
            while (!self.match(.lbrace) and !self.match(.newline) and !self.match(.eof)) _ = self.advance();
        }
        self.skipNewlines();
        const body = self.parseBlock();
        const node = self.ast.addNode(.fn_decl, tok.line);
        self.ast.nodes[node].text_start = name.start;
        self.ast.nodes[node].text_len = name.len;
        self.ast.nodes[node].child0 = first_param;
        self.ast.nodes[node].child2 = body;
        self.ast.nodes[node].int_val = @intCast(param_count);
        return node;
    }

    fn parseBlock(self: *Parser) u32 {
        _ = self.expect(.lbrace);
        self.skipNewlines();
        const block = self.ast.addNode(.block, self.peek().line);

        // Chain of statements linked via child1
        var head: u32 = 0;
        var tail: u32 = 0;

        while (!self.match(.rbrace) and !self.match(.eof)) {
            self.skipNewlines();
            if (self.match(.rbrace)) break;

            var stmt: u32 = 0;
            if (self.match(.kw_return)) {
                _ = self.advance();
                var val: u32 = 0;
                if (!self.match(.newline) and !self.match(.rbrace) and !self.match(.eof)) {
                    val = self.parseExpr();
                }
                stmt = self.ast.addNode(.return_stmt, self.peek().line);
                self.ast.nodes[stmt].child0 = val;
            } else if (self.match(.kw_let)) {
                _ = self.advance();
                if (self.match(.kw_mut)) _ = self.advance(); // let mut x
                const name_tok = self.expect(.identifier);
                // Optional type annotation
                if (self.match(.colon)) {
                    _ = self.advance();
                    while (!self.match(.assign) and !self.match(.newline) and
                        !self.match(.rbrace) and !self.match(.eof)) _ = self.advance();
                }
                var init_val: u32 = 0;
                if (self.match(.assign)) {
                    _ = self.advance();
                    init_val = self.parseExpr();
                }
                stmt = self.ast.addNode(.let_stmt, name_tok.line);
                self.ast.nodes[stmt].text_start = name_tok.start;
                self.ast.nodes[stmt].text_len = name_tok.len;
                self.ast.nodes[stmt].child0 = init_val;
            } else if (self.match(.identifier) and self.pos + 1 < self.lex.token_count) {
                // Assignment? identifier (= += -= *= /=)
                const next_kind = self.lex.get(self.pos + 1).kind;
                const is_assign = next_kind == .assign or next_kind == .plus_eq or
                    next_kind == .minus_eq or next_kind == .star_eq or next_kind == .slash_eq;
                if (is_assign) {
                    const name_tok = self.advance();
                    const op_tok = self.advance();
                    const value = self.parseExpr();
                    stmt = self.ast.addNode(.assign_stmt, name_tok.line);
                    self.ast.nodes[stmt].text_start = name_tok.start;
                    self.ast.nodes[stmt].text_len = name_tok.len;
                    self.ast.nodes[stmt].child0 = value;
                    self.ast.nodes[stmt].op = @intFromEnum(op_tok.kind);
                } else {
                    stmt = self.parseExpr();
                }
            } else if (self.match(.kw_while)) {
                stmt = self.parseWhile();
            } else if (self.match(.kw_break)) {
                const t = self.advance();
                stmt = self.ast.addNode(.break_stmt, t.line);
            } else if (self.match(.kw_continue)) {
                const t = self.advance();
                stmt = self.ast.addNode(.continue_stmt, t.line);
            } else if (self.match(.kw_if)) {
                stmt = self.parseIf();
            } else {
                stmt = self.parseExpr();
            }

            if (stmt != 0) {
                if (head == 0) {
                    head = stmt;
                    tail = stmt;
                } else {
                    self.ast.stmt_chains[tail] = stmt;
                    tail = stmt;
                }
            }
            self.skipNewlines();
        }
        _ = self.expect(.rbrace);
        self.ast.nodes[block].child0 = head;
        return block;
    }

    // ── Expression parsing with proper precedence ──────────────────

    fn parseExpr(self: *Parser) u32 {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) u32 {
        var left = self.parseAnd();
        while (self.match(.pipe_pipe)) {
            const op = self.advance();
            const right = self.parseAnd();
            left = self.addBinary(left, right, op);
        }
        return left;
    }

    fn parseAnd(self: *Parser) u32 {
        var left = self.parseEquality();
        while (self.match(.and_and)) {
            const op = self.advance();
            const right = self.parseEquality();
            left = self.addBinary(left, right, op);
        }
        return left;
    }

    fn parseEquality(self: *Parser) u32 {
        var left = self.parseRelational();
        while (self.match(.eq) or self.match(.ne)) {
            const op = self.advance();
            const right = self.parseRelational();
            left = self.addBinary(left, right, op);
        }
        return left;
    }

    fn parseRelational(self: *Parser) u32 {
        var left = self.parseAdditive();
        while (self.match(.lt) or self.match(.gt) or self.match(.le) or self.match(.ge)) {
            const op = self.advance();
            const right = self.parseAdditive();
            left = self.addBinary(left, right, op);
        }
        return left;
    }

    fn parseAdditive(self: *Parser) u32 {
        var left = self.parseMultiplicative();
        while (self.match(.plus) or self.match(.minus)) {
            const op = self.advance();
            const right = self.parseMultiplicative();
            left = self.addBinary(left, right, op);
        }
        return left;
    }

    fn parseMultiplicative(self: *Parser) u32 {
        var left = self.parseUnary();
        while (self.match(.star) or self.match(.slash) or self.match(.percent)) {
            const op = self.advance();
            const right = self.parseUnary();
            left = self.addBinary(left, right, op);
        }
        return left;
    }

    fn addBinary(self: *Parser, left: u32, right: u32, op: Token) u32 {
        const n = self.ast.addNode(.binary_expr, op.line);
        self.ast.nodes[n].child0 = left;
        self.ast.nodes[n].child1 = right;
        self.ast.nodes[n].op = @intFromEnum(op.kind);
        return n;
    }

    fn parseUnary(self: *Parser) u32 {
        if (self.match(.minus) or self.match(.bang)) {
            const op = self.advance();
            const operand = self.parseUnary();
            const n = self.ast.addNode(.unary_expr, op.line);
            self.ast.nodes[n].child0 = operand;
            self.ast.nodes[n].op = @intFromEnum(op.kind);
            return n;
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) u32 {
        const tok = self.peek();

        if (self.match(.int_literal)) {
            _ = self.advance();
            const n = self.ast.addNode(.int_literal, tok.line);
            const txt = self.lex.text(tok);
            // Strip '_' digit separators
            var cleaned: [64]u8 = undefined;
            var clen: usize = 0;
            for (txt) |c| {
                if (c != '_' and clen < cleaned.len) {
                    cleaned[clen] = c;
                    clen += 1;
                }
            }
            self.ast.nodes[n].int_val = std.fmt.parseInt(i64, cleaned[0..clen], 10) catch 0;
            return n;
        }

        if (self.match(.float_literal)) {
            printErr("Compile error at line ");
            printUsize(tok.line);
            printErr(": float literals are not yet supported in codegen\n");
            sysExit(1);
        }

        if (self.match(.string_literal)) {
            _ = self.advance();
            const n = self.ast.addNode(.string_literal, tok.line);
            self.ast.nodes[n].text_start = tok.start + 1; // skip opening quote
            self.ast.nodes[n].text_len = tok.len - 2; // skip both quotes
            return n;
        }

        if (self.match(.kw_true)) {
            _ = self.advance();
            const n = self.ast.addNode(.int_literal, tok.line);
            self.ast.nodes[n].int_val = 1;
            return n;
        }

        if (self.match(.kw_false)) {
            _ = self.advance();
            const n = self.ast.addNode(.int_literal, tok.line);
            self.ast.nodes[n].int_val = 0;
            return n;
        }

        if (self.match(.lparen)) {
            _ = self.advance();
            const e = self.parseExpr();
            _ = self.expect(.rparen);
            return e;
        }

        if (self.match(.identifier)) {
            _ = self.advance();
            const n = self.ast.addNode(.identifier, tok.line);
            self.ast.nodes[n].text_start = tok.start;
            self.ast.nodes[n].text_len = tok.len;
            // Function call?
            if (self.match(.lparen)) {
                _ = self.advance();
                // Each argument is wrapped in an expr_stmt node so the
                // arg chain (via child1) never collides with expression
                // internal links.
                var first_arg: u32 = 0;
                var last_arg: u32 = 0;
                while (!self.match(.rparen) and !self.match(.eof)) {
                    if (first_arg != 0) _ = self.expect(.comma);
                    const arg = self.parseExpr();
                    const wrap = self.ast.addNode(.expr_stmt, tok.line);
                    self.ast.nodes[wrap].child0 = arg;
                    if (first_arg == 0) {
                        first_arg = wrap;
                    } else {
                        self.ast.nodes[last_arg].child1 = wrap;
                    }
                    last_arg = wrap;
                }
                _ = self.expect(.rparen);
                const cn = self.ast.addNode(.call_expr, tok.line);
                self.ast.nodes[cn].child0 = n;
                self.ast.nodes[cn].child2 = first_arg; // args in child2 to avoid collision with block's child1 chaining
                return cn;
            }
            return n;
        }

        // Note: '{' and 'if' are NOT matched as primary expressions.
        // They are only parsed at statement level by the calling context
        // (parseBlock, parseIf, parseWhile). This avoids ambiguity where
        // a while/if condition would greedily consume the body block.

        // Fallback: skip unexpected token
        printErr("Parse error at line ");
        printUsize(tok.line);
        printErr(": unexpected token '");
        printErr(self.lex.text(tok));
        printErr("' (");
        printErr(@tagName(tok.kind));
        printErr(")\n");
        _ = self.advance();
        return self.ast.addNode(.identifier, tok.line);
    }

    fn parseIf(self: *Parser) u32 {
        const tok = self.expect(.kw_if);
        self.skipNewlines();
        const cond = self.parseExpr();
        self.skipNewlines();
        const then_b = self.parseBlock();
        var else_b: u32 = 0;
        self.skipNewlines();
        if (self.match(.kw_else) or self.match(.kw_elif)) {
            else_b = self.parseElseTail(tok.line);
        }
        const n = self.ast.addNode(.if_stmt, tok.line);
        self.ast.nodes[n].child0 = cond;
        self.ast.nodes[n].child1 = then_b;
        self.ast.nodes[n].child2 = else_b;
        return n;
    }

    /// Parse the tail of an if statement starting at `else` or `elif`.
    fn parseElseTail(self: *Parser, line: u32) u32 {
        const is_elif = self.match(.kw_elif);
        _ = self.advance();
        self.skipNewlines();
        if (!is_elif and self.match(.kw_if)) return self.parseIf();
        if (is_elif) {
            // elif <cond> <block> [else/elif ...]
            const tok = self.peek();
            _ = tok;
            const cond = self.parseExpr();
            self.skipNewlines();
            const body = self.parseBlock();
            const n = self.ast.addNode(.if_stmt, line);
            self.ast.nodes[n].child0 = cond;
            self.ast.nodes[n].child1 = body;
            self.skipNewlines();
            if (self.match(.kw_else) or self.match(.kw_elif)) {
                self.ast.nodes[n].child2 = self.parseElseTail(line);
            }
            return n;
        }
        return self.parseBlock();
    }

    fn parseWhile(self: *Parser) u32 {
        const tok = self.expect(.kw_while);
        self.skipNewlines();
        const cond = self.parseExpr();
        self.skipNewlines();
        const body = self.parseBlock();
        const n = self.ast.addNode(.while_stmt, tok.line);
        self.ast.nodes[n].child0 = cond;
        self.ast.nodes[n].child1 = body;
        return n;
    }
};

// ════════════════════════════════════════════════════════════════════════════
// x86-64 CODEGEN + ELF OUTPUT
// ════════════════════════════════════════════════════════════════════════════

const StringPatch = struct {
    patch_pos: u32,
    string_offset: u32,
};

const LocalVar = struct {
    name_start: u32,
    name_len: u32,
    slot: u32, // address = rbp - (slot * 8)
};

const FnInfo = struct {
    name_start: u32,
    name_len: u32,
    ast_idx: u32,
    param_count: u32,
    code_offset: u32,
};

const CallPatch = struct {
    name_start: u32,
    name_len: u32,
    patch_pos: u32,
};

const LoopCtx = struct {
    break_patches: [16]u32,
    break_count: u32,
    continue_target: u32,
};

const ARG_REGS = [_]u8{ 7, 6, 2, 1, 8, 9 }; // rdi, rsi, rdx, rcx, r8, r9

pub const Codegen = struct {
    code: [65536]u8,
    code_len: u32,
    rodata: [65536]u8,
    rodata_len: u32,
    string_patches: [512]StringPatch,
    patch_count: u32,
    string_offsets: [256]u32,
    string_lens: [256]u32,
    string_count: u32,
    src: []const u8,
    ast: *const AST,

    locals: [256]LocalVar,
    local_count: u32,
    next_slot: u32,
    total_slots: u32,
    in_main: bool,

    fns: [128]FnInfo,
    fn_count: u32,
    call_patches: [256]CallPatch,
    call_patch_count: u32,
    printint_patches: [64]u32,
    printint_patch_count: u32,

    loops: [8]LoopCtx,
    loop_depth: u32,

    printint_offset: u32,

    pub fn init(source: []const u8, tree: *const AST) Codegen {
        return .{
            .code = undefined,
            .code_len = 0,
            .rodata = undefined,
            .rodata_len = 0,
            .string_patches = undefined,
            .patch_count = 0,
            .string_offsets = undefined,
            .string_lens = undefined,
            .string_count = 0,
            .src = source,
            .ast = tree,
            .locals = undefined,
            .local_count = 0,
            .next_slot = 0,
            .total_slots = 0,
            .in_main = false,
            .fns = undefined,
            .fn_count = 0,
            .call_patches = undefined,
            .call_patch_count = 0,
            .printint_patches = undefined,
            .printint_patch_count = 0,
            .loops = undefined,
            .loop_depth = 0,
            .printint_offset = 0,
        };
    }

    // ── Emit bytes ──────────────────────────────────────────────
    fn emit8(self: *Codegen, b: u8) void {
        self.code[self.code_len] = b;
        self.code_len += 1;
    }

    fn emit32(self: *Codegen, v: u32) void {
        self.code[self.code_len..][0..4].* = .{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24) };
        self.code_len += 4;
    }

    fn emit64(self: *Codegen, v: u64) void {
        self.code[self.code_len..][0..8].* = .{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24), @truncate(v >> 32), @truncate(v >> 40), @truncate(v >> 48), @truncate(v >> 56) };
        self.code_len += 8;
    }

    // ── x86-64 instructions ────────────────────────────────────
    fn mov64imm(self: *Codegen, dst: u8, imm: u64) void {
        self.emit8(if (dst >= 8) 0x49 else 0x48);
        self.emit8(0xB8 + (dst & 7));
        self.emit64(imm);
    }

    fn pushReg(self: *Codegen, r: u8) void {
        if (r >= 8) self.emit8(0x41);
        self.emit8(0x50 + (r & 7));
    }

    fn popReg(self: *Codegen, r: u8) void {
        if (r >= 8) self.emit8(0x41);
        self.emit8(0x58 + (r & 7));
    }

    fn movRegReg(self: *Codegen, dst: u8, src: u8) void {
        var rex: u8 = 0x48;
        if (src >= 8) rex |= 0x04;
        if (dst >= 8) rex |= 0x01;
        self.emit8(rex);
        self.emit8(0x89);
        self.emit8(0xC0 | ((src & 7) << 3) | (dst & 7));
    }

    fn xorReg(self: *Codegen, a: u8, b: u8) void {
        var rex: u8 = 0x48;
        if (a >= 8) rex |= 0x04;
        if (b >= 8) rex |= 0x01;
        self.emit8(rex);
        self.emit8(0x31);
        self.emit8(0xC0 | ((b & 7) << 3) | (a & 7));
    }

    fn syscallInst(self: *Codegen) void {
        self.emit8(0x0F);
        self.emit8(0x05);
    }

    fn ret(self: *Codegen) void {
        self.emit8(0xC3);
    }

    /// LEA r64, [rip + disp32] with deferred patch for string addresses
    fn leaRipDeferred(self: *Codegen, dst: u8, string_idx: u32) void {
        var rex: u8 = 0x48;
        if (dst >= 8) rex |= 0x04;
        self.emit8(rex);
        self.emit8(0x8D);
        self.emit8(0x05 | ((dst & 7) << 3));
        const patch_pos = self.code_len;
        self.emit32(0);
        if (self.patch_count < self.string_patches.len) {
            self.string_patches[self.patch_count] = .{
                .patch_pos = patch_pos,
                .string_offset = self.string_offsets[string_idx],
            };
            self.patch_count += 1;
        }
    }

    fn emitJe(self: *Codegen) u32 {
        self.emit8(0x0F);
        self.emit8(0x84);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJne(self: *Codegen) u32 {
        self.emit8(0x0F);
        self.emit8(0x85);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJmp(self: *Codegen) u32 {
        self.emit8(0xE9);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJmpTo(self: *Codegen, target: u32) void {
        self.emit8(0xE9);
        const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(self.code_len + 4)));
        self.emit32(@bitCast(disp));
    }

    fn patchJump(self: *Codegen, patch_pos: u32) void {
        const disp: i32 = @intCast(@as(i64, @intCast(self.code_len)) - @as(i64, @intCast(patch_pos + 4)));
        std.mem.writeInt(i32, self.code[patch_pos..][0..4], disp, .little);
    }

    /// call rel32 to an absolute code offset, resolved immediately
    fn callOffset(self: *Codegen, target: u32) void {
        self.emit8(0xE8);
        const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(self.code_len + 4)));
        self.emit32(@bitCast(disp));
    }

    /// call rel32 to a named user function, patched later
    fn callNamed(self: *Codegen, name: []const u8) void {
        self.emit8(0xE8);
        const patch = self.code_len;
        self.emit32(0);
        if (self.call_patch_count < self.call_patches.len) {
            self.call_patches[self.call_patch_count] = .{
                .name_start = @intCast(name.ptr - self.src.ptr),
                .name_len = @intCast(name.len),
                .patch_pos = patch,
            };
            self.call_patch_count += 1;
        }
    }

    // ── Stack frame helpers ─────────────────────────────────────
    fn storeRegToSlot(self: *Codegen, reg: u8, slot: u32) void {
        const disp: i32 = -@as(i32, @intCast(slot)) * 8;
        var rex: u8 = 0x48;
        if (reg >= 8) rex |= 0x04;
        self.emit8(rex);
        self.emit8(0x89); // mov [rbp+disp], reg
        self.emit8(0x45 | ((reg & 7) << 3));
        self.emit8(@intCast(disp & 0xFF));
    }

    fn storeRaxToSlot(self: *Codegen, slot: u32) void {
        self.storeRegToSlot(0, slot);
    }

    fn loadSlotToRax(self: *Codegen, slot: u32) void {
        const disp: i32 = -@as(i32, @intCast(slot)) * 8;
        self.emit8(0x48);
        self.emit8(0x8B); // mov rax, [rbp+disp]
        self.emit8(0x45);
        self.emit8(@intCast(disp & 0xFF));
    }

    fn emitLeaveRet(self: *Codegen) void {
        // mov rsp, rbp ; pop rbp ; ret
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xEC);
        self.popReg(5);
        self.ret();
    }

    // ── Symbol tables ───────────────────────────────────────────
    fn nodeText(self: *const Codegen, idx: u32) []const u8 {
        const n = self.ast.nodes[idx];
        return self.src[n.text_start..][0..n.text_len];
    }

    fn findLocal(self: *Codegen, name: []const u8) ?u32 {
        var i: u32 = self.local_count;
        while (i > 0) {
            i -= 1;
            const l = self.locals[i];
            if (eql(self.src[l.name_start..][0..l.name_len], name)) return l.slot;
        }
        return null;
    }

    fn defineLocal(self: *Codegen, name: []const u8) void {
        if (self.findLocal(name) != null) {
            printErr("Compile error: redefinition of '");
            printErr(name);
            printErr("'\n");
            sysExit(1);
        }
        if (self.local_count >= self.locals.len) {
            printErr("Compile error: too many local variables\n");
            sysExit(1);
        }
        self.next_slot += 1;
        self.locals[self.local_count] = .{
            .name_start = @intCast(name.ptr - self.src.ptr),
            .name_len = @intCast(name.len),
            .slot = self.next_slot,
        };
        self.local_count += 1;
    }

    fn findFn(self: *Codegen, name: []const u8) ?u32 {
        for (0..self.fn_count) |i| {
            const f = self.fns[i];
            if (eql(self.src[f.name_start..][0..f.name_len], name)) return @intCast(i);
        }
        return null;
    }

    fn collectFns(self: *Codegen) void {
        for (0..self.ast.count) |i| {
            const n = self.ast.nodes[i];
            if (n.kind != .fn_decl) continue;
            if (self.fn_count >= self.fns.len) break;
            self.fns[self.fn_count] = .{
                .name_start = n.text_start,
                .name_len = n.text_len,
                .ast_idx = @intCast(i),
                .param_count = @intCast(n.int_val),
                .code_offset = 0,
            };
            self.fn_count += 1;
        }
    }

    /// Pre-pass: count let statements in a block so frame size is known
    /// before emitting the prologue.
    fn countLets(self: *const Codegen, block_idx: u32) u32 {
        var count: u32 = 0;
        var idx = self.ast.nodes[block_idx].child0; // first stmt
        while (idx != 0) {
            const n = self.ast.nodes[idx];
            const next = self.ast.stmt_chains[idx]; // save NEXT before recursing
            switch (n.kind) {
                .let_stmt => count += 1,
                .block => count += self.countLets(idx),
                .if_stmt => {
                    count += self.countLets(n.child1); // then block
                    if (n.child2 != 0) {
                        count += self.countLets(n.child2); // else block
                    }
                },
                .while_stmt => {
                    count += self.countLets(n.child1); // while body
                },
                else => {},
            }
            idx = next; // advance to next sibling statement
        }
        return count;
    }

    fn resetFunctionScope(self: *Codegen, param_count: u32, let_count: u32) void {
        self.local_count = 0;
        self.total_slots = param_count + let_count;
        self.next_slot = param_count; // lets are allocated after param slots
    }

    fn emitPrologue(self: *Codegen, params_head: u32) void {
        const frame = (self.total_slots * 8 + 15) & ~@as(u32, 15);
        self.pushReg(5); // push rbp
        // mov rbp, rsp
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xE5);
        if (frame > 0) {
            if (frame <= 127) {
                self.emit8(0x48);
                self.emit8(0x83);
                self.emit8(0xEC);
                self.emit8(@intCast(frame));
            } else {
                self.emit8(0x48);
                self.emit8(0x81);
                self.emit8(0xEC);
                self.emit32(frame);
            }
        }
        // Spill register args to their slots
        var pi = params_head;
        var ai: usize = 0;
        var slot: u32 = 1;
        while (pi != 0 and ai < ARG_REGS.len) {
            self.storeRegToSlot(ARG_REGS[ai], slot);
            pi = self.ast.nodes[pi].child1;
            ai += 1;
            slot += 1;
        }
    }

    // ── Patch all deferred references ───────────────────────────
    pub    fn patchStrings(self: *Codegen) void {
        for (0..self.patch_count) |i| {
            const p = self.string_patches[i];
            // RIP after the instruction = code_vaddr + patch_pos + 4
            // (patch_pos is where the 4-byte displacement sits;
            //  the instruction ends 4 bytes later)
            const disp: i32 = @intCast(@as(i64, @intCast(self.code_len + p.string_offset)) - @as(i64, @intCast(p.patch_pos + 4)));
            std.mem.writeInt(i32, self.code[p.patch_pos..][0..4], disp, .little);
        }
    }

    fn patchCalls(self: *Codegen) void {
        // Patch user-defined function calls
        for (0..self.call_patch_count) |i| {
            const p = self.call_patches[i];
            const name = self.src[p.name_start..][0..p.name_len];
            const fi = self.findFn(name) orelse {
                printErr("Compile error: call to undefined function '");
                printErr(name);
                printErr("'\n");
                sysExit(1);
            };
            const target = self.fns[fi].code_offset;
            const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(p.patch_pos + 4)));
            std.mem.writeInt(i32, self.code[p.patch_pos..][0..4], disp, .little);
        }
        // Patch printInt calls
        for (0..self.printint_patch_count) |i| {
            const patch_pos = self.printint_patches[i];
            const target = self.printint_offset;
            const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(patch_pos + 4)));
            std.mem.writeInt(i32, self.code[patch_pos..][0..4], disp, .little);
        }
    }

    // ── String table ────────────────────────────────────────────
    fn addString(self: *Codegen, str: []const u8) u32 {
        var i: u32 = 0;
        while (i < self.string_count) : (i += 1) {
            if (self.string_lens[i] == str.len) {
                var found = true;
                for (0..str.len) |j| {
                    if (self.rodata[self.string_offsets[i] + j] != str[j]) {
                        found = false;
                        break;
                    }
                }
                if (found) return i;
            }
        }
        const idx = self.string_count;
        const off = self.rodata_len;
        for (str) |ch| {
            self.rodata[self.rodata_len] = ch;
            self.rodata_len += 1;
        }
        self.rodata[self.rodata_len] = 0; // null terminator
        self.rodata_len += 1;

        if (self.string_count < 256) {
            self.string_offsets[self.string_count] = off;
            self.string_lens[self.string_count] = @intCast(str.len);
            self.string_count += 1;
        }
        return idx;
    }

    // ── Compile program ─────────────────────────────────────────
    pub fn compile(self: *Codegen) void {
        self.collectFns();

        // Main must sit at code offset 0 (ELF entry point)
        var compiled: [128]bool = @splat(false);
        var main_found = false;
        for (0..self.fn_count) |i| {
            const f = self.fns[i];
            if (eql(self.src[f.name_start..][0..f.name_len], "main")) {
                self.compileFn(@intCast(i));
                compiled[i] = true;
                main_found = true;
                break;
            }
        }

        for (0..self.fn_count) |i| {
            if (!compiled[i]) self.compileFn(@intCast(i));
        }

        if (!main_found) {
            // No main: just exit(0)
            self.mov64imm(0, 60);
            self.xorReg(7, 7);
            self.syscallInst();
        }

        self.emitPrintIntRoutine();
        self.patchCalls();
    }

    fn compileFn(self: *Codegen, fi: u32) void {
        const f = self.fns[fi];
        const decl = self.ast.nodes[f.ast_idx];
        const name = self.src[f.name_start..][0..f.name_len];
        const is_main = eql(name, "main");

        self.fns[fi].code_offset = self.code_len;
        self.in_main = is_main;
        self.loop_depth = 0;

        const let_count = self.countLets(decl.child2);
        self.resetFunctionScope(f.param_count, let_count);

        // Register parameter names as locals in slots 1..N
        var pi = decl.child0;
        while (pi != 0) {
            const pname = self.nodeText(pi);
            if (self.local_count >= self.locals.len) break;
            self.locals[self.local_count] = .{
                .name_start = @intCast(pname.ptr - self.src.ptr),
                .name_len = @intCast(pname.len),
                .slot = self.local_count + 1,
            };
            self.local_count += 1;
            pi = self.ast.nodes[pi].child1;
        }

        self.emitPrologue(decl.child0);
        self.compileBlock(decl.child2);

        if (is_main) {
            // Implicit exit(0)
            self.mov64imm(0, 60);
            self.xorReg(7, 7);
            self.syscallInst();
        } else {
            // Implicit return 0
            self.xorReg(0, 0);
            self.emitLeaveRet();
        }
    }

    /// Native itoa + write routine used by the printInt builtin.
    /// Input: rdi = signed 64-bit integer. Prints digits + newline.
    fn emitPrintIntRoutine(self: *Codegen) void {
        self.printint_offset = self.code_len;

        self.subRspImm(40); // digit buffer on stack
        // lea rsi, [rsp+39]
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x74);
        self.emit8(0x24);
        self.emit8(39);
        // mov byte [rsi], '\n'
        self.emit8(0xC6);
        self.emit8(0x06);
        self.emit8('\n');
        // mov rax, rdi
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xF8);
        // xor r8d, r8d  (sign flag)
        self.emit8(0x45);
        self.emit8(0x31);
        self.emit8(0xC0);
        // test rax, rax
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        // jns +9 (skip neg & mov r8d,1)
        self.emit8(0x79);
        self.emit8(9);
        // neg rax
        self.emit8(0x48);
        self.emit8(0xF7);
        self.emit8(0xD8);
        // mov r8d, 1
        self.emit8(0x41);
        self.emit8(0xB8);
        self.emit32(1);

        const div_loop = self.code_len;
        // mov r9d, 10
        self.emit8(0x41);
        self.emit8(0xB9);
        self.emit32(10);
        // xor edx, edx
        self.emit8(0x31);
        self.emit8(0xD2);
        // div r9
        self.emit8(0x49);
        self.emit8(0xF7);
        self.emit8(0xF1);
        // add dl, '0'
        self.emit8(0x80);
        self.emit8(0xC2);
        self.emit8('0');
        // dec rsi
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xCE);
        // mov [rsi], dl
        self.emit8(0x88);
        self.emit8(0x16);
        // test rax, rax
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        // jnz div_loop (backward rel8)
        const after_jnz = self.code_len + 2;
        const back_disp: i8 = @intCast(@as(i64, @intCast(div_loop)) - @as(i64, @intCast(after_jnz)));
        self.emit8(0x75);
        self.emit8(@bitCast(back_disp));

        // test r8, r8
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xC0);
        // jz +6 (skip sign write)
        self.emit8(0x74);
        self.emit8(6);
        // dec rsi
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xCE);
        // mov byte [rsi], '-'
        self.emit8(0xC6);
        self.emit8(0x06);
        self.emit8('-');

        // mov rdx, rsp
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xE2);
        // add rdx, 40
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xC2);
        self.emit8(40);
        // sub rdx, rsi
        self.emit8(0x48);
        self.emit8(0x29);
        self.emit8(0xF2);
        // mov eax, 1 (sys_write)
        self.emit8(0xB8);
        self.emit32(1);
        // mov edi, 1 (stdout)
        self.emit8(0xBF);
        self.emit32(1);
        self.syscallInst();
        // add rsp, 40
        self.subRspImmAdd(40);
        self.ret();
    }

    fn subRspImmAdd(self: *Codegen, imm: u32) void {
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xC4); // add rsp, imm8
        self.emit8(@intCast(imm));
    }

    fn subRspImm(self: *Codegen, imm: u32) void {
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xEC); // sub rsp, imm8
        self.emit8(@intCast(imm));
    }

    // ── Statement compilation ───────────────────────────────────
    fn compileBlock(self: *Codegen, block_idx: u32) void {
        const block = self.ast.nodes[block_idx];
        if (block.kind != .block) return;
        var stmt_idx = block.child0;
        while (stmt_idx != 0) {
            self.compileStmt(stmt_idx);
            stmt_idx = self.ast.stmt_chains[stmt_idx];
        }
    }

    fn compileStmt(self: *Codegen, idx: u32) void {
        if (idx == 0) return;
        const node = self.ast.nodes[idx];
        switch (node.kind) {
            .return_stmt => {
                if (node.child0 != 0) {
                    self.compileExpr(node.child0);
                } else {
                    self.xorReg(0, 0);
                }
                if (self.in_main) {
                    self.movRegReg(7, 0); // rdi = exit code
                    self.mov64imm(0, 60);
                    self.syscallInst();
                } else {
                    self.emitLeaveRet();
                }
            },
            .expr_stmt => {
                self.compileExpr(node.child0);
            },
            .call_expr => {
                // Bare call used as a statement
                self.compileExpr(idx);
            },
            .let_stmt => {
                const name = self.nodeText(idx);
                self.defineLocal(name);
                const slot = self.findLocal(name).?;
                if (node.child0 != 0) {
                    self.compileExpr(node.child0);
                } else {
                    self.xorReg(0, 0);
                }
                self.storeRaxToSlot(slot);
            },
            .assign_stmt => {
                const name = self.nodeText(idx);
                const slot = self.findLocal(name) orelse {
                    printErr("Compile error: assignment to undeclared variable '");
                    printErr(name);
                    printErr("'\n");
                    sysExit(1);
                };
                self.compileExpr(node.child0); // rhs → rax
                const op_kind: TokenKind = @enumFromInt(node.op);
                if (op_kind != .assign) {
                    // Compound: rax = var OP rhs
                    self.pushReg(0); // save rhs
                    self.loadSlotToRax(slot); // rax = current value
                    self.popReg(1); // rcx = rhs
                    self.emitArith(op_kind);
                }
                self.storeRaxToSlot(slot);
            },
            .block => {
                self.compileBlock(idx);
            },
            .if_stmt => {
                self.compileExpr(node.child0);
                // test rax, rax
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                const patch = self.emitJe();
                self.compileBlock(node.child1);
                if (node.child2 != 0) {
                    const jmp_patch = self.emitJmp();
                    self.patchJump(patch);
                    self.compileBlock(node.child2);
                    self.patchJump(jmp_patch);
                } else {
                    self.patchJump(patch);
                }
            },
            .while_stmt => {
                if (self.loop_depth >= self.loops.len) {
                    printErr("Compile error: loops nested too deeply\n");
                    sysExit(1);
                }
                const loop_start = self.code_len;
                self.loops[self.loop_depth] = .{ .break_patches = undefined, .break_count = 0, .continue_target = loop_start };
                self.loop_depth += 1;

                self.compileExpr(node.child0);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0); // test rax, rax
                const exit_patch = self.emitJe();
                self.compileBlock(node.child1);
                self.emitJmpTo(loop_start);
                self.patchJump(exit_patch);

                self.loop_depth -= 1;
                const ctx = self.loops[self.loop_depth];
                for (0..ctx.break_count) |b| {
                    self.patchJump(ctx.break_patches[b]);
                }
            },
            .break_stmt => {
                if (self.loop_depth == 0) {
                    printErr("Compile error: 'break' outside of loop\n");
                    sysExit(1);
                }
                self.recordBreak();
            },
            .continue_stmt => {
                if (self.loop_depth == 0) {
                    printErr("Compile error: 'continue' outside of loop\n");
                    sysExit(1);
                }
                self.emitJmpTo(self.loops[self.loop_depth - 1].continue_target);
            },
            else => {},
        }
    }

    fn recordBreak(self: *Codegen) void {
        const p = self.emitJmp();
        const ctx = &self.loops[self.loop_depth - 1];
        if (ctx.break_count < ctx.break_patches.len) {
            ctx.break_patches[ctx.break_count] = p;
            ctx.break_count += 1;
        }
    }

    /// Apply a binary arithmetic/comparison op with left in rax, right in rcx.
    fn emitArith(self: *Codegen, op_kind: TokenKind) void {
        switch (op_kind) {
            .plus, .plus_eq => {
                self.emit8(0x48);
                self.emit8(0x01);
                self.emit8(0xC8); // add rax, rcx
            },
            .minus, .minus_eq => {
                self.emit8(0x48);
                self.emit8(0x29);
                self.emit8(0xC8); // sub rax, rcx
            },
            .star, .star_eq => {
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xAF);
                self.emit8(0xC1); // imul rax, rcx
            },
            .slash, .slash_eq => {
                self.emit8(0x48);
                self.emit8(0x99); // cqo
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xF9); // idiv rcx
            },
            .percent => {
                self.emit8(0x48);
                self.emit8(0x99); // cqo
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xF9); // idiv rcx
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0xD0); // mov rax, rdx (remainder)
            },
            .eq => {
                self.cmpSetcc(0x94); // sete
            },
            .ne => {
                self.cmpSetcc(0x95); // setne
            },
            .lt => {
                self.cmpSetcc(0x9C); // setl
            },
            .ge => {
                self.cmpSetcc(0x9D); // setge
            },
            .le => {
                self.cmpSetcc(0x9E); // setle
            },
            .gt => {
                self.cmpSetcc(0x9F); // setg
            },
            else => {},
        }
    }

    /// cmp rax, rcx ; setXX al ; movzx rax, al
    fn cmpSetcc(self: *Codegen, cc: u8) void {
        self.emit8(0x48);
        self.emit8(0x39);
        self.emit8(0xC8); // cmp rax, rcx
        self.emit8(0x0F);
        self.emit8(cc);
        self.emit8(0xC0); // setXX al
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0xB6);
        self.emit8(0xC0); // movzx rax, al
    }

    fn compileLogicalAnd(self: *Codegen, node: ASTNode) void {
        self.compileExpr(node.child0);
        self.emitTestRax();
        const fail1 = self.emitJe();
        self.compileExpr(node.child1);
        self.emitTestRax();
        const fail2 = self.emitJe();
        self.mov64imm(0, 1);
        const done = self.emitJmp();
        self.patchJump(fail1);
        self.patchJump(fail2);
        self.xorReg(0, 0);
        self.patchJump(done);
    }

    fn compileLogicalOr(self: *Codegen, node: ASTNode) void {
        self.compileExpr(node.child0);
        self.emitTestRax();
        const ok1 = self.emitJne();
        self.compileExpr(node.child1);
        self.emitTestRax();
        const ok2 = self.emitJne();
        self.xorReg(0, 0);
        const done = self.emitJmp();
        self.patchJump(ok1);
        self.patchJump(ok2);
        self.mov64imm(0, 1);
        self.patchJump(done);
    }

    fn emitTestRax(self: *Codegen) void {
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0); // test rax, rax
    }

    fn compileExpr(self: *Codegen, idx: u32) void {
        if (idx == 0) return;
        const node = self.ast.nodes[idx];
        switch (node.kind) {
            .int_literal => {
                self.mov64imm(0, @bitCast(node.int_val));
            },
            .string_literal => {
                const str = self.src[node.text_start..][0..node.text_len];
                const str_idx = self.addString(str);
                self.leaRipDeferred(6, str_idx); // rsi = string address
                self.mov64imm(2, str.len); // rdx = length
            },
            .identifier => {
                const name = self.nodeText(idx);
                const slot = self.findLocal(name) orelse {
                    printErr("Compile error: undefined variable '");
                    printErr(name);
                    printErr("'\n");
                    sysExit(1);
                };
                self.loadSlotToRax(slot);
            },
            .unary_expr => {
                self.compileExpr(node.child0);
                const op_kind: TokenKind = @enumFromInt(node.op);
                if (op_kind == .minus) {
                    self.emit8(0x48);
                    self.emit8(0xF7);
                    self.emit8(0xD8); // neg rax
                } else if (op_kind == .bang) {
                    self.emitTestRax();
                    self.emit8(0x0F);
                    self.emit8(0x94);
                    self.emit8(0xC0); // sete al
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0xB6);
                    self.emit8(0xC0); // movzx rax, al
                }
            },
            .binary_expr => {
                const op_kind: TokenKind = @enumFromInt(node.op);
                if (op_kind == .and_and) {
                    self.compileLogicalAnd(node);
                    return;
                }
                if (op_kind == .pipe_pipe) {
                    self.compileLogicalOr(node);
                    return;
                }
                // Evaluate right, push, evaluate left, pop into rcx, operate
                self.compileExpr(node.child1); // right → rax
                self.pushReg(0);
                self.compileExpr(node.child0); // left → rax
                self.popReg(1); // rcx = right
                self.emitArith(op_kind);
            },
            .call_expr => {
                const callee = self.ast.nodes[node.child0];
                if (callee.kind != .identifier) return;
                const name = self.nodeText(node.child0);

                // Count args (wrapped in expr_stmt chain in child2)
                var argc: u32 = 0;
                var ai = node.child2;
                while (ai != 0) {
                    argc += 1;
                    ai = self.ast.nodes[ai].child1;
                }

                if (eql(name, "println") or eql(name, "print")) {
                    if (argc != 1) {
                        printErr("Compile error: ");
                        printErr(name);
                        printErr(" expects exactly 1 argument\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    self.mov64imm(0, 1); // rax = sys_write
                    self.mov64imm(7, 1); // rdi = stdout
                    self.syscallInst();
                    if (eql(name, "println")) {
                        const nl_idx = self.addString("\n");
                        self.leaRipDeferred(6, nl_idx);
                        self.mov64imm(0, 1);
                        self.mov64imm(7, 1);
                        self.mov64imm(2, 1);
                        self.syscallInst();
                    }
                    return;
                }

                if (eql(name, "printInt")) {
                    if (argc != 1) {
                        printErr("Compile error: printInt expects exactly 1 argument\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    self.movRegReg(7, 0); // rdi = value
                    // Emit a call rel32 and record for later patching.
                    self.emit8(0xE8);
                    const patch = self.code_len;
                    self.emit32(0);
                    if (self.printint_patch_count < self.printint_patches.len) {
                        self.printint_patches[self.printint_patch_count] = patch;
                        self.printint_patch_count += 1;
                    }
                    return;
                }

                if (eql(name, "exit")) {
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    self.movRegReg(7, 0);
                    self.mov64imm(0, 60);
                    self.syscallInst();
                    return;
                }

                // User-defined function call (System V AMD64 convention)
                const fi = self.findFn(name) orelse {
                    printErr("Compile error: call to undefined function '");
                    printErr(name);
                    printErr("'\n");
                    sysExit(1);
                };
                if (argc != self.fns[fi].param_count) {
                    printErr("Compile error: function '");
                    printErr(name);
                    printErr("' expects ");
                    printUsize(self.fns[fi].param_count);
                    printErr(" argument(s), got ");
                    printUsize(argc);
                    printErr("\n");
                    sysExit(1);
                }
                if (argc > ARG_REGS.len) {
                    printErr("Compile error: more than 6 arguments not supported yet\n");
                    sysExit(1);
                }
                // Evaluate args left-to-right, pushing each
                ai = node.child2;
                while (ai != 0) {
                    self.compileExpr(self.ast.nodes[ai].child0);
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                }
                // Pop into arg registers in reverse order
                var ri: usize = argc;
                while (ri > 0) {
                    ri -= 1;
                    self.popReg(ARG_REGS[ri]);
                }
                self.callNamed(name);
            },
            else => {},
        }
    }

    // ── ELF Generation ─────────────────────────────────────────
    pub fn generateELF(self: *Codegen, output: []u8) usize {
        var pos: usize = 0;
        const header_size: u64 = 64;
        const phdr_size: u64 = 56;
        const num_phdrs: u64 = 2;
        const total_size: u64 = self.code_len + self.rodata_len;
        // Page-align the code offset so (p_offset % p_align) == (p_vaddr % p_align)
        const raw_offset = header_size + phdr_size * num_phdrs;
        const code_file_offset = (raw_offset + 0xFFF) & ~@as(u64, 0xFFF); // round up to 4096
        const code_vaddr: u64 = 0x400000;
        const entry = code_vaddr;

        // ELF Header (64 bytes)
        output[0..16].* = .{ 0x7F, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        write16(output[16..], 2); // ET_EXEC
        write16(output[18..], 62); // EM_X86_64
        write32(output[20..], 1); // version
        write64(output[24..], entry); // entry
        write64(output[32..], header_size); // phoff
        write64(output[40..], 0); // shoff
        write32(output[48..], 0); // flags
        write16(output[52..], 64); // ehsize
        write16(output[54..], 56); // phentsize
        write16(output[56..], @intCast(num_phdrs)); // phnum
        write16(output[58..], 64); // shentsize
        write16(output[60..], 0); // shnum
        write16(output[62..], 0); // shstrndx
        pos = 64;

        // PT_LOAD (code + rodata)
        write32(output[pos..][0..4], 1); pos += 4;
        write32(output[pos..][0..4], 5); pos += 4;
        write64(output[pos..][0..8], code_file_offset); pos += 8;
        write64(output[pos..][0..8], code_vaddr); pos += 8;
        write64(output[pos..][0..8], code_vaddr); pos += 8;
        write64(output[pos..][0..8], total_size); pos += 8;
        write64(output[pos..][0..8], total_size + 0x10000); pos += 8;
        write64(output[pos..][0..8], 0x1000); pos += 8;

        // PT_GNU_STACK
        write32(output[pos..][0..4], 0x6474e551); pos += 4;
        write32(output[pos..][0..4], 7); pos += 4;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], 0x10); pos += 8;

        // Pad to code_file_offset (page-aligned)
        while (pos < code_file_offset) {
            output[pos] = 0;
            pos += 1;
        }

        // Code
        @memcpy(output[pos..][0..self.code_len], self.code[0..self.code_len]);
        pos += self.code_len;

        // Rodata
        @memcpy(output[pos..][0..self.rodata_len], self.rodata[0..self.rodata_len]);
        pos += self.rodata_len;

        return pos;
    }
};

fn write16(buf: []u8, val: u16) void {
    buf[0..2].* = .{ @truncate(val), @truncate(val >> 8) };
}

fn write32(buf: []u8, val: u32) void {
    buf[0..4].* = .{ @truncate(val), @truncate(val >> 8), @truncate(val >> 16), @truncate(val >> 24) };
}

fn write64(buf: []u8, val: u64) void {
    buf[0..8].* = .{ @truncate(val), @truncate(val >> 8), @truncate(val >> 16), @truncate(val >> 24), @truncate(val >> 32), @truncate(val >> 40), @truncate(val >> 48), @truncate(val >> 56) };
}

// ════════════════════════════════════════════════════════════════════════════
// COMPILER (orchestrates the pipeline)
// ════════════════════════════════════════════════════════════════════════════

pub const Compiler = struct {
    source: []const u8,
    filename: []const u8,

    fn init(source: []const u8, filename: []const u8) Compiler {
        return .{ .source = source, .filename = filename };
    }

    pub fn compile(self: *Compiler) ![]const u8 {
        // Phase 1: Lex
        var lexer = Lexer.init(self.source);
        lexer.tokenize();

        // Phase 2: Parse
        var ast = AST.init();
        var parser = Parser{ .lex = &lexer, .pos = 0, .ast = &ast, .src = self.source };
        parser.parse();

        // Phase 3: Codegen
        var cg = Codegen.init(self.source, &ast);
        cg.compile();

        // Phase 3.5: Patch all deferred references
        cg.patchStrings();

        // Phase 4: Generate ELF
        var output: [262144]u8 = undefined;
        const size = cg.generateELF(&output);

        const result = std.heap.page_allocator.alloc(u8, size) catch return error.OutOfMemory;
        @memcpy(result, output[0..size]);
        return result;
    }
};
