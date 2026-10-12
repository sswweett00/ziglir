// ════════════════════════════════════════════════════════════════════════════
// AST OPTIMIZER — Low-level optimizations on the AST before codegen
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const lex = @import("lexer.zig");
const parser = @import("parser.zig");

const TokenKind = lex.TokenKind;
const AST = parser.AST;
const ASTNode = parser.ASTNode;
const NodeKind = parser.NodeKind;

const eql = util.eql;

pub const Optimizer = struct {
    ast: *AST,
    src: []const u8,

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
            if (n.kind == .fn_decl and n.child2 != 0) {
                self.optimizeBlock(n.child2, changed);
            }
        }
    }

    // ── Block / statement optimization ───────────────────────────
    fn optimizeBlock(self: *Optimizer, block_idx: u32, changed: *bool) void {
        const block = self.ast.nodes[block_idx];
        if (block.kind != .block) return;
        var stmt_idx = block.child0;
        while (stmt_idx != 0) {
            const next = self.ast.stmt_chains[stmt_idx];
            self.optimizeStmt(stmt_idx, changed);
            stmt_idx = next;
        }
    }

    fn optimizeStmt(self: *Optimizer, idx: u32, changed: *bool) void {
        const node = self.ast.nodes[idx];
        switch (node.kind) {
            .let_stmt => {
                if (node.child0 != 0) {
                    self.optimizeExpr(node.child0, changed);
                    // Track constant bindings for propagation
                    const val = self.getConstantValue(node.child0);
                    if (val) |v| {
                        self.trackConst(idx, v);
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
                // Invalidate tracked constant for the assigned variable
                if (node.text_len > 0) self.invalidateConst(self.textOf(node.text_start, node.text_len), node.source_id);
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
                            self.ast.nodes[idx] = .{ .kind = .block, .line = node.line, .child0 = 0 };
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
                // Recurse into branches
                const n2 = self.ast.nodes[idx];
                if (n2.child1 != 0) self.optimizeBlock(n2.child1, changed);
                if (n2.child2 != 0) self.optimizeBlock(n2.child2, changed);
            },
            .while_stmt => {
                // Invalidate any variable modified inside the loop body
                // BEFORE optimizing the condition — otherwise constant
                // propagation would incorrectly replace the variable with
                // its pre-loop value (e.g. i = 0) in the condition.
                if (node.child1 != 0) {
                    var lb_starts: [128]u32 = undefined;
                    var lb_lens: [128]u32 = undefined;
                    var lb_count: u32 = 0;
                    self.collectModifiedVars(node.child1, &lb_starts, &lb_lens, &lb_count);
                    for (0..lb_count) |bi| {
                        const name = self.textOf(lb_starts[bi], lb_lens[bi]);
                        if (name.len > 0) self.invalidateConst(name, 0);
                    }
                }
                self.optimizeExpr(node.child0, changed);
                // while false → remove loop body entirely
                const val = self.getConstantValue(node.child0);
                if (val) |v| {
                    if (v == 0) {
                        self.ast.nodes[idx] = .{ .kind = .block, .line = node.line, .child0 = 0 };
                        changed.* = true;
                        return;
                    }
                }
                const n2 = self.ast.nodes[idx];
                if (n2.child1 != 0) self.optimizeBlock(n2.child1, changed);
            },
            .for_stmt => {
                // Same pre-invalidation for for loops: the iteration variable
                // is always modified, plus anything modified in the body.
                if (node.child1 != 0) {
                    var fb_starts: [128]u32 = undefined;
                    var fb_lens: [128]u32 = undefined;
                    var fb_count: u32 = 0;
                    self.collectModifiedVars(node.child1, &fb_starts, &fb_lens, &fb_count);
                    for (0..fb_count) |bi| {
                        const name = self.textOf(fb_starts[bi], fb_lens[bi]);
                        if (name.len > 0) self.invalidateConst(name, 0);
                    }
                    // Also invalidate the loop iteration variable itself
                    if (node.text_len > 0) {
                        const lv = self.textOf(node.text_start, node.text_len);
                        if (lv.len > 0) self.invalidateConst(lv, node.source_id);
                    }
                    self.optimizeBlock(node.child1, changed);
                }
            },
            .break_stmt, .continue_stmt => {
                // DCE: cut unreachable statements after break/continue
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
            .block => {
                self.optimizeBlock(idx, changed);
            },
            else => {},
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
            .ternary_expr => {
                self.optimizeExpr(node.child0, changed);
                self.optimizeExpr(node.child1, changed);
                self.optimizeExpr(node.child2, changed);
                self.foldTernaryExpr(idx, changed);
            },
            .call_expr => {
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
            .addr_of, .deref => {
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
        const left = self.ast.nodes[node.child0];
        const right = self.ast.nodes[node.child1];
        const op: TokenKind = @enumFromInt(node.op);

        // ── Full constant folding: int_literal OP int_literal ──
        if (left.kind == .int_literal and right.kind == .int_literal) {
            const a = left.int_val;
            const b = right.int_val;
            const result: i64 = switch (op) {
                .plus => a +% b,
                .minus => a -% b,
                .star => a *% b,
                .slash => if (b != 0 and !(a == std.math.minInt(i64) and b == -1)) @divTrunc(a, b) else return,
                .percent => if (b != 0) @rem(a, b) else return,
                .eq => if (a == b) 1 else 0,
                .ne => if (a != b) 1 else 0,
                .lt => if (a < b) 1 else 0,
                .gt => if (a > b) 1 else 0,
                .le => if (a <= b) 1 else 0,
                .ge => if (a >= b) 1 else 0,
                .and_and => if (a != 0 and b != 0) 1 else 0,
                .pipe_pipe => if (a != 0 or b != 0) 1 else 0,
                .amp => a & b,
                .pipe => a | b,
                .caret => a ^ b,
                .lshift => if (b >= 0 and b < 64) a << @as(u6, @intCast(b)) else return,
                .rshift => if (b >= 0 and b < 64) a >> @as(u6, @intCast(b)) else return,
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
        if (node.child0 == node.child1) {
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

    /// Read text for a node directly from the source buffer (works even when
    /// source_count == 0, which is always the case for single-file builds).
    fn textOf(self: *const Optimizer, start: u32, len: u32) []const u8 {
        if (start + len <= self.src.len) return self.src[start..][0..len];
        return "";
    }

    fn invalidateConst(self: *Optimizer, name: []const u8, src_id: u32) void {
        for (0..self.const_count) |i| {
            if (!self.const_active[i]) continue;
            if (self.const_name_len[i] != name.len) continue;
            if (self.const_name_src[i] != src_id) continue;
            if (eql(self.textOf(self.const_name_start[i], self.const_name_len[i]), name))
                self.const_active[i] = false;
        }
    }

    fn propagateConst(self: *Optimizer, idx: u32, changed: *bool) void {
        const node = self.ast.nodes[idx];
        if (node.text_len == 0) return;
        for (0..self.const_count) |i| {
            if (!self.const_active[i]) continue;
            if (self.const_name_len[i] != node.text_len) continue;
            if (self.const_name_src[i] != node.source_id) continue;
            if (eql(self.textOf(self.const_name_start[i], self.const_name_len[i]),
                self.textOf(node.text_start, node.text_len)))
            {
                self.ast.nodes[idx] = .{ .kind = .int_literal, .line = node.line, .int_val = self.const_value[i] };
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
            if (n.kind == .fn_decl and n.child2 != 0) {
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

    /// Collect every variable that is written to inside `block_idx`
    /// (including nested loops/ifs).  Writes go into `out_starts/`
    /// `out_lens`; `out_count` is updated.
    fn collectModifiedVars(self: *const Optimizer, block_idx: u32, out_starts: []u32, out_lens: []u32, out_count: *u32) void {
        var stmt_idx = self.ast.nodes[block_idx].child0;
        while (stmt_idx != 0) {
            const n = self.ast.nodes[stmt_idx];
            switch (n.kind) {
                .assign_stmt => {
                    if (n.text_len > 0 and out_count.* < out_starts.len) {
                        if (!self.nameInSet(n.text_start, n.text_len, out_starts, out_lens, out_count.*)) {
                            out_starts[out_count.*] = n.text_start;
                            out_lens[out_count.*] = n.text_len;
                            out_count.* += 1;
                        }
                    }
                },
                .let_stmt => {
                    // A let_stmt does not modify an existing variable;
                    // it creates a new one.  But if the initializer has
                    // side-effects that write to something, we'll catch
                    // that through assign_stmts inside nested blocks.
                },
                .for_stmt => {
                    // The iteration variable is modified each pass.
                    if (n.text_len > 0 and out_count.* < out_starts.len) {
                        if (!self.nameInSet(n.text_start, n.text_len, out_starts, out_lens, out_count.*)) {
                            out_starts[out_count.*] = n.text_start;
                            out_lens[out_count.*] = n.text_len;
                            out_count.* += 1;
                        }
                    }
                    if (n.child1 != 0) self.collectModifiedVars(n.child1, out_starts, out_lens, out_count);
                },
                .while_stmt => {
                    if (n.child1 != 0) self.collectModifiedVars(n.child1, out_starts, out_lens, out_count);
                },
                .if_stmt => {
                    if (n.child1 != 0) self.collectModifiedVars(n.child1, out_starts, out_lens, out_count);
                    if (n.child2 != 0) self.collectModifiedVars(n.child2, out_starts, out_lens, out_count);
                },
                .block => {
                    self.collectModifiedVars(stmt_idx, out_starts, out_lens, out_count);
                },
                else => {},
            }
            stmt_idx = self.ast.stmt_chains[stmt_idx];
        }
    }

    /// Return true if (name_start, name_len) already exists in the set.
    fn nameInSet(self: *const Optimizer, start: u32, len: u32, starts: []const u32, lens: []const u32, count: u32) bool {
        const name = self.textOf(start, len);
        for (0..count) |i| {
            if (lens[i] == len and eql(self.textOf(starts[i], lens[i]), name)) return true;
        }
        return false;
    }

    /// Return true if `idx` references any variable in the modified set.
    fn exprRefsModified(self: *const Optimizer, idx: u32, mod_starts: []const u32, mod_lens: []const u32, mod_count: u32) bool {
        if (idx == 0) return false;
        const n = self.ast.nodes[idx];
        switch (n.kind) {
            .identifier => {
                if (n.text_len == 0) return false;
                return self.nameInSet(n.text_start, n.text_len, mod_starts, mod_lens, mod_count);
            },
            .binary_expr => {
                return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_count) or
                    self.exprRefsModified(n.child1, mod_starts, mod_lens, mod_count);
            },
            .unary_expr, .addr_of, .deref => {
                return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_count);
            },
            .ternary_expr => {
                return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_count) or
                    self.exprRefsModified(n.child1, mod_starts, mod_lens, mod_count) or
                    self.exprRefsModified(n.child2, mod_starts, mod_lens, mod_count);
            },
            .call_expr => {
                // Check callee and arguments.
                if (self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_count)) return true;
                var ai = n.child2;
                while (ai != 0) {
                    if (self.exprRefsModified(self.ast.nodes[ai].child0, mod_starts, mod_lens, mod_count)) return true;
                    ai = self.ast.nodes[ai].child1;
                }
                return false;
            },
            .field_access => {
                return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_count);
            },
            .index_expr => {
                return self.exprRefsModified(n.child0, mod_starts, mod_lens, mod_count) or
                    self.exprRefsModified(n.child1, mod_starts, mod_lens, mod_count);
            },
            else => return false,
        }
    }

    /// Return true when `idx` is a pure expression (no side-effects).
    fn isPureExpr(self: *const Optimizer, idx: u32) bool {
        if (idx == 0) return true;
        const n = self.ast.nodes[idx];
        switch (n.kind) {
            .int_literal, .string_literal, .identifier => return true,
            .binary_expr => return self.isPureExpr(n.child0) and self.isPureExpr(n.child1),
            .unary_expr, .addr_of, .deref => return self.isPureExpr(n.child0),
            .ternary_expr => {
                return self.isPureExpr(n.child0) and self.isPureExpr(n.child1) and self.isPureExpr(n.child2);
            },
            .field_access => return self.isPureExpr(n.child0),
            .index_expr => return self.isPureExpr(n.child0) and self.isPureExpr(n.child1),
            else => return false, // call_expr, etc. → not pure
        }
    }

    /// Try to hoist loop-invariant `let` statements from `body_idx` to
    /// just before `loop_idx` in the parent block.
    fn hoistFromLoop(self: *Optimizer, parent_block: u32, prev_of_loop_in: u32, loop_idx: u32, body_idx: u32, changed: *bool) void {
        var prev_of_loop = prev_of_loop_in;
        const body = self.ast.nodes[body_idx];
        if (body.kind != .block) return;

        // 1. Collect variables modified anywhere in the loop body.
        var mod_starts: [128]u32 = undefined;
        var mod_lens: [128]u32 = undefined;
        var mod_count: u32 = 0;
        self.collectModifiedVars(body_idx, &mod_starts, &mod_lens, &mod_count);
        if (mod_count == 0) return; // nothing modified → nothing safe to hoist

        // 2. Walk the body looking for hoistable let statements.
        var prev_body: u32 = 0;
        var stmt_idx = body.child0;
        while (stmt_idx != 0) {
            const next = self.ast.stmt_chains[stmt_idx];
            const n = self.ast.nodes[stmt_idx];

            if (n.kind == .let_stmt and n.child0 != 0) {
                // The let variable itself must not be modified inside the loop.
                const var_is_clean = !self.nameInSet(n.text_start, n.text_len, &mod_starts, &mod_lens, mod_count);
                // The initializer must be pure (no side-effects) and must not
                // reference any variable that is modified inside the loop.
                const init_ok = self.isPureExpr(n.child0) and
                    !self.exprRefsModified(n.child0, &mod_starts, &mod_lens, mod_count);

                if (var_is_clean and init_ok) {
                    // ── Remove from loop body ────────────────────
                    if (prev_body == 0) {
                        self.ast.nodes[body_idx].child0 = next;
                    } else {
                        self.ast.stmt_chains[prev_body] = next;
                    }
                    // ── Insert before the loop in parent block ───
                    self.ast.stmt_chains[stmt_idx] = loop_idx;
                    if (prev_of_loop == 0) {
                        self.ast.nodes[parent_block].child0 = stmt_idx;
                    } else {
                        self.ast.stmt_chains[prev_of_loop] = stmt_idx;
                    }
                    prev_of_loop = stmt_idx; // next hoist goes after this one
                    changed.* = true;
                    stmt_idx = next;
                    continue;
                }
            }

            prev_body = stmt_idx;
            stmt_idx = next;
        }
    }
};

