// ════════════════════════════════════════════════════════════════════════════
// LEXER — Tokenizer for LIR source code
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const eql = @import("util.zig").eql;

pub const TokenKind = enum(u8) {
    // Literals
    int_literal,
    float_literal,
    string_literal,
    char_literal,
    identifier,
    // Keywords
    kw_fn,
    kw_let,
    kw_mut,
    kw_const,
    kw_struct,
    kw_enum,
    kw_trait,
    kw_impl,
    kw_match,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_in,
    kw_return,
    kw_break,
    kw_continue,
    kw_defer,
    kw_pub,
    kw_mod,
    kw_use,
    kw_import,
    kw_type,
    kw_extern,
    kw_self,
    kw_true,
    kw_false,
    kw_null,
    kw_comptime,
    kw_try,
    kw_panic,
    kw_elif,
    kw_i8,
    kw_i16,
    kw_i32,
    kw_i64,
    kw_u8,
    kw_u16,
    kw_u32,
    kw_u64,
    kw_f32,
    kw_f64,
    kw_bool,
    kw_string,
    kw_void,
    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    assign,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    amp,
    pipe,
    caret,
    tilde,
    bang,
    and_and,
    pipe_pipe,
    arrow,
    fat_arrow,
    lshift,
    rshift,
    dot_dot,
    colon_colon,
    star_star,
    // Delimiters
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    semicolon,
    colon,
    comma,
    dot,
    at,
    hash,
    question,
    // Special
    newline,
    eof,
};

pub fn isTypeKeyword(kind: TokenKind) bool {
    return switch (kind) {
        .kw_i8,
        .kw_i16,
        .kw_i32,
        .kw_i64,
        .kw_u8,
        .kw_u16,
        .kw_u32,
        .kw_u64,
        .kw_f32,
        .kw_f64,
        .kw_bool,
        .kw_string,
        .kw_void,
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
    overflowed: bool,

    pub fn init(source: []const u8) Lexer {
        return .{
            .src = source,
            .pos = 0,
            .line = 1,
            .tokens = undefined,
            .token_count = 0,
            .overflowed = false,
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

    fn emit(self: *Lexer, kind: TokenKind, start: u32, start_line: u32) void {
        if (self.token_count < self.tokens.len) {
            self.tokens[self.token_count] = .{
                .kind = kind,
                .start = start,
                .len = self.pos - start,
                .line = start_line,
            };
            self.token_count += 1;
        } else {
            self.overflowed = true;
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
            const start_line = self.line;
            const ch = self.peek();

            // Numbers
            if (ch >= '0' and ch <= '9') {
                while (self.pos < self.src.len and ((self.peek() >= '0' and self.peek() <= '9') or self.peek() == '_' or
                    (self.peek() == '.' and self.pos + 1 < self.src.len and
                        self.src[self.pos + 1] >= '0' and self.src[self.pos + 1] <= '9')))
                    _ = self.advance();
                const has_dot = std.mem.indexOfScalar(u8, self.src[start..self.pos], '.') != null;
                self.emit(if (has_dot) .float_literal else .int_literal, start, start_line);
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
                self.emit(keywordOrIdent(word), start, start_line);
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
                self.emit(.string_literal, start, start_line);
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
                '.' => if (self.peek() == '.') blk: {
                    _ = self.advance();
                    break :blk .dot_dot;
                } else .dot,
                '\n' => .newline,
                else => .eof,
            };
            self.emit(kind, start, start_line);
        }
        self.emit(.eof, self.pos, self.line);
    }

    // Static comptime string map for O(1) keyword lookups instead of O(N) array iteration
    const keyword_map = std.StaticStringMap(TokenKind).initComptime(&[_]struct { []const u8, TokenKind }{
        .{ "fn", .kw_fn },             .{ "let", .kw_let },     .{ "mut", .kw_mut },       .{ "const", .kw_const },
        .{ "struct", .kw_struct },     .{ "enum", .kw_enum },   .{ "trait", .kw_trait },   .{ "impl", .kw_impl },
        .{ "match", .kw_match },       .{ "if", .kw_if },       .{ "else", .kw_else },     .{ "while", .kw_while },
        .{ "for", .kw_for },           .{ "in", .kw_in },       .{ "return", .kw_return }, .{ "break", .kw_break },
        .{ "continue", .kw_continue }, .{ "defer", .kw_defer }, .{ "pub", .kw_pub },       .{ "mod", .kw_mod },
        .{ "use", .kw_use },           .{ "import", .kw_import }, .{ "type", .kw_type },   .{ "extern", .kw_extern },
        .{ "self", .kw_self },         .{ "true", .kw_true },   .{ "false", .kw_false },   .{ "null", .kw_null },
        .{ "comptime", .kw_comptime }, .{ "try", .kw_try },     .{ "panic", .kw_panic },   .{ "elif", .kw_elif },
        .{ "and", .and_and },          .{ "or", .pipe_pipe },   .{ "i8", .kw_i8 },         .{ "i16", .kw_i16 },
        .{ "i32", .kw_i32 },           .{ "i64", .kw_i64 },     .{ "u8", .kw_u8 },         .{ "u16", .kw_u16 },
        .{ "u32", .kw_u32 },           .{ "u64", .kw_u64 },     .{ "f32", .kw_f32 },       .{ "f64", .kw_f64 },
        .{ "bool", .kw_bool },         .{ "string", .kw_string }, .{ "void", .kw_void },
    });

    fn keywordOrIdent(word: []const u8) TokenKind {
        return keyword_map.get(word) orelse .identifier;
    }

    pub fn text(self: *const Lexer, tok: Token) []const u8 {
        return self.src[tok.start..][0..tok.len];
    }

    pub fn get(self: *const Lexer, idx: u32) Token {
        if (idx >= self.token_count) return .{ .kind = .eof, .start = 0, .len = 0, .line = 0 };
        return self.tokens[idx];
    }
};
