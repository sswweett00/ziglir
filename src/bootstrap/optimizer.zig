// ════════════════════════════════════════════════════════════════════════════
// AST OPTIMIZER — Low-level optimizations on the AST before codegen
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const lex = @import("lexer.zig");
const parser = @import("parser.zig");
const sema_mod = @import("sema.zig");

const TokenKind = lex.TokenKind;
const AST = parser.AST;
const ASTNode = parser.ASTNode;
const NodeKind = parser.NodeKind;

const eql = util.eql;

pub const Optimizer = struct {
    ast: *AST,
    src: []const u8,
    sema_info: ?*sema_mod.SemaInfo = null,

    // Constant propagation tracking (flat, per-pass)
    const_count: u32,
    const_name_start: [128]u32,
    const_name_len: [128]u32,
    const_name_src: [128]u32,
    const_value: [128]i64,
    const_active: [128]bool,

    pub fn init(ast: *AST, src: []const u8) Optimizer {
        return .{
            .ast = ast,
            .src = src,
            .const_count = 0,
            .const_name_start = undefined,
            .const_name_len = undefined,
            .const_name_src = undefined,
            .const_value = undefined,
            .const_active = undefined,
        };
    }

    /// Run all optimization passes until no more changes occur.
    pub fn optimize(self: *Optimizer) void {
        var changed = true;
        var passes: u32 = 0;
        while (changed and passes < 10) {
            changed = false;
            self.const_count = 0; // reset constant tracking each pass
            self.walkAndOptimize(&changed);
            self.hoistLoopInvariantCode(&changed);
            passes += 1;
        }
    }

    // ── Top-level walker ─────────────────────────────────────────
    fn walkAndOptimize(self: *Optimizer, changed: *bool) void {
        for (1..self.ast.count) |i| {
            const n = self.ast.nodes[i];
            if (n.kind == .fn_decl and (n.flags & 64) == 0 and n.child2 != 0) {
                self.optimizeBlock(n.child2, changed);
            }
        }
    }

    // ── Block / statement optimization ───────────────────────────
    fn optimizeBlock(self: *Optimizer, block_idx: u32, changed: *bool) void {
        const block = self.ast.nodes[block_idx];
        if (block.kind != .block) return;
        const saved_const_count = self.const_count;
        var stmt_idx = block.child0;
        while (stmt_idx != 0) {
            const next = self.ast.stmt_chains[stmt_idx];
            self.optimizeStmt(stmt_idx, changed);
            stmt_idx = next;
        }
        self.const_count = saved_const_count;
    }

    fn optimizeStmt(self: *Optimizer, idx: u32, changed: *bool) void {
        const node = self.ast.nodes[idx];
        switch (node.kind) {
            .let_stmt => {
                if (node.child0 != 0) {
                    self.optimizeExpr(node.child0, changed);
                    if ((node.flags & 4) == 0) {
                        // Track constant bindings for propagation (after optimizing initializer)
                        const val = self.getConstantValue(node.child0);
                        if (val) |v| {
                            self.trackConst(idx, v);
                        } else if (node.text_len > 0) {
                            // Shadow any outer constant with same name
                            self.invalidateConst(self.textOfSrc(node.text_start, node.text_len, node.source_id), node.source_id);
                        }
                    }
                }
            },
            .return_stmt => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
                // DCE: cut unreachable statements after return
                if (self.ast.stmt_chains[idx] != 0) {
                    self.ast.stmt_chains[idx] = 0;
                    changed.* = true;
                }
            },
            .assign_stmt => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
                if (node.child1 != 0) self.optimizeExpr(node.child1, changed);
                // Invalidate tracked constant for the assigned variable (or all on pointer write)
                if (node.text_len > 0) {
                    self.invalidateConst(self.textOfSrc(node.text_start, node.text_len, node.source_id), node.source_id);
                } else {
                    self.invalidateAllConsts();
                }
            },
            .if_stmt => {
                self.optimizeExpr(node.child0, changed);
                // Constant-condition folding: if (const) { ... } else { ... }
                const val = self.getConstantValue(node.child0);
                if (val) |v| {
                    if (v == 0) {
                        // if false: keep else branch (or empty block)
                        if (node.child2 != 0) {
                            self.ast.nodes[idx] = self.ast.nodes[node.child2];
                        } else {
                            self.ast.nodes[idx] = .{ .kind = .block, .line = node.line, .source_id = node.source_id, .child0 = 0 };
                        }
                        changed.* = true;
                        return; // already replaced, don't recurse into old children
                    } else {
                        // if true: keep then branch
                        self.ast.nodes[idx] = self.ast.nodes[node.child1];
                        changed.* = true;
                        return;
                    }
                }
                // Recurse into branches, invalidating variables modified inside branches afterwards
                const n2 = self.ast.nodes[idx];
                if (n2.child1 != 0) self.optimizeStmt(n2.child1, changed);
                if (n2.child2 != 0) self.optimizeStmt(n2.child2, changed);
                var mod_starts: [128]u32 = undefined;
                var mod_lens: [128]u32 = undefined;
                var mod_srcs: [128]u32 = undefined;
                var mod_count: u32 = 0;
                var has_ptr_write = false;
                if (n2.child1 != 0) self.collectModifiedVarsStmt(n2.child1, &mod_starts, &mod_lens, &mod_srcs, &mod_count, &has_ptr_write);
                if (n2.child2 != 0) self.collectModifiedVarsStmt(n2.child2, &mod_starts, &mod_lens, &mod_srcs, &mod_count, &has_ptr_write);
                if (has_ptr_write) {
                    self.invalidateAllConsts();
                } else {
                    for (0..mod_count) |bi| {
                        const name = self.textOfSrc(mod_starts[bi], mod_lens[bi], mod_srcs[bi]);
                        if (name.len > 0) self.invalidateConst(name, mod_srcs[bi]);
                    }
                }
            },
            .while_stmt => {
                if (node.child1 != 0) {
                    var lb_starts: [128]u32 = undefined;
                    var lb_lens: [128]u32 = undefined;
                    var lb_srcs: [128]u32 = undefined;
                    var lb_count: u32 = 0;
                    var has_ptr_write = false;
                    self.collectModifiedVarsStmt(node.child1, &lb_starts, &lb_lens, &lb_srcs, &lb_count, &has_ptr_write);
                    if (has_ptr_write) {
                        self.invalidateAllConsts();
                    } else {
                        for (0..lb_count) |bi| {
                            const name = self.textOfSrc(lb_starts[bi], lb_lens[bi], lb_srcs[bi]);
                            if (name.len > 0) self.invalidateConst(name, lb_srcs[bi]);
                        }
                    }
                }
                self.optimizeExpr(node.child0, changed);
                // while false → remove loop body entirely
                const val = self.getConstantValue(node.child0);
                if (val) |v| {
                    if (v == 0) {
                        self.ast.nodes[idx] = .{ .kind = .block, .line = node.line, .source_id = node.source_id, .child0 = 0 };
                        changed.* = true;
                        return;
                    }
                }
                const n2 = self.ast.nodes[idx];
                if (n2.child1 != 0) self.optimizeBlock(n2.child1, changed);
            },
            .for_stmt => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
                if (node.child2 != 0) self.optimizeExpr(node.child2, changed);
                if (node.child1 != 0) {
                    var fb_starts: [128]u32 = undefined;
                    var fb_lens: [128]u32 = undefined;
                    var fb_srcs: [128]u32 = undefined;
                    var fb_count: u32 = 0;
                    var has_ptr_write = false;
                    self.collectModifiedVarsStmt(node.child1, &fb_starts, &fb_lens, &fb_srcs, &fb_count, &has_ptr_write);
                    if (has_ptr_write) {
                        self.invalidateAllConsts();
                    } else {
                        for (0..fb_count) |bi| {
                            const name = self.textOfSrc(fb_starts[bi], fb_lens[bi], fb_srcs[bi]);
                            if (name.len > 0) self.invalidateConst(name, fb_srcs[bi]);
                        }
                    }
                    // Also invalidate the loop iteration variable itself
                    if (node.text_len > 0) {
                        const lv = self.textOfSrc(node.text_start, node.text_len, node.source_id);
                        if (lv.len > 0) self.invalidateConst(lv, node.source_id);
                    }
                    self.optimizeBlock(node.child1, changed);
                }
            },
            .break_stmt, .continue_stmt, .unreachable_stmt => {
                // DCE: cut unreachable statements after control terminator
                if (self.ast.stmt_chains[idx] != 0) {
                    self.ast.stmt_chains[idx] = 0;
                    changed.* = true;
                }
            },
            .expr_stmt => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
            },
            .call_expr => {
                // Bare call as statement — optimize arguments
                self.optimizeCallArgs(idx, changed);
            },
            .defer_stmt => {
                if (node.child0 != 0) self.optimizeStmt(node.child0, changed);
            },
            .block => {
                self.optimizeBlock(idx, changed);
            },
            else => {
                self.optimizeExpr(idx, changed);
            },
        }
    }

    // ── Expression optimization ───────────────────────────────────
    fn optimizeExpr(self: *Optimizer, idx: u32, changed: *bool) void {
        if (idx == 0) return;
        const node = self.ast.nodes[idx];
        switch (node.kind) {
            .binary_expr => {
                self.optimizeExpr(node.child0, changed);
                self.optimizeExpr(node.child1, changed);
                self.foldBinaryExpr(idx, changed);
            },
            .unary_expr => {
                self.optimizeExpr(node.child0, changed);
                self.foldUnaryExpr(idx, changed);
            },
            .cast_expr => {
                self.optimizeExpr(node.child0, changed);
            },
            .ternary_expr => {
                self.optimizeExpr(node.child0, changed);
                self.optimizeExpr(node.child1, changed);
                self.optimizeExpr(node.child2, changed);
                self.foldTernaryExpr(idx, changed);
            },
            .match_expr => {
                self.optimizeExpr(node.child0, changed);
                var arm = node.child1;
                while (arm != 0) : (arm = self.ast.nodes[arm].child2) {
                    var pat = self.ast.nodes[arm].child0;
                    while (pat != 0) : (pat = self.ast.stmt_chains[pat]) {
                        self.optimizeExpr(pat, changed);
                    }
                    if (self.ast.nodes[arm].extra != 0) self.optimizeExpr(self.ast.nodes[arm].extra, changed);
                    const body = self.ast.nodes[arm].child1;
                    if (body != 0) self.optimizeStmt(body, changed);
                }
                if (node.child2 != 0) self.optimizeStmt(node.child2, changed);
            },
            .if_stmt => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
                if (node.child1 != 0) self.optimizeStmt(node.child1, changed);
                if (node.child2 != 0) self.optimizeStmt(node.child2, changed);
                self.invalidateAllConsts();
            },
            .array_lit, .tuple_lit => {
                if (node.kind == .array_lit and (node.flags & 1) != 0) {
                    if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
                    if (node.child1 != 0) self.optimizeExpr(node.child1, changed);
                } else {
                    var elem = node.child0;
                    while (elem != 0) : (elem = self.ast.nodes[elem].child1) {
                        if (self.ast.nodes[elem].child0 != 0) self.optimizeExpr(self.ast.nodes[elem].child0, changed);
                    }
                }
            },
            .map_lit => {
                var pair = node.child0;
                while (pair != 0) : (pair = self.ast.nodes[pair].child1) {
                    if (self.ast.nodes[pair].child0 != 0) self.optimizeExpr(self.ast.nodes[pair].child0, changed);
                    if (self.ast.nodes[pair].child2 != 0) self.optimizeExpr(self.ast.nodes[pair].child2, changed);
                }
            },
            .list_comp => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
                if (node.child1 != 0) self.optimizeExpr(node.child1, changed);
                if ((node.flags & 2) != 0 and node.extra != 0) self.optimizeExpr(node.extra, changed);
                if (node.child2 != 0) self.optimizeExpr(node.child2, changed);
            },
            .interp_string => {
                var seg = node.child0;
                while (seg != 0) : (seg = self.ast.stmt_chains[seg]) {
                    self.optimizeExpr(seg, changed);
                }
            },
            .try_expr, .spawn_expr, .comptime_expr => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
            },
            .coalesce_expr => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
                if (node.child1 != 0) self.optimizeExpr(node.child1, changed);
            },
            .closure_expr => {
                // Optimize inside closure body with fresh const scope
                if (node.child2 != 0) {
                    const saved_cc = self.const_count;
                    self.const_count = 0;
                    self.optimizeBlock(node.child2, changed);
                    self.const_count = saved_cc;
                }
            },
            .call_expr => {
                self.optimizeCallArgs(idx, changed);
            },
            .method_call, .scoped_access => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
                self.optimizeCallArgs(idx, changed);
            },
            .identifier => {
                self.propagateConst(idx, changed);
            },
            .field_access => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
            },
            .index_expr => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
                if (node.child1 != 0) self.optimizeExpr(node.child1, changed);
            },
            .addr_of => {
                if (node.child0 != 0) {
                    // Taking the address of a variable invalidates constant propagation for it
                    const sub = self.ast.nodes[node.child0];
                    if (sub.kind == .identifier and sub.text_len > 0) {
                        self.invalidateConst(self.textOf(sub.text_start, sub.text_len), sub.source_id);
                    } else {
                        self.optimizeExpr(node.child0, changed);
                    }
                }
            },
            .deref => {
                if (node.child0 != 0) self.optimizeExpr(node.child0, changed);
            },
            else => {},
        }
    }

    fn optimizeCallArgs(self: *Optimizer, call_idx: u32, changed: *bool) void {
        var ai = self.ast.nodes[call_idx].child2;
        while (ai != 0) {
            const arg = self.ast.nodes[ai].child0;
            if (arg != 0) self.optimizeExpr(arg, changed);
            ai = self.ast.nodes[ai].child1;
        }
    }

    // ── Constant folding for binary expressions ──────────────────
    fn foldBinaryExpr(self: *Optimizer, idx: u32, changed: *bool) void {
        const node = self.ast.nodes[idx];
        if (node.child0 == 0 or node.child1 == 0) return;
        if (self.sema_info) |si| {
            if (si.is_float_op[idx] or si.is_string_op[idx]) return;
        }
        const left = self.ast.nodes[node.child0];
        const right = self.ast.nodes[node.child1];
        const op: TokenKind = @enumFromInt(node.op);

        // ── Full constant folding: int_literal OP int_literal ──
        if (left.kind == .int_literal and right.kind == .int_literal) {
            const a = left.int_val;
            const b = right.int_val;
            const is_uns = if (self.sema_info) |si| si.is_unsigned_op[idx] else false;
            const ua: u64 = @bitCast(a);
            const ub: u64 = @bitCast(b);
            const result: i64 = switch (op) {
                .plus => a +% b,
                .minus => a -% b,
                .star => a *% b,
                .slash => if (is_uns)
                    (if (ub != 0) @bitCast(ua / ub) else return)
                else
                    (if (b != 0 and !(a == std.math.minInt(i64) and b == -1)) @divTrunc(a, b) else return),
                .percent => if (is_uns)
                    (if (ub != 0) @bitCast(ua % ub) else return)
                else
                    (if (b != 0 and !(a == std.math.minInt(i64) and b == -1)) @rem(a, b) else return),
                .eq => if (a == b) 1 else 0,
                .ne => if (a != b) 1 else 0,
                .lt => if (is_uns) (if (ua < ub) @as(i64, 1) else 0) else (if (a < b) @as(i64, 1) else 0),
                .gt => if (is_uns) (if (ua > ub) @as(i64, 1) else 0) else (if (a > b) @as(i64, 1) else 0),
                .le => if (is_uns) (if (ua <= ub) @as(i64, 1) else 0) else (if (a <= b) @as(i64, 1) else 0),
                .ge => if (is_uns) (if (ua >= ub) @as(i64, 1) else 0) else (if (a >= b) @as(i64, 1) else 0),
                .and_and => if (a != 0 and b != 0) 1 else 0,
                .pipe_pipe => if (a != 0 or b != 0) 1 else 0,
                .amp => a & b,
                .pipe => a | b,
                .caret => a ^ b,
                .lshift => if (b >= 0 and b < 64) a << @as(u6, @intCast(b)) else return,
                .rshift => if (b >= 0 and b < 64) (if (is_uns) @bitCast(ua >> @as(u6, @intCast(b))) else a >> @as(u6, @intCast(b))) else return,
                else => return,
            };
            self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = result };
            changed.* = true;
            return;
        }

        // ── Algebraic identities & strength reduction ────────────
        if (left.kind == .int_literal) {
            const a = left.int_val;
            switch (op) {
                .plus => {
                    if (a == 0) {
                        self.replaceWithChild(idx, node.child1, changed);
                        return;
                    }
                },
                .minus => {
                    if (a == 0) {
                        // 0 - x → -(x)
                        self.ast.nodes[idx] = .{ .kind = .unary_expr, .line = node.line, .child0 = node.child1, .op = @intFromEnum(TokenKind.minus) };
                        changed.* = true;
                        return;
                    }
                },
                .star => {
                    if (a == 0 and self.isPureExpr(node.child1)) {
                        self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = 0 };
                        changed.* = true;
                        return;
                    }
                    if (a == 1) {
                        self.replaceWithChild(idx, node.child1, changed);
                        return;
                    }
                },
                // Do not fold 0 / x unless both operands were constant.
                // Unknown x may be zero (division trap) or have side effects.
                .slash => {},
                .and_and => {
                    if (a == 0) {
                        self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = 0 };
                        changed.* = true;
                        return;
                    }
                    if (a != 0) {
                        self.replaceWithChild(idx, node.child1, changed);
                        return;
                    }
                },
                .pipe_pipe => {
                    if (a != 0) {
                        self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = 1 };
                        changed.* = true;
                        return;
                    }
                    if (a == 0) {
                        self.replaceWithChild(idx, node.child1, changed);
                        return;
                    }
                },
                else => {},
            }
        }

        if (right.kind == .int_literal) {
            const b = right.int_val;
            switch (op) {
                .plus => {
                    if (b == 0) {
                        self.replaceWithChild(idx, node.child0, changed);
                        return;
                    }
                },
                .minus => {
                    if (b == 0) {
                        self.replaceWithChild(idx, node.child0, changed);
                        return;
                    }
                },
                .star => {
                    if (b == 0 and self.isPureExpr(node.child0)) {
                        self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = 0 };
                        changed.* = true;
                        return;
                    }
                    if (b == 1) {
                        self.replaceWithChild(idx, node.child0, changed);
                        return;
                    }
                },
                .percent => {
                    if (b == 1 and self.isPureExpr(node.child0)) {
                        self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = 0 };
                        changed.* = true;
                        return;
                    }
                },
                .and_and => {
                    if (b == 0 and self.isPureExpr(node.child0)) {
                        self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = 0 };
                        changed.* = true;
                        return;
                    }
                    if (b != 0) {
                        self.replaceWithChild(idx, node.child0, changed);
                        return;
                    }
                },
                .pipe_pipe => {
                    if (b != 0 and self.isPureExpr(node.child0)) {
                        self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = 1 };
                        changed.* = true;
                        return;
                    }
                    if (b == 0) {
                        self.replaceWithChild(idx, node.child0, changed);
                        return;
                    }
                },
                else => {},
            }
        }

        // ── Strength reduction: x * 2^n → x << n ───────────────
        if (op == .star) {
            if (left.kind == .int_literal) {
                const a = left.int_val;
                if (a > 0 and (a & (a -% 1)) == 0) {
                    const shift_amt: i64 = @intCast(@ctz(@as(u64, @bitCast(a))));
                    self.ast.nodes[idx] = .{
                        .kind = .binary_expr,
                        .line = node.line,
                        .child0 = node.child1,
                        .child1 = self.makeIntLiteral(node.line, shift_amt),
                        .op = @intFromEnum(TokenKind.lshift),
                    };
                    changed.* = true;
                    return;
                }
            }
            if (right.kind == .int_literal) {
                const b = right.int_val;
                if (b > 0 and (b & (b -% 1)) == 0) {
                    const shift_amt: i64 = @intCast(@ctz(@as(u64, @bitCast(b))));
                    self.ast.nodes[idx] = .{
                        .kind = .binary_expr,
                        .line = node.line,
                        .child0 = node.child0,
                        .child1 = self.makeIntLiteral(node.line, shift_amt),
                        .op = @intFromEnum(TokenKind.lshift),
                    };
                    changed.* = true;
                    return;
                }
            }
        }

        // ── Strength reduction: x / 2^n → x >> n (when safe) ───
        if (op == .slash and right.kind == .int_literal) {
            const b = right.int_val;
            if (b > 0 and (b & (b -% 1)) == 0) {
                // Also check that the dividend is known non-negative
                if (left.kind == .int_literal and left.int_val >= 0) {
                    const shift_amt: i64 = @intCast(@ctz(@as(u64, @bitCast(b))));
                    self.ast.nodes[idx] = .{
                        .kind = .binary_expr,
                        .line = node.line,
                        .child0 = node.child0,
                        .child1 = self.makeIntLiteral(node.line, shift_amt),
                        .op = @intFromEnum(TokenKind.rshift),
                    };
                    changed.* = true;
                    return;
                }
            }
        }

        // ── Identity comparison: x == x → 1, x != x → 0 ────────
        if (node.child0 == node.child1 and self.isPureExpr(node.child0)) {
            if (op == .eq) {
                self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = 1 };
                changed.* = true;
            } else if (op == .ne) {
                self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = 0 };
                changed.* = true;
            }
        }
    }

    // ── Constant folding for unary expressions ──────────────────
    fn foldUnaryExpr(self: *Optimizer, idx: u32, changed: *bool) void {
        const node = self.ast.nodes[idx];
        if (node.child0 == 0) return;
        const inner = self.ast.nodes[node.child0];
        const op: TokenKind = @enumFromInt(node.op);

        // !int_literal or -int_literal
        if (inner.kind == .int_literal) {
            const result: i64 = switch (op) {
                .minus => -%inner.int_val,
                .bang => if (inner.int_val == 0) 1 else 0,
                else => return,
            };
            self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = result };
            changed.* = true;
            return;
        }

        // Do not rewrite !!x to x: logical negation normalizes values to
        // 0/1, so !!42 is 1 rather than 42. A future boolean-aware IR pass
        // can safely simplify this when the value is already known boolean.
    }

    // ── Ternary simplification ─────────────────────────────────
    fn foldTernaryExpr(self: *Optimizer, idx: u32, changed: *bool) void {
        const node = self.ast.nodes[idx];
        const cond = self.ast.nodes[node.child0];
        if (cond.kind == .int_literal) {
            if (cond.int_val != 0) {
                self.replaceWithChild(idx, node.child1, changed);
            } else {
                self.replaceWithChild(idx, node.child2, changed);
            }
        }
    }

    // ── Helpers ─────────────────────────────────────────────────

    /// Replace node at `idx` with a shallow copy of node at `child_idx`.
    fn replaceWithChild(self: *Optimizer, idx: u32, child_idx: u32, changed: *bool) void {
        self.ast.nodes[idx] = self.ast.nodes[child_idx];
        if (self.sema_info) |si| {
            si.node_types[idx] = si.node_types[child_idx];
            si.field_offsets[idx] = si.field_offsets[child_idx];
            si.struct_indices[idx] = si.struct_indices[child_idx];
            si.is_string_op[idx] = si.is_string_op[child_idx];
            si.is_float_op[idx] = si.is_float_op[child_idx];
            si.is_len_prop[idx] = si.is_len_prop[child_idx];
            si.is_const_val[idx] = si.is_const_val[child_idx];
            si.const_vals[idx] = si.const_vals[child_idx];
            si.method_fn_nodes[idx] = si.method_fn_nodes[child_idx];
            si.is_method_auto_ref[idx] = si.is_method_auto_ref[child_idx];
            si.is_unsigned_op[idx] = si.is_unsigned_op[child_idx];
            si.enum_def_idx[idx] = si.enum_def_idx[child_idx];
            si.enum_variant_idx[idx] = si.enum_variant_idx[child_idx];
            si.closure_ids[idx] = si.closure_ids[child_idx];
            si.trait_impl_idx[idx] = si.trait_impl_idx[child_idx];
        }
        changed.* = true;
    }

    /// Create a fresh int_literal node; returns its index.
    fn makeIntLiteral(self: *Optimizer, line: u32, value: i64) u32 {
        const n = self.ast.addNode(.int_literal, line);
        self.ast.nodes[n].int_val = value;
        return n;
    }

    /// If `idx` points to an int_literal, return its value.
    fn getConstantValue(self: *const Optimizer, idx: u32) ?i64 {
        if (idx == 0) return null;
        const n = self.ast.nodes[idx];
        if (n.kind == .int_literal) return n.int_val;
        return null;
    }

    // ── Constant propagation ─────────────────────────────────────

    fn trackConst(self: *Optimizer, let_idx: u32, value: i64) void {
        const node = self.ast.nodes[let_idx];
        if (self.const_count >= 128) return;
        const i = self.const_count;
        self.const_name_start[i] = node.text_start;
        self.const_name_len[i] = node.text_len;
        self.const_name_src[i] = node.source_id;
        self.const_value[i] = value;
        self.const_active[i] = true;
        self.const_count += 1;
    }

    fn textOfSrc(self: *const Optimizer, start: u32, len: u32, source_id: u32) []const u8 {
        if (source_id < self.ast.source_count) {
            return self.ast.nodeTextSrcFrom(start, len, source_id);
        }
        if (@as(usize, start) + @as(usize, len) <= self.src.len) return self.src[start..][0..len];
        return "";
    }

    fn textOf(self: *const Optimizer, start: u32, len: u32) []const u8 {
        return self.textOfSrc(start, len, 0);
    }

    fn invalidateConst(self: *Optimizer, name: []const u8, src_id: u32) void {
        for (0..self.const_count) |i| {
            if (!self.const_active[i]) continue;
            if (self.const_name_len[i] != name.len) continue;
            if (self.const_name_src[i] != src_id) continue;
            if (eql(self.textOfSrc(self.const_name_start[i], self.const_name_len[i], src_id), name))
                self.const_active[i] = false;
        }
    }

    fn invalidateAllConsts(self: *Optimizer) void {
        for (0..self.const_count) |i| {
            self.const_active[i] = false;
        }
    }

    fn propagateConst(self: *Optimizer, idx: u32, changed: *bool) void {
        const node = self.ast.nodes[idx];
        if (node.text_len == 0) return;
        // Never overwrite a Sema-resolved constant or identifier from another scope if needed;
        // search newest-to-oldest so shadowed bindings resolve properly
        var i: u32 = self.const_count;
        while (i > 0) {
            i -= 1;
            if (!self.const_active[i]) continue;
            if (self.const_name_len[i] != node.text_len) continue;
            if (self.const_name_src[i] != node.source_id) continue;
            if (eql(self.textOfSrc(self.const_name_start[i], self.const_name_len[i], node.source_id),
                self.textOfSrc(node.text_start, node.text_len, node.source_id)))
            {
                self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .source_id = node.source_id, .int_val = self.const_value[i] };
                changed.* = true;
                return;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // Loop-Invariant Code Motion (LICM)
    // ═══════════════════════════════════════════════════════════════

    /// Top-level entry: walk all fn_decl bodies looking for loops.
    fn hoistLoopInvariantCode(self: *Optimizer, changed: *bool) void {
        for (1..self.ast.count) |i| {
            const n = self.ast.nodes[i];
            if (n.kind == .fn_decl and (n.flags & 64) == 0 and n.child2 != 0) {
                self.hoistInBlock(n.child2, changed);
            }
        }
    }

    /// Recursively walk a block, processing loops it contains.
    fn hoistInBlock(self: *Optimizer, block_idx: u32, changed: *bool) void {
        const block = self.ast.nodes[block_idx];
        if (block.kind != .block) return;

        var prev_idx: u32 = 0;
        var stmt_idx = block.child0;
        while (stmt_idx != 0) {
            const next = self.ast.stmt_chains[stmt_idx];
            const n = self.ast.nodes[stmt_idx];
            switch (n.kind) {
                .while_stmt => {
                    if (n.child1 != 0) {
                        self.hoistFromLoop(block_idx, prev_idx, stmt_idx, n.child1, changed);
                        self.hoistInBlock(n.child1, changed);
                    }
                },
                .for_stmt => {
                    if (n.child1 != 0) {
                        self.hoistFromLoop(block_idx, prev_idx, stmt_idx, n.child1, changed);
                        self.hoistInBlock(n.child1, changed);
                    }
                },
                .if_stmt => {
                    if (n.child1 != 0) self.hoistInBlock(n.child1, changed);
                    if (n.child2 != 0) self.hoistInBlock(n.child2, changed);
                },
                .block => self.hoistInBlock(stmt_idx, changed),
                else => {},
            }
            prev_idx = stmt_idx;
            stmt_idx = next;
        }
    }

    fn collectModifiedVarsStmt(self: *const Optimizer, stmt_idx: u32, out_starts: []u32, out_lens: []u32, out_srcs: []u32, out_count: *u32, has_ptr_write: *bool) void {
        if (stmt_idx == 0) return;
        const n = self.ast.nodes[stmt_idx];
        switch (n.kind) {
            .assign_stmt => {
                if (n.text_len > 0) {
                    if (out_count.* < out_starts.len and
                        !self.nameInSet(n.text_start, n.text_len, n.source_id, out_starts, out_lens, out_srcs, out_count.*))
                    {
                        out_starts[out_count.*] = n.text_start;
                        out_lens[out_count.*] = n.text_len;
                        out_srcs[out_count.*] = n.source_id;
                        out_count.* += 1;
                    }
                } else {
                    has_ptr_write.* = true;
                }
            },
            .for_stmt => {
                if (n.text_len > 0 and out_count.* < out_starts.len) {
                    if (!self.nameInSet(n.text_start, n.text_len, n.source_id, out_starts, out_lens, out_srcs, out_count.*)) {
                        out_starts[out_count.*] = n.text_start;
                        out_lens[out_count.*] = n.text_len;
                        out_srcs[out_count.*] = n.source_id;
                        out_count.* += 1;
                    }
                }
                if (n.child1 != 0) self.collectModifiedVarsStmt(n.child1, out_starts, out_lens, out_srcs, out_count, has_ptr_write);
            },
            .while_stmt => {
                if (n.child1 != 0) self.collectModifiedVarsStmt(n.child1, out_starts, out_lens, out_srcs, out_count, has_ptr_write);
            },
            .if_stmt => {
                if (n.child1 != 0) self.collectModifiedVarsStmt(n.child1, out_starts, out_lens, out_srcs, out_count, has_ptr_write);
                if (n.child2 != 0) self.collectModifiedVarsStmt(n.child2, out_starts, out_lens, out_srcs, out_count, has_ptr_write);
            },
            .match_expr => {
                var arm = n.child1;
                while (arm != 0) : (arm = self.ast.nodes[arm].child2) {
                    if (self.ast.nodes[arm].child1 != 0) {
                        self.collectModifiedVarsStmt(self.ast.nodes[arm].child1, out_starts, out_lens, out_srcs, out_count, has_ptr_write);
                    }
                }
                if (n.child2 != 0) self.collectModifiedVarsStmt(n.child2, out_starts, out_lens, out_srcs, out_count, has_ptr_write);
            },
            .defer_stmt => {
                if (n.child0 != 0) self.collectModifiedVarsStmt(n.child0, out_starts, out_lens, out_srcs, out_count, has_ptr_write);
            },
            .block => self.collectModifiedVars(stmt_idx, out_starts, out_lens, out_srcs, out_count, has_ptr_write),
            else => {},
        }
    }

    fn collectModifiedVars(self: *const Optimizer, block_idx: u32, out_starts: []u32, out_lens: []u32, out_srcs: []u32, out_count: *u32, has_ptr_write: *bool) void {
        var stmt_idx = self.ast.nodes[block_idx].child0;
        while (stmt_idx != 0) {
            self.collectModifiedVarsStmt(stmt_idx, out_starts, out_lens, out_srcs, out_count, has_ptr_write);
            stmt_idx = self.ast.stmt_chains[stmt_idx];
        }
    }

    /// Return true if (name_start, name_len, source_id) already exists in the set.
    fn nameInSet(self: *const Optimizer, start: u32, len: u32, src_id: u32, starts: []const u32, lens: []const u32, srcs: []const u32, count: u32) bool {
        const name = self.textOfSrc(start, len, src_id);
        for (0..count) |i| {
            if (lens[i] == len and srcs[i] == src_id and eql(self.textOfSrc(starts[i], lens[i], srcs[i]), name)) return true;
        }
        return false;
    }

    /// Return true if `idx` references any variable in the modified set.
    fn exprRefsModified(self: *const Optimizer, idx: u32, mod_starts: []const u32, mod_lens: []const u32, mod_srcs: []const u32, mod_count: u32) bool {
        if (idx == 0) return false;
        const n = self.ast.nodes[idx];
        switch (n.kind) {
            .identifier => {
                if (n.text_len == 0) return false;
                return self.nameInSet(n.text_start, n.text_len, n.source_id, mod_starts, mod_lens, mod_srcs, mod_count);
            },
            .binary_expr => {
                return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_srcs, mod_count) or
                    self.exprRefsModified(n.child1, mod_starts, mod_lens, mod_srcs, mod_count);
            },
            .unary_expr, .addr_of, .deref, .cast_expr, .try_expr, .spawn_expr, .comptime_expr => {
                return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_srcs, mod_count);
            },
            .coalesce_expr => {
                return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_srcs, mod_count) or
                    self.exprRefsModified(n.child1, mod_starts, mod_lens, mod_srcs, mod_count);
            },
            .ternary_expr => {
                return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_srcs, mod_count) or
                    self.exprRefsModified(n.child1, mod_starts, mod_lens, mod_srcs, mod_count) or
                    self.exprRefsModified(n.child2, mod_starts, mod_lens, mod_srcs, mod_count);
            },
            .call_expr, .method_call, .scoped_access => {
                // Check callee/receiver and arguments.
                if (self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_srcs, mod_count)) return true;
                var ai = n.child2;
                while (ai != 0) {
                    if (self.exprRefsModified(self.ast.nodes[ai].child0, mod_starts, mod_lens, mod_srcs, mod_count)) return true;
                    ai = self.ast.nodes[ai].child1;
                }
                return false;
            },
            .tuple_lit, .array_lit => {
                if (n.kind == .array_lit and (n.flags & 1) != 0) {
                    return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_srcs, mod_count) or
                        self.exprRefsModified(n.child1, mod_starts, mod_lens, mod_srcs, mod_count);
                }
                var elem = n.child0;
                while (elem != 0) : (elem = self.ast.nodes[elem].child1) {
                    if (self.exprRefsModified(self.ast.nodes[elem].child0, mod_starts, mod_lens, mod_srcs, mod_count)) return true;
                }
                return false;
            },
            .interp_string => {
                var seg = n.child0;
                while (seg != 0) : (seg = self.ast.stmt_chains[seg]) {
                    if (self.exprRefsModified(seg, mod_starts, mod_lens, mod_srcs, mod_count)) return true;
                }
                return false;
            },
            .field_access => {
                return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_srcs, mod_count);
            },
            .index_expr => {
                return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_srcs, mod_count) or
                    self.exprRefsModified(n.child1, mod_starts, mod_lens, mod_srcs, mod_count);
            },
            else => return false,
        }
    }

    /// Return true when `idx` is pure and cannot trap (safe for DCE and speculative LICM).
    fn isPureExpr(self: *const Optimizer, idx: u32) bool {
        if (idx == 0) return true;
        const n = self.ast.nodes[idx];
        switch (n.kind) {
            .int_literal, .string_literal, .identifier => return true,
            .binary_expr => {
                const op: TokenKind = @enumFromInt(n.op);
                if (op == .slash or op == .percent) {
                    // Division/modulo can trap with SIGFPE on divisor==0 or MIN_INT/-1
                    const rhs = self.ast.nodes[n.child1];
                    if (rhs.kind != .int_literal or rhs.int_val == 0 or rhs.int_val == -1) return false;
                }
                return self.isPureExpr(n.child0) and self.isPureExpr(n.child1);
            },
            .unary_expr, .addr_of => return self.isPureExpr(n.child0),
            .ternary_expr => {
                return self.isPureExpr(n.child0) and self.isPureExpr(n.child1) and self.isPureExpr(n.child2);
            },
            // Memory reads and function calls can fault or observe mutations
            else => return false,
        }
    }

    fn collectLoopLetsStmt(self: *const Optimizer, stmt_idx: u32, out_starts: []u32, out_lens: []u32, out_srcs: []u32, out_count: *u32) void {
        if (stmt_idx == 0) return;
        const n = self.ast.nodes[stmt_idx];
        switch (n.kind) {
            .let_stmt => {
                if (n.text_len > 0 and out_count.* < out_starts.len and
                    !self.nameInSet(n.text_start, n.text_len, n.source_id, out_starts, out_lens, out_srcs, out_count.*))
                {
                    out_starts[out_count.*] = n.text_start;
                    out_lens[out_count.*] = n.text_len;
                    out_srcs[out_count.*] = n.source_id;
                    out_count.* += 1;
                }
            },
            .for_stmt => {
                if (n.text_len > 0 and out_count.* < out_starts.len and
                    !self.nameInSet(n.text_start, n.text_len, n.source_id, out_starts, out_lens, out_srcs, out_count.*))
                {
                    out_starts[out_count.*] = n.text_start;
                    out_lens[out_count.*] = n.text_len;
                    out_srcs[out_count.*] = n.source_id;
                    out_count.* += 1;
                }
                if (n.child1 != 0) self.collectLoopLetsStmt(n.child1, out_starts, out_lens, out_srcs, out_count);
            },
            .while_stmt => {
                if (n.child1 != 0) self.collectLoopLetsStmt(n.child1, out_starts, out_lens, out_srcs, out_count);
            },
            .if_stmt => {
                if (n.child1 != 0) self.collectLoopLetsStmt(n.child1, out_starts, out_lens, out_srcs, out_count);
                if (n.child2 != 0) self.collectLoopLetsStmt(n.child2, out_starts, out_lens, out_srcs, out_count);
            },
            .match_expr => {
                var arm = n.child1;
                while (arm != 0) : (arm = self.ast.nodes[arm].child2) {
                    if (self.ast.nodes[arm].child1 != 0) {
                        self.collectLoopLetsStmt(self.ast.nodes[arm].child1, out_starts, out_lens, out_srcs, out_count);
                    }
                }
                if (n.child2 != 0) self.collectLoopLetsStmt(n.child2, out_starts, out_lens, out_srcs, out_count);
            },
            .defer_stmt => {
                if (n.child0 != 0) self.collectLoopLetsStmt(n.child0, out_starts, out_lens, out_srcs, out_count);
            },
            .block => {
                var c = n.child0;
                while (c != 0) : (c = self.ast.stmt_chains[c]) {
                    self.collectLoopLetsStmt(c, out_starts, out_lens, out_srcs, out_count);
                }
            },
            else => {},
        }
    }

    fn hoistFromLoop(self: *Optimizer, parent_block: u32, prev_of_loop_in: u32, loop_idx: u32, body_idx: u32, changed: *bool) void {
        var prev_of_loop = prev_of_loop_in;
        const body = self.ast.nodes[body_idx];
        if (body.kind != .block) return;

        // 1. Collect variables modified anywhere in the loop body.
        var mod_starts: [128]u32 = undefined;
        var mod_lens: [128]u32 = undefined;
        var mod_srcs: [128]u32 = undefined;
        var mod_count: u32 = 0;
        var has_ptr_write = false;
        self.collectModifiedVars(body_idx, &mod_starts, &mod_lens, &mod_srcs, &mod_count, &has_ptr_write);
        if (mod_count == 0 or has_ptr_write) return;

        // Also collect all loop-local bindings so we never hoist `let hi = f(b)` out
        // past an unhoisted loop-local `let b = ...`.
        var dep_starts: [128]u32 = undefined;
        var dep_lens: [128]u32 = undefined;
        var dep_srcs: [128]u32 = undefined;
        var dep_count: u32 = mod_count;
        for (0..mod_count) |mi| {
            dep_starts[mi] = mod_starts[mi];
            dep_lens[mi] = mod_lens[mi];
            dep_srcs[mi] = mod_srcs[mi];
        }
        self.collectLoopLetsStmt(body_idx, &dep_starts, &dep_lens, &dep_srcs, &dep_count);

        // 2. Walk the body looking for hoistable let statements.
        var prev_body: u32 = 0;
        var stmt_idx = body.child0;
        while (stmt_idx != 0) {
            const next = self.ast.stmt_chains[stmt_idx];
            const n = self.ast.nodes[stmt_idx];

            if (n.kind == .let_stmt and (n.flags & 4) == 0 and n.text_len > 0 and n.child0 != 0) {
                const var_is_clean = !self.nameInSet(n.text_start, n.text_len, n.source_id, &mod_starts, &mod_lens, &mod_srcs, mod_count);
                const init_ok = self.isPureExpr(n.child0) and
                    !self.exprRefsModified(n.child0, &dep_starts, &dep_lens, &dep_srcs, dep_count);
                // Ensure we don't hoist a variable that shadows a prior reference in the loop
                const referenced_before = self.loopUsesNameBefore(loop_idx, body_idx, n.text_start, n.text_len, n.source_id, stmt_idx);

                if (var_is_clean and init_ok and !referenced_before) {
                    if (prev_body == 0) {
                        self.ast.nodes[body_idx].child0 = next;
                    } else {
                        self.ast.stmt_chains[prev_body] = next;
                    }
                    self.ast.stmt_chains[stmt_idx] = loop_idx;
                    if (prev_of_loop == 0) {
                        self.ast.nodes[parent_block].child0 = stmt_idx;
                    } else {
                        self.ast.stmt_chains[prev_of_loop] = stmt_idx;
                    }
                    prev_of_loop = stmt_idx;
                    changed.* = true;
                    stmt_idx = next;
                    continue;
                }
            }

            prev_body = stmt_idx;
            stmt_idx = next;
        }
    }

    fn loopUsesNameBefore(self: *const Optimizer, loop_idx: u32, body_idx: u32, start: u32, len: u32, src_id: u32, limit_stmt: u32) bool {
        if (len == 0) return true;
        const lp = self.ast.nodes[loop_idx];
        var s = [1]u32{start};
        var l = [1]u32{len};
        var sr = [1]u32{src_id};
        if (lp.child0 != 0 and self.exprRefsModified(lp.child0, &s, &l, &sr, 1)) return true;
        var cur = self.ast.nodes[body_idx].child0;
        while (cur != 0 and cur != limit_stmt) {
            if (self.stmtRefsName(cur, &s, &l, &sr)) return true;
            cur = self.ast.stmt_chains[cur];
        }
        return false;
    }

    fn stmtRefsName(self: *const Optimizer, idx: u32, s: []const u32, l: []const u32, sr: []const u32) bool {
        if (idx == 0) return false;
        const n = self.ast.nodes[idx];
        return switch (n.kind) {
            .let_stmt, .return_stmt, .expr_stmt => self.exprRefsModified(n.child0, s, l, sr, 1),
            .assign_stmt => self.exprRefsModified(n.child0, s, l, sr, 1) or self.exprRefsModified(n.child1, s, l, sr, 1),
            .if_stmt => self.exprRefsModified(n.child0, s, l, sr, 1) or self.stmtRefsName(n.child1, s, l, sr) or self.stmtRefsName(n.child2, s, l, sr),
            .while_stmt => self.exprRefsModified(n.child0, s, l, sr, 1) or self.stmtRefsName(n.child1, s, l, sr),
            .for_stmt => self.exprRefsModified(n.child0, s, l, sr, 1) or self.exprRefsModified(n.child2, s, l, sr, 1) or self.stmtRefsName(n.child1, s, l, sr),
            .block => blk: {
                var c = n.child0;
                while (c != 0) : (c = self.ast.stmt_chains[c]) {
                    if (self.stmtRefsName(c, s, l, sr)) break :blk true;
                }
                break :blk false;
            },
            else => self.exprRefsModified(idx, s, l, sr, 1),
        };
    }
};

