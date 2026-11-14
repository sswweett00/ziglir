// ════════════════════════════════════════════════════════════════════════════
// PARSER — AST node types, AST data structure, and recursive-descent parser
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const lex = @import("lexer.zig");
const diag_mod = @import("diag.zig");

const TokenKind = lex.TokenKind;
const Token = lex.Token;
const Lexer = lex.Lexer;
const DiagList = diag_mod.DiagList;

const printErr = util.printErr;
const printErrUsize = util.printErrUsize;

pub const MAX_AST_NODES: usize = 16384;
pub const MAX_STRUCTS: usize = 256;
pub const MAX_ENUMS: usize = 128;
pub const MAX_CONSTS: usize = 256;
pub const MAX_ALIASES: usize = 256;
pub const MAX_SOURCES: usize = 64;
pub const SYNTH_SOURCE_ID: u32 = MAX_SOURCES - 1;
pub const MAX_TYPE_DESCS: usize = 1024;
pub const MAX_TRAITS: usize = 64;
pub const MAX_TRAIT_IMPLS: usize = 128;
pub const MAX_GENERICS: usize = 128;

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
    unreachable_stmt,
    call_expr,
    binary_expr,
    unary_expr,
    identifier,
    int_literal,
    float_literal,
    string_literal,
    // Struct / Union support
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
    // Full-language additions
    const_decl,
    enum_decl,
    type_alias,
    defer_stmt,
    match_expr,
    match_arm,
    cast_expr,
    array_lit,
    method_call,
    scoped_access,
    // Multi-paradigm universal additions
    tuple_lit,
    tuple_pattern,
    closure_expr,
    trait_decl,
    union_decl,
    try_expr,
    coalesce_expr,
    comptime_expr,
    list_comp,
    map_lit,
    spawn_expr,
    interp_string,
    generic_call,
};

pub const TypeTag = enum(u8) {
    none = 0,
    i64 = 1,
    bool = 2,
    string = 3,
    void = 4,
    ptr = 5,
    struct_type = 6,
    i8 = 7,
    i16 = 8,
    i32 = 9,
    isize = 10,
    u8 = 11,
    u16 = 12,
    u32 = 13,
    u64 = 14,
    usize = 15,
    enum_type = 16,
    fixed_array = 17,
    never = 18,
    f32 = 19,
    f64 = 20,
    fn_ptr = 21,
    tuple = 22,
    option = 23,
    result = 24,
    dyn_trait = 25,
    map = 26,
    chan = 27,
    generic_param = 28,
    generic_inst = 29,
    slice = 30,

    pub fn isUnsigned(self: TypeTag) bool {
        return switch (self) {
            .u8, .u16, .u32, .u64, .usize => true,
            else => false,
        };
    }

    pub fn isInteger(self: TypeTag) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .isize, .u8, .u16, .u32, .u64, .usize => true,
            else => false,
        };
    }

    pub fn isFloat(self: TypeTag) bool {
        return self == .f32 or self == .f64;
    }

    pub fn bitWidth(self: TypeTag) u8 {
        return switch (self) {
            .i8, .u8, .bool => 8,
            .i16, .u16 => 16,
            .i32, .u32, .f32 => 32,
            else => 64,
        };
    }
};

pub const TextSpan = struct {
    start: u32 = 0,
    len: u32 = 0,
    source_id: u32 = 0,
};

pub const TypeDesc = struct {
    kind: TypeTag = .none,
    param_count: u8 = 0,
    param_tags: [8]TypeTag = .{.none} ** 8,
    param_extras: [8]u32 = .{0} ** 8,
    param_elems: [8]TypeTag = .{.none} ** 8,
    ret_tag: TypeTag = .void,
    ret_extra: u32 = 0,
    ret_elem: TypeTag = .none,
    base_name: TextSpan = .{},
    const_expr_node: u32 = 0, // for [CONST_EXPR]T or Option/Result inner
};

pub const TraitMethod = struct {
    name: TextSpan = .{},
    param_count: u8 = 0,
    param_tags: [8]TypeTag = .{.none} ** 8,
    param_extras: [8]u32 = .{0} ** 8,
    param_elems: [8]TypeTag = .{.none} ** 8,
    ret_tag: TypeTag = .void,
    ret_extra: u32 = 0,
    ret_elem: TypeTag = .none,
};

pub const TraitDef = struct {
    name: TextSpan = .{},
    line: u32 = 1,
    methods: [16]TraitMethod = undefined,
    method_count: u32 = 0,
};

pub const TraitImpl = struct {
    trait_idx: u32 = 0,
    struct_idx: u32 = 0,
    method_fn_nodes: [16]u32 = .{0} ** 16,
};

pub const GenericTemplate = struct {
    kind: enum(u8) { fn_t, struct_t, enum_t, impl_t },
    node_or_def_idx: u32 = 0,
    name: TextSpan = .{},
    params: [4]TextSpan = undefined,
    param_count: u8 = 0,
};

pub const ASTNode = struct {
    kind: NodeKind,
    line: u32,
    col: u32 = 1,
    source_id: u32 = 0,
    child0: u32 = 0,
    child1: u32 = 0,
    child2: u32 = 0,
    extra: u32 = 0,
    op: u8 = 0,
    // flags bits:
    // bit 0 (1): mut / bool_lit / inclusive_range / tuple_field_idx
    // bit 1 (2): is_method
    // bit 2 (4): #[test]
    // bit 3 (8): #[inline]
    // bit 4 (16): comptime_fn / #[cold]
    // bit 5 (32): has_range_pat / pre_unescaped
    flags: u8 = 0,
    type_tag: TypeTag = .none,
    elem_type: TypeTag = .none,
    int_val: i64 = 0,
    text_start: u32 = 0,
    text_len: u32 = 0,
};

pub const StructField = struct {
    name_start: u32,
    name_len: u32,
    offset: u32,
    type_tag: TypeTag = .i64,
    extra: u32 = 0, // struct_idx+1 or enum_idx+1 or fixed_array_len or type_desc_idx
    elem_type: TypeTag = .none,
};

pub const StructDef = struct {
    name_start: u32,
    name_len: u32,
    line: u32 = 1,
    source_id: u32 = 0,
    fields: [32]StructField,
    field_count: u32,
    total_size: u32,
    is_union: bool = false,
    is_generic: bool = false,
    generic_params: [4]TextSpan = .{TextSpan{}} ** 4,
    generic_param_count: u8 = 0,
};

pub const EnumVariant = struct {
    name_start: u32,
    name_len: u32,
    value: i64,
    payload_count: u8 = 0,
    payload_tags: [8]TypeTag = .{.none} ** 8,
    payload_extras: [8]u32 = .{0} ** 8,
    payload_elems: [8]TypeTag = .{.none} ** 8,
};

pub const EnumDef = struct {
    name_start: u32,
    name_len: u32,
    line: u32 = 1,
    source_id: u32 = 0,
    variants: [64]EnumVariant,
    variant_count: u32,
    has_payloads: bool = false,
    is_generic: bool = false,
    generic_params: [4]TextSpan = .{TextSpan{}} ** 4,
    generic_param_count: u8 = 0,
};

pub const TypeAliasDef = struct {
    name_start: u32,
    name_len: u32,
    source_id: u32 = 0,
    target_tag: TypeTag,
    target_extra: u32 = 0,
    target_elem: TypeTag = .none,
};

pub const AST = struct {
    nodes: [MAX_AST_NODES]ASTNode,
    count: u32,
    overflowed: bool,
    stmt_chains: [MAX_AST_NODES]u32,
    struct_defs: [MAX_STRUCTS]StructDef,
    struct_count: u32,
    enum_defs: [MAX_ENUMS]EnumDef,
    enum_count: u32,
    alias_defs: [MAX_ALIASES]TypeAliasDef,
    alias_count: u32,
    type_descs: [MAX_TYPE_DESCS]TypeDesc,
    type_desc_count: u32,
    trait_defs: [MAX_TRAITS]TraitDef,
    trait_count: u32,
    trait_impls: [MAX_TRAIT_IMPLS]TraitImpl,
    trait_impl_count: u32,
    generics: [MAX_GENERICS]GenericTemplate,
    generic_count: u32,
    synth_buf: [65536]u8,
    synth_len: u32,
    sources: [MAX_SOURCES][]const u8,
    source_count: u32,

    pub fn initInPlace(self: *AST) void {
        self.count = 1;
        self.overflowed = false;
        @memset(&self.stmt_chains, 0);
        self.struct_count = 0;
        self.enum_count = 0;
        self.alias_count = 0;
        self.type_desc_count = 1;
        self.type_descs[0] = .{};
        self.trait_count = 0;
        self.trait_impl_count = 0;
        self.generic_count = 0;
        self.synth_len = 0;
        self.source_count = 0;
        self.sources[SYNTH_SOURCE_ID] = self.synth_buf[0..0];
        self.nodes[0] = .{ .kind = .identifier, .line = 0 };
    }

    pub fn init() AST {
        var ast: AST = undefined;
        ast.initInPlace();
        return ast;
    }

    pub fn addSynthText(self: *AST, s: []const u8) TextSpan {
        const len: u32 = @intCast(@min(s.len, self.synth_buf.len - @as(usize, self.synth_len)));
        const start = self.synth_len;
        if (len > 0) {
            @memcpy(self.synth_buf[start..][0..len], s[0..len]);
            self.synth_len += len;
        }
        self.sources[SYNTH_SOURCE_ID] = self.synth_buf[0..self.synth_len];
        return .{ .start = start, .len = len, .source_id = SYNTH_SOURCE_ID };
    }

    pub fn addTypeDesc(self: *AST, desc: TypeDesc) u32 {
        if (@as(usize, self.type_desc_count) >= self.type_descs.len) {
            self.overflowed = true;
            return 0;
        }
        const idx = self.type_desc_count;
        self.type_descs[idx] = desc;
        self.type_desc_count += 1;
        return idx;
    }

    pub fn findTraitBySlice(self: *const AST, fallback_src: []const u8, sought: []const u8) ?u32 {
        const count = @min(@as(usize, self.trait_count), self.trait_defs.len);
        for (0..count) |i| {
            const td = self.trait_defs[i];
            const src = if (td.name.source_id == SYNTH_SOURCE_ID) self.sources[SYNTH_SOURCE_ID] else if (td.name.source_id < self.source_count) self.sources[td.name.source_id] else fallback_src;
            if (!validSourceRange(src, td.name.start, td.name.len)) continue;
            if (std.mem.eql(u8, src[@as(usize, td.name.start)..][0..@as(usize, td.name.len)], sought)) {
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn addNode(self: *AST, kind: NodeKind, line: u32) u32 {
        if (@as(usize, self.count) >= self.nodes.len) {
            self.overflowed = true;
            return 0;
        }
        const idx = self.count;
        self.nodes[idx] = .{ .kind = kind, .line = line };
        self.count += 1;
        return idx;
    }

    fn validSourceRange(src: []const u8, start: u32, length: u32) bool {
        const s: usize = start;
        const n: usize = length;
        return s <= src.len and n <= src.len - s;
    }

    pub fn nodeText(self: *const AST, idx: u32) []const u8 {
        if (idx == 0 or idx >= self.count) return "";
        const n = self.nodes[idx];
        const sid = n.source_id;
        const src = if (sid == SYNTH_SOURCE_ID)
            self.sources[SYNTH_SOURCE_ID]
        else if (self.source_count > 0)
            self.sources[if (sid < self.source_count) sid else 0]
        else
            return "";
        if (!validSourceRange(src, n.text_start, n.text_len)) return "";
        return src[@as(usize, n.text_start)..][0..@as(usize, n.text_len)];
    }

    pub fn nodeTextSrcFrom(self: *const AST, start: u32, length: u32, source_id: u32) []const u8 {
        const src = if (source_id == SYNTH_SOURCE_ID)
            self.sources[SYNTH_SOURCE_ID]
        else if (source_id < self.source_count)
            self.sources[source_id]
        else
            return "";
        if (!validSourceRange(src, start, length)) return "";
        return src[@as(usize, start)..][0..@as(usize, length)];
    }

    pub fn findStructByName(self: *const AST, src: []const u8, name_start: u32, name_len: u32) ?u32 {
        if (!validSourceRange(src, name_start, name_len)) return null;
        const sought = src[@as(usize, name_start)..][0..@as(usize, name_len)];
        return self.findStructBySlice(src, sought);
    }

    pub fn findStructBySlice(self: *const AST, fallback_src: []const u8, sought: []const u8) ?u32 {
        const count = @min(@as(usize, self.struct_count), self.struct_defs.len);
        for (0..count) |i| {
            const def = self.struct_defs[i];
            const src = if (def.source_id == SYNTH_SOURCE_ID)
                self.sources[SYNTH_SOURCE_ID]
            else if (def.source_id < self.source_count)
                self.sources[def.source_id]
            else
                fallback_src;
            if (!validSourceRange(src, def.name_start, def.name_len)) continue;
            if (std.mem.eql(u8, src[@as(usize, def.name_start)..][0..@as(usize, def.name_len)], sought)) {
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn findEnumBySlice(self: *const AST, fallback_src: []const u8, sought: []const u8) ?u32 {
        const count = @min(@as(usize, self.enum_count), self.enum_defs.len);
        for (0..count) |i| {
            const def = self.enum_defs[i];
            const src = if (def.source_id == SYNTH_SOURCE_ID)
                self.sources[SYNTH_SOURCE_ID]
            else if (def.source_id < self.source_count)
                self.sources[def.source_id]
            else
                fallback_src;
            if (!validSourceRange(src, def.name_start, def.name_len)) continue;
            if (std.mem.eql(u8, src[@as(usize, def.name_start)..][0..@as(usize, def.name_len)], sought)) {
                return @intCast(i);
            }
        }
        return null;
    }

    pub fn findAliasBySlice(self: *const AST, fallback_src: []const u8, sought: []const u8) ?TypeAliasDef {
        const count = @min(@as(usize, self.alias_count), self.alias_defs.len);
        for (0..count) |i| {
            const def = self.alias_defs[i];
            const src = if (def.source_id == SYNTH_SOURCE_ID)
                self.sources[SYNTH_SOURCE_ID]
            else if (def.source_id < self.source_count)
                self.sources[def.source_id]
            else
                fallback_src;
            if (!validSourceRange(src, def.name_start, def.name_len)) continue;
            if (std.mem.eql(u8, src[@as(usize, def.name_start)..][0..@as(usize, def.name_len)], sought)) {
                return def;
            }
        }
        return null;
    }

    pub fn copySubtree(self: *AST, other: *const AST, root: u32, source_id: u32) u32 {
        if (root == 0 or root >= other.count) return 0;
        var remap: [MAX_AST_NODES]u32 = .{@as(u32, 0)} ** MAX_AST_NODES;
        var queue: [MAX_AST_NODES]u32 = undefined;
        var qhead: u32 = 0;
        var qtail: u32 = 0;

        const first_sid = if (other.nodes[root].source_id == SYNTH_SOURCE_ID) blk: {
            const s = other.nodeText(root);
            const sp = self.addSynthText(s);
            break :blk sp;
        } else null;

        const new_root = self.addNode(other.nodes[root].kind, other.nodes[root].line);
        self.nodes[new_root] = other.nodes[root];
        if (first_sid) |sp| {
            self.nodes[new_root].source_id = sp.source_id;
            self.nodes[new_root].text_start = sp.start;
            self.nodes[new_root].text_len = sp.len;
        } else {
            self.nodes[new_root].source_id = source_id;
        }
        remap[root] = new_root;
        queue[qtail] = root;
        qtail += 1;

        while (qhead < qtail) {
            const old_idx = queue[qhead];
            qhead += 1;
            const new_idx = remap[old_idx];
            const old_node = other.nodes[old_idx];

            inline for (.{ "child0", "child1", "child2" }) |field_name| {
                const c = @field(old_node, field_name);
                if (c != 0) {
                    if (remap[c] == 0) {
                        const nc = self.addNode(other.nodes[c].kind, other.nodes[c].line);
                        self.nodes[nc] = other.nodes[c];
                        if (other.nodes[c].source_id == SYNTH_SOURCE_ID) {
                            const sp = self.addSynthText(other.nodeText(c));
                            self.nodes[nc].source_id = sp.source_id;
                            self.nodes[nc].text_start = sp.start;
                            self.nodes[nc].text_len = sp.len;
                        } else {
                            self.nodes[nc].source_id = source_id;
                        }
                        remap[c] = nc;
                        queue[qtail] = c;
                        qtail += 1;
                    }
                    @field(self.nodes[new_idx], field_name) = remap[c];
                }
            }

            if (other.stmt_chains[old_idx] != 0) {
                const old_next = other.stmt_chains[old_idx];
                if (remap[old_next] == 0) {
                    const nc = self.addNode(other.nodes[old_next].kind, other.nodes[old_next].line);
                    self.nodes[nc] = other.nodes[old_next];
                    if (other.nodes[old_next].source_id == SYNTH_SOURCE_ID) {
                        const sp = self.addSynthText(other.nodeText(old_next));
                        self.nodes[nc].source_id = sp.source_id;
                        self.nodes[nc].text_start = sp.start;
                        self.nodes[nc].text_len = sp.len;
                    } else {
                        self.nodes[nc].source_id = source_id;
                    }
                    remap[old_next] = nc;
                    queue[qtail] = old_next;
                    qtail += 1;
                }
                self.stmt_chains[new_idx] = remap[old_next];
            }
        }
        return new_root;
    }
};

pub const ParsedType = struct {
    tag: TypeTag = .none,
    extra: u32 = 0, // struct_idx+1, enum_idx+1, or fixed_array length
    elem_type: TypeTag = .none,
};

pub const Parser = struct {
    lex: *const Lexer,
    pos: u32,
    ast: *AST,
    src: []const u8,
    source_id: u32 = 0,
    diag: ?*DiagList = null,
    invalid_integer_literal: bool = false,
    invalid_integer_line: u32 = 0,
    invalid_integer_col: u32 = 1,
    invalid_integer_len: u32 = 1,
    invalid_syntax: bool = false,
    unsupported_float_literal: bool = false,
    in_cond_header: bool = false,
    in_match_pattern: bool = false,
    active_gen_params: [4]parser_mod_TextSpan = .{parser_mod_TextSpan{}} ** 4,
    active_gen_count: u8 = 0,
    pending_fn_flags: u8 = 0,
    recursion_depth: u32 = 0,

    const MAX_RECURSION_DEPTH: u32 = 64;
    const parser_mod_TextSpan = TextSpan;

    fn newNode(self: *Parser, kind: NodeKind, line: u32) u32 {
        const idx = self.ast.addNode(kind, line);
        if (idx != 0) self.ast.nodes[idx].source_id = self.source_id;
        return idx;
    }

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

    fn reportErr(self: *Parser, tok: Token, comptime fmt: []const u8, args: anytype) void {
        self.invalid_syntax = true;
        if (self.diag) |d| {
            d.addFmtAt(.err, self.source_id, tok.line, tok.col, tok.len, fmt, args);
        } else {
            printErr("Parse error at line ");
            printErrUsize(tok.line);
            printErr(": ");
            var buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
            printErr(msg);
            printErr("\n");
        }
    }

    fn expect(self: *Parser, kind: TokenKind) Token {
        const t = self.peek();
        if (t.kind != kind) {
            self.reportErr(t, "expected {s}, got {s}", .{ @tagName(kind), @tagName(t.kind) });
            if (t.kind != .eof) _ = self.advance();
            return .{ .kind = kind, .start = t.start, .len = 0, .line = t.line, .col = t.col };
        }
        return self.advance();
    }

    fn skipNewlines(self: *Parser) void {
        while (self.match(.newline) or self.match(.semicolon)) _ = self.advance();
    }

    fn skipOnlyNewlines(self: *Parser) void {
        while (self.match(.newline)) _ = self.advance();
    }

    fn skipToStmtEnd(self: *Parser) void {
        while (!self.match(.newline) and !self.match(.semicolon) and !self.match(.rbrace) and !self.match(.eof)) {
            _ = self.advance();
        }
    }

    pub fn parse(self: *Parser) void {
        if (self.ast.source_count == 0) {
            self.ast.sources[0] = self.src;
            self.ast.source_count = 1;
        }
        while (!self.match(.eof)) {
            const loop_start = self.pos;
            self.skipNewlines();
            if (self.match(.eof)) break;

            if (self.match(.hash)) {
                _ = self.advance();
                if (self.match(.lbracket)) {
                    _ = self.advance();
                    while (!self.match(.rbracket) and !self.match(.eof)) {
                        if (self.match(.identifier)) {
                            const attr = self.lex.text(self.advance());
                            if (std.mem.eql(u8, attr, "test")) {
                                self.pending_fn_flags |= 4;
                            } else if (std.mem.eql(u8, attr, "inline")) {
                                self.pending_fn_flags |= 8;
                            } else if (std.mem.eql(u8, attr, "cold")) {
                                self.pending_fn_flags |= 16;
                            }
                        } else {
                            _ = self.advance();
                        }
                    }
                    _ = self.expect(.rbracket);
                    continue;
                }
            } else if (self.match(.kw_pub)) {
                _ = self.advance();
                continue;
            } else if (self.match(.kw_comptime)) {
                _ = self.advance();
                if (self.match(.kw_fn)) {
                    self.pending_fn_flags |= 16;
                    _ = self.parseFnDecl(0);
                    self.pending_fn_flags = 0;
                } else {
                    const t = self.peek();
                    self.reportErr(t, "expected fn after top-level comptime", .{});
                    self.skipToStmtEnd();
                }
            } else if (self.match(.kw_fn)) {
                _ = self.parseFnDecl(0);
                self.pending_fn_flags = 0;
            } else if (self.match(.kw_import) or self.match(.kw_use)) {
                self.pending_fn_flags = 0;
                _ = self.advance();
                if (self.match(.string_literal)) {
                    const path_tok = self.advance();
                    const node = self.newNode(.module_import, path_tok.line);
                    self.ast.nodes[node].col = path_tok.col;
                    self.ast.nodes[node].text_start = path_tok.start + 1;
                    self.ast.nodes[node].text_len = if (path_tok.len >= 2) path_tok.len - 2 else 0;
                    self.ast.nodes[node].flags = 1; // quoted path import
                } else if (self.match(.identifier)) {
                    const mod_tok = self.advance();
                    var end_pos: u32 = mod_tok.start + mod_tok.len;
                    while (self.match(.colon_colon)) {
                        _ = self.advance();
                        if (self.match(.identifier)) {
                            const seg = self.advance();
                            end_pos = seg.start + seg.len;
                        } else {
                            self.reportErr(self.peek(), "expected module name after '::'", .{});
                            break;
                        }
                    }
                    const node = self.newNode(.module_import, mod_tok.line);
                    self.ast.nodes[node].col = mod_tok.col;
                    self.ast.nodes[node].text_start = mod_tok.start;
                    self.ast.nodes[node].text_len = end_pos - mod_tok.start;
                } else {
                    const t = self.peek();
                    self.reportErr(t, "expected module name or path after import/use", .{});
                    self.skipToStmtEnd();
                }
            } else if (self.match(.kw_struct)) {
                self.pending_fn_flags = 0;
                _ = self.parseStructDecl();
            } else if (self.match(.kw_union)) {
                self.pending_fn_flags = 0;
                _ = self.parseUnionDecl();
            } else if (self.match(.kw_trait)) {
                self.pending_fn_flags = 0;
                _ = self.parseTraitDecl();
            } else if (self.match(.kw_impl)) {
                self.pending_fn_flags = 0;
                self.parseImplDecl();
            } else if (self.match(.kw_enum)) {
                self.pending_fn_flags = 0;
                _ = self.parseEnumDecl();
            } else if (self.match(.kw_const)) {
                self.pending_fn_flags = 0;
                _ = self.parseConstDecl();
            } else if (self.match(.kw_type)) {
                self.pending_fn_flags = 0;
                _ = self.parseTypeAliasDecl();
            } else if (self.match(.kw_mod) or self.match(.kw_extern)) {
                self.pending_fn_flags = 0;
                const t = self.peek();
                self.reportErr(t, "unsupported top-level declaration '{s}'", .{@tagName(t.kind)});
                _ = self.advance();
                var brace_depth: u32 = 0;
                while (!self.match(.eof)) {
                    if (self.match(.lbrace)) {
                        brace_depth += 1;
                        _ = self.advance();
                    } else if (self.match(.rbrace)) {
                        _ = self.advance();
                        if (brace_depth <= 1) break;
                        brace_depth -= 1;
                    } else if (brace_depth == 0 and (self.match(.newline) or self.match(.semicolon))) {
                        break;
                    } else {
                        _ = self.advance();
                    }
                }
            } else {
                self.pending_fn_flags = 0;
                const t = self.peek();
                self.reportErr(t, "expected top-level declaration (fn, struct, union, enum, trait, const, type, impl, import), got '{s}'", .{self.lex.text(t)});
                _ = self.advance();
            }
            self.skipNewlines();
            if (self.pos == loop_start and !self.match(.eof)) {
                _ = self.advance();
            }
        }
    }

    fn pushGenParams(self: *Parser, allow_parens: bool) void {
        self.active_gen_count = 0;
        if (self.match(.lt) or (allow_parens and self.match(.lparen))) {
            const close_kind: TokenKind = if (self.match(.lt)) .gt else .rparen;
            _ = self.advance();
            while (!self.match(close_kind) and !self.match(.eof)) {
                self.skipOnlyNewlines();
                if (self.match(close_kind)) break;
                const pt = self.expect(.identifier);
                if (self.active_gen_count < 4) {
                    self.active_gen_params[self.active_gen_count] = .{
                        .start = pt.start,
                        .len = pt.len,
                        .source_id = self.source_id,
                    };
                    self.active_gen_count += 1;
                }
                if (self.match(.colon)) {
                    // Skip optional trait bound T: Trait
                    _ = self.advance();
                    if (self.match(.identifier)) _ = self.advance();
                }
                if (self.match(.comma)) _ = self.advance() else break;
            }
            _ = self.expect(close_kind);
        }
    }

    fn findActiveGenParam(self: *const Parser, name: []const u8) ?u32 {
        for (0..self.active_gen_count) |i| {
            const sp = self.active_gen_params[i];
            const pname = self.ast.nodeTextSrcFrom(sp.start, sp.len, sp.source_id);
            if (std.mem.eql(u8, pname, name)) return @intCast(i);
        }
        return null;
    }

    fn parseTypeSpec(self: *Parser, allow_void: bool) ParsedType {
        const tok = self.peek();
        if (tok.kind == .star) {
            _ = self.advance();
            if (self.match(.kw_const) or self.match(.kw_mut)) _ = self.advance();
            const inner = self.parseTypeSpec(true);
            if (inner.tag == .none) return .{};
            if (inner.tag == .ptr or inner.tag == .fixed_array or inner.tag == .tuple or
                inner.tag == .fn_ptr or inner.tag == .generic_inst)
            {
                const td = self.ast.addTypeDesc(.{
                    .kind = .ptr,
                    .ret_tag = inner.tag,
                    .ret_extra = inner.extra,
                    .ret_elem = inner.elem_type,
                });
                return .{ .tag = .ptr, .extra = td | 0x80000000, .elem_type = inner.tag };
            }
            return .{ .tag = .ptr, .extra = inner.extra, .elem_type = inner.tag };
        }
        if (tok.kind == .question) {
            _ = self.advance();
            const inner = self.parseTypeSpec(false);
            if (inner.tag == .none) return .{};
            const base_sp = self.ast.addSynthText("Option");
            const td = self.ast.addTypeDesc(.{
                .kind = .generic_inst,
                .param_count = 1,
                .param_tags = .{ inner.tag, .none, .none, .none, .none, .none, .none, .none },
                .param_extras = .{ inner.extra, 0, 0, 0, 0, 0, 0, 0 },
                .param_elems = .{ inner.elem_type, .none, .none, .none, .none, .none, .none, .none },
                .base_name = base_sp,
            });
            return .{ .tag = .generic_inst, .extra = td };
        }
        if (tok.kind == .bang) {
            _ = self.advance();
            const inner = self.parseTypeSpec(true);
            if (inner.tag == .none) return .{};
            const base_sp = self.ast.addSynthText("Result");
            const td = self.ast.addTypeDesc(.{
                .kind = .generic_inst,
                .param_count = 2,
                .param_tags = .{ inner.tag, .i64, .none, .none, .none, .none, .none, .none },
                .param_extras = .{ inner.extra, 0, 0, 0, 0, 0, 0, 0 },
                .param_elems = .{ inner.elem_type, .none, .none, .none, .none, .none, .none, .none },
                .base_name = base_sp,
            });
            return .{ .tag = .generic_inst, .extra = td };
        }
        if (tok.kind == .lbracket) {
            _ = self.advance();
            if (self.match(.rbracket)) {
                _ = self.advance();
                const elem = self.parseTypeSpec(false);
                if (elem.tag == .none) return .{};
                const td = self.ast.addTypeDesc(.{
                    .kind = .slice,
                    .ret_tag = elem.tag,
                    .ret_extra = elem.extra,
                    .ret_elem = elem.elem_type,
                });
                return .{ .tag = .slice, .extra = td, .elem_type = elem.tag };
            }
            if (self.match(.int_literal) and self.lex.get(self.pos + 1).kind == .rbracket) {
                const len_tok = self.advance();
                const len_val = self.parseIntLiteralToken(len_tok);
                if (len_val <= 0 or len_val > 65536) {
                    self.reportErr(len_tok, "fixed array length must be between 1 and 65536", .{});
                }
                _ = self.expect(.rbracket);
                const elem = self.parseTypeSpec(false);
                if (elem.tag == .none) return .{};
                return .{ .tag = .fixed_array, .extra = @intCast(@max(len_val, 1)), .elem_type = elem.tag };
            } else {
                const len_expr = self.parseExpr();
                _ = self.expect(.rbracket);
                const elem = self.parseTypeSpec(false);
                if (elem.tag == .none) return .{};
                const td = self.ast.addTypeDesc(.{
                    .kind = .fixed_array,
                    .const_expr_node = len_expr,
                    .ret_tag = elem.tag,
                    .ret_extra = elem.extra,
                    .ret_elem = elem.elem_type,
                });
                return .{ .tag = .fixed_array, .extra = td | 0x80000000, .elem_type = elem.tag };
            }
        }
        if (tok.kind == .lparen) {
            _ = self.advance();
            if (self.match(.rparen)) {
                _ = self.advance();
                return .{ .tag = .void };
            }
            var desc = TypeDesc{ .kind = .tuple };
            while (!self.match(.rparen) and !self.match(.eof)) {
                const et = self.parseTypeSpec(false);
                if (desc.param_count < 8) {
                    const idx = desc.param_count;
                    desc.param_tags[idx] = et.tag;
                    desc.param_extras[idx] = et.extra;
                    desc.param_elems[idx] = et.elem_type;
                    desc.param_count += 1;
                }
                if (self.match(.comma)) _ = self.advance() else break;
            }
            _ = self.expect(.rparen);
            if (desc.param_count == 1) {
                return .{ .tag = desc.param_tags[0], .extra = desc.param_extras[0], .elem_type = desc.param_elems[0] };
            }
            const td = self.ast.addTypeDesc(desc);
            return .{ .tag = .tuple, .extra = td };
        }
        if (tok.kind == .kw_fn) {
            _ = self.advance();
            _ = self.expect(.lparen);
            var desc = TypeDesc{ .kind = .fn_ptr, .ret_tag = .void };
            while (!self.match(.rparen) and !self.match(.eof)) {
                const pt = self.parseTypeSpec(false);
                if (desc.param_count < 8) {
                    const idx = desc.param_count;
                    desc.param_tags[idx] = pt.tag;
                    desc.param_extras[idx] = pt.extra;
                    desc.param_elems[idx] = pt.elem_type;
                    desc.param_count += 1;
                }
                if (self.match(.comma)) _ = self.advance() else break;
            }
            _ = self.expect(.rparen);
            if (self.match(.arrow)) {
                _ = self.advance();
                const rt = self.parseTypeSpec(true);
                desc.ret_tag = rt.tag;
                desc.ret_extra = rt.extra;
                desc.ret_elem = rt.elem_type;
            }
            const td = self.ast.addTypeDesc(desc);
            return .{ .tag = .fn_ptr, .extra = td };
        }
        if (tok.kind == .kw_dyn) {
            _ = self.advance();
            const tname_tok = self.expect(.identifier);
            const tname = self.lex.text(tname_tok);
            if (self.ast.findTraitBySlice(self.src, tname)) |ti| {
                return .{ .tag = .dyn_trait, .extra = ti + 1 };
            }
            const td = self.ast.addTypeDesc(.{
                .kind = .dyn_trait,
                .base_name = .{ .start = tname_tok.start, .len = tname_tok.len, .source_id = self.source_id },
            });
            return .{ .tag = .dyn_trait, .extra = td | 0x80000000 };
        }
        const simple: ?TypeTag = switch (tok.kind) {
            .kw_i8 => .i8,
            .kw_i16 => .i16,
            .kw_i32 => .i32,
            .kw_i64 => .i64,
            .kw_isize => .isize,
            .kw_u8 => .u8,
            .kw_u16 => .u16,
            .kw_u32 => .u32,
            .kw_u64 => .u64,
            .kw_usize => .usize,
            .kw_f32 => .f32,
            .kw_f64 => .f64,
            .kw_bool => .bool,
            .kw_string => .string,
            .kw_void => if (allow_void) .void else null,
            .kw_never => if (allow_void) .never else null,
            else => null,
        };
        if (simple) |t| {
            _ = self.advance();
            return .{ .tag = t };
        }
        if (tok.kind == .identifier) {
            const name = self.lex.text(tok);
            if (std.mem.eql(u8, name, "anyopaque")) {
                _ = self.advance();
                return .{ .tag = .void };
            }
            if (std.mem.eql(u8, name, "Map")) {
                _ = self.advance();
                var desc = TypeDesc{ .kind = .map, .param_count = 2 };
                desc.param_tags[0] = .string;
                desc.param_tags[1] = .i64;
                if (self.match(.lt) or self.match(.lparen)) {
                    const ck: TokenKind = if (self.match(.lt)) .gt else .rparen;
                    _ = self.advance();
                    const kt = self.parseTypeSpec(false);
                    desc.param_tags[0] = kt.tag;
                    desc.param_extras[0] = kt.extra;
                    desc.param_elems[0] = kt.elem_type;
                    if (self.match(.comma)) {
                        _ = self.advance();
                        const vt = self.parseTypeSpec(false);
                        desc.param_tags[1] = vt.tag;
                        desc.param_extras[1] = vt.extra;
                        desc.param_elems[1] = vt.elem_type;
                    }
                    _ = self.expect(ck);
                }
                const td = self.ast.addTypeDesc(desc);
                return .{ .tag = .map, .extra = td };
            }
            if (std.mem.eql(u8, name, "Chan")) {
                _ = self.advance();
                var elem_tag: TypeTag = .i64;
                if (self.match(.lt) or self.match(.lparen)) {
                    const ck: TokenKind = if (self.match(.lt)) .gt else .rparen;
                    _ = self.advance();
                    const et = self.parseTypeSpec(false);
                    elem_tag = et.tag;
                    _ = self.expect(ck);
                }
                return .{ .tag = .chan, .elem_type = elem_tag };
            }
            if (self.findActiveGenParam(name)) |gidx| {
                _ = self.advance();
                return .{ .tag = .generic_param, .extra = gidx };
            }
            const next_tok = self.lex.get(self.pos + 1);
            if (next_tok.kind == .lt or next_tok.kind == .lparen) {
                _ = self.advance();
                const ck: TokenKind = if (self.match(.lt)) .gt else .rparen;
                _ = self.advance();
                var desc = TypeDesc{
                    .kind = .generic_inst,
                    .base_name = .{ .start = tok.start, .len = tok.len, .source_id = self.source_id },
                };
                while (!self.match(ck) and !self.match(.eof)) {
                    const ta = self.parseTypeSpec(false);
                    if (desc.param_count < 8) {
                        const i = desc.param_count;
                        desc.param_tags[i] = ta.tag;
                        desc.param_extras[i] = ta.extra;
                        desc.param_elems[i] = ta.elem_type;
                        desc.param_count += 1;
                    }
                    if (self.match(.comma)) _ = self.advance() else break;
                }
                _ = self.expect(ck);
                const td = self.ast.addTypeDesc(desc);
                return .{ .tag = .generic_inst, .extra = td };
            }
            if (self.ast.findStructBySlice(self.src, name)) |si| {
                _ = self.advance();
                return .{ .tag = .struct_type, .extra = si + 1 };
            }
            if (self.ast.findEnumBySlice(self.src, name)) |ei| {
                _ = self.advance();
                return .{ .tag = .enum_type, .extra = ei + 1 };
            }
            if (self.ast.findAliasBySlice(self.src, name)) |al| {
                _ = self.advance();
                return .{ .tag = al.target_tag, .extra = al.target_extra, .elem_type = al.target_elem };
            }
        }
        self.reportErr(tok, "unsupported or unknown type '{s}'", .{self.lex.text(tok)});
        if (tok.kind != .eof and tok.kind != .comma and tok.kind != .rparen and
            tok.kind != .lbrace and tok.kind != .assign and tok.kind != .newline and tok.kind != .semicolon)
        {
            _ = self.advance();
        }
        return .{};
    }

    fn parseConstDecl(self: *Parser) u32 {
        const ctok = self.expect(.kw_const);
        const name_tok = self.expect(.identifier);
        var ty: ParsedType = .{ .tag = .none };
        if (self.match(.colon)) {
            _ = self.advance();
            ty = self.parseTypeSpec(false);
        }
        _ = self.expect(.assign);
        const expr = self.parseExpr();
        const node = self.newNode(.const_decl, ctok.line);
        self.ast.nodes[node].col = ctok.col;
        self.ast.nodes[node].text_start = name_tok.start;
        self.ast.nodes[node].text_len = name_tok.len;
        self.ast.nodes[node].child0 = expr;
        self.ast.nodes[node].type_tag = ty.tag;
        self.ast.nodes[node].extra = ty.extra;
        return node;
    }

    fn parseTypeAliasDecl(self: *Parser) u32 {
        const ttok = self.expect(.kw_type);
        const name_tok = self.expect(.identifier);
        _ = self.expect(.assign);
        const target = self.parseTypeSpec(true);
        if (target.tag != .none and @as(usize, self.ast.alias_count) < self.ast.alias_defs.len) {
            self.ast.alias_defs[self.ast.alias_count] = .{
                .name_start = name_tok.start,
                .name_len = name_tok.len,
                .source_id = self.source_id,
                .target_tag = target.tag,
                .target_extra = target.extra,
                .target_elem = target.elem_type,
            };
            self.ast.alias_count += 1;
        }
        const node = self.newNode(.type_alias, ttok.line);
        self.ast.nodes[node].col = ttok.col;
        self.ast.nodes[node].text_start = name_tok.start;
        self.ast.nodes[node].text_len = name_tok.len;
        self.ast.nodes[node].type_tag = target.tag;
        self.ast.nodes[node].extra = target.extra;
        return node;
    }

    fn parseEnumDecl(self: *Parser) u32 {
        const etok = self.expect(.kw_enum);
        const name_tok = self.expect(.identifier);
        const saved_gen = self.active_gen_count;
        const saved_params = self.active_gen_params;
        self.pushGenParams(true);
        defer {
            self.active_gen_count = saved_gen;
            self.active_gen_params = saved_params;
        }
        self.skipOnlyNewlines();
        _ = self.expect(.lbrace);
        self.skipNewlines();

        if (@as(usize, self.ast.enum_count) >= self.ast.enum_defs.len) {
            self.ast.overflowed = true;
            var depth: u32 = 1;
            while (depth > 0 and !self.match(.eof)) {
                const k = self.advance().kind;
                if (k == .lbrace) depth += 1 else if (k == .rbrace) depth -= 1;
            }
            return 0;
        }

        const ei = self.ast.enum_count;
        self.ast.enum_count += 1;
        self.ast.enum_defs[ei] = .{
            .name_start = name_tok.start,
            .name_len = name_tok.len,
            .line = name_tok.line,
            .source_id = self.source_id,
            .variants = undefined,
            .variant_count = 0,
            .has_payloads = false,
            .is_generic = self.active_gen_count > 0,
            .generic_params = self.active_gen_params,
            .generic_param_count = self.active_gen_count,
        };

        var next_val: i64 = 0;
        while (!self.match(.rbrace) and !self.match(.eof)) {
            const loop_pos = self.pos;
            self.skipNewlines();
            if (self.match(.rbrace) or self.match(.eof)) break;
            const vtok = self.expect(.identifier);
            var variant = EnumVariant{
                .name_start = vtok.start,
                .name_len = vtok.len,
                .value = next_val,
            };
            if (self.match(.lparen)) {
                _ = self.advance();
                self.ast.enum_defs[ei].has_payloads = true;
                while (!self.match(.rparen) and !self.match(.eof)) {
                    const pt = self.parseTypeSpec(false);
                    if (variant.payload_count < 8) {
                        const pi = variant.payload_count;
                        variant.payload_tags[pi] = pt.tag;
                        variant.payload_extras[pi] = pt.extra;
                        variant.payload_elems[pi] = pt.elem_type;
                        variant.payload_count += 1;
                    }
                    if (self.match(.comma)) _ = self.advance() else break;
                }
                _ = self.expect(.rparen);
            } else if (self.match(.assign)) {
                _ = self.advance();
                var sign: i64 = 1;
                if (self.match(.minus)) {
                    _ = self.advance();
                    sign = -1;
                }
                const num_tok = self.expect(.int_literal);
                variant.value = sign * self.parseIntLiteralToken(num_tok);
            }
            next_val = variant.value + 1;

            const ed = &self.ast.enum_defs[ei];
            if (@as(usize, ed.variant_count) >= ed.variants.len) {
                self.ast.overflowed = true;
            } else {
                ed.variants[ed.variant_count] = variant;
                ed.variant_count += 1;
            }
            if (self.match(.comma)) _ = self.advance();
            self.skipNewlines();
            if (self.pos == loop_pos) _ = self.advance();
        }
        _ = self.expect(.rbrace);

        const node = self.newNode(.enum_decl, etok.line);
        self.ast.nodes[node].col = etok.col;
        self.ast.nodes[node].text_start = name_tok.start;
        self.ast.nodes[node].text_len = name_tok.len;
        self.ast.nodes[node].int_val = @intCast(ei);
        if (self.active_gen_count > 0 and @as(usize, self.ast.generic_count) < self.ast.generics.len) {
            self.ast.generics[self.ast.generic_count] = .{
                .kind = .enum_t,
                .node_or_def_idx = ei,
                .name = .{ .start = name_tok.start, .len = name_tok.len, .source_id = self.source_id },
                .params = self.active_gen_params,
                .param_count = self.active_gen_count,
            };
            self.ast.generic_count += 1;
        }
        return node;
    }

    fn parseUnionDecl(self: *Parser) u32 {
        const tok = self.expect(.kw_union);
        const name_tok = self.expect(.identifier);
        self.skipOnlyNewlines();
        _ = self.expect(.lbrace);
        self.skipNewlines();

        if (@as(usize, self.ast.struct_count) >= self.ast.struct_defs.len) {
            self.ast.overflowed = true;
            var depth: u32 = 1;
            while (depth > 0 and !self.match(.eof)) {
                const k = self.advance().kind;
                if (k == .lbrace) depth += 1 else if (k == .rbrace) depth -= 1;
            }
            return 0;
        }
        const si: u32 = self.ast.struct_count;
        self.ast.struct_count += 1;
        self.ast.struct_defs[si] = .{
            .name_start = name_tok.start,
            .name_len = name_tok.len,
            .line = name_tok.line,
            .source_id = self.source_id,
            .fields = undefined,
            .field_count = 0,
            .total_size = 8,
            .is_union = true,
        };
        var max_size: u32 = 8;
        while (!self.match(.rbrace) and !self.match(.eof)) {
            const loop_pos = self.pos;
            self.skipNewlines();
            if (self.match(.rbrace) or self.match(.eof)) break;
            const field_name = self.expect(.identifier);
            _ = self.expect(.colon);
            const ftype = self.parseTypeSpec(false);
            if (self.match(.comma)) _ = self.advance();
            self.skipNewlines();

            const sd = &self.ast.struct_defs[si];
            if (@as(usize, sd.field_count) < sd.fields.len) {
                sd.fields[sd.field_count] = .{
                    .name_start = field_name.start,
                    .name_len = field_name.len,
                    .offset = 0, // union: all fields overlap at offset 0!
                    .type_tag = ftype.tag,
                    .extra = ftype.extra,
                    .elem_type = ftype.elem_type,
                };
                sd.field_count += 1;
            }
            const fsize: u32 = if (ftype.tag == .fixed_array) @max(ftype.extra, 1) * 8 else 8;
            if (fsize > max_size) max_size = fsize;
            if (self.pos == loop_pos) _ = self.advance();
        }
        self.ast.struct_defs[si].total_size = max_size;
        _ = self.expect(.rbrace);

        const node = self.newNode(.struct_decl, tok.line);
        self.ast.nodes[node].col = tok.col;
        self.ast.nodes[node].text_start = name_tok.start;
        self.ast.nodes[node].text_len = name_tok.len;
        self.ast.nodes[node].int_val = @intCast(si);
        return node;
    }

    fn parseTraitDecl(self: *Parser) void {
        const ttok = self.expect(.kw_trait);
        const name_tok = self.expect(.identifier);
        self.skipOnlyNewlines();
        _ = self.expect(.lbrace);
        self.skipNewlines();

        if (@as(usize, self.ast.trait_count) >= self.ast.trait_defs.len) {
            self.ast.overflowed = true;
            var depth: u32 = 1;
            while (depth > 0 and !self.match(.eof)) {
                const k = self.advance().kind;
                if (k == .lbrace) depth += 1 else if (k == .rbrace) depth -= 1;
            }
            return;
        }
        const ti = self.ast.trait_count;
        self.ast.trait_count += 1;
        self.ast.trait_defs[ti] = .{
            .name = .{ .start = name_tok.start, .len = name_tok.len, .source_id = self.source_id },
            .line = ttok.line,
            .method_count = 0,
        };

        while (!self.match(.rbrace) and !self.match(.eof)) {
            const loop_pos = self.pos;
            self.skipNewlines();
            if (self.match(.rbrace) or self.match(.eof)) break;
            if (self.match(.kw_pub)) {
                _ = self.advance();
                continue;
            }
            if (self.match(.kw_fn)) {
                _ = self.advance();
                const mname = self.expect(.identifier);
                _ = self.expect(.lparen);
                var m = TraitMethod{
                    .name = .{ .start = mname.start, .len = mname.len, .source_id = self.source_id },
                };
                var idx: u32 = 0;
                while (!self.match(.rparen) and !self.match(.eof)) {
                    if (idx > 0) {
                        _ = self.expect(.comma);
                        if (self.match(.rparen)) break;
                    }
                    if (idx == 0 and self.match(.amp)) {
                        _ = self.advance();
                        if (self.match(.kw_mut)) _ = self.advance();
                    }
                    const ptok = if (self.match(.kw_self)) self.advance() else self.expect(.identifier);
                    var ptype: ParsedType = if (ptok.kind == .kw_self) .{ .tag = .ptr } else .{ .tag = .i64 };
                    if (self.match(.colon)) {
                        _ = self.advance();
                        ptype = self.parseTypeSpec(false);
                    }
                    if (m.param_count < 8) {
                        const pi = m.param_count;
                        m.param_tags[pi] = ptype.tag;
                        m.param_extras[pi] = ptype.extra;
                        m.param_elems[pi] = ptype.elem_type;
                        m.param_count += 1;
                    }
                    idx += 1;
                }
                _ = self.expect(.rparen);
                if (self.match(.arrow)) {
                    _ = self.advance();
                    const rt = self.parseTypeSpec(true);
                    m.ret_tag = rt.tag;
                    m.ret_extra = rt.extra;
                    m.ret_elem = rt.elem_type;
                }
                // Optional default method body { ... } (skip cleanly if provided)
                self.skipOnlyNewlines();
                if (self.match(.lbrace)) {
                    _ = self.parseBlock();
                }
                const td = &self.ast.trait_defs[ti];
                if (td.method_count < td.methods.len) {
                    td.methods[td.method_count] = m;
                    td.method_count += 1;
                }
            } else {
                const t = self.peek();
                self.reportErr(t, "expected method signature in trait block", .{});
                _ = self.advance();
            }
            self.skipNewlines();
            if (self.pos == loop_pos) _ = self.advance();
        }
        _ = self.expect(.rbrace);
        const node = self.newNode(.trait_decl, ttok.line);
        self.ast.nodes[node].col = ttok.col;
        self.ast.nodes[node].text_start = name_tok.start;
        self.ast.nodes[node].text_len = name_tok.len;
        self.ast.nodes[node].int_val = @intCast(ti);
    }

    fn parseImplDecl(self: *Parser) void {
        _ = self.expect(.kw_impl);
        const saved_gen = self.active_gen_count;
        const saved_params = self.active_gen_params;
        self.pushGenParams(false);
        defer {
            self.active_gen_count = saved_gen;
            self.active_gen_params = saved_params;
        }

        const first_tok = self.expect(.identifier);
        // Optional type args <T> / (T) after first ident
        if (self.match(.lt) or self.match(.lparen)) {
            const ck: TokenKind = if (self.match(.lt)) .gt else .rparen;
            _ = self.advance();
            var depth: u32 = 1;
            while (depth > 0 and !self.match(.eof)) {
                const k = self.advance().kind;
                if (k == .lt or k == .lparen) depth += 1 else if (k == .gt or k == .rparen) depth -= 1;
                _ = ck;
            }
        }

        var trait_opt: ?u32 = null;
        var struct_tok = first_tok;
        if (self.match(.kw_for)) {
            _ = self.advance();
            const tname = self.lex.text(first_tok);
            trait_opt = self.ast.findTraitBySlice(self.src, tname);
            if (trait_opt == null) {
                self.reportErr(first_tok, "impl for unknown trait '{s}'", .{tname});
            }
            struct_tok = self.expect(.identifier);
            if (self.match(.lt) or self.match(.lparen)) {
                _ = self.advance();
                var depth: u32 = 1;
                while (depth > 0 and !self.match(.eof)) {
                    const k = self.advance().kind;
                    if (k == .lt or k == .lparen) depth += 1 else if (k == .gt or k == .rparen) depth -= 1;
                }
            }
        }

        const sname = self.lex.text(struct_tok);
        const si_opt = self.ast.findStructBySlice(self.src, sname);
        if (si_opt == null) {
            self.reportErr(struct_tok, "impl for unknown struct '{s}'", .{sname});
        }
        self.skipOnlyNewlines();
        _ = self.expect(.lbrace);
        self.skipNewlines();
        const owner_plus1 = if (si_opt) |si| si + 1 else 0;
        if (si_opt) |si| {
            // Inherit generic params from struct if impl didn't declare <T> explicitly
            if (self.active_gen_count == 0 and self.ast.struct_defs[si].is_generic) {
                self.active_gen_count = self.ast.struct_defs[si].generic_param_count;
                self.active_gen_params = self.ast.struct_defs[si].generic_params;
            }
        }

        var trait_impl_idx: ?u32 = null;
        if (trait_opt) |ti| {
            if (si_opt) |si| {
                if (@as(usize, self.ast.trait_impl_count) < self.ast.trait_impls.len) {
                    const idx = self.ast.trait_impl_count;
                    self.ast.trait_impl_count += 1;
                    self.ast.trait_impls[idx] = .{
                        .trait_idx = ti,
                        .struct_idx = si,
                    };
                    trait_impl_idx = idx;
                }
            }
        }

        while (!self.match(.rbrace) and !self.match(.eof)) {
            const loop_pos = self.pos;
            self.skipNewlines();
            if (self.match(.rbrace) or self.match(.eof)) break;
            if (self.match(.kw_pub)) {
                _ = self.advance();
                continue;
            }
            if (self.match(.kw_fn)) {
                const fn_node = self.parseFnDecl(owner_plus1);
                if (trait_impl_idx) |idx| {
                    const ti = self.ast.trait_impls[idx].trait_idx;
                    const td = self.ast.trait_defs[ti];
                    const mname = self.ast.nodeText(fn_node);
                    for (0..td.method_count) |mi| {
                        const tm = td.methods[mi];
                        const tm_name = self.ast.nodeTextSrcFrom(tm.name.start, tm.name.len, tm.name.source_id);
                        if (std.mem.eql(u8, tm_name, mname)) {
                            self.ast.trait_impls[idx].method_fn_nodes[mi] = fn_node;
                            break;
                        }
                    }
                }
            } else {
                const t = self.peek();
                self.reportErr(t, "expected method declaration inside impl block", .{});
                _ = self.advance();
            }
            self.skipNewlines();
            if (self.pos == loop_pos) _ = self.advance();
        }
        _ = self.expect(.rbrace);
    }

    fn parseFnDecl(self: *Parser, owner_struct_plus1: u32) u32 {
        const tok = self.expect(.kw_fn);
        const name = self.expect(.identifier);
        const saved_gen = self.active_gen_count;
        const saved_params = self.active_gen_params;
        if (self.match(.lt)) {
            self.pushGenParams(false);
        }
        defer {
            self.active_gen_count = saved_gen;
            self.active_gen_params = saved_params;
        }

        _ = self.expect(.lparen);
        var first_param: u32 = 0;
        var last_param: u32 = 0;
        var param_count: u32 = 0;
        while (!self.match(.rparen) and !self.match(.eof)) {
            const loop_pos = self.pos;
            self.skipOnlyNewlines();
            if (self.match(.rparen)) break;
            if (param_count > 0) {
                _ = self.expect(.comma);
                self.skipOnlyNewlines();
                if (self.match(.rparen)) break;
            }
            var pflags: u8 = 0;
            if (param_count == 0 and owner_struct_plus1 > 0 and self.match(.amp)) {
                _ = self.advance();
                if (self.match(.kw_mut)) {
                    _ = self.advance();
                    pflags |= 1;
                } else {
                    pflags |= 2;
                }
            } else if (self.match(.kw_mut)) {
                _ = self.advance();
                pflags |= 1;
            }
            const ptok = if (self.match(.kw_self)) self.advance() else self.expect(.identifier);
            var ptype: ParsedType = .{ .tag = .i64 };
            if (ptok.kind == .kw_self and !self.match(.colon) and owner_struct_plus1 > 0) {
                ptype = .{ .tag = .ptr, .extra = owner_struct_plus1, .elem_type = .struct_type };
            } else if (self.match(.colon)) {
                _ = self.advance();
                ptype = self.parseTypeSpec(false);
                if (!self.match(.assign) and !self.match(.comma) and !self.match(.rparen) and !self.match(.newline) and !self.match(.eof)) {
                    const bad = self.peek();
                    self.reportErr(bad, "unsupported compound parameter type syntax", .{});
                    while (!self.match(.comma) and !self.match(.rparen) and !self.match(.eof)) _ = self.advance();
                }
            }
            const pnode = self.newNode(.identifier, ptok.line);
            self.ast.nodes[pnode].col = ptok.col;
            self.ast.nodes[pnode].text_start = ptok.start;
            self.ast.nodes[pnode].text_len = ptok.len;
            self.ast.nodes[pnode].type_tag = ptype.tag;
            self.ast.nodes[pnode].elem_type = ptype.elem_type;
            self.ast.nodes[pnode].child0 = ptype.extra;
            self.ast.nodes[pnode].flags = pflags;
            if (self.match(.assign)) {
                _ = self.advance();
                self.ast.nodes[pnode].child2 = self.parseExpr();
            }
            if (first_param == 0) {
                first_param = pnode;
            } else {
                self.ast.nodes[last_param].child1 = pnode;
            }
            last_param = pnode;
            param_count += 1;
            if (self.pos == loop_pos) _ = self.advance();
        }
        _ = self.expect(.rparen);

        var ret_type: ParsedType = .{ .tag = .none };
        if (self.match(.arrow)) {
            _ = self.advance();
            ret_type = self.parseTypeSpec(true);
            if (!self.match(.lbrace) and !self.match(.newline) and !self.match(.kw_where) and !self.match(.eof)) {
                const bad = self.peek();
                self.reportErr(bad, "unsupported return type syntax", .{});
                while (!self.match(.lbrace) and !self.match(.newline) and !self.match(.eof)) _ = self.advance();
            }
        }
        if (self.match(.kw_where)) {
            _ = self.advance();
            while (!self.match(.lbrace) and !self.match(.eof)) _ = self.advance();
        }
        self.skipOnlyNewlines();
        const body = self.parseBlock();
        const node = self.newNode(.fn_decl, tok.line);
        self.ast.nodes[node].col = tok.col;
        self.ast.nodes[node].text_start = name.start;
        self.ast.nodes[node].text_len = name.len;
        self.ast.nodes[node].child0 = first_param;
        self.ast.nodes[node].child2 = body;
        self.ast.nodes[node].int_val = @intCast(param_count);
        self.ast.nodes[node].type_tag = ret_type.tag;
        self.ast.nodes[node].elem_type = ret_type.elem_type;
        self.ast.nodes[node].extra = owner_struct_plus1;
        self.ast.nodes[node].flags |= self.pending_fn_flags;
        if (owner_struct_plus1 > 0) self.ast.nodes[node].flags |= 2;
        if (ret_type.tag == .struct_type or ret_type.tag == .enum_type or
            ret_type.tag == .tuple or ret_type.tag == .fn_ptr or ret_type.tag == .generic_inst or
            ret_type.tag == .dyn_trait or ret_type.tag == .map or ret_type.tag == .slice)
        {
            self.ast.nodes[node].child1 = ret_type.extra;
        }
        if (self.active_gen_count > 0) {
            self.ast.nodes[node].flags |= 64; // generic fn template
            if (@as(usize, self.ast.generic_count) < self.ast.generics.len) {
                self.ast.generics[self.ast.generic_count] = .{
                    .kind = .fn_t,
                    .node_or_def_idx = node,
                    .name = .{ .start = name.start, .len = name.len, .source_id = self.source_id },
                    .params = self.active_gen_params,
                    .param_count = self.active_gen_count,
                };
                self.ast.generic_count += 1;
            }
        }
        return node;
    }

    fn parseSingleStatement(self: *Parser) u32 {
        if (self.recursion_depth >= MAX_RECURSION_DEPTH) {
            self.reportErr(self.peek(), "nesting exceeds maximum recursion depth ({d})", .{MAX_RECURSION_DEPTH});
            return 0;
        }
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;

        var stmt: u32 = 0;
        if (self.match(.kw_unreachable)) {
            const tok = self.advance();
            stmt = self.newNode(.unreachable_stmt, tok.line);
            self.ast.nodes[stmt].col = tok.col;
        } else if (self.match(.kw_return)) {
            const tok = self.advance();
            var val: u32 = 0;
            if (!self.match(.newline) and !self.match(.semicolon) and !self.match(.rbrace) and !self.match(.eof)) {
                val = self.parseExpr();
            }
            stmt = self.newNode(.return_stmt, tok.line);
            self.ast.nodes[stmt].col = tok.col;
            self.ast.nodes[stmt].child0 = val;
        } else if (self.match(.kw_let) or self.match(.kw_var)) {
            const let_tok = self.advance();
            var is_mut: u8 = if (let_tok.kind == .kw_var) 1 else 0;
            if (let_tok.kind == .kw_let and self.match(.kw_mut)) {
                _ = self.advance();
                is_mut = 1;
            }
            if (self.match(.lparen)) {
                // Tuple destructuring: let (a, mut b) = expr
                _ = self.advance();
                var first_pat: u32 = 0;
                var last_pat: u32 = 0;
                var pcount: i64 = 0;
                while (!self.match(.rparen) and !self.match(.eof)) {
                    var elem_mut: u8 = is_mut;
                    if (self.match(.kw_mut)) {
                        _ = self.advance();
                        elem_mut = 1;
                    }
                    const id_tok = self.expect(.identifier);
                    const pn = self.newNode(.identifier, id_tok.line);
                    self.ast.nodes[pn].col = id_tok.col;
                    self.ast.nodes[pn].text_start = id_tok.start;
                    self.ast.nodes[pn].text_len = id_tok.len;
                    self.ast.nodes[pn].flags = elem_mut;
                    if (first_pat == 0) {
                        first_pat = pn;
                    } else {
                        self.ast.nodes[last_pat].child1 = pn;
                    }
                    last_pat = pn;
                    pcount += 1;
                    if (self.match(.comma)) _ = self.advance() else break;
                }
                _ = self.expect(.rparen);
                _ = self.expect(.assign);
                const rhs = self.parseExpr();
                const pat = self.newNode(.tuple_pattern, let_tok.line);
                self.ast.nodes[pat].child0 = first_pat;
                self.ast.nodes[pat].int_val = pcount;
                stmt = self.newNode(.let_stmt, let_tok.line);
                self.ast.nodes[stmt].col = let_tok.col;
                self.ast.nodes[stmt].child0 = rhs;
                self.ast.nodes[stmt].child2 = pat;
                self.ast.nodes[stmt].flags = is_mut | 4;
                return stmt;
            }
            const name_tok = self.expect(.identifier);
            var ann_type: ParsedType = .{ .tag = .none };
            if (self.match(.colon)) {
                _ = self.advance();
                ann_type = self.parseTypeSpec(false);
                if (!self.match(.assign) and !self.match(.newline) and !self.match(.semicolon) and
                    !self.match(.rbrace) and !self.match(.eof))
                {
                    self.reportErr(self.peek(), "unexpected token in variable type annotation", .{});
                    while (!self.match(.assign) and !self.match(.newline) and !self.match(.semicolon) and
                        !self.match(.rbrace) and !self.match(.eof)) _ = self.advance();
                }
            }
            var init_val: u32 = 0;
            if (self.match(.assign)) {
                _ = self.advance();
                init_val = self.parseExpr();
            }
            stmt = self.newNode(.let_stmt, name_tok.line);
            self.ast.nodes[stmt].col = let_tok.col;
            self.ast.nodes[stmt].text_start = name_tok.start;
            self.ast.nodes[stmt].text_len = name_tok.len;
            self.ast.nodes[stmt].child0 = init_val;
            self.ast.nodes[stmt].child1 = ann_type.extra;
            self.ast.nodes[stmt].extra = ann_type.extra;
            self.ast.nodes[stmt].elem_type = ann_type.elem_type;
            self.ast.nodes[stmt].flags = is_mut;
            self.ast.nodes[stmt].type_tag = ann_type.tag;
        } else if (self.match(.kw_const)) {
            stmt = self.parseConstDecl();
        } else if (self.match(.kw_defer)) {
            const dtok = self.advance();
            self.skipOnlyNewlines();
            const body = if (self.match(.lbrace)) self.parseBlock() else self.parseSingleStatement();
            stmt = self.newNode(.defer_stmt, dtok.line);
            self.ast.nodes[stmt].col = dtok.col;
            self.ast.nodes[stmt].child0 = body;
        } else if (self.match(.kw_for)) {
            stmt = self.parseFor();
        } else if (self.match(.kw_loop)) {
            const tok = self.advance();
            self.skipOnlyNewlines();
            const cond = self.newNode(.int_literal, tok.line);
            self.ast.nodes[cond].int_val = 1;
            self.ast.nodes[cond].flags = 1; // bool literal
            const body = self.parseBlock();
            stmt = self.newNode(.while_stmt, tok.line);
            self.ast.nodes[stmt].col = tok.col;
            self.ast.nodes[stmt].child0 = cond;
            self.ast.nodes[stmt].child1 = body;
        } else if (self.match(.kw_while)) {
            stmt = self.parseWhile();
        } else if (self.match(.kw_break)) {
            const t = self.advance();
            stmt = self.newNode(.break_stmt, t.line);
            self.ast.nodes[stmt].col = t.col;
        } else if (self.match(.kw_continue)) {
            const t = self.advance();
            stmt = self.newNode(.continue_stmt, t.line);
            self.ast.nodes[stmt].col = t.col;
        } else if (self.match(.kw_if)) {
            stmt = self.parseIf();
        } else if (self.match(.lbrace)) {
            stmt = self.parseBlock();
        } else if (self.match(.kw_volatile) or
            self.match(.kw_asm) or self.match(.kw_try) or self.match(.kw_unsafe))
        {
            const t = self.peek();
            self.reportErr(t, "unsupported statement '{s}'", .{@tagName(t.kind)});
            self.skipToStmtEnd();
        } else {
            const expr = self.parseExpr();
            const pk = self.peek().kind;
            const is_assign = pk == .assign or pk == .plus_eq or pk == .minus_eq or
                pk == .star_eq or pk == .star_star_eq or pk == .slash_eq or pk == .percent_eq or
                pk == .amp_eq or pk == .pipe_eq or pk == .caret_eq or
                pk == .lshift_eq or pk == .rshift_eq;
            if (is_assign) {
                const op_tok = self.advance();
                const rhs = self.parseExpr();
                const lhs_node = self.ast.nodes[expr];
                if (lhs_node.kind == .identifier) {
                    stmt = self.newNode(.assign_stmt, lhs_node.line);
                    self.ast.nodes[stmt].col = lhs_node.col;
                    self.ast.nodes[stmt].text_start = lhs_node.text_start;
                    self.ast.nodes[stmt].text_len = lhs_node.text_len;
                    self.ast.nodes[stmt].child0 = rhs;
                    self.ast.nodes[stmt].op = @intFromEnum(op_tok.kind);
                } else if (lhs_node.kind == .deref or lhs_node.kind == .field_access or lhs_node.kind == .index_expr) {
                    stmt = self.newNode(.assign_stmt, lhs_node.line);
                    self.ast.nodes[stmt].col = lhs_node.col;
                    self.ast.nodes[stmt].child0 = expr;
                    self.ast.nodes[stmt].child1 = rhs;
                    self.ast.nodes[stmt].op = @intFromEnum(op_tok.kind);
                } else {
                    self.reportErr(op_tok, "invalid assignment target", .{});
                    stmt = expr;
                }
            } else {
                stmt = expr;
            }
        }
        return stmt;
    }

    fn parseBlock(self: *Parser) u32 {
        if (self.recursion_depth >= MAX_RECURSION_DEPTH) {
            self.reportErr(self.peek(), "nesting exceeds maximum recursion depth ({d})", .{MAX_RECURSION_DEPTH});
            return 0;
        }
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;

        const lb = self.expect(.lbrace);
        self.skipNewlines();
        const block = self.newNode(.block, lb.line);
        self.ast.nodes[block].col = lb.col;

        var head: u32 = 0;
        var tail: u32 = 0;

        while (!self.match(.rbrace) and !self.match(.eof)) {
            const loop_pos = self.pos;
            self.skipNewlines();
            if (self.match(.rbrace) or self.match(.eof)) break;

            const stmt = self.parseSingleStatement();
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
            if (self.pos == loop_pos and !self.match(.rbrace) and !self.match(.eof)) {
                _ = self.advance();
            }
        }
        _ = self.expect(.rbrace);
        self.ast.nodes[block].child0 = head;
        return block;
    }

    // ── Expression parsing with proper precedence ──────────────────

    fn parseExpr(self: *Parser) u32 {
        if (self.recursion_depth >= MAX_RECURSION_DEPTH) {
            self.reportErr(self.peek(), "nesting exceeds maximum recursion depth ({d})", .{MAX_RECURSION_DEPTH});
            return 0;
        }
        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;

        var left = self.parseTernary();
        while (self.match(.pipe_gt)) {
            const ptok = self.advance();
            const rhs = self.parseTernary();
            const rhs_node = self.ast.nodes[rhs];
            if (rhs_node.kind == .call_expr or rhs_node.kind == .method_call) {
                const wrap = self.newNode(.expr_stmt, ptok.line);
                self.ast.nodes[wrap].child0 = left;
                self.ast.nodes[wrap].child1 = rhs_node.child2;
                self.ast.nodes[rhs].child2 = wrap;
                left = rhs;
            } else {
                const wrap = self.newNode(.expr_stmt, ptok.line);
                self.ast.nodes[wrap].child0 = left;
                const cn = self.newNode(.call_expr, ptok.line);
                self.ast.nodes[cn].col = ptok.col;
                self.ast.nodes[cn].child0 = rhs;
                self.ast.nodes[cn].child2 = wrap;
                left = cn;
            }
        }
        return left;
    }

    fn isTernaryAtQuestion(self: *const Parser) bool {
        var look = self.pos + 1;
        var depth: i32 = 0;
        while (true) {
            const t = self.lex.get(look);
            switch (t.kind) {
                .eof, .newline, .semicolon => return false,
                .lparen, .lbracket, .lbrace => depth += 1,
                .rparen, .rbracket, .rbrace => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .comma => if (depth == 0) return false,
                .colon => if (depth == 0) return true,
                else => {},
            }
            look += 1;
        }
    }

    fn parseTernary(self: *Parser) u32 {
        const cond = self.parseCoalesce();
        if (self.match(.question) and self.isTernaryAtQuestion()) {
            const qtok = self.advance();
            const then_expr = self.parseExpr();
            _ = self.expect(.colon);
            const else_expr = self.parseExpr();
            const n = self.newNode(.ternary_expr, qtok.line);
            self.ast.nodes[n].col = qtok.col;
            self.ast.nodes[n].child0 = cond;
            self.ast.nodes[n].child1 = then_expr;
            self.ast.nodes[n].child2 = else_expr;
            return n;
        }
        return cond;
    }

    fn parseCoalesce(self: *Parser) u32 {
        var left = self.parseOr();
        while (self.match(.question_question)) {
            const op = self.advance();
            const right = self.parseOr();
            const n = self.newNode(.coalesce_expr, op.line);
            self.ast.nodes[n].col = op.col;
            self.ast.nodes[n].child0 = left;
            self.ast.nodes[n].child1 = right;
            left = n;
        }
        return left;
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
        var left = self.parseBitOr();
        while (self.match(.and_and)) {
            const op = self.advance();
            const right = self.parseBitOr();
            left = self.addBinary(left, right, op);
        }
        return left;
    }

    fn parseBitOr(self: *Parser) u32 {
        var left = self.parseBitXor();
        while (self.match(.pipe)) {
            const op = self.advance();
            const right = self.parseBitXor();
            left = self.addBinary(left, right, op);
        }
        return left;
    }

    fn parseBitXor(self: *Parser) u32 {
        var left = self.parseBitAnd();
        while (self.match(.caret)) {
            const op = self.advance();
            const right = self.parseBitAnd();
            left = self.addBinary(left, right, op);
        }
        return left;
    }

    fn parseBitAnd(self: *Parser) u32 {
        var left = self.parseEquality();
        while (self.match(.amp)) {
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
        var left = self.parseShift();
        while (self.match(.lt) or self.match(.gt) or self.match(.le) or self.match(.ge)) {
            const op = self.advance();
            const right = self.parseShift();
            left = self.addBinary(left, right, op);
        }
        return left;
    }

    fn parseShift(self: *Parser) u32 {
        var left = self.parseAdditive();
        while (self.match(.lshift) or self.match(.rshift)) {
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
        var left = self.parseCast();
        while (self.match(.star) or self.match(.slash) or self.match(.percent)) {
            const op = self.advance();
            const right = self.parseCast();
            left = self.addBinary(left, right, op);
        }
        return left;
    }

    fn parseCast(self: *Parser) u32 {
        var expr = self.parseUnary();
        while (self.match(.kw_as)) {
            const atok = self.advance();
            const target = self.parseTypeSpec(false);
            const cn = self.newNode(.cast_expr, atok.line);
            self.ast.nodes[cn].col = atok.col;
            self.ast.nodes[cn].child0 = expr;
            self.ast.nodes[cn].type_tag = target.tag;
            self.ast.nodes[cn].extra = target.extra;
            self.ast.nodes[cn].elem_type = target.elem_type;
            expr = cn;
        }
        return expr;
    }

    fn addBinary(self: *Parser, left: u32, right: u32, op: Token) u32 {
        const n = self.newNode(.binary_expr, op.line);
        self.ast.nodes[n].col = op.col;
        self.ast.nodes[n].child0 = left;
        self.ast.nodes[n].child1 = right;
        self.ast.nodes[n].op = @intFromEnum(op.kind);
        return n;
    }

    fn parseUnary(self: *Parser) u32 {
        if (self.match(.amp)) {
            const op = self.advance();
            const is_mut_ref: u8 = if (self.match(.kw_mut)) blk_m: {
                _ = self.advance();
                break :blk_m 1;
            } else 0;
            const operand = self.parseUnary();
            const n = self.newNode(.addr_of, op.line);
            self.ast.nodes[n].col = op.col;
            self.ast.nodes[n].child0 = operand;
            self.ast.nodes[n].flags = is_mut_ref;
            return n;
        }
        if (self.match(.star)) {
            const op = self.advance();
            const operand = self.parseUnary();
            const n = self.newNode(.deref, op.line);
            self.ast.nodes[n].col = op.col;
            self.ast.nodes[n].child0 = operand;
            return n;
        }
        if (self.match(.plus) or self.match(.minus) or self.match(.bang) or self.match(.tilde)) {
            const op = self.advance();
            const operand = self.parseUnary();
            const n = self.newNode(.unary_expr, op.line);
            self.ast.nodes[n].col = op.col;
            self.ast.nodes[n].child0 = operand;
            self.ast.nodes[n].op = @intFromEnum(op.kind);
            return n;
        }
        return self.parsePower();
    }

    // Power binds tighter than unary signs and associates right-to-left:
    // -2 ** 2 == -(2 ** 2), 2 ** 3 ** 2 == 2 ** (3 ** 2).
    fn parsePower(self: *Parser) u32 {
        const left = self.parsePrimary();
        if (self.match(.star_star)) {
            const op = self.advance();
            return self.addBinary(left, self.parseUnary(), op);
        }
        return left;
    }

    fn parseIntLiteralToken(self: *Parser, tok: Token) i64 {
        const txt = self.lex.text(tok);
        if (txt.len == 0) {
            self.invalid_integer_literal = true;
            self.invalid_integer_line = tok.line;
            self.invalid_integer_col = tok.col;
            self.invalid_integer_len = @max(tok.len, 1);
            return 0;
        }

        var base: u8 = 10;
        var digits_start: usize = 0;
        if (txt.len >= 2 and txt[0] == '0') {
            if (txt[1] == 'x' or txt[1] == 'X') {
                base = 16;
                digits_start = 2;
            } else if (txt[1] == 'b' or txt[1] == 'B') {
                base = 2;
                digits_start = 2;
            } else if (txt[1] == 'o' or txt[1] == 'O') {
                base = 8;
                digits_start = 2;
            }
        }

        const body = txt[digits_start..];
        var cleaned: [128]u8 = undefined;
        var clen: usize = 0;
        var malformed = body.len == 0;
        for (body, 0..) |c, i| {
            if (c == '_') {
                if (i == 0 or i + 1 == body.len or body[i - 1] == '_' or body[i + 1] == '_') malformed = true;
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
        if (malformed) {
            self.invalid_integer_literal = true;
            self.invalid_integer_line = tok.line;
            self.invalid_integer_col = tok.col;
            self.invalid_integer_len = @max(tok.len, 1);
            return 0;
        }
        return std.fmt.parseInt(i64, cleaned[0..clen], base) catch blk: {
            self.invalid_integer_literal = true;
            self.invalid_integer_line = tok.line;
            self.invalid_integer_col = tok.col;
            self.invalid_integer_len = @max(tok.len, 1);
            break :blk 0;
        };
    }

    fn parseCharLiteralToken(self: *Parser, tok: Token) i64 {
        const raw = self.lex.text(tok);
        if (raw.len < 3) {
            self.reportErr(tok, "invalid character literal", .{});
            return 0;
        }
        const inner = raw[1 .. raw.len - 1];
        if (inner.len == 1 and inner[0] != '\\') return @intCast(inner[0]);
        if (inner.len >= 2 and inner[0] == '\\') {
            return switch (inner[1]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '\'' => '\'',
                '"' => '"',
                '0' => 0,
                'x' => if (inner.len == 4) @intCast(std.fmt.parseInt(u8, inner[2..4], 16) catch 0) else 0,
                else => 0,
            };
        }
        self.reportErr(tok, "invalid character literal", .{});
        return 0;
    }

    fn parseCallArgs(self: *Parser, line: u32) u32 {
        _ = self.advance(); // '('
        var first_arg: u32 = 0;
        var last_arg: u32 = 0;
        while (!self.match(.rparen) and !self.match(.eof)) {
            const loop_pos = self.pos;
            self.skipOnlyNewlines();
            if (self.match(.rparen)) break;
            if (first_arg != 0) {
                _ = self.expect(.comma);
                self.skipOnlyNewlines();
                if (self.match(.rparen)) break;
            }
            var label: ?Token = null;
            if (!self.in_match_pattern and self.match(.identifier) and self.lex.get(self.pos + 1).kind == .colon) {
                label = self.advance();
                _ = self.advance();
                self.skipOnlyNewlines();
            }
            const arg = if (self.in_match_pattern) self.parsePatternElement() else self.parseExpr();
            const wrap = self.newNode(.expr_stmt, line);
            self.ast.nodes[wrap].child0 = arg;
            if (label) |token| {
                self.ast.nodes[wrap].flags |= 128;
                self.ast.nodes[wrap].text_start = token.start;
                self.ast.nodes[wrap].text_len = token.len;
                self.ast.nodes[wrap].line = token.line;
                self.ast.nodes[wrap].col = token.col;
            }
            if (first_arg == 0) {
                first_arg = wrap;
            } else {
                self.ast.nodes[last_arg].child1 = wrap;
            }
            last_arg = wrap;
            self.skipOnlyNewlines();
            if (self.pos == loop_pos) _ = self.advance();
        }
        _ = self.expect(.rparen);
        return first_arg;
    }

    fn looksLikeStructInit(self: *const Parser) bool {
        if (self.in_cond_header) return false;
        const name_tok = self.lex.get(self.pos - 1);
        if (self.ast.findStructBySlice(self.src, self.lex.text(name_tok)) != null) return true;
        var look = self.pos + 1;
        while (self.lex.get(look).kind == .newline) look += 1;
        if (self.lex.get(look).kind == .rbrace) return true;
        if (self.lex.get(look).kind == .identifier and self.lex.get(look + 1).kind == .colon) return true;
        return false;
    }

    fn parsePatternElement(self: *Parser) u32 {
        const saved = self.in_match_pattern;
        self.in_match_pattern = true;
        defer self.in_match_pattern = saved;
        const left = self.parseBitXor();
        if (self.match(.dot_dot) or self.match(.dot_dot_eq)) {
            const op = self.advance();
            return self.addBinary(left, self.parseBitXor(), op);
        }
        return left;
    }

    fn parseMatch(self: *Parser) u32 {
        const mtok = self.expect(.kw_match);
        const saved = self.in_cond_header;
        self.in_cond_header = true;
        const scrutinee = self.parseExpr();
        self.in_cond_header = saved;
        self.skipOnlyNewlines();
        _ = self.expect(.lbrace);
        self.skipNewlines();

        var first_arm: u32 = 0;
        var last_arm: u32 = 0;
        var default_body: u32 = 0;

        while (!self.match(.rbrace) and !self.match(.eof)) {
            const loop_pos = self.pos;
            self.skipNewlines();
            if (self.match(.rbrace) or self.match(.eof)) break;

            const arm_tok = self.peek();
            if (default_body != 0) self.reportErr(arm_tok, "wildcard match arm must be last", .{});
            var is_wildcard = false;
            var pat_head: u32 = 0;
            var pat_tail: u32 = 0;

            var guard_expr: u32 = 0;
            if (self.match(.kw_else) or (self.match(.identifier) and std.mem.eql(u8, self.lex.text(arm_tok), "_"))) {
                _ = self.advance();
                is_wildcard = true;
                if (self.match(.kw_if)) {
                    if (arm_tok.kind == .kw_else) self.reportErr(arm_tok, "use '_ if condition' for a guarded wildcard", .{});
                    _ = self.advance();
                    const saved_header = self.in_cond_header;
                    self.in_cond_header = true;
                    guard_expr = self.parseExpr();
                    self.in_cond_header = saved_header;
                    is_wildcard = false;
                    pat_head = self.newNode(.identifier, arm_tok.line);
                    self.ast.nodes[pat_head].text_start = arm_tok.start;
                    self.ast.nodes[pat_head].text_len = arm_tok.len;
                }
            } else {
                while (!self.match(.fat_arrow) and !self.match(.kw_if) and !self.match(.eof)) {
                    const p = self.parsePatternElement();
                    if (pat_head == 0) {
                        pat_head = p;
                        pat_tail = p;
                    } else {
                        self.ast.stmt_chains[pat_tail] = p;
                        pat_tail = p;
                    }
                    if (self.match(.pipe)) {
                        _ = self.advance();
                    } else {
                        break;
                    }
                }
                if (self.match(.kw_if)) {
                    _ = self.advance();
                    const saved_header = self.in_cond_header;
                    self.in_cond_header = true;
                    guard_expr = self.parseExpr();
                    self.in_cond_header = saved_header;
                }
            }
            _ = self.expect(.fat_arrow);
            self.skipOnlyNewlines();
            const body = if (self.match(.lbrace))
                self.parseBlock()
            else if (self.match(.kw_return) or self.match(.kw_break) or self.match(.kw_continue) or
                self.match(.kw_unreachable) or self.match(.kw_defer) or self.match(.kw_if) or
                self.match(.kw_while) or self.match(.kw_loop) or self.match(.kw_for) or self.match(.kw_let) or self.match(.kw_var))
                self.parseSingleStatement()
            else
                self.parseExpr();

            if (is_wildcard) {
                default_body = body;
            } else {
                const arm = self.newNode(.match_arm, arm_tok.line);
                self.ast.nodes[arm].col = arm_tok.col;
                self.ast.nodes[arm].child0 = pat_head;
                self.ast.nodes[arm].child1 = body;
                self.ast.nodes[arm].extra = guard_expr;
                if (first_arm == 0) {
                    first_arm = arm;
                } else {
                    self.ast.nodes[last_arm].child2 = arm;
                }
                last_arm = arm;
            }
            if (self.match(.comma)) _ = self.advance();
            self.skipNewlines();
            if (self.pos == loop_pos) _ = self.advance();
        }
        _ = self.expect(.rbrace);

        const mn = self.newNode(.match_expr, mtok.line);
        self.ast.nodes[mn].col = mtok.col;
        self.ast.nodes[mn].child0 = scrutinee;
        self.ast.nodes[mn].child1 = first_arm;
        self.ast.nodes[mn].child2 = default_body;
        return mn;
    }

    fn parseFloatLiteralToken(self: *Parser, tok: Token) f64 {
        const txt = self.lex.text(tok);
        var cleaned: [128]u8 = undefined;
        var clen: usize = 0;
        var malformed = txt.len == 0;
        for (txt, 0..) |c, i| {
            if (c == '_') {
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
        if (clen == 0 or malformed) {
            self.reportErr(tok, "invalid float literal '{s}'", .{txt});
            return 0.0;
        }
        return std.fmt.parseFloat(f64, cleaned[0..clen]) catch {
            self.reportErr(tok, "invalid float literal '{s}'", .{txt});
            return 0.0;
        };
    }

    fn parseStringLiteralOrInterp(self: *Parser, tok: Token) u32 {
        const inner_start = tok.start + 1;
        const inner_len = if (tok.len >= 2) tok.len - 2 else 0;
        const raw = if (@as(usize, inner_start) + inner_len <= self.src.len)
            self.src[inner_start..][0..inner_len]
        else
            "";

        // Fast path: check for unescaped '{' with matching '}'
        var has_interp = false;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\') {
                i += 1;
                continue;
            }
            if (raw[i] == '{') {
                // Find matching '}'
                var j = i + 1;
                var bdepth: u32 = 1;
                while (j < raw.len and bdepth > 0) : (j += 1) {
                    if (raw[j] == '\\') {
                        j += 1;
                        continue;
                    }
                    if (raw[j] == '{') bdepth += 1 else if (raw[j] == '}') bdepth -= 1;
                }
                if (bdepth == 0) {
                    has_interp = true;
                    break;
                }
            }
        }
        if (!has_interp) {
            const n = self.newNode(.string_literal, tok.line);
            self.ast.nodes[n].col = tok.col;
            self.ast.nodes[n].text_start = inner_start;
            self.ast.nodes[n].text_len = inner_len;
            return n;
        }

        const interp = self.newNode(.interp_string, tok.line);
        self.ast.nodes[interp].col = tok.col;
        var seg_head: u32 = 0;
        var seg_tail: u32 = 0;
        var cur_start: usize = 0;
        i = 0;
        while (i < raw.len) {
            if (raw[i] == '\\') {
                i += 2;
                continue;
            }
            if (raw[i] == '{') {
                var j = i + 1;
                var bdepth: u32 = 1;
                while (j < raw.len and bdepth > 0) : (j += 1) {
                    if (raw[j] == '\\') {
                        j += 1;
                        continue;
                    }
                    if (raw[j] == '{') bdepth += 1 else if (raw[j] == '}') bdepth -= 1;
                }
                if (bdepth == 0) {
                    const expr_raw = std.mem.trim(u8, raw[i + 1 .. j - 1], " \t\r\n");
                    var is_valid_interp = false;
                    var en: u32 = 0;
                    if (expr_raw.len > 0 and expr_raw[0] != '\\' and expr_raw[0] != ':' and expr_raw[0] != '"') {
                        const expr_sp = self.ast.addSynthText(expr_raw);
                        const expr_slice = self.ast.sources[SYNTH_SOURCE_ID][expr_sp.start..][0..expr_sp.len];
                        if (std.heap.page_allocator.create(Lexer)) |sub_lex| {
                            defer std.heap.page_allocator.destroy(sub_lex);
                            sub_lex.* = Lexer.init(expr_slice);
                            sub_lex.tokenize();
                            if (!sub_lex.invalid and sub_lex.token_count > 0) {
                                var temp_diag = diag_mod.DiagList.init();
                                var sub_p = Parser{
                                    .lex = sub_lex,
                                    .pos = 0,
                                    .ast = self.ast,
                                    .src = self.ast.sources[SYNTH_SOURCE_ID],
                                    .source_id = SYNTH_SOURCE_ID,
                                    .diag = &temp_diag,
                                };
                                for (0..sub_lex.token_count) |ti| {
                                    sub_lex.tokens[ti].start += expr_sp.start;
                                }
                                sub_lex.src = self.ast.sources[SYNTH_SOURCE_ID];
                                const saved_ast_count = self.ast.count;
                                en = sub_p.parseExpr();
                                if (!sub_p.invalid_syntax and temp_diag.error_count == 0 and (sub_p.match(.eof) or sub_p.pos >= sub_lex.token_count - 1)) {
                                    is_valid_interp = true;
                                } else {
                                    self.ast.count = saved_ast_count;
                                }
                            }
                        } else |_| {}
                    }
                    if (is_valid_interp) {
                        if (i > cur_start) {
                            const lit_sp = self.ast.addSynthText(raw[cur_start..i]);
                            const sn = self.newNode(.string_literal, tok.line);
                            self.ast.nodes[sn].col = tok.col;
                            self.ast.nodes[sn].source_id = lit_sp.source_id;
                            self.ast.nodes[sn].text_start = lit_sp.start;
                            self.ast.nodes[sn].text_len = lit_sp.len;
                            if (seg_head == 0) seg_head = sn else self.ast.stmt_chains[seg_tail] = sn;
                            seg_tail = sn;
                        }
                        if (seg_head == 0) seg_head = en else self.ast.stmt_chains[seg_tail] = en;
                        seg_tail = en;
                        i = j;
                        cur_start = j;
                        continue;
                    }
                }
            }
            i += 1;
        }
        if (seg_head == 0) {
            const n = self.newNode(.string_literal, tok.line);
            self.ast.nodes[n].col = tok.col;
            self.ast.nodes[n].text_start = inner_start;
            self.ast.nodes[n].text_len = inner_len;
            return n;
        }
        if (cur_start < raw.len) {
            const lit_sp = self.ast.addSynthText(raw[cur_start..]);
            const sn = self.newNode(.string_literal, tok.line);
            self.ast.nodes[sn].col = tok.col;
            self.ast.nodes[sn].source_id = lit_sp.source_id;
            self.ast.nodes[sn].text_start = lit_sp.start;
            self.ast.nodes[sn].text_len = lit_sp.len;
            if (seg_head == 0) seg_head = sn else self.ast.stmt_chains[seg_tail] = sn;
            seg_tail = sn;
        }
        self.ast.nodes[interp].child0 = seg_head;
        return interp;
    }

    fn parseClosureExpr(self: *Parser) u32 {
        const start_tok = self.peek();
        var first_param: u32 = 0;
        var last_param: u32 = 0;
        var param_count: i64 = 0;

        if (self.match(.pipe_pipe)) {
            _ = self.advance();
        } else {
            _ = self.expect(.pipe);
            while (!self.match(.pipe) and !self.match(.eof)) {
                if (param_count > 0) _ = self.expect(.comma);
                if (self.match(.pipe)) break;
                const pt = self.expect(.identifier);
                var ptype: ParsedType = .{ .tag = .none };
                if (self.match(.colon)) {
                    _ = self.advance();
                    ptype = self.parseTypeSpec(false);
                }
                const pn = self.newNode(.identifier, pt.line);
                self.ast.nodes[pn].col = pt.col;
                self.ast.nodes[pn].text_start = pt.start;
                self.ast.nodes[pn].text_len = pt.len;
                self.ast.nodes[pn].type_tag = ptype.tag;
                self.ast.nodes[pn].elem_type = ptype.elem_type;
                self.ast.nodes[pn].child0 = ptype.extra;
                if (first_param == 0) first_param = pn else self.ast.nodes[last_param].child1 = pn;
                last_param = pn;
                param_count += 1;
            }
            _ = self.expect(.pipe);
        }

        var ret_type: ParsedType = .{ .tag = .none };
        if (self.match(.arrow)) {
            _ = self.advance();
            ret_type = self.parseTypeSpec(true);
        }
        self.skipOnlyNewlines();
        var body: u32 = 0;
        if (self.match(.lbrace)) {
            body = self.parseBlock();
        } else {
            const expr = self.parseExpr();
            const ret = self.newNode(.return_stmt, start_tok.line);
            self.ast.nodes[ret].child0 = expr;
            const blk = self.newNode(.block, start_tok.line);
            self.ast.nodes[blk].child0 = ret;
            body = blk;
        }
        const cn = self.newNode(.closure_expr, start_tok.line);
        self.ast.nodes[cn].col = start_tok.col;
        self.ast.nodes[cn].child0 = first_param;
        self.ast.nodes[cn].child1 = ret_type.extra;
        self.ast.nodes[cn].child2 = body;
        self.ast.nodes[cn].int_val = param_count;
        self.ast.nodes[cn].type_tag = ret_type.tag;
        self.ast.nodes[cn].elem_type = ret_type.elem_type;
        return cn;
    }

    fn looksLikeGenericExprArgs(self: *const Parser) bool {
        var look = self.pos;
        if (self.lex.get(look).kind == .colon_colon and self.lex.get(look + 1).kind == .lt) {
            look += 1;
        }
        if (self.lex.get(look).kind != .lt) return false;
        look += 1;
        var depth: i32 = 1;
        var steps: u32 = 0;
        while (depth > 0 and steps < 32) : (steps += 1) {
            const t = self.lex.get(look);
            switch (t.kind) {
                .eof, .newline, .semicolon, .lbrace, .rbrace => return false,
                .lt => depth += 1,
                .gt => depth -= 1,
                else => {},
            }
            look += 1;
        }
        if (depth != 0) return false;
        const after = self.lex.get(look).kind;
        return after == .lparen or after == .lbrace or after == .colon_colon;
    }

    fn parsePrimary(self: *Parser) u32 {
        const tok = self.peek();

        if (self.match(.kw_match)) {
            return self.parseMatch();
        }

        if (self.match(.pipe) or self.match(.pipe_pipe)) {
            return self.parsePostfix(self.parseClosureExpr());
        }

        if (self.match(.kw_spawn)) {
            const st = self.advance();
            self.skipOnlyNewlines();
            var target: u32 = 0;
            if (self.match(.lbrace)) {
                const blk = self.parseBlock();
                const cl = self.newNode(.closure_expr, st.line);
                self.ast.nodes[cl].child2 = blk;
                target = cl;
            } else {
                target = self.parseExpr();
            }
            const sn = self.newNode(.spawn_expr, st.line);
            self.ast.nodes[sn].col = st.col;
            self.ast.nodes[sn].child0 = target;
            return self.parsePostfix(sn);
        }

        if (self.match(.kw_comptime)) {
            const ct = self.advance();
            self.skipOnlyNewlines();
            const inner = if (self.match(.lbrace)) self.parseBlock() else self.parseExpr();
            const cn = self.newNode(.comptime_expr, ct.line);
            self.ast.nodes[cn].col = ct.col;
            self.ast.nodes[cn].child0 = inner;
            return self.parsePostfix(cn);
        }

        if (self.match(.int_literal)) {
            _ = self.advance();
            const n = self.newNode(.int_literal, tok.line);
            self.ast.nodes[n].col = tok.col;
            self.ast.nodes[n].int_val = self.parseIntLiteralToken(tok);
            return n;
        }

        if (self.match(.char_literal)) {
            _ = self.advance();
            const n = self.newNode(.int_literal, tok.line);
            self.ast.nodes[n].col = tok.col;
            self.ast.nodes[n].int_val = self.parseCharLiteralToken(tok);
            return n;
        }

        if (self.match(.float_literal)) {
            _ = self.advance();
            const fval = self.parseFloatLiteralToken(tok);
            const n = self.newNode(.float_literal, tok.line);
            self.ast.nodes[n].col = tok.col;
            self.ast.nodes[n].int_val = @bitCast(fval);
            self.ast.nodes[n].type_tag = .f64;
            return n;
        }

        if (self.match(.string_literal)) {
            _ = self.advance();
            return self.parseStringLiteralOrInterp(tok);
        }

        if (self.match(.kw_true)) {
            _ = self.advance();
            const n = self.newNode(.int_literal, tok.line);
            self.ast.nodes[n].col = tok.col;
            self.ast.nodes[n].int_val = 1;
            self.ast.nodes[n].flags = 1;
            return n;
        }

        if (self.match(.kw_false) or self.match(.kw_null)) {
            const lit_tok = self.advance();
            const n = self.newNode(.int_literal, lit_tok.line);
            self.ast.nodes[n].col = lit_tok.col;
            self.ast.nodes[n].int_val = 0;
            self.ast.nodes[n].flags = if (lit_tok.kind == .kw_false) 1 else 2;
            return n;
        }

        if (self.match(.hash) and self.lex.get(self.pos + 1).kind == .lbrace) {
            const ht = self.advance();
            _ = self.advance(); // '{'
            self.skipOnlyNewlines();
            var first_pair: u32 = 0;
            var last_pair: u32 = 0;
            var pcount: i64 = 0;
            while (!self.match(.rbrace) and !self.match(.eof)) {
                const loop_pos = self.pos;
                self.skipOnlyNewlines();
                if (self.match(.rbrace)) break;
                if (first_pair != 0) {
                    if (self.match(.comma)) _ = self.advance();
                    self.skipOnlyNewlines();
                    if (self.match(.rbrace)) break;
                }
                const k = self.parseExpr();
                _ = self.expect(.colon);
                const v = self.parseExpr();
                const pair = self.newNode(.expr_stmt, ht.line);
                self.ast.nodes[pair].child0 = k;
                self.ast.nodes[pair].child2 = v;
                if (first_pair == 0) first_pair = pair else self.ast.nodes[last_pair].child1 = pair;
                last_pair = pair;
                pcount += 1;
                self.skipOnlyNewlines();
                if (self.pos == loop_pos) _ = self.advance();
            }
            _ = self.expect(.rbrace);
            const mn = self.newNode(.map_lit, ht.line);
            self.ast.nodes[mn].col = ht.col;
            self.ast.nodes[mn].child0 = first_pair;
            self.ast.nodes[mn].int_val = pcount;
            return self.parsePostfix(mn);
        }

        if (self.match(.lbracket)) {
            const lb = self.advance();
            self.skipOnlyNewlines();
            if (!self.match(.rbracket)) {
                const elem0 = self.parseExpr();
                if (self.match(.kw_for)) {
                    _ = self.advance();
                    const vtok = self.expect(.identifier);
                    _ = self.expect(.kw_in);
                    const saved_c = self.in_cond_header;
                    self.in_cond_header = true;
                    const iter0 = self.parseExpr();
                    var iter1: u32 = 0;
                    var comp_flags: u8 = 0;
                    if (self.match(.dot_dot) or self.match(.dot_dot_eq)) {
                        comp_flags = 2 | (if (self.match(.dot_dot_eq)) @as(u8, 1) else 0);
                        _ = self.advance();
                        iter1 = self.parseExpr();
                    }
                    var pred: u32 = 0;
                    if (self.match(.kw_if)) {
                        _ = self.advance();
                        pred = self.parseExpr();
                    }
                    self.in_cond_header = saved_c;
                    self.skipOnlyNewlines();
                    _ = self.expect(.rbracket);
                    const lc = self.newNode(.list_comp, lb.line);
                    self.ast.nodes[lc].col = lb.col;
                    self.ast.nodes[lc].text_start = vtok.start;
                    self.ast.nodes[lc].text_len = vtok.len;
                    self.ast.nodes[lc].child0 = elem0;
                    self.ast.nodes[lc].child1 = iter0;
                    self.ast.nodes[lc].extra = iter1;
                    self.ast.nodes[lc].child2 = pred;
                    self.ast.nodes[lc].flags = comp_flags;
                    return self.parsePostfix(lc);
                }
                if (self.match(.semicolon)) {
                    _ = self.advance();
                    self.skipOnlyNewlines();
                    const count_expr = self.parseExpr();
                    self.skipOnlyNewlines();
                    _ = self.expect(.rbracket);
                    const an = self.newNode(.array_lit, lb.line);
                    self.ast.nodes[an].col = lb.col;
                    self.ast.nodes[an].child0 = elem0;
                    self.ast.nodes[an].child1 = count_expr;
                    self.ast.nodes[an].flags = 1;
                    return self.parsePostfix(an);
                }
                const first_elem = self.newNode(.expr_stmt, lb.line);
                self.ast.nodes[first_elem].child0 = elem0;
                var last_elem = first_elem;
                var elem_count: i64 = 1;
                self.skipOnlyNewlines();
                while (!self.match(.rbracket) and !self.match(.eof)) {
                    const loop_pos = self.pos;
                    _ = self.expect(.comma);
                    self.skipOnlyNewlines();
                    if (self.match(.rbracket)) break;
                    const elem = self.parseExpr();
                    const wrap = self.newNode(.expr_stmt, lb.line);
                    self.ast.nodes[wrap].child0 = elem;
                    self.ast.nodes[last_elem].child1 = wrap;
                    last_elem = wrap;
                    elem_count += 1;
                    self.skipOnlyNewlines();
                    if (self.pos == loop_pos) _ = self.advance();
                }
                _ = self.expect(.rbracket);
                const an = self.newNode(.array_lit, lb.line);
                self.ast.nodes[an].col = lb.col;
                self.ast.nodes[an].child0 = first_elem;
                self.ast.nodes[an].int_val = elem_count;
                return self.parsePostfix(an);
            }
            _ = self.expect(.rbracket);
            const an = self.newNode(.array_lit, lb.line);
            self.ast.nodes[an].col = lb.col;
            self.ast.nodes[an].int_val = 0;
            return self.parsePostfix(an);
        }

        if (self.match(.lparen)) {
            const lp = self.advance();
            if (self.match(.rparen)) {
                _ = self.advance();
                const un = self.newNode(.int_literal, lp.line);
                self.ast.nodes[un].int_val = 0;
                return self.parsePostfix(un);
            }
            const saved_cond = self.in_cond_header;
            self.in_cond_header = false;
            const e0 = if (self.in_match_pattern) self.parsePatternElement() else self.parseExpr();
            if (self.match(.comma)) {
                const first_elem = self.newNode(.expr_stmt, lp.line);
                self.ast.nodes[first_elem].child0 = e0;
                var last_elem = first_elem;
                var count: i64 = 1;
                while (self.match(.comma)) {
                    _ = self.advance();
                    self.skipOnlyNewlines();
                    if (self.match(.rparen)) break;
                    const en = if (self.in_match_pattern) self.parsePatternElement() else self.parseExpr();
                    const wrap = self.newNode(.expr_stmt, lp.line);
                    self.ast.nodes[wrap].child0 = en;
                    self.ast.nodes[last_elem].child1 = wrap;
                    last_elem = wrap;
                    count += 1;
                }
                self.in_cond_header = saved_cond;
                _ = self.expect(.rparen);
                const tn = self.newNode(.tuple_lit, lp.line);
                self.ast.nodes[tn].col = lp.col;
                self.ast.nodes[tn].child0 = first_elem;
                self.ast.nodes[tn].int_val = count;
                return self.parsePostfix(tn);
            }
            self.in_cond_header = saved_cond;
            _ = self.expect(.rparen);
            if (e0 == 0) return 0;
            return self.parsePostfix(e0);
        }

        if (self.match(.at)) {
            const at_tok = self.advance();
            const name_tok = self.expect(.identifier);
            const full_name_start = at_tok.start;
            const full_name_len = name_tok.start + name_tok.len - at_tok.start;
            const bname = self.src[full_name_start..][0..full_name_len];
            const n = self.newNode(.identifier, at_tok.line);
            self.ast.nodes[n].col = at_tok.col;
            self.ast.nodes[n].text_start = full_name_start;
            self.ast.nodes[n].text_len = full_name_len;
            if (self.match(.lparen)) {
                if (std.mem.eql(u8, bname, "@size_of") or std.mem.eql(u8, bname, "@align_of") or std.mem.eql(u8, bname, "@type_name")) {
                    _ = self.advance(); // '('
                    const ty = self.parseTypeSpec(true);
                    _ = self.expect(.rparen);
                    const td = self.ast.addTypeDesc(.{
                        .kind = ty.tag,
                        .ret_tag = ty.tag,
                        .ret_extra = ty.extra,
                        .ret_elem = ty.elem_type,
                    });
                    const cn = self.newNode(.call_expr, at_tok.line);
                    self.ast.nodes[cn].col = at_tok.col;
                    self.ast.nodes[cn].child0 = n;
                    self.ast.nodes[cn].extra = td;
                    self.ast.nodes[cn].flags = 64; // type-arg intrinsic
                    return self.parsePostfix(cn);
                }
                const first_arg = self.parseCallArgs(at_tok.line);
                const cn = self.newNode(.call_expr, at_tok.line);
                self.ast.nodes[cn].col = at_tok.col;
                self.ast.nodes[cn].child0 = n;
                self.ast.nodes[cn].child2 = first_arg;
                return self.parsePostfix(cn);
            }
            return n;
        }

        if (self.match(.identifier) or self.match(.kw_self) or (self.match(.kw_string) and self.lex.get(self.pos + 1).kind == .lbrace)) {
            _ = self.advance();
            var result = self.newNode(.identifier, tok.line);
            self.ast.nodes[result].col = tok.col;
            self.ast.nodes[result].text_start = tok.start;
            self.ast.nodes[result].text_len = tok.len;

            var gen_td: u32 = 0;
            if (self.looksLikeGenericExprArgs()) {
                if (self.match(.colon_colon)) _ = self.advance();
                _ = self.expect(.lt);
                var desc = TypeDesc{
                    .kind = .generic_inst,
                    .base_name = .{ .start = tok.start, .len = tok.len, .source_id = self.source_id },
                };
                while (!self.match(.gt) and !self.match(.eof)) {
                    const ta = self.parseTypeSpec(false);
                    if (desc.param_count < 8) {
                        const ti = desc.param_count;
                        desc.param_tags[ti] = ta.tag;
                        desc.param_extras[ti] = ta.extra;
                        desc.param_elems[ti] = ta.elem_type;
                        desc.param_count += 1;
                    }
                    if (self.match(.comma)) _ = self.advance() else break;
                }
                _ = self.expect(.gt);
                gen_td = self.ast.addTypeDesc(desc);
                if (self.match(.colon_colon)) {
                    self.ast.nodes[result].extra = gen_td;
                    self.ast.nodes[result].flags |= 32;
                }
            }

            if (self.match(.lparen)) {
                const first_arg = self.parseCallArgs(tok.line);
                const cn = self.newNode(.call_expr, tok.line);
                self.ast.nodes[cn].col = tok.col;
                self.ast.nodes[cn].child0 = result;
                self.ast.nodes[cn].child2 = first_arg;
                if (gen_td != 0) {
                    self.ast.nodes[cn].extra = gen_td;
                    self.ast.nodes[cn].flags |= 32;
                }
                result = cn;
            } else if (self.match(.lbrace) and (gen_td != 0 or self.looksLikeStructInit())) {
                _ = self.advance();
                self.skipOnlyNewlines();
                var first_field: u32 = 0;
                var last_field: u32 = 0;
                while (!self.match(.rbrace) and !self.match(.eof)) {
                    const loop_pos = self.pos;
                    self.skipOnlyNewlines();
                    if (self.match(.rbrace)) break;
                    if (first_field != 0) {
                        if (self.match(.comma)) _ = self.advance();
                        self.skipOnlyNewlines();
                        if (self.match(.rbrace)) break;
                    }
                    const fname = self.expect(.identifier);
                    _ = self.expect(.colon);
                    const fval = self.parseExpr();
                    const finit = self.newNode(.expr_stmt, fname.line);
                    self.ast.nodes[finit].col = fname.col;
                    self.ast.nodes[finit].text_start = fname.start;
                    self.ast.nodes[finit].text_len = fname.len;
                    self.ast.nodes[finit].child0 = fval;
                    if (first_field == 0) {
                        first_field = finit;
                    } else {
                        self.ast.nodes[last_field].child1 = finit;
                    }
                    last_field = finit;
                    self.skipOnlyNewlines();
                    if (self.pos == loop_pos) _ = self.advance();
                }
                _ = self.expect(.rbrace);
                const sn = self.newNode(.struct_init, tok.line);
                self.ast.nodes[sn].col = tok.col;
                self.ast.nodes[sn].text_start = tok.start;
                self.ast.nodes[sn].text_len = tok.len;
                self.ast.nodes[sn].child2 = first_field;
                if (gen_td != 0) {
                    self.ast.nodes[sn].extra = gen_td;
                    self.ast.nodes[sn].flags |= 32;
                }
                result = sn;
            }
            return self.parsePostfix(result);
        }

        if (self.match(.kw_if)) {
            return self.parsePostfix(self.parseIf());
        }

        if (self.match(.kw_panic)) {
            const ptok = self.advance();
            const msg_expr = if (self.match(.lparen)) blk: {
                _ = self.advance();
                self.skipOnlyNewlines();
                const e = self.parseExpr();
                self.skipOnlyNewlines();
                _ = self.expect(.rparen);
                break :blk e;
            } else self.parseExpr();
            const fn_sp = self.ast.addSynthText("@panic");
            const fn_id = self.newNode(.identifier, ptok.line);
            self.ast.nodes[fn_id].col = ptok.col;
            self.ast.nodes[fn_id].source_id = fn_sp.source_id;
            self.ast.nodes[fn_id].text_start = fn_sp.start;
            self.ast.nodes[fn_id].text_len = fn_sp.len;
            const arg_wrap = self.newNode(.expr_stmt, ptok.line);
            self.ast.nodes[arg_wrap].child0 = msg_expr;
            const cn = self.newNode(.call_expr, ptok.line);
            self.ast.nodes[cn].col = ptok.col;
            self.ast.nodes[cn].child0 = fn_id;
            self.ast.nodes[cn].child2 = arg_wrap;
            return cn;
        }

        if (self.match(.kw_try) or
            self.match(.kw_volatile) or self.match(.kw_asm) or self.match(.kw_unsafe))
        {
            self.reportErr(tok, "unsupported expression '{s}'", .{@tagName(tok.kind)});
        } else {
            self.reportErr(tok, "unexpected token '{s}' ({s})", .{ self.lex.text(tok), @tagName(tok.kind) });
        }
        _ = self.advance();
        return self.newNode(.identifier, tok.line);
    }

    fn parseIf(self: *Parser) u32 {
        const tok = self.expect(.kw_if);
        self.skipOnlyNewlines();
        const saved = self.in_cond_header;
        self.in_cond_header = true;
        const cond = self.parseExpr();
        self.in_cond_header = saved;
        self.skipOnlyNewlines();
        const then_b = self.parseBlock();
        var else_b: u32 = 0;
        self.skipOnlyNewlines();
        if (self.match(.kw_else) or self.match(.kw_elif)) {
            else_b = self.parseElseTail(tok.line);
        }
        const n = self.newNode(.if_stmt, tok.line);
        self.ast.nodes[n].col = tok.col;
        self.ast.nodes[n].child0 = cond;
        self.ast.nodes[n].child1 = then_b;
        self.ast.nodes[n].child2 = else_b;
        return n;
    }

    fn parseElseTail(self: *Parser, line: u32) u32 {
        const is_elif = self.match(.kw_elif);
        _ = self.advance();
        self.skipOnlyNewlines();
        if (!is_elif and self.match(.kw_if)) return self.parseIf();
        if (is_elif) {
            const saved = self.in_cond_header;
            self.in_cond_header = true;
            const cond = self.parseExpr();
            self.in_cond_header = saved;
            self.skipOnlyNewlines();
            const body = self.parseBlock();
            const n = self.newNode(.if_stmt, line);
            self.ast.nodes[n].child0 = cond;
            self.ast.nodes[n].child1 = body;
            self.skipOnlyNewlines();
            if (self.match(.kw_else) or self.match(.kw_elif)) {
                self.ast.nodes[n].child2 = self.parseElseTail(line);
            }
            return n;
        }
        return self.parseBlock();
    }

    fn parseWhile(self: *Parser) u32 {
        const tok = self.expect(.kw_while);
        self.skipOnlyNewlines();
        const saved = self.in_cond_header;
        self.in_cond_header = true;
        const cond = self.parseExpr();
        self.in_cond_header = saved;
        self.skipOnlyNewlines();
        const body = self.parseBlock();
        const n = self.newNode(.while_stmt, tok.line);
        self.ast.nodes[n].col = tok.col;
        self.ast.nodes[n].child0 = cond;
        self.ast.nodes[n].child1 = body;
        return n;
    }

    fn parseStructDecl(self: *Parser) u32 {
        const tok = self.expect(.kw_struct);
        const name_tok = self.expect(.identifier);
        const saved_gen = self.active_gen_count;
        const saved_params = self.active_gen_params;
        self.pushGenParams(true);
        defer {
            self.active_gen_count = saved_gen;
            self.active_gen_params = saved_params;
        }
        self.skipOnlyNewlines();
        _ = self.expect(.lbrace);
        self.skipNewlines();

        if (@as(usize, self.ast.struct_count) >= self.ast.struct_defs.len) {
            self.ast.overflowed = true;
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
            .line = name_tok.line,
            .source_id = self.source_id,
            .fields = undefined,
            .field_count = 0,
            .total_size = 0,
            .is_generic = self.active_gen_count > 0,
            .generic_params = self.active_gen_params,
            .generic_param_count = self.active_gen_count,
        };
        var field_offset: u32 = 0;

        while (!self.match(.rbrace) and !self.match(.eof)) {
            const loop_pos = self.pos;
            self.skipNewlines();
            if (self.match(.rbrace) or self.match(.eof)) break;

            if (self.match(.kw_pub)) {
                _ = self.advance();
                continue;
            }
            if (self.match(.kw_fn)) {
                _ = self.parseFnDecl(si + 1);
                self.skipNewlines();
                if (self.pos == loop_pos) _ = self.advance();
                continue;
            }

            const field_name = self.expect(.identifier);
            _ = self.expect(.colon);
            const ftype = self.parseTypeSpec(false);
            const had_comma = self.match(.comma);
            if (had_comma) _ = self.advance();
            if (!had_comma and !self.match(.newline) and !self.match(.semicolon) and !self.match(.rbrace) and !self.match(.eof)) {
                self.reportErr(self.peek(), "unsupported struct field type syntax", .{});
                while (!self.match(.newline) and !self.match(.semicolon) and !self.match(.rbrace) and !self.match(.eof)) _ = self.advance();
            }
            self.skipNewlines();

            const sd = &self.ast.struct_defs[si];
            if (@as(usize, sd.field_count) >= sd.fields.len) {
                self.ast.overflowed = true;
            } else {
                sd.fields[sd.field_count] = .{
                    .name_start = field_name.start,
                    .name_len = field_name.len,
                    .offset = field_offset,
                    .type_tag = ftype.tag,
                    .extra = ftype.extra,
                    .elem_type = ftype.elem_type,
                };
                sd.field_count += 1;
            }
            // Keep 8-byte aligned slots (fixed arrays occupy N*8 unless symbolic)
            const fa_len: u32 = if (ftype.tag == .fixed_array and (ftype.extra & 0x80000000) == 0) @max(ftype.extra, 1) else 1;
            field_offset += if (ftype.tag == .fixed_array) fa_len * 8 else 8;
            if (self.pos == loop_pos) _ = self.advance();
        }
        self.ast.struct_defs[si].total_size = field_offset;
        _ = self.expect(.rbrace);

        const node = self.newNode(.struct_decl, tok.line);
        self.ast.nodes[node].col = tok.col;
        self.ast.nodes[node].text_start = name_tok.start;
        self.ast.nodes[node].text_len = name_tok.len;
        self.ast.nodes[node].int_val = @intCast(si);
        if (self.active_gen_count > 0 and @as(usize, self.ast.generic_count) < self.ast.generics.len) {
            self.ast.generics[self.ast.generic_count] = .{
                .kind = .struct_t,
                .node_or_def_idx = si,
                .name = .{ .start = name_tok.start, .len = name_tok.len, .source_id = self.source_id },
                .params = self.active_gen_params,
                .param_count = self.active_gen_count,
            };
            self.ast.generic_count += 1;
        }
        return node;
    }

    fn parsePostfix(self: *Parser, base: u32) u32 {
        if (base == 0) return 0;
        var result = base;
        while (self.match(.dot) or self.match(.lbracket) or self.match(.colon_colon) or
            self.match(.lparen) or (self.match(.question) and !self.isTernaryAtQuestion()))
        {
            if (self.match(.question)) {
                const qt = self.advance();
                const tn = self.newNode(.try_expr, qt.line);
                self.ast.nodes[tn].col = qt.col;
                self.ast.nodes[tn].child0 = result;
                result = tn;
            } else if (self.match(.lparen)) {
                const pt = self.peek();
                const args = self.parseCallArgs(pt.line);
                const cn = self.newNode(.call_expr, pt.line);
                self.ast.nodes[cn].col = pt.col;
                self.ast.nodes[cn].child0 = result;
                self.ast.nodes[cn].child2 = args;
                result = cn;
            } else if (self.match(.lbracket)) {
                const lb = self.advance();
                const idx_expr = self.parseExpr();
                _ = self.expect(.rbracket);
                const n = self.newNode(.index_expr, lb.line);
                self.ast.nodes[n].col = lb.col;
                self.ast.nodes[n].child0 = result;
                self.ast.nodes[n].child1 = idx_expr;
                result = n;
            } else if (self.match(.colon_colon)) {
                _ = self.advance();
                const member = self.expect(.identifier);
                if (self.match(.lparen)) {
                    const args = self.parseCallArgs(member.line);
                    const mn = self.newNode(.scoped_access, member.line);
                    self.ast.nodes[mn].col = member.col;
                    self.ast.nodes[mn].child0 = result;
                    self.ast.nodes[mn].child2 = args;
                    self.ast.nodes[mn].flags = 1; // call form Type::fn(...)
                    self.ast.nodes[mn].text_start = member.start;
                    self.ast.nodes[mn].text_len = member.len;
                    result = mn;
                } else {
                    const sn = self.newNode(.scoped_access, member.line);
                    self.ast.nodes[sn].col = member.col;
                    self.ast.nodes[sn].child0 = result;
                    self.ast.nodes[sn].text_start = member.start;
                    self.ast.nodes[sn].text_len = member.len;
                    result = sn;
                }
            } else {
                _ = self.advance(); // '.'
                if (self.match(.int_literal)) {
                    const itok = self.advance();
                    const idx_val = self.parseIntLiteralToken(itok);
                    const n = self.newNode(.field_access, itok.line);
                    self.ast.nodes[n].col = itok.col;
                    self.ast.nodes[n].child0 = result;
                    self.ast.nodes[n].int_val = idx_val;
                    self.ast.nodes[n].flags = 1; // tuple index field
                    result = n;
                } else if (self.match(.float_literal)) {
                    // Handles chained tuple field e.g. t.0.1
                    const ftok = self.advance();
                    const txt = self.lex.text(ftok);
                    if (std.mem.indexOfScalar(u8, txt, '.')) |dot_pos| {
                        const idx0 = std.fmt.parseInt(i64, txt[0..dot_pos], 10) catch 0;
                        const idx1 = std.fmt.parseInt(i64, txt[dot_pos + 1 ..], 10) catch 0;
                        const n0 = self.newNode(.field_access, ftok.line);
                        self.ast.nodes[n0].col = ftok.col;
                        self.ast.nodes[n0].child0 = result;
                        self.ast.nodes[n0].int_val = idx0;
                        self.ast.nodes[n0].flags = 1;
                        const n1 = self.newNode(.field_access, ftok.line);
                        self.ast.nodes[n1].col = ftok.col;
                        self.ast.nodes[n1].child0 = n0;
                        self.ast.nodes[n1].int_val = idx1;
                        self.ast.nodes[n1].flags = 1;
                        result = n1;
                    }
                } else {
                    const field_name = self.expect(.identifier);
                    if (self.match(.lparen)) {
                        const args = self.parseCallArgs(field_name.line);
                        const mn = self.newNode(.method_call, field_name.line);
                        self.ast.nodes[mn].col = field_name.col;
                        self.ast.nodes[mn].child0 = result;
                        self.ast.nodes[mn].child2 = args;
                        self.ast.nodes[mn].text_start = field_name.start;
                        self.ast.nodes[mn].text_len = field_name.len;
                        result = mn;
                    } else {
                        const n = self.newNode(.field_access, field_name.line);
                        self.ast.nodes[n].col = field_name.col;
                        self.ast.nodes[n].child0 = result;
                        self.ast.nodes[n].text_start = field_name.start;
                        self.ast.nodes[n].text_len = field_name.len;
                        result = n;
                    }
                }
            }
        }
        return result;
    }

    fn parseFor(self: *Parser) u32 {
        const for_tok = self.advance();
        const var_tok = self.expect(.identifier);
        _ = self.expect(.kw_in);
        const saved = self.in_cond_header;
        self.in_cond_header = true;
        const first = self.parseExpr();
        var is_range: i64 = 0;
        var second: u32 = 0;
        var inclusive: u8 = 0;
        if (self.match(.dot_dot) or self.match(.dot_dot_eq)) {
            inclusive = if (self.match(.dot_dot_eq)) 1 else 0;
            _ = self.advance();
            second = self.parseExpr();
            is_range = 1;
        }
        self.in_cond_header = saved;
        self.skipOnlyNewlines();
        const body = self.parseBlock();
        const n = self.newNode(.for_stmt, var_tok.line);
        self.ast.nodes[n].col = for_tok.col;
        self.ast.nodes[n].text_start = var_tok.start;
        self.ast.nodes[n].text_len = var_tok.len;
        self.ast.nodes[n].child0 = first;
        self.ast.nodes[n].child1 = body;
        self.ast.nodes[n].child2 = second;
        self.ast.nodes[n].int_val = is_range;
        self.ast.nodes[n].flags = inclusive;
        return n;
    }
};
