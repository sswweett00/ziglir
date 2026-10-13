// ════════════════════════════════════════════════════════════════════════════
// PARSER — AST node types, AST data structure, and recursive-descent parser
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const lex = @import("lexer.zig");
const TokenKind = lex.TokenKind;
const Token = lex.Token;
const Lexer = lex.Lexer;

const eql = util.eql;
const printErr = util.printErr;
const printUsize = util.printUsize;

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
    // Struct support
    struct_decl,
    struct_init,
    field_access,
    // Pointer support
    addr_of,
    deref,
    // Module import
    module_import,
    // Iteration & advanced expressions
    for_stmt,
    index_expr,
    ternary_expr,
};

pub const ASTNode = struct {
    kind: NodeKind,
    line: u32,
    source_id: u32 = 0, // which source file this node came from
    child0: u32 = 0,
    child1: u32 = 0,
    child2: u32 = 0,
    op: u8 = 0,
    int_val: i64 = 0,
    text_start: u32 = 0,
    text_len: u32 = 0,
};

pub const StructField = struct {
    name_start: u32,
    name_len: u32,
    offset: u32,
};

pub const StructDef = struct {
    name_start: u32,
    name_len: u32,
    fields: [32]StructField,
    field_count: u32,
    total_size: u32,
};

pub const AST = struct {
    nodes: [4096]ASTNode,
    count: u32,
    overflowed: bool,
    stmt_chains: [4096]u32,
    struct_defs: [128]StructDef,
    struct_count: u32,
    sources: [32][]const u8,
    source_count: u32,

    pub fn init() AST {
        var ast = AST{ .nodes = undefined, .count = 1, .overflowed = false, .stmt_chains = .{@as(u32, 0)} ** 4096, .struct_defs = undefined, .struct_count = 0, .sources = undefined, .source_count = 0 };
        ast.nodes[0] = .{ .kind = .identifier, .line = 0 };
        return ast;
    }

    pub fn addNode(self: *AST, kind: NodeKind, line: u32) u32 {
        if (@as(usize, self.count) >= self.nodes.len) {
            // Keep the parser in-bounds and let the compiler report a normal
            // diagnostic after parsing; never terminate the embedding process.
            self.overflowed = true;
            return 0;
        }
        const idx = self.count;
        self.nodes[idx] = .{ .kind = kind, .line = line };
        self.count += 1;
        return idx;
    }

    pub fn nodeText(self: *const AST, idx: u32) []const u8 {
        const n = self.nodes[idx];
        if (self.source_count > 0 and n.text_start + n.text_len <= self.sources[0].len) {
            return self.sources[0][n.text_start..][0..n.text_len];
        }
        return "";
    }

    pub fn nodeTextSrcFrom(self: *const AST, start: u32, length: u32, source_id: u32) []const u8 {
        if (source_id < self.source_count) {
            const s = self.sources[source_id];
            if (start + length <= s.len) {
                return s[start..][0..length];
            }
        }
        return "";
    }

    pub fn findStructByName(self: *const AST, src: []const u8, name_start: u32, name_len: u32) ?u32 {
        for (0..self.struct_count) |i| {
            const s = self.struct_defs[i];
            if (s.name_len == name_len and std.mem.eql(u8, src[s.name_start..][0..s.name_len], src[name_start..][0..name_len])) return @intCast(i);
        }
        return null;
    }

    pub fn copySubtree(self: *AST, other: *const AST, root: u32, source_id: u32) u32 {
        if (root == 0 or root >= other.count) return 0;
        var remap: [4096]u32 = .{@as(u32, 0)} ** 4096;
        var queue: [4096]u32 = undefined;
        var qhead: u32 = 0;
        var qtail: u32 = 0;

        const new_root = self.addNode(other.nodes[root].kind, other.nodes[root].line);
        self.nodes[new_root] = other.nodes[root];
        self.nodes[new_root].source_id = source_id;
        remap[root] = new_root;
        queue[qtail] = root;
        qtail += 1;

        while (qhead < qtail) {
            const old_idx = queue[qhead];
            qhead += 1;
            const new_idx = remap[old_idx];
            const old_node = other.nodes[old_idx];

            if (old_node.child0 != 0) {
                if (remap[old_node.child0] == 0) {
                    const new_child = self.addNode(other.nodes[old_node.child0].kind, other.nodes[old_node.child0].line);
                    self.nodes[new_child] = other.nodes[old_node.child0];
                    self.nodes[new_child].source_id = source_id;
                    remap[old_node.child0] = new_child;
                    queue[qtail] = old_node.child0;
                    qtail += 1;
                }
                self.nodes[new_idx].child0 = remap[old_node.child0];
            }
            if (old_node.child1 != 0) {
                if (remap[old_node.child1] == 0) {
                    const new_child = self.addNode(other.nodes[old_node.child1].kind, other.nodes[old_node.child1].line);
                    self.nodes[new_child] = other.nodes[old_node.child1];
                    self.nodes[new_child].source_id = source_id;
                    remap[old_node.child1] = new_child;
                    queue[qtail] = old_node.child1;
                    qtail += 1;
                }
                self.nodes[new_idx].child1 = remap[old_node.child1];
            }
            if (old_node.child2 != 0) {
                if (remap[old_node.child2] == 0) {
                    const new_child = self.addNode(other.nodes[old_node.child2].kind, other.nodes[old_node.child2].line);
                    self.nodes[new_child] = other.nodes[old_node.child2];
                    self.nodes[new_child].source_id = source_id;
                    remap[old_node.child2] = new_child;
                    queue[qtail] = old_node.child2;
                    qtail += 1;
                }
                self.nodes[new_idx].child2 = remap[old_node.child2];
            }

            if (other.stmt_chains[old_idx] != 0) {
                if (remap[other.stmt_chains[old_idx]] == 0) {
                    const old_next = other.stmt_chains[old_idx];
                    const new_child = self.addNode(other.nodes[old_next].kind, other.nodes[old_next].line);
                    self.nodes[new_child] = other.nodes[old_next];
                    self.nodes[new_child].source_id = source_id;
                    remap[old_next] = new_child;
                    queue[qtail] = old_next;
                    qtail += 1;
                }
                self.stmt_chains[new_idx] = remap[other.stmt_chains[old_idx]];
            }
        }
        return new_root;
    }
};

pub const Parser = struct {
    lex: *const Lexer,
    pos: u32,
    ast: *AST,
    src: []const u8,
    source_id: u32 = 0,
    invalid_integer_literal: bool = false,
    invalid_integer_line: u32 = 0,
    invalid_syntax: bool = false,
    unsupported_float_literal: bool = false,

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
            self.invalid_syntax = true;

            // Make forward progress on malformed input so parsing can finish
            // and return a normal compiler error instead of exiting the host.
            if (t.kind != .eof) _ = self.advance();
            return .{ .kind = kind, .start = t.start, .len = 0, .line = t.line };
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
                _ = self.advance();
                if (self.match(.string_literal)) {
                    const path_tok = self.advance();
                    const node = self.ast.addNode(.module_import, path_tok.line);
                    self.ast.nodes[node].text_start = path_tok.start + 1;
                    self.ast.nodes[node].text_len = path_tok.len - 2;
                } else {
                    while (!self.match(.newline) and !self.match(.eof)) _ = self.advance();
                }
            } else if (self.match(.kw_struct)) {
                _ = self.parseStructDecl();
            } else if (self.match(.kw_enum) or self.match(.kw_trait) or
                self.match(.kw_impl) or self.match(.kw_mod) or self.match(.kw_extern))
            {
                // Never silently discard a declaration. These constructs are
                // recognized by the lexer but are not yet fully implemented.
                printErr("Unsupported declaration at line ");
                printUsize(self.peek().line);
                printErr(": ");
                printErr(@tagName(self.peek().kind));
                printErr(" is not implemented by this compiler\\n");
                self.invalid_syntax = true;
                while (!self.match(.newline) and !self.match(.eof)) _ = self.advance();
            } else if (self.match(.kw_const) or self.match(.kw_type)) {
                printErr("Unsupported declaration at line ");
                printUsize(self.peek().line);
                printErr(": ");
                printErr(@tagName(self.peek().kind));
                printErr(" is not implemented by this compiler\\n");
                self.invalid_syntax = true;
                while (!self.match(.newline) and !self.match(.semicolon) and !self.match(.eof)) _ = self.advance();
            } else if (self.match(.kw_pub)) {
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
        var first_param: u32 = 0;
        var last_param: u32 = 0;
        var param_count: u32 = 0;
        while (!self.match(.rparen) and !self.match(.eof)) {
            if (param_count > 0) _ = self.expect(.comma);
            if (self.match(.rparen)) break;
            const ptok = self.expect(.identifier);
            if (self.match(.colon)) {
                _ = self.advance();
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
                if (self.match(.kw_mut)) _ = self.advance();
                const name_tok = self.expect(.identifier);
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
            } else if (self.match(.star) and self.pos + 1 < self.lex.token_count) {
                const star_tok = self.peek();
                const deref_expr = self.parseUnary();
                const pk = self.peek().kind;
                const is_assign = pk == .assign or pk == .plus_eq or pk == .minus_eq or
                    pk == .star_eq or pk == .slash_eq;
                if (is_assign) {
                    const op_tok = self.advance();
                    const value = self.parseExpr();
                    stmt = self.ast.addNode(.assign_stmt, star_tok.line);
                    self.ast.nodes[stmt].child0 = deref_expr;
                    self.ast.nodes[stmt].child1 = value;
                    self.ast.nodes[stmt].op = @intFromEnum(op_tok.kind);
                } else {
                    stmt = deref_expr;
                }
            } else if (self.match(.identifier) and self.pos + 1 < self.lex.token_count) {
                const next_kind = self.lex.get(self.pos + 1).kind;
                if (next_kind == .dot or next_kind == .lbracket) {
                    const base_expr = self.parsePrimary();
                    const postfix_expr = self.parsePostfix(base_expr);
                    const pk = self.peek().kind;
                    const is_assign = pk == .assign or pk == .plus_eq or pk == .minus_eq or
                        pk == .star_eq or pk == .slash_eq;
                    if (is_assign and (self.ast.nodes[postfix_expr].kind == .field_access or
                        self.ast.nodes[postfix_expr].kind == .deref or
                        self.ast.nodes[postfix_expr].kind == .index_expr))
                    {
                        const op_tok = self.advance();
                        const value = self.parseExpr();
                        stmt = self.ast.addNode(.assign_stmt, self.ast.nodes[postfix_expr].line);
                        self.ast.nodes[stmt].child0 = postfix_expr;
                        self.ast.nodes[stmt].child1 = value;
                        self.ast.nodes[stmt].op = @intFromEnum(op_tok.kind);
                    } else if (pk == .assign or pk == .plus_eq or pk == .minus_eq or
                        pk == .star_eq or pk == .slash_eq)
                    {
                        const name_tok = self.ast.nodes[base_expr];
                        const op_tok = self.advance();
                        const value = self.parseExpr();
                        stmt = self.ast.addNode(.assign_stmt, self.ast.nodes[base_expr].line);
                        self.ast.nodes[stmt].text_start = name_tok.text_start;
                        self.ast.nodes[stmt].text_len = name_tok.text_len;
                        self.ast.nodes[stmt].child0 = value;
                        self.ast.nodes[stmt].op = @intFromEnum(op_tok.kind);
                    } else {
                        stmt = postfix_expr;
                    }
                } else {
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
                }
            } else if (self.match(.kw_for)) {
                stmt = self.parseFor();
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
        const cond = self.parseOr();
        if (self.match(.question)) {
            _ = self.advance();
            const then_expr = self.parseExpr();
            _ = self.expect(.colon);
            const else_expr = self.parseExpr();
            const n = self.ast.addNode(.ternary_expr, self.peek().line);
            self.ast.nodes[n].child0 = cond;
            self.ast.nodes[n].child1 = then_expr;
            self.ast.nodes[n].child2 = else_expr;
            return n;
        }
        return cond;
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
        if (self.match(.amp)) {
            const op = self.advance();
            const operand = self.parseUnary();
            const n = self.ast.addNode(.addr_of, op.line);
            self.ast.nodes[n].child0 = operand;
            return n;
        }
        if (self.match(.star) and self.pos + 1 < self.lex.token_count) {
            const next_kind = self.lex.get(self.pos + 1).kind;
            if (next_kind == .identifier or next_kind == .star or next_kind == .lparen) {
                const op = self.advance();
                const operand = self.parseUnary();
                const n = self.ast.addNode(.deref, op.line);
                self.ast.nodes[n].child0 = operand;
                return n;
            }
        }
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
            var cleaned: [64]u8 = undefined;
            var clen: usize = 0;
            var malformed = txt.len == 0;
            for (txt, 0..) |c, i| {
                if (c == '_') {
                    // Separators are legal only between digits, never at an
                    // edge or adjacent to another separator.
                    if (i == 0 or i + 1 == txt.len or txt[i - 1] == '_' or txt[i + 1] == '_') malformed = true;
                    continue;
                }
                if (clen >= cleaned.len) {
                    malformed = true;
                    break;
                }
                cleaned[clen] = c;
                clen += 1;
            }
            if (clen == 0) malformed = true;
            if (!malformed) {
                self.ast.nodes[n].int_val = std.fmt.parseInt(i64, cleaned[0..clen], 10) catch blk: {
                    self.invalid_integer_literal = true;
                    self.invalid_integer_line = tok.line;
                    break :blk 0;
                };
            } else {
                self.invalid_integer_literal = true;
                self.invalid_integer_line = tok.line;
            }
            return n;
        }

        if (self.match(.float_literal)) {
            printErr("Compile error at line ");
            printUsize(tok.line);
            printErr(": float literals are not yet supported in codegen\n");
            self.unsupported_float_literal = true;
            _ = self.advance();
            return self.ast.addNode(.int_literal, tok.line);
        }

        if (self.match(.string_literal)) {
            _ = self.advance();
            const n = self.ast.addNode(.string_literal, tok.line);
            self.ast.nodes[n].text_start = tok.start + 1;
            self.ast.nodes[n].text_len = tok.len - 2;
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

        if (self.match(.at)) {
            const at_tok = self.advance();
            const name_tok = self.expect(.identifier);
            const full_name_start = at_tok.start;
            const full_name_len = name_tok.start + name_tok.len - at_tok.start;
            const n = self.ast.addNode(.identifier, at_tok.line);
            self.ast.nodes[n].text_start = full_name_start;
            self.ast.nodes[n].text_len = full_name_len;
            if (self.match(.lparen)) {
                _ = self.advance();
                var first_arg: u32 = 0;
                var last_arg: u32 = 0;
                while (!self.match(.rparen) and !self.match(.eof)) {
                    if (first_arg != 0) _ = self.expect(.comma);
                    const arg = self.parseExpr();
                    const wrap = self.ast.addNode(.expr_stmt, at_tok.line);
                    self.ast.nodes[wrap].child0 = arg;
                    if (first_arg == 0) {
                        first_arg = wrap;
                    } else {
                        self.ast.nodes[last_arg].child1 = wrap;
                    }
                    last_arg = wrap;
                }
                _ = self.expect(.rparen);
                const cn = self.ast.addNode(.call_expr, at_tok.line);
                self.ast.nodes[cn].child0 = n;
                self.ast.nodes[cn].child2 = first_arg;
                return cn;
            }
            return n;
        }

        if (self.match(.identifier)) {
            _ = self.advance();
            var result = self.ast.addNode(.identifier, tok.line);
            self.ast.nodes[result].text_start = tok.start;
            self.ast.nodes[result].text_len = tok.len;
            if (self.match(.lparen)) {
                _ = self.advance();
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
                self.ast.nodes[cn].child0 = result;
                self.ast.nodes[cn].child2 = first_arg;
                result = cn;
            }
            return self.parsePostfix(result);
        }

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

    fn parseElseTail(self: *Parser, line: u32) u32 {
        const is_elif = self.match(.kw_elif);
        _ = self.advance();
        self.skipNewlines();
        if (!is_elif and self.match(.kw_if)) return self.parseIf();
        if (is_elif) {
            _ = self.peek();
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

    fn parseStructDecl(self: *Parser) u32 {
        const tok = self.expect(.kw_struct);
        const name_tok = self.expect(.identifier);
        self.skipNewlines();
        _ = self.expect(.lbrace);
        self.skipNewlines();

        if (@as(usize, self.ast.struct_count) >= self.ast.struct_defs.len) {
            self.ast.overflowed = true;
            // The opening brace has already been consumed. Skip this whole
            // declaration with balanced-brace tracking, without indexing the
            // exhausted struct table or exiting the host process.
            var depth: u32 = 1;
            while (depth > 0 and !self.match(.eof)) {
                const skipped = self.advance().kind;
                if (skipped == .lbrace) depth += 1 else if (skipped == .rbrace) depth -= 1;
            }
            return 0;
        }
        const si: u32 = self.ast.struct_count;
        self.ast.struct_count += 1;
        self.ast.struct_defs[si] = .{
            .name_start = name_tok.start,
            .name_len = name_tok.len,
            .fields = undefined,
            .field_count = 0,
            .total_size = 0,
        };
        var field_offset: u32 = 0;

        while (!self.match(.rbrace) and !self.match(.eof)) {
            self.skipNewlines();
            if (self.match(.rbrace)) break;
            const field_name = self.expect(.identifier);
            _ = self.expect(.colon);
            while (!self.match(.newline) and !self.match(.rbrace) and !self.match(.eof)) _ = self.advance();
            self.skipNewlines();

            const sd = &self.ast.struct_defs[si];
            if (@as(usize, sd.field_count) >= sd.fields.len) {
                self.ast.overflowed = true;
            } else {
                sd.fields[sd.field_count] = .{
                    .name_start = field_name.start,
                    .name_len = field_name.len,
                    .offset = field_offset,
                };
                sd.field_count += 1;
            }
            field_offset += 8;
        }
        self.ast.struct_defs[si].total_size = field_offset;
        _ = self.expect(.rbrace);

        const node = self.ast.addNode(.struct_decl, tok.line);
        self.ast.nodes[node].text_start = name_tok.start;
        self.ast.nodes[node].text_len = name_tok.len;
        self.ast.nodes[node].int_val = @intCast(si);
        return node;
    }

    fn parsePostfix(self: *Parser, base: u32) u32 {
        var result = base;
        while (self.match(.dot) or self.match(.lbracket)) {
            if (self.match(.lbracket)) {
                _ = self.advance();
                const idx_expr = self.parseExpr();
                _ = self.expect(.rbracket);
                const n = self.ast.addNode(.index_expr, self.peek().line);
                self.ast.nodes[n].child0 = result;
                self.ast.nodes[n].child1 = idx_expr;
                result = n;
            } else {
                _ = self.advance();
                const field_name = self.expect(.identifier);
                const n = self.ast.addNode(.field_access, field_name.line);
                self.ast.nodes[n].child0 = result;
                self.ast.nodes[n].text_start = field_name.start;
                self.ast.nodes[n].text_len = field_name.len;
                result = n;
            }
        }
        return result;
    }

    fn parseFor(self: *Parser) u32 {
        _ = self.advance();
        const var_tok = self.expect(.identifier);
        _ = self.expect(.kw_in);
        const first = self.parseExpr();
        var is_range: i64 = 0;
        var second: u32 = 0;
        if (self.match(.dot_dot)) {
            _ = self.advance();
            second = self.parseExpr();
            is_range = 1;
        }
        const body = self.parseBlock();
        const n = self.ast.addNode(.for_stmt, var_tok.line);
        self.ast.nodes[n].text_start = var_tok.start;
        self.ast.nodes[n].text_len = var_tok.len;
        self.ast.nodes[n].child0 = first;
        self.ast.nodes[n].child1 = body;
        self.ast.nodes[n].child2 = second;
        self.ast.nodes[n].int_val = is_range;
        return n;
    }
};
