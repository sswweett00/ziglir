// ════════════════════════════════════════════════════════════════════════════
// LEXER — Tokenizer for LIR source code with source spans and validation
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");

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
    kw_var,
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
    kw_loop,
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
    // Low-level systems-language keywords (lexed; parser/codegen support is gated separately)
    kw_unsafe,
    kw_volatile,
    kw_asm,
    kw_align,
    kw_packed,
    kw_union,
    kw_unreachable,
    kw_as,
    kw_isize,
    kw_usize,
    kw_i128,
    kw_u128,
    kw_never,
    kw_dyn,
    kw_spawn,
    kw_async,
    kw_await,
    kw_where,
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
    percent_eq,
    amp_eq,
    pipe_eq,
    caret_eq,
    lshift_eq,
    rshift_eq,
    amp,
    pipe,
    caret,
    tilde,
    bang,
    and_and,
    pipe_pipe,
    pipe_gt,
    arrow,
    fat_arrow,
    lshift,
    rshift,
    dot_dot,
    dot_dot_eq,
    colon_colon,
    star_star,
    question_question,
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
        .kw_i128,
        .kw_u128,
        .kw_isize,
        .kw_usize,
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
        .kw_never,
        => true,
        else => false,
    };
}

pub const Token = struct {
    kind: TokenKind,
    start: u32,
    len: u32,
    line: u32,
    col: u32 = 1,
};

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isAlpha(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

fn isAlnum(ch: u8) bool {
    return isAlpha(ch) or isDigit(ch);
}

fn isHexDigit(ch: u8) bool {
    return isDigit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

pub const Lexer = struct {
    src: []const u8,
    pos: u32,
    line: u32,
    line_start: u32,
    tokens: [16384]Token,
    token_count: u32,
    overflowed: bool,
    invalid: bool,
    invalid_line: u32,
    invalid_col: u32,

    pub fn init(source: []const u8) Lexer {
        return .{
            .src = source,
            .pos = 0,
            .line = 1,
            .line_start = 0,
            .tokens = undefined,
            .token_count = 0,
            .overflowed = false,
            .invalid = false,
            .invalid_line = 0,
            .invalid_col = 0,
        };
    }

    fn peek(self: *const Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn peekNext(self: *const Lexer) u8 {
        if (@as(usize, self.pos) + 1 >= self.src.len) return 0;
        return self.src[self.pos + 1];
    }

    fn currentCol(self: *const Lexer) u32 {
        return (self.pos - self.line_start) + 1;
    }

    fn markInvalid(self: *Lexer, line: u32, col: u32) void {
        if (!self.invalid) {
            self.invalid = true;
            self.invalid_line = line;
            self.invalid_col = col;
        }
    }

    fn advance(self: *Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        const ch = self.src[self.pos];
        self.pos += 1;
        if (ch == '\n') {
            self.line += 1;
            self.line_start = self.pos;
        }
        return ch;
    }

    fn emit(self: *Lexer, kind: TokenKind, start: u32, start_line: u32, start_col: u32) void {
        if (self.token_count < self.tokens.len) {
            self.tokens[self.token_count] = .{
                .kind = kind,
                .start = start,
                .len = self.pos - start,
                .line = start_line,
                .col = start_col,
            };
            self.token_count += 1;
        } else {
            self.overflowed = true;
        }
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const ch = self.peek();
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                _ = self.advance();
            } else if (ch == '\n') {
                break;
            } else if (ch == '/' and self.peekNext() == '/') {
                while (self.pos < self.src.len and self.peek() != '\n') _ = self.advance();
            } else if (ch == '/' and self.peekNext() == '*') {
                const start_line = self.line;
                const start_col = self.currentCol();
                _ = self.advance(); // '/'
                _ = self.advance(); // '*'
                var depth: u32 = 1;
                while (self.pos < self.src.len and depth > 0) {
                    if (self.peek() == '/' and self.peekNext() == '*') {
                        _ = self.advance();
                        _ = self.advance();
                        depth += 1;
                    } else if (self.peek() == '*' and self.peekNext() == '/') {
                        _ = self.advance();
                        _ = self.advance();
                        depth -= 1;
                    } else {
                        _ = self.advance();
                    }
                }
                if (depth > 0) {
                    self.markInvalid(start_line, start_col);
                }
            } else if (ch == '#' and self.peekNext() != '[' and self.peekNext() != '{') {
                while (self.pos < self.src.len and self.peek() != '\n') _ = self.advance();
            } else {
                break;
            }
        }
    }

    pub fn tokenize(self: *Lexer) void {
        while (self.pos < self.src.len) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.src.len) break;

            const start = self.pos;
            const start_line = self.line;
            const start_col = self.currentCol();
            const ch = self.peek();

            // Numbers (decimal, hex 0x, binary 0b, octal 0o, float with optional exponent)
            if (isDigit(ch)) {
                const next = self.peekNext();
                if (ch == '0' and (next == 'x' or next == 'X' or next == 'b' or next == 'B' or next == 'o' or next == 'O')) {
                    _ = self.advance();
                    _ = self.advance();
                    while (self.pos < self.src.len and isAlnum(self.peek())) {
                        _ = self.advance();
                    }
                    self.emit(.int_literal, start, start_line, start_col);
                    continue;
                }

                var has_dot = false;
                var has_exp = false;
                while (self.pos < self.src.len) {
                    const c = self.peek();
                    if (isDigit(c) or c == '_') {
                        _ = self.advance();
                    } else if (!has_dot and !has_exp and c == '.' and @as(usize, self.pos) + 1 < self.src.len and
                        isDigit(self.src[self.pos + 1]))
                    {
                        has_dot = true;
                        _ = self.advance();
                    } else if (!has_exp and (c == 'e' or c == 'E')) {
                        const p1 = @as(usize, self.pos) + 1;
                        if (p1 < self.src.len and (isDigit(self.src[p1]) or
                            ((self.src[p1] == '+' or self.src[p1] == '-') and p1 + 1 < self.src.len and isDigit(self.src[p1 + 1]))))
                        {
                            has_exp = true;
                            _ = self.advance();
                            if (self.peek() == '+' or self.peek() == '-') _ = self.advance();
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                }
                self.emit(if (has_dot or has_exp) .float_literal else .int_literal, start, start_line, start_col);
                continue;
            }

            // Identifiers / keywords
            if (isAlpha(ch)) {
                _ = self.advance();
                while (self.pos < self.src.len and isAlnum(self.peek())) {
                    _ = self.advance();
                }
                const word = self.src[start..self.pos];
                self.emit(keywordOrIdent(word), start, start_line, start_col);
                continue;
            }

            // Strings
            if (ch == '"') {
                _ = self.advance();
                var closed = false;
                while (self.pos < self.src.len) {
                    const c = self.peek();
                    if (c == '"') {
                        _ = self.advance();
                        closed = true;
                        break;
                    }
                    if (c == '\\') {
                        const esc_line = self.line;
                        const esc_col = self.currentCol();
                        _ = self.advance();
                        if (self.pos >= self.src.len) {
                            self.markInvalid(start_line, start_col);
                            break;
                        }
                        const esc = self.advance();
                        switch (esc) {
                            'n', 'r', 't', '\\', '"', '\'', '0', '{', '}' => {},
                            'x' => {
                                if (@as(usize, self.pos) + 2 > self.src.len or
                                    !isHexDigit(self.src[self.pos]) or !isHexDigit(self.src[self.pos + 1]))
                                {
                                    self.markInvalid(esc_line, esc_col);
                                } else {
                                    _ = self.advance();
                                    _ = self.advance();
                                }
                            },
                            else => self.markInvalid(esc_line, esc_col),
                        }
                    } else {
                        _ = self.advance();
                    }
                }
                if (!closed) {
                    self.markInvalid(start_line, start_col);
                }
                self.emit(.string_literal, start, start_line, start_col);
                continue;
            }

            // Character literals ('a', '\n', '\x41')
            if (ch == '\'') {
                _ = self.advance();
                if (self.pos >= self.src.len or self.peek() == '\n' or self.peek() == '\'') {
                    self.markInvalid(start_line, start_col);
                    if (self.peek() == '\'') _ = self.advance();
                    self.emit(.char_literal, start, start_line, start_col);
                    continue;
                }
                if (self.peek() == '\\') {
                    _ = self.advance();
                    if (self.pos >= self.src.len) {
                        self.markInvalid(start_line, start_col);
                        self.emit(.char_literal, start, start_line, start_col);
                        continue;
                    }
                    const esc = self.advance();
                    switch (esc) {
                        'n', 'r', 't', '\\', '"', '\'', '0' => {},
                        'x' => {
                            if (@as(usize, self.pos) + 2 > self.src.len or
                                !isHexDigit(self.src[self.pos]) or !isHexDigit(self.src[self.pos + 1]))
                            {
                                self.markInvalid(start_line, start_col);
                            } else {
                                _ = self.advance();
                                _ = self.advance();
                            }
                        },
                        else => self.markInvalid(start_line, start_col),
                    }
                } else {
                    _ = self.advance();
                }
                if (self.pos < self.src.len and self.peek() == '\'') {
                    _ = self.advance();
                } else {
                    self.markInvalid(start_line, start_col);
                    while (self.pos < self.src.len and self.peek() != '\'' and self.peek() != '\n') _ = self.advance();
                    if (self.peek() == '\'') _ = self.advance();
                }
                self.emit(.char_literal, start, start_line, start_col);
                continue;
            }

            // Operators / delimiters
            _ = self.advance();
            var is_unknown = false;
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
                '%' => if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .percent_eq;
                } else .percent,
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
                '<' => if (self.peek() == '<') blk: {
                    _ = self.advance();
                    if (self.peek() == '=') {
                        _ = self.advance();
                        break :blk .lshift_eq;
                    }
                    break :blk .lshift;
                } else if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .le;
                } else .lt,
                '>' => if (self.peek() == '>') blk: {
                    _ = self.advance();
                    if (self.peek() == '=') {
                        _ = self.advance();
                        break :blk .rshift_eq;
                    }
                    break :blk .rshift;
                } else if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .ge;
                } else .gt,
                '&' => if (self.peek() == '&') blk: {
                    _ = self.advance();
                    break :blk .and_and;
                } else if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .amp_eq;
                } else .amp,
                '|' => if (self.peek() == '|') blk: {
                    _ = self.advance();
                    break :blk .pipe_pipe;
                } else if (self.peek() == '>') blk: {
                    _ = self.advance();
                    break :blk .pipe_gt;
                } else if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .pipe_eq;
                } else .pipe,
                '^' => if (self.peek() == '=') blk: {
                    _ = self.advance();
                    break :blk .caret_eq;
                } else .caret,
                '~' => .tilde,
                '?' => if (self.peek() == '?') blk: {
                    _ = self.advance();
                    break :blk .question_question;
                } else .question,
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
                    if (self.peek() == '=') {
                        _ = self.advance();
                        break :blk .dot_dot_eq;
                    }
                    break :blk .dot_dot;
                } else .dot,
                '\n' => .newline,
                else => blk: {
                    is_unknown = true;
                    self.markInvalid(start_line, start_col);
                    break :blk .eof;
                },
            };
            if (!is_unknown) {
                self.emit(kind, start, start_line, start_col);
            }
        }
        self.emit(.eof, self.pos, self.line, self.currentCol());
    }

    // Static comptime string map for O(1) keyword lookups
    const keyword_map = std.StaticStringMap(TokenKind).initComptime(&[_]struct { []const u8, TokenKind }{
        .{ "fn", .kw_fn },                   .{ "let", .kw_let },       .{ "var", .kw_var },       .{ "mut", .kw_mut },           .{ "const", .kw_const },
        .{ "struct", .kw_struct },           .{ "enum", .kw_enum },     .{ "trait", .kw_trait },   .{ "impl", .kw_impl },         .{ "loop", .kw_loop },
        .{ "match", .kw_match },             .{ "if", .kw_if },         .{ "else", .kw_else },     .{ "while", .kw_while },       .{ "for", .kw_for },
        .{ "in", .kw_in },                   .{ "return", .kw_return }, .{ "break", .kw_break },   .{ "continue", .kw_continue }, .{ "defer", .kw_defer },
        .{ "pub", .kw_pub },                 .{ "mod", .kw_mod },       .{ "use", .kw_use },       .{ "import", .kw_import },     .{ "type", .kw_type },
        .{ "extern", .kw_extern },           .{ "self", .kw_self },     .{ "true", .kw_true },     .{ "false", .kw_false },       .{ "null", .kw_null },
        .{ "comptime", .kw_comptime },       .{ "try", .kw_try },       .{ "panic", .kw_panic },   .{ "elif", .kw_elif },         .{ "and", .and_and },
        .{ "or", .pipe_pipe },               .{ "i8", .kw_i8 },         .{ "i16", .kw_i16 },       .{ "i32", .kw_i32 },           .{ "i64", .kw_i64 },
        .{ "u8", .kw_u8 },                   .{ "u16", .kw_u16 },       .{ "u32", .kw_u32 },       .{ "u64", .kw_u64 },           .{ "f32", .kw_f32 },
        .{ "f64", .kw_f64 },                 .{ "bool", .kw_bool },     .{ "string", .kw_string }, .{ "void", .kw_void },         .{ "unsafe", .kw_unsafe },
        .{ "volatile", .kw_volatile },       .{ "asm", .kw_asm },       .{ "align", .kw_align },   .{ "packed", .kw_packed },     .{ "union", .kw_union },
        .{ "unreachable", .kw_unreachable }, .{ "as", .kw_as },         .{ "isize", .kw_isize },   .{ "usize", .kw_usize },       .{ "i128", .kw_i128 },
        .{ "u128", .kw_u128 },               .{ "never", .kw_never },   .{ "dyn", .kw_dyn },       .{ "spawn", .kw_spawn },       .{ "async", .kw_async },
        .{ "await", .kw_await },             .{ "where", .kw_where },
    });

    fn keywordOrIdent(word: []const u8) TokenKind {
        return keyword_map.get(word) orelse .identifier;
    }

    pub fn text(self: *const Lexer, tok: Token) []const u8 {
        if (@as(usize, tok.start) > self.src.len or @as(usize, tok.len) > self.src.len - @as(usize, tok.start)) return "";
        return self.src[tok.start..][0..tok.len];
    }

    pub fn get(self: *const Lexer, idx: u32) Token {
        if (idx >= self.token_count) return .{ .kind = .eof, .start = 0, .len = 0, .line = 0, .col = 1 };
        return self.tokens[idx];
    }
};
