// ════════════════════════════════════════════════════════════════════════════
// EXPAND — Pre-sema AST expansion:
//   1. Standard Option<T> & Result<T, E> ADT injection
//   2. Comptime expression & comptime fn evaluation + [CONST_EXPR]T sizing
//   3. Generics monomorphization (structs, enums, methods, functions)
//   4. @size_of / @align_of / @type_name resolution
//   5. #[test] runner synthesis when in test_mode
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const lex = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const diag_mod = @import("diag.zig");

const TokenKind = lex.TokenKind;
const AST = parser_mod.AST;
const ASTNode = parser_mod.ASTNode;
const NodeKind = parser_mod.NodeKind;
const TypeTag = parser_mod.TypeTag;
const ParsedType = parser_mod.ParsedType;
const TextSpan = parser_mod.TextSpan;
const GenericTemplate = parser_mod.GenericTemplate;
const SYNTH_SOURCE_ID = parser_mod.SYNTH_SOURCE_ID;
const DiagList = diag_mod.DiagList;

const CtValue = union(enum) {
    int: i64,
    float: f64,
};

const ComptimeEval = struct {
    ast: *AST,
    diag: *DiagList,
    steps: u32 = 0,
    depth: u32 = 0,
    failed: bool = false,

    const MAX_STEPS: u32 = 200_000;
    const MAX_DEPTH: u32 = 64;

    const LocalSlot = struct {
        name: []const u8,
        val: CtValue,
    };

    const Env = struct {
        slots: [64]LocalSlot = undefined,
        count: u32 = 0,
        returning: bool = false,
        ret_val: CtValue = .{ .int = 0 },
        breaking: bool = false,
        continuing: bool = false,

        fn get(self: *const Env, name: []const u8) ?CtValue {
            var i = self.count;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, self.slots[i].name, name)) return self.slots[i].val;
            }
            return null;
        }

        fn set(self: *Env, name: []const u8, v: CtValue) void {
            var i = self.count;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, self.slots[i].name, name)) {
                    self.slots[i].val = v;
                    return;
                }
            }
            if (self.count < self.slots.len) {
                self.slots[self.count] = .{ .name = name, .val = v };
                self.count += 1;
            }
        }

        fn define(self: *Env, name: []const u8, v: CtValue) void {
            if (self.count < self.slots.len) {
                self.slots[self.count] = .{ .name = name, .val = v };
                self.count += 1;
            }
        }
    };

    fn tick(self: *ComptimeEval) bool {
        self.steps += 1;
        if (self.steps > MAX_STEPS) {
            self.failed = true;
            return false;
        }
        return true;
    }

    fn findTopConst(self: *const ComptimeEval, name: []const u8) ?u32 {
        var i: u32 = 1;
        while (i < self.ast.count) : (i += 1) {
            const n = self.ast.nodes[i];
            if (n.kind == .const_decl and std.mem.eql(u8, self.ast.nodeText(i), name)) {
                return i;
            }
        }
        return null;
    }

    fn findFnNode(self: *const ComptimeEval, name: []const u8) ?u32 {
        var i: u32 = 1;
        while (i < self.ast.count) : (i += 1) {
            const n = self.ast.nodes[i];
            if (n.kind == .fn_decl and n.extra == 0 and std.mem.eql(u8, self.ast.nodeText(i), name)) {
                return i;
            }
        }
        return null;
    }

    fn evalExpr(self: *ComptimeEval, idx: u32, env: *Env) ?CtValue {
        if (idx == 0 or idx >= self.ast.count or self.failed or !self.tick()) return null;
        const n = self.ast.nodes[idx];
        switch (n.kind) {
            .int_literal => return .{ .int = n.int_val },
            .float_literal => return .{ .float = @bitCast(n.int_val) },
            .identifier => {
                const name = self.ast.nodeText(idx);
                if (env.get(name)) |v| return v;
                if (self.findTopConst(name)) |ci| {
                    if (self.depth >= MAX_DEPTH) return null;
                    self.depth += 1;
                    defer self.depth -= 1;
                    var sub_env = Env{};
                    return self.evalExpr(self.ast.nodes[ci].child0, &sub_env);
                }
                return null;
            },
            .unary_expr => {
                const sub = self.evalExpr(n.child0, env) orelse return null;
                const op: TokenKind = @enumFromInt(n.op);
                return switch (sub) {
                    .int => |iv| switch (op) {
                        .minus => .{ .int = std.math.negate(iv) catch return null },
                        .bang => .{ .int = if (iv == 0) 1 else 0 },
                        .tilde => .{ .int = ~iv },
                        else => null,
                    },
                    .float => |fv| switch (op) {
                        .minus => .{ .float = -fv },
                        else => null,
                    },
                };
            },
            .binary_expr => {
                const op: TokenKind = @enumFromInt(n.op);
                if (op == .and_and) {
                    const lv = self.evalExpr(n.child0, env) orelse return null;
                    const lb = switch (lv) {
                        .int => |iv| iv != 0,
                        .float => |fv| fv != 0.0,
                    };
                    if (!lb) return .{ .int = 0 };
                    const rv = self.evalExpr(n.child1, env) orelse return null;
                    const rb = switch (rv) {
                        .int => |iv| iv != 0,
                        .float => |fv| fv != 0.0,
                    };
                    return .{ .int = if (rb) 1 else 0 };
                }
                if (op == .pipe_pipe) {
                    const lv = self.evalExpr(n.child0, env) orelse return null;
                    const lb = switch (lv) {
                        .int => |iv| iv != 0,
                        .float => |fv| fv != 0.0,
                    };
                    if (lb) return .{ .int = 1 };
                    const rv = self.evalExpr(n.child1, env) orelse return null;
                    const rb = switch (rv) {
                        .int => |iv| iv != 0,
                        .float => |fv| fv != 0.0,
                    };
                    return .{ .int = if (rb) 1 else 0 };
                }
                const lhs = self.evalExpr(n.child0, env) orelse return null;
                const rhs = self.evalExpr(n.child1, env) orelse return null;
                if (lhs == .float or rhs == .float) {
                    const lf: f64 = switch (lhs) {
                        .float => |f| f,
                        .int => |i| @floatFromInt(i),
                    };
                    const rf: f64 = switch (rhs) {
                        .float => |f| f,
                        .int => |i| @floatFromInt(i),
                    };
                    return switch (op) {
                        .plus => .{ .float = lf + rf },
                        .minus => .{ .float = lf - rf },
                        .star => .{ .float = lf * rf },
                        .slash => .{ .float = lf / rf },
                        .eq => .{ .int = if (lf == rf) 1 else 0 },
                        .ne => .{ .int = if (lf != rf) 1 else 0 },
                        .lt => .{ .int = if (lf < rf) 1 else 0 },
                        .le => .{ .int = if (lf <= rf) 1 else 0 },
                        .gt => .{ .int = if (lf > rf) 1 else 0 },
                        .ge => .{ .int = if (lf >= rf) 1 else 0 },
                        else => null,
                    };
                }
                const li = lhs.int;
                const ri = rhs.int;
                return switch (op) {
                    .plus => .{ .int = std.math.add(i64, li, ri) catch return null },
                    .minus => .{ .int = std.math.sub(i64, li, ri) catch return null },
                    .star => .{ .int = std.math.mul(i64, li, ri) catch return null },
                    .slash => if (ri != 0) .{ .int = @divTrunc(li, ri) } else null,
                    .percent => if (ri != 0) .{ .int = @rem(li, ri) } else null,
                    .lshift => if (ri >= 0 and ri < 64) .{ .int = li << @intCast(ri) } else null,
                    .rshift => if (ri >= 0 and ri < 64) .{ .int = li >> @intCast(ri) } else null,
                    .amp => .{ .int = li & ri },
                    .pipe => .{ .int = li | ri },
                    .caret => .{ .int = li ^ ri },
                    .eq => .{ .int = if (li == ri) 1 else 0 },
                    .ne => .{ .int = if (li != ri) 1 else 0 },
                    .lt => .{ .int = if (li < ri) 1 else 0 },
                    .le => .{ .int = if (li <= ri) 1 else 0 },
                    .gt => .{ .int = if (li > ri) 1 else 0 },
                    .ge => .{ .int = if (li >= ri) 1 else 0 },
                    else => null,
                };
            },
            .ternary_expr => {
                const c = self.evalExpr(n.child0, env) orelse return null;
                const cond = switch (c) {
                    .int => |iv| iv != 0,
                    .float => |fv| fv != 0.0,
                };
                return self.evalExpr(if (cond) n.child1 else n.child2, env);
            },
            .cast_expr => {
                const v = self.evalExpr(n.child0, env) orelse return null;
                if (n.type_tag.isFloat()) {
                    return switch (v) {
                        .float => v,
                        .int => |iv| .{ .float = @floatFromInt(iv) },
                    };
                }
                if (n.type_tag.isInteger() or n.type_tag == .bool) {
                    return switch (v) {
                        .int => v,
                        .float => |fv| .{ .int = @intFromFloat(fv) },
                    };
                }
                return v;
            },
            .comptime_expr => {
                if (self.ast.nodes[n.child0].kind == .block) {
                    var sub = env.*;
                    const r = self.evalBlock(n.child0, &sub);
                    if (sub.returning) return sub.ret_val;
                    return r;
                }
                return self.evalExpr(n.child0, env);
            },
            .call_expr => {
                if (n.child0 == 0 or self.ast.nodes[n.child0].kind != .identifier) return null;
                const fname = self.ast.nodeText(n.child0);
                const fn_node = self.findFnNode(fname) orelse return null;
                if (self.depth >= MAX_DEPTH) {
                    self.failed = true;
                    return null;
                }
                self.depth += 1;
                defer self.depth -= 1;

                var fn_env = Env{};
                var p = self.ast.nodes[fn_node].child0;
                var a = n.child2;
                while (p != 0 and a != 0) {
                    const val = self.evalExpr(self.ast.nodes[a].child0, env) orelse return null;
                    fn_env.define(self.ast.nodeText(p), val);
                    p = self.ast.nodes[p].child1;
                    a = self.ast.nodes[a].child1;
                }
                if (p != 0 or a != 0) return null;
                const tail = self.evalBlock(self.ast.nodes[fn_node].child2, &fn_env);
                if (fn_env.returning) return fn_env.ret_val;
                return tail;
            },
            .block => {
                var sub = env.*;
                const r = self.evalBlock(idx, &sub);
                if (sub.returning) return sub.ret_val;
                return r;
            },
            else => return null,
        }
    }

    fn evalBlock(self: *ComptimeEval, block_idx: u32, env: *Env) ?CtValue {
        const saved_count = env.count;
        defer env.count = saved_count;
        var st = self.ast.nodes[block_idx].child0;
        var last_val: ?CtValue = .{ .int = 0 };
        while (st != 0) : (st = self.ast.stmt_chains[st]) {
            if (!self.tick() or self.failed) return null;
            const node = self.ast.nodes[st];
            switch (node.kind) {
                .let_stmt => {
                    const v = if (node.child0 != 0) (self.evalExpr(node.child0, env) orelse return null) else CtValue{ .int = 0 };
                    env.define(self.ast.nodeText(st), v);
                    last_val = v;
                },
                .assign_stmt => {
                    if (node.text_len == 0) return null;
                    const v = self.evalExpr(node.child0, env) orelse return null;
                    const name = self.ast.nodeText(st);
                    const op: TokenKind = @enumFromInt(node.op);
                    if (op == .assign) {
                        env.set(name, v);
                    } else {
                        const cur = env.get(name) orelse return null;
                        if (cur == .int and v == .int) {
                            const nv: i64 = switch (op) {
                                .plus_eq => std.math.add(i64, cur.int, v.int) catch return null,
                                .minus_eq => std.math.sub(i64, cur.int, v.int) catch return null,
                                .star_eq => std.math.mul(i64, cur.int, v.int) catch return null,
                                .slash_eq => if (v.int != 0) @divTrunc(cur.int, v.int) else return null,
                                .percent_eq => if (v.int != 0) @rem(cur.int, v.int) else return null,
                                else => return null,
                            };
                            env.set(name, .{ .int = nv });
                        } else return null;
                    }
                },
                .return_stmt => {
                    const v = if (node.child0 != 0) (self.evalExpr(node.child0, env) orelse return null) else CtValue{ .int = 0 };
                    env.returning = true;
                    env.ret_val = v;
                    return v;
                },
                .break_stmt => {
                    env.breaking = true;
                    return last_val;
                },
                .continue_stmt => {
                    env.continuing = true;
                    return last_val;
                },
                .if_stmt => {
                    const cv = self.evalExpr(node.child0, env) orelse return null;
                    const cond = switch (cv) {
                        .int => |iv| iv != 0,
                        .float => |fv| fv != 0.0,
                    };
                    if (cond) {
                        last_val = self.evalBlock(node.child1, env);
                    } else if (node.child2 != 0) {
                        if (self.ast.nodes[node.child2].kind == .if_stmt) {
                            // wrap single if_stmt tail
                            const cv2 = self.evalExpr(self.ast.nodes[node.child2].child0, env) orelse return null;
                            const c2 = switch (cv2) {
                                .int => |iv| iv != 0,
                                .float => |fv| fv != 0.0,
                            };
                            if (c2) {
                                last_val = self.evalBlock(self.ast.nodes[node.child2].child1, env);
                            } else if (self.ast.nodes[node.child2].child2 != 0) {
                                last_val = self.evalBlock(self.ast.nodes[node.child2].child2, env);
                            }
                        } else {
                            last_val = self.evalBlock(node.child2, env);
                        }
                    }
                    if (env.returning or env.breaking or env.continuing) return last_val;
                },
                .while_stmt => {
                    while (!self.failed) {
                        const cv = self.evalExpr(node.child0, env) orelse return null;
                        const cond = switch (cv) {
                            .int => |iv| iv != 0,
                            .float => |fv| fv != 0.0,
                        };
                        if (!cond) break;
                        _ = self.evalBlock(node.child1, env);
                        if (env.returning) return env.ret_val;
                        if (env.breaking) {
                            env.breaking = false;
                            break;
                        }
                        if (env.continuing) env.continuing = false;
                    }
                },
                .for_stmt => {
                    if (node.int_val == 0) return null;
                    const lo_v = self.evalExpr(node.child0, env) orelse return null;
                    const hi_v = self.evalExpr(node.child2, env) orelse return null;
                    if (lo_v != .int or hi_v != .int) return null;
                    var cur = lo_v.int;
                    const end = hi_v.int;
                    const inc = (node.flags & 1) != 0;
                    const vname = self.ast.nodeText(st);
                    while (!self.failed and (if (inc) cur <= end else cur < end)) : (cur += 1) {
                        const outer = env.count;
                        env.define(vname, .{ .int = cur });
                        _ = self.evalBlock(node.child1, env);
                        env.count = outer;
                        if (env.returning) return env.ret_val;
                        if (env.breaking) {
                            env.breaking = false;
                            break;
                        }
                        if (env.continuing) env.continuing = false;
                    }
                },
                else => {
                    last_val = self.evalExpr(st, env);
                },
            }
            if (env.returning) return env.ret_val;
        }
        return last_val;
    }
};

fn injectStdGenerics(ast: *AST) void {
    if (ast.findEnumBySlice("", "Option") == null and @as(usize, ast.enum_count) < ast.enum_defs.len and @as(usize, ast.generic_count) < ast.generics.len) {
        const ei = ast.enum_count;
        ast.enum_count += 1;
        const name_sp = ast.addSynthText("Option");
        const t_sp = ast.addSynthText("T");
        const some_sp = ast.addSynthText("Some");
        const none_sp = ast.addSynthText("None");
        ast.enum_defs[ei] = .{
            .name_start = name_sp.start,
            .name_len = name_sp.len,
            .line = 0,
            .source_id = SYNTH_SOURCE_ID,
            .variants = undefined,
            .variant_count = 2,
            .has_payloads = true,
            .is_generic = true,
            .generic_params = .{ t_sp, TextSpan{}, TextSpan{}, TextSpan{} },
            .generic_param_count = 1,
        };
        ast.enum_defs[ei].variants[0] = .{
            .name_start = some_sp.start,
            .name_len = some_sp.len,
            .value = 0,
            .payload_count = 1,
            .payload_tags = .{ .generic_param, .none, .none, .none, .none, .none, .none, .none },
            .payload_extras = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .payload_elems = .{ .none, .none, .none, .none, .none, .none, .none, .none },
        };
        ast.enum_defs[ei].variants[1] = .{
            .name_start = none_sp.start,
            .name_len = none_sp.len,
            .value = 1,
            .payload_count = 0,
        };
        ast.generics[ast.generic_count] = .{
            .kind = .enum_t,
            .node_or_def_idx = ei,
            .name = name_sp,
            .params = .{ t_sp, TextSpan{}, TextSpan{}, TextSpan{} },
            .param_count = 1,
        };
        ast.generic_count += 1;
    }

    if (ast.findEnumBySlice("", "Result") == null and @as(usize, ast.enum_count) < ast.enum_defs.len and @as(usize, ast.generic_count) < ast.generics.len) {
        const ei = ast.enum_count;
        ast.enum_count += 1;
        const name_sp = ast.addSynthText("Result");
        const t_sp = ast.addSynthText("T");
        const e_sp = ast.addSynthText("E");
        const ok_sp = ast.addSynthText("Ok");
        const err_sp = ast.addSynthText("Err");
        ast.enum_defs[ei] = .{
            .name_start = name_sp.start,
            .name_len = name_sp.len,
            .line = 0,
            .source_id = SYNTH_SOURCE_ID,
            .variants = undefined,
            .variant_count = 2,
            .has_payloads = true,
            .is_generic = true,
            .generic_params = .{ t_sp, e_sp, TextSpan{}, TextSpan{} },
            .generic_param_count = 2,
        };
        ast.enum_defs[ei].variants[0] = .{
            .name_start = ok_sp.start,
            .name_len = ok_sp.len,
            .value = 0,
            .payload_count = 1,
            .payload_tags = .{ .generic_param, .none, .none, .none, .none, .none, .none, .none },
            .payload_extras = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            .payload_elems = .{ .none, .none, .none, .none, .none, .none, .none, .none },
        };
        ast.enum_defs[ei].variants[1] = .{
            .name_start = err_sp.start,
            .name_len = err_sp.len,
            .value = 1,
            .payload_count = 1,
            .payload_tags = .{ .generic_param, .none, .none, .none, .none, .none, .none, .none },
            .payload_extras = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
            .payload_elems = .{ .none, .none, .none, .none, .none, .none, .none, .none },
        };
        ast.generics[ast.generic_count] = .{
            .kind = .enum_t,
            .node_or_def_idx = ei,
            .name = name_sp,
            .params = .{ t_sp, e_sp, TextSpan{}, TextSpan{} },
            .param_count = 2,
        };
        ast.generic_count += 1;
    }
}

fn evalComptimeAll(ast: *AST, diag: *DiagList) void {
    var ce = ComptimeEval{ .ast = ast, .diag = diag };

    // 1. Evaluate symbolic [EXPR]T fixed array lengths in TypeDescs & AST nodes
    for (1..ast.count) |i| {
        const n = &ast.nodes[i];
        if (n.type_tag == .fixed_array and (n.extra & 0x80000000) != 0) {
            const td_idx = n.extra & 0x7FFFFFFF;
            if (td_idx > 0 and td_idx < ast.type_desc_count) {
                const len_expr = ast.type_descs[td_idx].const_expr_node;
                var env = ComptimeEval.Env{};
                if (ce.evalExpr(len_expr, &env)) |cv| {
                    if (cv == .int and cv.int > 0 and cv.int <= 65536) {
                        n.extra = @intCast(cv.int);
                    }
                }
            }
        }
    }
    for (0..ast.struct_count) |si| {
        const sd = &ast.struct_defs[si];
        var offset: u32 = 0;
        for (0..sd.field_count) |fi| {
            const f = &sd.fields[fi];
            if (f.type_tag == .fixed_array and (f.extra & 0x80000000) != 0) {
                const td_idx = f.extra & 0x7FFFFFFF;
                if (td_idx > 0 and td_idx < ast.type_desc_count) {
                    var env = ComptimeEval.Env{};
                    if (ce.evalExpr(ast.type_descs[td_idx].const_expr_node, &env)) |cv| {
                        if (cv == .int and cv.int > 0 and cv.int <= 65536) {
                            f.extra = @intCast(cv.int);
                        }
                    }
                }
            }
            if (!sd.is_union) {
                f.offset = offset;
                const flen: u32 = if (f.type_tag == .fixed_array and (f.extra & 0x80000000) == 0) @max(f.extra, 1) else 1;
                offset += if (f.type_tag == .fixed_array) flen * 8 else 8;
            }
        }
        if (!sd.is_union) sd.total_size = offset;
    }

    // 2. Replace comptime_expr nodes and comptime fn const initializers with literals
    for (1..ast.count) |i| {
        const n = &ast.nodes[i];
        if (n.kind == .comptime_expr) {
            var env = ComptimeEval.Env{};
            if (ce.evalExpr(n.child0, &env)) |cv| {
                switch (cv) {
                    .int => |iv| {
                        n.kind = .int_literal;
                        n.int_val = iv;
                        n.child0 = 0;
                    },
                    .float => |fv| {
                        n.kind = .float_literal;
                        n.int_val = @bitCast(fv);
                        n.type_tag = .f64;
                        n.child0 = 0;
                    },
                }
            }
        } else if (n.kind == .const_decl and n.child0 != 0) {
            const rhs = ast.nodes[n.child0];
            if (rhs.kind == .call_expr) {
                var env = ComptimeEval.Env{};
                if (ce.evalExpr(n.child0, &env)) |cv| {
                    if (cv == .int) {
                        const lit = ast.addNode(.int_literal, n.line);
                        if (lit != 0) {
                            ast.nodes[lit].int_val = cv.int;
                            ast.nodes[i].child0 = lit;
                        }
                    }
                }
            }
        }
    }
}

fn formatTypeName(ast: *const AST, t: ParsedType, buf: []u8) []const u8 {
    return switch (t.tag) {
        .i8 => "i8",
        .i16 => "i16",
        .i32 => "i32",
        .i64, .isize => "i64",
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64, .usize => "u64",
        .f32 => "f32",
        .f64 => "f64",
        .bool => "bool",
        .string => "string",
        .void => "void",
        .never => "never",
        .ptr => std.fmt.bufPrint(buf, "ptr_{s}", .{formatTypeName(ast, .{ .tag = t.elem_type, .extra = t.extra }, buf[64..])}) catch "ptr",
        .struct_type => if (t.extra > 0 and t.extra - 1 < ast.struct_count) blk: {
            const sd = ast.struct_defs[t.extra - 1];
            break :blk ast.nodeTextSrcFrom(sd.name_start, sd.name_len, sd.source_id);
        } else "struct",
        .enum_type => if (t.extra > 0 and t.extra - 1 < ast.enum_count) blk: {
            const ed = ast.enum_defs[t.extra - 1];
            break :blk ast.nodeTextSrcFrom(ed.name_start, ed.name_len, ed.source_id);
        } else "enum",
        .fn_ptr => "fn",
        .tuple => "tuple",
        .map => "map",
        .chan => "chan",
        else => "any",
    };
}

fn buildMangledName(ast: *AST, base: []const u8, args: []const ParsedType) TextSpan {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeAll(base) catch {};
    for (args) |a| {
        var tmp: [128]u8 = undefined;
        w.writeAll("__") catch {};
        w.writeAll(formatTypeName(ast, a, &tmp)) catch {};
    }
    return ast.addSynthText(fbs.getWritten());
}

fn cloneParamList(ast: *AST, head: u32) u32 {
    if (head == 0 or head >= ast.count) return 0;
    const nc = ast.addNode(ast.nodes[head].kind, ast.nodes[head].line);
    if (nc == 0) return 0;
    ast.nodes[nc] = ast.nodes[head];
    if (ast.nodes[head].child1 != 0) ast.nodes[nc].child1 = cloneParamList(ast, ast.nodes[head].child1);
    return nc;
}

fn cloneNodeSubtree(ast: *AST, root: u32) u32 {
    if (root == 0 or root >= ast.count) return 0;
    const nc = ast.addNode(ast.nodes[root].kind, ast.nodes[root].line);
    if (nc == 0) return 0;
    const old_n = ast.nodes[root];
    ast.nodes[nc] = old_n;
    switch (old_n.kind) {
        .fn_decl, .closure_expr => {
            if (old_n.child0 != 0) ast.nodes[nc].child0 = cloneParamList(ast, old_n.child0);
            // child1 holds ret_type.extra (non-node integer)
            if (old_n.child2 != 0) ast.nodes[nc].child2 = cloneNodeSubtree(ast, old_n.child2);
        },
        .let_stmt => {
            if (old_n.child0 != 0) ast.nodes[nc].child0 = cloneNodeSubtree(ast, old_n.child0);
            // child1 holds ann_type.extra (non-node integer)
            if (old_n.child2 != 0) ast.nodes[nc].child2 = cloneNodeSubtree(ast, old_n.child2);
        },
        .tuple_pattern => {
            if (old_n.child0 != 0) ast.nodes[nc].child0 = cloneParamList(ast, old_n.child0);
        },
        .identifier, .int_literal, .float_literal, .string_literal, .break_stmt, .continue_stmt, .unreachable_stmt => {},
        .match_arm => {
            if (old_n.child0 != 0) ast.nodes[nc].child0 = cloneNodeSubtree(ast, old_n.child0);
            if (old_n.child1 != 0) ast.nodes[nc].child1 = cloneNodeSubtree(ast, old_n.child1);
            if (old_n.child2 != 0) ast.nodes[nc].child2 = cloneNodeSubtree(ast, old_n.child2);
            if (old_n.extra != 0) ast.nodes[nc].extra = cloneNodeSubtree(ast, old_n.extra);
        },
        .list_comp => {
            if (old_n.child0 != 0) ast.nodes[nc].child0 = cloneNodeSubtree(ast, old_n.child0);
            if (old_n.child1 != 0) ast.nodes[nc].child1 = cloneNodeSubtree(ast, old_n.child1);
            if (old_n.child2 != 0) ast.nodes[nc].child2 = cloneNodeSubtree(ast, old_n.child2);
            if (old_n.extra != 0) ast.nodes[nc].extra = cloneNodeSubtree(ast, old_n.extra);
        },
        else => {
            if (old_n.child0 != 0) ast.nodes[nc].child0 = cloneNodeSubtree(ast, old_n.child0);
            if (old_n.child1 != 0) ast.nodes[nc].child1 = cloneNodeSubtree(ast, old_n.child1);
            if (old_n.child2 != 0) ast.nodes[nc].child2 = cloneNodeSubtree(ast, old_n.child2);
        },
    }
    if (ast.stmt_chains[root] != 0) ast.stmt_chains[nc] = cloneNodeSubtree(ast, ast.stmt_chains[root]);
    return nc;
}

fn substParsedType(ast: *AST, t: ParsedType, args: []const ParsedType, gen_struct_idx: ?u32, conc_struct_idx: ?u32) ParsedType {
    if (t.tag == .generic_param) {
        if (t.extra < args.len) return args[t.extra];
        return .{ .tag = .i64 };
    }
    if (t.tag == .ptr and t.elem_type == .generic_param) {
        if (t.extra < args.len) {
            const inner = args[t.extra];
            return .{ .tag = .ptr, .extra = inner.extra, .elem_type = inner.tag };
        }
    }
    if (t.tag == .generic_inst and t.extra > 0 and t.extra < ast.type_desc_count) {
        const old_td = ast.type_descs[t.extra];
        var new_td = old_td;
        var modified = false;
        for (0..old_td.param_count) |pi| {
            const sub = substParsedType(ast, .{
                .tag = old_td.param_tags[pi],
                .extra = old_td.param_extras[pi],
                .elem_type = old_td.param_elems[pi],
            }, args, gen_struct_idx, conc_struct_idx);
            if (sub.tag != old_td.param_tags[pi] or sub.extra != old_td.param_extras[pi]) modified = true;
            new_td.param_tags[pi] = sub.tag;
            new_td.param_extras[pi] = sub.extra;
            new_td.param_elems[pi] = sub.elem_type;
        }
        if (modified) {
            const nid = ast.addTypeDesc(new_td);
            return .{ .tag = .generic_inst, .extra = nid };
        }
    }
    if (gen_struct_idx != null and conc_struct_idx != null) {
        if (t.tag == .struct_type and t.extra == gen_struct_idx.? + 1) {
            return .{ .tag = .struct_type, .extra = conc_struct_idx.? + 1 };
        }
        if (t.tag == .ptr and t.elem_type == .struct_type and t.extra == gen_struct_idx.? + 1) {
            return .{ .tag = .ptr, .extra = conc_struct_idx.? + 1, .elem_type = .struct_type };
        }
    }
    return t;
}

fn substNodeTypes(ast: *AST, root: u32, args: []const ParsedType, gen_struct_idx: ?u32, conc_struct_idx: ?u32) void {
    if (root == 0 or root >= ast.count) return;
    const old_n = ast.nodes[root];
    switch (old_n.kind) {
        .fn_decl, .closure_expr => {
            var p = old_n.child0;
            while (p != 0) : (p = ast.nodes[p].child1) {
                const pn = &ast.nodes[p];
                const ppt = substParsedType(ast, .{ .tag = pn.type_tag, .extra = pn.child0, .elem_type = pn.elem_type }, args, gen_struct_idx, conc_struct_idx);
                pn.type_tag = ppt.tag;
                pn.elem_type = ppt.elem_type;
                pn.child0 = ppt.extra;
            }
            const rpt = substParsedType(ast, .{ .tag = old_n.type_tag, .extra = old_n.child1, .elem_type = old_n.elem_type }, args, gen_struct_idx, conc_struct_idx);
            ast.nodes[root].type_tag = rpt.tag;
            ast.nodes[root].elem_type = rpt.elem_type;
            ast.nodes[root].child1 = rpt.extra;
            if (old_n.child2 != 0) substNodeTypes(ast, old_n.child2, args, gen_struct_idx, conc_struct_idx);
        },
        .let_stmt => {
            const lpt = substParsedType(ast, .{ .tag = old_n.type_tag, .extra = old_n.extra, .elem_type = old_n.elem_type }, args, gen_struct_idx, conc_struct_idx);
            ast.nodes[root].type_tag = lpt.tag;
            ast.nodes[root].elem_type = lpt.elem_type;
            ast.nodes[root].extra = lpt.extra;
            ast.nodes[root].child1 = lpt.extra;
            if (old_n.child0 != 0) substNodeTypes(ast, old_n.child0, args, gen_struct_idx, conc_struct_idx);
            if (old_n.child2 != 0) substNodeTypes(ast, old_n.child2, args, gen_struct_idx, conc_struct_idx);
        },
        .identifier => {
            if (old_n.type_tag == .generic_param) {
                const idx = old_n.child0;
                if (idx < args.len) {
                    ast.nodes[root].type_tag = args[idx].tag;
                    ast.nodes[root].elem_type = args[idx].elem_type;
                    ast.nodes[root].child0 = args[idx].extra;
                }
            } else {
                const pt = substParsedType(ast, .{ .tag = old_n.type_tag, .extra = old_n.extra, .elem_type = old_n.elem_type }, args, gen_struct_idx, conc_struct_idx);
                ast.nodes[root].type_tag = pt.tag;
                ast.nodes[root].elem_type = pt.elem_type;
                ast.nodes[root].extra = pt.extra;
            }
        },
        .int_literal, .float_literal, .string_literal, .break_stmt, .continue_stmt, .unreachable_stmt, .tuple_pattern => {},
        .match_arm => {
            if (old_n.child0 != 0) substNodeTypes(ast, old_n.child0, args, gen_struct_idx, conc_struct_idx);
            if (old_n.child1 != 0) substNodeTypes(ast, old_n.child1, args, gen_struct_idx, conc_struct_idx);
            if (old_n.child2 != 0) substNodeTypes(ast, old_n.child2, args, gen_struct_idx, conc_struct_idx);
            if (old_n.extra != 0) substNodeTypes(ast, old_n.extra, args, gen_struct_idx, conc_struct_idx);
        },
        .list_comp => {
            if (old_n.child0 != 0) substNodeTypes(ast, old_n.child0, args, gen_struct_idx, conc_struct_idx);
            if (old_n.child1 != 0) substNodeTypes(ast, old_n.child1, args, gen_struct_idx, conc_struct_idx);
            if (old_n.child2 != 0) substNodeTypes(ast, old_n.child2, args, gen_struct_idx, conc_struct_idx);
            if (old_n.extra != 0) substNodeTypes(ast, old_n.extra, args, gen_struct_idx, conc_struct_idx);
        },
        else => {
            const pt = substParsedType(ast, .{ .tag = old_n.type_tag, .extra = old_n.extra, .elem_type = old_n.elem_type }, args, gen_struct_idx, conc_struct_idx);
            ast.nodes[root].type_tag = pt.tag;
            ast.nodes[root].elem_type = pt.elem_type;
            ast.nodes[root].extra = pt.extra;
            if (old_n.child0 != 0) substNodeTypes(ast, old_n.child0, args, gen_struct_idx, conc_struct_idx);
            if (old_n.child1 != 0) substNodeTypes(ast, old_n.child1, args, gen_struct_idx, conc_struct_idx);
            if (old_n.child2 != 0) substNodeTypes(ast, old_n.child2, args, gen_struct_idx, conc_struct_idx);
        },
    }
    if (ast.stmt_chains[root] != 0) substNodeTypes(ast, ast.stmt_chains[root], args, gen_struct_idx, conc_struct_idx);
}

fn instantiateGenericType(ast: *AST, base_name: []const u8, args: []const ParsedType) ?ParsedType {
    // Check if any arg is still a generic_param
    for (args) |a| {
        if (a.tag == .generic_param or a.tag == .none) return null;
    }

    const mangled_sp = buildMangledName(ast, base_name, args);
    const mangled = ast.nodeTextSrcFrom(mangled_sp.start, mangled_sp.len, mangled_sp.source_id);

    if (ast.findStructBySlice("", mangled)) |si| {
        return .{ .tag = .struct_type, .extra = si + 1 };
    }
    if (ast.findEnumBySlice("", mangled)) |ei| {
        return .{ .tag = .enum_type, .extra = ei + 1 };
    }

    // Instantiate generic struct
    if (ast.findStructBySlice("", base_name)) |gen_si| {
        const gsd = ast.struct_defs[gen_si];
        if (!gsd.is_generic) return .{ .tag = .struct_type, .extra = gen_si + 1 };
        if (@as(usize, ast.struct_count) >= ast.struct_defs.len) {
            ast.overflowed = true;
            return null;
        }
        const new_si = ast.struct_count;
        ast.struct_count += 1;
        ast.struct_defs[new_si] = gsd;
        ast.struct_defs[new_si].name_start = mangled_sp.start;
        ast.struct_defs[new_si].name_len = mangled_sp.len;
        ast.struct_defs[new_si].source_id = mangled_sp.source_id;
        ast.struct_defs[new_si].is_generic = false;
        ast.struct_defs[new_si].generic_param_count = 0;

        var offset: u32 = 0;
        for (0..ast.struct_defs[new_si].field_count) |fi| {
            const f = &ast.struct_defs[new_si].fields[fi];
            if (gsd.source_id != SYNTH_SOURCE_ID) {
                const fnm = ast.nodeTextSrcFrom(f.name_start, f.name_len, gsd.source_id);
                const fsp = ast.addSynthText(fnm);
                f.name_start = fsp.start;
                f.name_len = fsp.len;
            }
            const ft = substParsedType(ast, .{ .tag = f.type_tag, .extra = f.extra, .elem_type = f.elem_type }, args, gen_si, new_si);
            f.type_tag = ft.tag;
            f.extra = ft.extra;
            f.elem_type = ft.elem_type;
            if (!ast.struct_defs[new_si].is_union) {
                f.offset = offset;
                const flen: u32 = if (f.type_tag == .fixed_array) @max(f.extra, 1) else 1;
                offset += if (f.type_tag == .fixed_array) flen * 8 else 8;
            }
        }
        if (!ast.struct_defs[new_si].is_union) ast.struct_defs[new_si].total_size = offset;

        const sd_node = ast.addNode(.struct_decl, gsd.line);
        if (sd_node != 0) {
            ast.nodes[sd_node].text_start = mangled_sp.start;
            ast.nodes[sd_node].text_len = mangled_sp.len;
            ast.nodes[sd_node].source_id = mangled_sp.source_id;
            ast.nodes[sd_node].int_val = @intCast(new_si);
        }

        // Instantiate all methods attached to gen_si
        const limit = ast.count;
        for (1..limit) |ni| {
            const mn = ast.nodes[ni];
            if (mn.kind == .fn_decl and mn.extra == gen_si + 1) {
                const cloned = cloneNodeSubtree(ast, @intCast(ni));
                if (cloned != 0) {
                    ast.nodes[cloned].extra = new_si + 1;
                    ast.nodes[cloned].flags &= ~@as(u8, 64);
                    // Substitute params (child0) & return & body (child2)
                    var p = ast.nodes[cloned].child0;
                    while (p != 0) : (p = ast.nodes[p].child1) {
                        const pn = &ast.nodes[p];
                        const pt = substParsedType(ast, .{ .tag = pn.type_tag, .extra = pn.child0, .elem_type = pn.elem_type }, args, gen_si, new_si);
                        pn.type_tag = pt.tag;
                        pn.elem_type = pt.elem_type;
                        pn.child0 = pt.extra;
                    }
                    const rt = substParsedType(ast, .{ .tag = ast.nodes[cloned].type_tag, .extra = ast.nodes[cloned].child1, .elem_type = ast.nodes[cloned].elem_type }, args, gen_si, new_si);
                    ast.nodes[cloned].type_tag = rt.tag;
                    ast.nodes[cloned].elem_type = rt.elem_type;
                    if (rt.tag == .struct_type or rt.tag == .enum_type or rt.tag == .tuple or rt.tag == .fn_ptr or rt.tag == .generic_inst or rt.tag == .dyn_trait or rt.tag == .map or rt.tag == .slice) {
                        ast.nodes[cloned].child1 = rt.extra;
                    }
                    substNodeTypes(ast, ast.nodes[cloned].child2, args, gen_si, new_si);
                }
            }
        }
        return .{ .tag = .struct_type, .extra = new_si + 1 };
    }

    // Instantiate generic enum
    if (ast.findEnumBySlice("", base_name)) |gen_ei| {
        const ged = ast.enum_defs[gen_ei];
        if (!ged.is_generic) return .{ .tag = .enum_type, .extra = gen_ei + 1 };
        if (@as(usize, ast.enum_count) >= ast.enum_defs.len) {
            ast.overflowed = true;
            return null;
        }
        const new_ei = ast.enum_count;
        ast.enum_count += 1;
        ast.enum_defs[new_ei] = ged;
        ast.enum_defs[new_ei].name_start = mangled_sp.start;
        ast.enum_defs[new_ei].name_len = mangled_sp.len;
        ast.enum_defs[new_ei].source_id = mangled_sp.source_id;
        ast.enum_defs[new_ei].is_generic = false;
        ast.enum_defs[new_ei].generic_param_count = 0;

        for (0..ast.enum_defs[new_ei].variant_count) |vi| {
            const v = &ast.enum_defs[new_ei].variants[vi];
            if (ged.source_id != SYNTH_SOURCE_ID) {
                const vnm = ast.nodeTextSrcFrom(v.name_start, v.name_len, ged.source_id);
                const vsp = ast.addSynthText(vnm);
                v.name_start = vsp.start;
                v.name_len = vsp.len;
            }
            for (0..v.payload_count) |pi| {
                const pt = substParsedType(ast, .{
                    .tag = v.payload_tags[pi],
                    .extra = v.payload_extras[pi],
                    .elem_type = v.payload_elems[pi],
                }, args, null, null);
                v.payload_tags[pi] = pt.tag;
                v.payload_extras[pi] = pt.extra;
                v.payload_elems[pi] = pt.elem_type;
            }
        }
        const ed_node = ast.addNode(.enum_decl, ged.line);
        if (ed_node != 0) {
            ast.nodes[ed_node].text_start = mangled_sp.start;
            ast.nodes[ed_node].text_len = mangled_sp.len;
            ast.nodes[ed_node].source_id = mangled_sp.source_id;
            ast.nodes[ed_node].int_val = @intCast(new_ei);
        }
        return .{ .tag = .enum_type, .extra = new_ei + 1 };
    }
    return null;
}

fn inferExprTypeSimple(ast: *const AST, expr: u32) ParsedType {
    if (expr == 0 or expr >= ast.count) return .{ .tag = .i64 };
    const n = ast.nodes[expr];
    return switch (n.kind) {
        .float_literal => .{ .tag = .f64 },
        .int_literal => if (n.flags == 1) .{ .tag = .bool } else .{ .tag = .i64 },
        .string_literal, .interp_string => .{ .tag = .string },
        .struct_init => if (ast.findStructBySlice("", ast.nodeText(expr))) |si| .{ .tag = .struct_type, .extra = si + 1 } else .{ .tag = .i64 },
        .cast_expr => .{ .tag = n.type_tag, .extra = n.extra, .elem_type = n.elem_type },
        .binary_expr => blk: {
            const lt = inferExprTypeSimple(ast, n.child0);
            if (lt.tag.isFloat()) break :blk lt;
            break :blk inferExprTypeSimple(ast, n.child1);
        },
        else => .{ .tag = .i64 },
    };
}

fn instantiateGenericFn(ast: *AST, gen_fn_node: u32, args: []const ParsedType) ?TextSpan {
    const base_name = ast.nodeText(gen_fn_node);
    const mangled_sp = buildMangledName(ast, base_name, args);
    const mangled = ast.nodeTextSrcFrom(mangled_sp.start, mangled_sp.len, mangled_sp.source_id);

    for (1..ast.count) |i| {
        if (ast.nodes[i].kind == .fn_decl and ast.nodes[i].extra == 0 and
            (ast.nodes[i].flags & 64) == 0 and std.mem.eql(u8, ast.nodeText(@intCast(i)), mangled))
        {
            return mangled_sp;
        }
    }

    const cloned = cloneNodeSubtree(ast, gen_fn_node);
    if (cloned == 0) return null;
    ast.nodes[cloned].text_start = mangled_sp.start;
    ast.nodes[cloned].text_len = mangled_sp.len;
    ast.nodes[cloned].source_id = mangled_sp.source_id;
    ast.nodes[cloned].flags &= ~@as(u8, 64);

    var p = ast.nodes[cloned].child0;
    while (p != 0) : (p = ast.nodes[p].child1) {
        const pn = &ast.nodes[p];
        const pt = substParsedType(ast, .{ .tag = pn.type_tag, .extra = pn.child0, .elem_type = pn.elem_type }, args, null, null);
        pn.type_tag = pt.tag;
        pn.elem_type = pt.elem_type;
        pn.child0 = pt.extra;
    }
    const rt = substParsedType(ast, .{ .tag = ast.nodes[cloned].type_tag, .extra = ast.nodes[cloned].child1, .elem_type = ast.nodes[cloned].elem_type }, args, null, null);
    ast.nodes[cloned].type_tag = rt.tag;
    ast.nodes[cloned].elem_type = rt.elem_type;
    if (rt.tag == .struct_type or rt.tag == .enum_type) ast.nodes[cloned].child1 = rt.extra;
    substNodeTypes(ast, ast.nodes[cloned].child2, args, null, null);
    return mangled_sp;
}

fn rewriteCtxConstructors(ast: *AST, node_idx: u32, expected_enum_plus1: u32) void {
    if (node_idx == 0 or node_idx >= ast.count) return;
    const n = &ast.nodes[node_idx];
    if (expected_enum_plus1 > 0 and expected_enum_plus1 - 1 < ast.enum_count) {
        const ed = ast.enum_defs[expected_enum_plus1 - 1];
        const ename = ast.nodeTextSrcFrom(ed.name_start, ed.name_len, ed.source_id);
        const is_opt = std.mem.startsWith(u8, ename, "Option__");
        const is_res = std.mem.startsWith(u8, ename, "Result__");
        if (n.kind == .identifier and std.mem.eql(u8, ast.nodeText(node_idx), "None") and is_opt) {
            const eid = ast.addNode(.identifier, n.line);
            if (eid != 0) {
                ast.nodes[eid].text_start = ed.name_start;
                ast.nodes[eid].text_len = ed.name_len;
                ast.nodes[eid].source_id = ed.source_id;
                const sp = ast.addSynthText("None");
                n.kind = .scoped_access;
                n.child0 = eid;
                n.text_start = sp.start;
                n.text_len = sp.len;
                n.source_id = sp.source_id;
                n.flags = 0;
            }
            return;
        }
        if (n.kind == .call_expr and n.child0 != 0) {
            const cname = ast.nodeText(n.child0);
            if ((is_opt and std.mem.eql(u8, cname, "Some")) or
                (is_res and (std.mem.eql(u8, cname, "Ok") or std.mem.eql(u8, cname, "Err"))))
            {
                const eid = ast.addNode(.identifier, n.line);
                if (eid != 0) {
                    ast.nodes[eid].text_start = ed.name_start;
                    ast.nodes[eid].text_len = ed.name_len;
                    ast.nodes[eid].source_id = ed.source_id;
                    const sp = ast.addSynthText(cname);
                    n.kind = .scoped_access;
                    n.child0 = eid;
                    n.text_start = sp.start;
                    n.text_len = sp.len;
                    n.source_id = sp.source_id;
                    n.flags = 1;
                }
            }
        }
    }
    switch (n.kind) {
        .block => {
            var s = n.child0;
            while (s != 0) : (s = ast.stmt_chains[s]) {
                rewriteCtxConstructors(ast, s, expected_enum_plus1);
            }
        },
        .expr_stmt, .return_stmt => rewriteCtxConstructors(ast, n.child0, expected_enum_plus1),
        .assign_stmt => rewriteCtxConstructors(ast, n.child1, expected_enum_plus1),
        .let_stmt => {
            const let_enum = if (n.type_tag == .enum_type) n.extra else expected_enum_plus1;
            rewriteCtxConstructors(ast, n.child0, let_enum);
        },
        .if_stmt => {
            rewriteCtxConstructors(ast, n.child1, expected_enum_plus1);
            rewriteCtxConstructors(ast, n.child2, expected_enum_plus1);
        },
        .while_stmt, .for_stmt => rewriteCtxConstructors(ast, n.child1, expected_enum_plus1),
        .coalesce_expr => {
            rewriteCtxConstructors(ast, n.child0, expected_enum_plus1);
            rewriteCtxConstructors(ast, n.child1, expected_enum_plus1);
        },
        .match_expr => {
            var arm = n.child1;
            while (arm != 0) : (arm = ast.nodes[arm].child2) {
                rewriteCtxConstructors(ast, ast.nodes[arm].child1, expected_enum_plus1);
            }
            rewriteCtxConstructors(ast, n.child2, expected_enum_plus1);
        },
        else => {},
    }
}

fn monomorphizeAll(ast: *AST) void {
    var pass: u32 = 0;
    while (pass < 6) : (pass += 1) {
        var changed = false;

        // Resolve .generic_inst TypeDescs in place
        for (1..ast.type_desc_count) |ti| {
            const td = &ast.type_descs[ti];
            if (td.kind == .generic_inst) {
                const base = ast.nodeTextSrcFrom(td.base_name.start, td.base_name.len, td.base_name.source_id);
                var concrete: [8]ParsedType = undefined;
                for (0..td.param_count) |pi| {
                    concrete[pi] = .{ .tag = td.param_tags[pi], .extra = td.param_extras[pi], .elem_type = td.param_elems[pi] };
                }
                if (instantiateGenericType(ast, base, concrete[0..td.param_count])) |res| {
                    td.kind = res.tag;
                    td.ret_tag = res.tag;
                    td.ret_extra = res.extra;
                    td.ret_elem = res.elem_type;
                    changed = true;
                }
            }
        }

        // Resolve nested .generic_inst inside TypeDescs, struct fields, and enum payloads
        for (1..ast.type_desc_count) |ti| {
            const td = &ast.type_descs[ti];
            for (0..td.param_count) |pi| {
                if (td.param_tags[pi] == .generic_inst and td.param_extras[pi] > 0 and td.param_extras[pi] < ast.type_desc_count) {
                    const inner = ast.type_descs[td.param_extras[pi]];
                    if (inner.ret_tag == .struct_type or inner.ret_tag == .enum_type) {
                        td.param_tags[pi] = inner.ret_tag;
                        td.param_extras[pi] = inner.ret_extra;
                        changed = true;
                    }
                }
            }
            if (td.ret_tag == .generic_inst and td.ret_extra > 0 and td.ret_extra < ast.type_desc_count) {
                const inner = ast.type_descs[td.ret_extra];
                if (inner.ret_tag == .struct_type or inner.ret_tag == .enum_type) {
                    td.ret_tag = inner.ret_tag;
                    td.ret_extra = inner.ret_extra;
                    changed = true;
                }
            }
        }
        for (0..ast.struct_count) |si| {
            if (ast.struct_defs[si].is_generic) continue;
            for (0..ast.struct_defs[si].field_count) |fi| {
                const f = &ast.struct_defs[si].fields[fi];
                if (f.type_tag == .generic_inst and f.extra > 0 and f.extra < ast.type_desc_count) {
                    const td = ast.type_descs[f.extra];
                    if (td.ret_tag == .struct_type or td.ret_tag == .enum_type) {
                        f.type_tag = td.ret_tag;
                        f.extra = td.ret_extra;
                        changed = true;
                    }
                }
            }
        }
        for (0..ast.enum_count) |ei| {
            if (ast.enum_defs[ei].is_generic) continue;
            for (0..ast.enum_defs[ei].variant_count) |vi| {
                const v = &ast.enum_defs[ei].variants[vi];
                for (0..v.payload_count) |pi| {
                    if (v.payload_tags[pi] == .generic_inst and v.payload_extras[pi] > 0 and v.payload_extras[pi] < ast.type_desc_count) {
                        const td = ast.type_descs[v.payload_extras[pi]];
                        if (td.ret_tag == .struct_type or td.ret_tag == .enum_type) {
                            v.payload_tags[pi] = td.ret_tag;
                            v.payload_extras[pi] = td.ret_extra;
                            changed = true;
                        }
                    }
                }
            }
        }

        // Update AST nodes referencing resolved TypeDescs or generic expressions
        for (1..ast.count) |i| {
            const n = &ast.nodes[i];
            const td_idx = if (n.kind == .fn_decl) n.child1 else n.extra;
            if (n.type_tag == .generic_inst and td_idx > 0 and td_idx < ast.type_desc_count) {
                const td = ast.type_descs[td_idx];
                if (td.ret_tag == .struct_type or td.ret_tag == .enum_type) {
                    n.type_tag = td.ret_tag;
                    if (n.kind == .fn_decl) n.child1 = td.ret_extra else {
                        n.extra = td.ret_extra;
                        if (n.kind == .let_stmt) n.child1 = td.ret_extra;
                    }
                    changed = true;
                }
            }
            if (n.kind == .identifier and n.type_tag == .generic_inst and n.child0 > 0 and n.child0 < ast.type_desc_count) {
                const td = ast.type_descs[n.child0];
                if (td.ret_tag == .struct_type or td.ret_tag == .enum_type) {
                    n.type_tag = td.ret_tag;
                    n.child0 = td.ret_extra;
                    changed = true;
                }
            }
            if (n.kind == .struct_init and (n.flags & 32) != 0 and n.extra > 0 and n.extra < ast.type_desc_count) {
                const td = ast.type_descs[n.extra];
                if (td.ret_tag == .struct_type and td.ret_extra > 0) {
                    const sd = ast.struct_defs[td.ret_extra - 1];
                    n.text_start = sd.name_start;
                    n.text_len = sd.name_len;
                    n.source_id = sd.source_id;
                    n.flags &= ~@as(u8, 32);
                    changed = true;
                }
            }
            if (n.kind == .scoped_access and n.child0 != 0) {
                const base_id = &ast.nodes[n.child0];
                if ((base_id.flags & 32) != 0 and base_id.extra > 0 and base_id.extra < ast.type_desc_count) {
                    const td = ast.type_descs[base_id.extra];
                    if (td.ret_tag == .enum_type and td.ret_extra > 0) {
                        const ed = ast.enum_defs[td.ret_extra - 1];
                        base_id.text_start = ed.name_start;
                        base_id.text_len = ed.name_len;
                        base_id.source_id = ed.source_id;
                        base_id.flags &= ~@as(u8, 32);
                        changed = true;
                    } else if (td.ret_tag == .struct_type and td.ret_extra > 0) {
                        const sd = ast.struct_defs[td.ret_extra - 1];
                        base_id.text_start = sd.name_start;
                        base_id.text_len = sd.name_len;
                        base_id.source_id = sd.source_id;
                        base_id.flags &= ~@as(u8, 32);
                        changed = true;
                    }
                }
            }
            if (n.kind == .call_expr and n.child0 != 0) {
                const callee_name = ast.nodeText(n.child0);
                // Explicit or inferred generic function call
                for (0..ast.generic_count) |gi| {
                    const gt = ast.generics[gi];
                    if (gt.kind == .fn_t) {
                        const gname = ast.nodeTextSrcFrom(gt.name.start, gt.name.len, gt.name.source_id);
                        if (std.mem.eql(u8, gname, callee_name)) {
                            var targs: [4]ParsedType = .{ParsedType{ .tag = .i64 }} ** 4;
                            var tcount: usize = gt.param_count;
                            if ((n.flags & 32) != 0 and n.extra > 0 and n.extra < ast.type_desc_count) {
                                const td = ast.type_descs[n.extra];
                                tcount = td.param_count;
                                for (0..tcount) |ti| {
                                    targs[ti] = .{ .tag = td.param_tags[ti], .extra = td.param_extras[ti], .elem_type = td.param_elems[ti] };
                                }
                            } else {
                                // Infer from arguments
                                var p = ast.nodes[gt.node_or_def_idx].child0;
                                var a = n.child2;
                                while (p != 0 and a != 0) : ({
                                    p = ast.nodes[p].child1;
                                    a = ast.nodes[a].child1;
                                }) {
                                    if (ast.nodes[p].type_tag == .generic_param and ast.nodes[p].child0 < 4) {
                                        targs[ast.nodes[p].child0] = inferExprTypeSimple(ast, ast.nodes[a].child0);
                                    }
                                }
                            }
                            if (instantiateGenericFn(ast, gt.node_or_def_idx, targs[0..tcount])) |fn_sp| {
                                ast.nodes[n.child0].text_start = fn_sp.start;
                                ast.nodes[n.child0].text_len = fn_sp.len;
                                ast.nodes[n.child0].source_id = fn_sp.source_id;
                                n.flags &= ~@as(u8, 32);
                                changed = true;
                            }
                            break;
                        }
                    }
                }
            }
        }
        if (!changed) break;
    }

    // Rewrite context-typed bare Some/None/Ok/Err in functions and let statements
    for (1..ast.count) |i| {
        const fn_n = ast.nodes[i];
        if (fn_n.kind == .fn_decl and (fn_n.flags & 64) == 0) {
            const ret_enum = if (fn_n.type_tag == .enum_type) fn_n.child1 else 0;
            rewriteCtxConstructors(ast, fn_n.child2, ret_enum);
        }
    }

    // Collect match_arm pattern roots so standalone Some/Ok/Err fallback never corrupts match patterns
    var is_match_pat: [parser_mod.MAX_AST_NODES]bool = [_]bool{false} ** parser_mod.MAX_AST_NODES;
    for (1..ast.count) |mi| {
        if (ast.nodes[mi].kind == .match_arm and ast.nodes[mi].child0 < is_match_pat.len) {
            is_match_pat[ast.nodes[mi].child0] = true;
        }
    }

    // Standalone Some(x) / Ok(x) / Err(e) fallback
    for (1..ast.count) |i| {
        if (is_match_pat[i]) continue;
        const n = &ast.nodes[i];
        if (n.kind == .call_expr and n.child0 != 0 and n.child2 != 0) {
            const cname = ast.nodeText(n.child0);
            if (std.mem.eql(u8, cname, "Some")) {
                const arg_ty = inferExprTypeSimple(ast, ast.nodes[n.child2].child0);
                if (instantiateGenericType(ast, "Option", &.{arg_ty})) |res| {
                    const ed = ast.enum_defs[res.extra - 1];
                    const eid = ast.addNode(.identifier, n.line);
                    if (eid != 0) {
                        ast.nodes[eid].text_start = ed.name_start;
                        ast.nodes[eid].text_len = ed.name_len;
                        ast.nodes[eid].source_id = ed.source_id;
                        const sp = ast.addSynthText("Some");
                        n.kind = .scoped_access;
                        n.child0 = eid;
                        n.text_start = sp.start;
                        n.text_len = sp.len;
                        n.source_id = sp.source_id;
                        n.flags = 1;
                    }
                }
            } else if (std.mem.eql(u8, cname, "Ok") or std.mem.eql(u8, cname, "Err")) {
                const arg_ty = inferExprTypeSimple(ast, ast.nodes[n.child2].child0);
                const t_arg = if (std.mem.eql(u8, cname, "Ok")) arg_ty else ParsedType{ .tag = .i64 };
                const e_arg = if (std.mem.eql(u8, cname, "Err")) arg_ty else ParsedType{ .tag = .i64 };
                if (instantiateGenericType(ast, "Result", &.{ t_arg, e_arg })) |res| {
                    const ed = ast.enum_defs[res.extra - 1];
                    const eid = ast.addNode(.identifier, n.line);
                    if (eid != 0) {
                        ast.nodes[eid].text_start = ed.name_start;
                        ast.nodes[eid].text_len = ed.name_len;
                        ast.nodes[eid].source_id = ed.source_id;
                        const sp = ast.addSynthText(cname);
                        n.kind = .scoped_access;
                        n.child0 = eid;
                        n.text_start = sp.start;
                        n.text_len = sp.len;
                        n.source_id = sp.source_id;
                        n.flags = 1;
                    }
                }
            }
        }
    }

    // Also update StructDef field types that pointed to generic_inst
    for (0..ast.struct_count) |si| {
        const sd = &ast.struct_defs[si];
        if (sd.is_generic) continue;
        for (0..sd.field_count) |fi| {
            const f = &sd.fields[fi];
            if (f.type_tag == .generic_inst and f.extra > 0 and f.extra < ast.type_desc_count) {
                const td = ast.type_descs[f.extra];
                if (td.ret_tag == .struct_type or td.ret_tag == .enum_type) {
                    f.type_tag = td.ret_tag;
                    f.extra = td.ret_extra;
                    f.elem_type = td.ret_elem;
                }
            }
        }
    }

    // Evaluate compile-time type intrinsics: @size_of(T), @align_of(T), @type_name(T)
    for (1..ast.count) |i| {
        const n = &ast.nodes[i];
        if (n.kind == .call_expr and (n.flags & 64) != 0 and n.child0 != 0) {
            const bname = ast.nodeText(n.child0);
            const td = if (n.extra > 0 and n.extra < ast.type_desc_count) ast.type_descs[n.extra] else continue;
            const ty = ParsedType{ .tag = td.ret_tag, .extra = td.ret_extra, .elem_type = td.ret_elem };
            if (std.mem.eql(u8, bname, "@size_of")) {
                const sz: i64 = switch (ty.tag) {
                    .i8, .u8, .bool => 1,
                    .i16, .u16 => 2,
                    .i32, .u32, .f32 => 4,
                    .void, .never => 0,
                    .struct_type => if (ty.extra > 0 and ty.extra - 1 < ast.struct_count) @intCast(ast.struct_defs[ty.extra - 1].total_size) else 8,
                    .fixed_array => @as(i64, @intCast(@max(ty.extra, 1))) * 8,
                    else => 8,
                };
                n.kind = .int_literal;
                n.int_val = sz;
                n.flags = 0;
            } else if (std.mem.eql(u8, bname, "@align_of")) {
                const al: i64 = switch (ty.tag) {
                    .i8, .u8, .bool => 1,
                    .i16, .u16 => 2,
                    .i32, .u32, .f32 => 4,
                    .void, .never => 1,
                    else => 8,
                };
                n.kind = .int_literal;
                n.int_val = al;
                n.flags = 0;
            } else if (std.mem.eql(u8, bname, "@type_name")) {
                var tbuf: [128]u8 = undefined;
                const tn = formatTypeName(ast, ty, &tbuf);
                const sp = ast.addSynthText(tn);
                n.kind = .string_literal;
                n.text_start = sp.start;
                n.text_len = sp.len;
                n.source_id = sp.source_id;
                n.flags = 0;
            }
        }
    }
}

fn synthesizeTestRunner(ast: *AST) void {
    var test_fns: [128]u32 = undefined;
    var test_count: usize = 0;
    var main_node: u32 = 0;

    for (1..ast.count) |i| {
        const n = ast.nodes[i];
        if (n.kind == .fn_decl and n.extra == 0) {
            if ((n.flags & 4) != 0 and test_count < test_fns.len) {
                test_fns[test_count] = @intCast(i);
                test_count += 1;
            } else if (std.mem.eql(u8, ast.nodeText(@intCast(i)), "main")) {
                main_node = @intCast(i);
            }
        }
    }
    if (test_count == 0) return;

    if (main_node != 0) {
        const renamed = ast.addSynthText("__lir_user_main_disabled");
        ast.nodes[main_node].text_start = renamed.start;
        ast.nodes[main_node].text_len = renamed.len;
        ast.nodes[main_node].source_id = renamed.source_id;
    }

    const blk = ast.addNode(.block, 1);
    var head: u32 = 0;
    var tail: u32 = 0;
    const println_sp = ast.addSynthText("println");

    for (test_fns[0..test_count]) |tfn| {
        const tname = ast.nodeText(tfn);
        // call test fn
        const id_node = ast.addNode(.identifier, ast.nodes[tfn].line);
        ast.nodes[id_node].text_start = ast.nodes[tfn].text_start;
        ast.nodes[id_node].text_len = ast.nodes[tfn].text_len;
        ast.nodes[id_node].source_id = ast.nodes[tfn].source_id;
        const call_n = ast.addNode(.call_expr, ast.nodes[tfn].line);
        ast.nodes[call_n].child0 = id_node;
        if (head == 0) head = call_n else ast.stmt_chains[tail] = call_n;
        tail = call_n;

        // println("PASS: <name>")
        var msg_buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "  PASS: {s}", .{tname}) catch "  PASS";
        const msg_sp = ast.addSynthText(msg);
        const str_n = ast.addNode(.string_literal, ast.nodes[tfn].line);
        ast.nodes[str_n].text_start = msg_sp.start;
        ast.nodes[str_n].text_len = msg_sp.len;
        ast.nodes[str_n].source_id = msg_sp.source_id;
        const arg_w = ast.addNode(.expr_stmt, ast.nodes[tfn].line);
        ast.nodes[arg_w].child0 = str_n;
        const p_id = ast.addNode(.identifier, ast.nodes[tfn].line);
        ast.nodes[p_id].text_start = println_sp.start;
        ast.nodes[p_id].text_len = println_sp.len;
        ast.nodes[p_id].source_id = println_sp.source_id;
        const p_call = ast.addNode(.call_expr, ast.nodes[tfn].line);
        ast.nodes[p_call].child0 = p_id;
        ast.nodes[p_call].child2 = arg_w;
        ast.stmt_chains[tail] = p_call;
        tail = p_call;
    }

    var sum_buf: [64]u8 = undefined;
    const sum_msg = std.fmt.bufPrint(&sum_buf, "All {d} tests passed!", .{test_count}) catch "All tests passed!";
    const sum_sp = ast.addSynthText(sum_msg);
    const sum_str = ast.addNode(.string_literal, 1);
    ast.nodes[sum_str].text_start = sum_sp.start;
    ast.nodes[sum_str].text_len = sum_sp.len;
    ast.nodes[sum_str].source_id = sum_sp.source_id;
    const sum_arg = ast.addNode(.expr_stmt, 1);
    ast.nodes[sum_arg].child0 = sum_str;
    const sp_id = ast.addNode(.identifier, 1);
    ast.nodes[sp_id].text_start = println_sp.start;
    ast.nodes[sp_id].text_len = println_sp.len;
    ast.nodes[sp_id].source_id = println_sp.source_id;
    const sp_call = ast.addNode(.call_expr, 1);
    ast.nodes[sp_call].child0 = sp_id;
    ast.nodes[sp_call].child2 = sum_arg;
    ast.stmt_chains[tail] = sp_call;
    tail = sp_call;

    const z = ast.addNode(.int_literal, 1);
    ast.nodes[z].int_val = 0;
    const ret = ast.addNode(.return_stmt, 1);
    ast.nodes[ret].child0 = z;
    ast.stmt_chains[tail] = ret;
    ast.nodes[blk].child0 = head;

    const main_sp = ast.addSynthText("main");
    const mfn = ast.addNode(.fn_decl, 1);
    ast.nodes[mfn].text_start = main_sp.start;
    ast.nodes[mfn].text_len = main_sp.len;
    ast.nodes[mfn].source_id = main_sp.source_id;
    ast.nodes[mfn].type_tag = .i64;
    ast.nodes[mfn].child2 = blk;
}

pub fn expand(ast: *AST, diag: *DiagList, test_mode: bool) !void {
    injectStdGenerics(ast);
    evalComptimeAll(ast, diag);
    monomorphizeAll(ast);
    if (test_mode) synthesizeTestRunner(ast);
}
