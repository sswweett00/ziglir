// ════════════════════════════════════════════════════════════════════════════
// IR GENERATOR — Lowers AST + SemaInfo into CFG Basic-Block IR
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const lex = @import("lexer.zig");
const parser = @import("parser.zig");
const ir = @import("ir.zig");
const sema_mod = @import("sema.zig");
const diag_mod = @import("diag.zig");
const target_mod = @import("target.zig");

const TokenKind = lex.TokenKind;
const AST = parser.AST;
const ASTNode = parser.ASTNode;
const NodeKind = parser.NodeKind;
const IRInst = ir.IRInst;
const IROp = ir.IROp;
const IRFn = ir.IRFn;
const IRModule = ir.IRModule;
const MAX_INSTS_PER_BLOCK = ir.MAX_INSTS_PER_BLOCK;
const MAX_BLOCKS_PER_FN = ir.MAX_BLOCKS_PER_FN;
const MAX_FNS = ir.MAX_FNS;
const SemaInfo = sema_mod.SemaInfo;
const DiagList = diag_mod.DiagList;

const eql = util.eql;

pub const IRGenError = error{
    TooManyFunctions,
    TooManyBlocks,
    TooManyLocals,
    TooManyArgs,
    UndefinedVariable,
    UndefinedFunctionCall,
    CapacityOverflow,
    InvalidConstruct,
};

pub const IRGen = struct {
    ast: *const AST,
    mod: *IRModule,
    src: []const u8,
    sema_info: ?*const SemaInfo = null,
    diag: ?*DiagList = null,
    target: target_mod.Target = target_mod.Target.host(),

    cur_fn_idx: u32 = 0,
    cur_block_idx: u16 = 0,
    next_vreg: u16 = 1,

    // Scoped local symbol table
    local_names: [512][]const u8 = undefined,
    local_slots: [512]u16 = undefined,
    local_depths: [512]u32 = undefined,
    local_count: u32 = 0,
    scope_depth: u32 = 0,

    // Loop break/continue target stack
    loop_break: [32]u16 = undefined,
    loop_continue: [32]u16 = undefined,
    loop_scope_depths: [32]u32 = undefined,
    loop_depth: u32 = 0,

    // Defer LIFO stack
    defer_stmts: [64]u32 = undefined,
    defer_scopes: [64]u32 = undefined,
    defer_count: u32 = 0,

    // Closure / function-value wrapper mapping
    fn_wrappers: [MAX_FNS]i32 = .{-1} ** MAX_FNS,
    wrapper_target_fn: [MAX_FNS]i32 = .{-1} ** MAX_FNS,

    first_error: ?IRGenError = null,

    pub fn init(ast: *const AST, mod: *IRModule, src: []const u8) IRGen {
        return .{
            .ast = ast,
            .mod = mod,
            .src = src,
        };
    }

    pub fn initWithContext(ast: *const AST, mod: *IRModule, src: []const u8, sema_info: ?*const SemaInfo, diag: ?*DiagList) IRGen {
        return .{
            .ast = ast,
            .mod = mod,
            .src = src,
            .sema_info = sema_info,
            .diag = diag,
        };
    }

    fn recordError(self: *IRGen, err: IRGenError, line: u32, col: u32, comptime fmt: []const u8, args: anytype) void {
        self.recordErrorAt(err, 0, line, col, fmt, args);
    }

    fn recordErrorAt(self: *IRGen, err: IRGenError, source_id: u32, line: u32, col: u32, comptime fmt: []const u8, args: anytype) void {
        if (self.first_error == null) self.first_error = err;
        if (self.diag) |d| {
            d.addFmtAt(.err, source_id, line, col, 1, fmt, args);
        } else {
            util.printErr("IR error at line ");
            util.printErrUsize(line);
            util.printErr(": ");
            var buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
            util.printErr(msg);
            util.printErr("\n");
        }
    }

    fn srcText(self: *const IRGen, start: u32, length: u32, source_id: u32) []const u8 {
        if (source_id == parser.SYNTH_SOURCE_ID or (self.ast.source_count > 0 and source_id < self.ast.source_count)) {
            return self.ast.nodeTextSrcFrom(start, length, source_id);
        }
        const s: usize = start;
        const l: usize = length;
        if (s <= self.src.len and l <= self.src.len - s) return self.src[s..][0..l];
        return "";
    }

    fn nodeText(self: *const IRGen, idx: u32) []const u8 {
        if (idx == 0 or idx >= self.ast.count) return "";
        const n = self.ast.nodes[idx];
        return self.srcText(n.text_start, n.text_len, n.source_id);
    }

    fn curFn(self: *IRGen) *IRFn {
        return &self.mod.fns[self.cur_fn_idx];
    }

    fn allocVreg(self: *IRGen) u16 {
        const v = self.next_vreg;
        self.next_vreg += 1;
        if (self.next_vreg > self.curFn().vreg_count) {
            self.curFn().vreg_count = self.next_vreg;
        }
        return v;
    }

    fn newBlock(self: *IRGen) u16 {
        const f = self.curFn();
        if (f.block_count >= MAX_BLOCKS_PER_FN) {
            self.recordError(error.TooManyBlocks, 1, 1, "function exceeds {d} basic blocks", .{MAX_BLOCKS_PER_FN});
            return f.block_count - 1;
        }
        const bi = f.block_count;
        f.blocks[bi].label = bi;
        f.blocks[bi].inst_count = 0;
        f.block_count += 1;
        return bi;
    }

    fn blockTerminated(self: *const IRGen, bi: u16) bool {
        const f = &self.mod.fns[self.cur_fn_idx];
        if (bi >= f.block_count) return false;
        const b = &f.blocks[bi];
        if (b.inst_count == 0) return false;
        return b.insts[b.inst_count - 1].op.isTerminator();
    }

    fn emit(self: *IRGen, inst: IRInst) void {
        if (self.first_error != null) return;
        const f = self.curFn();
        var b = &f.blocks[self.cur_block_idx];
        if (b.inst_count > 0 and b.insts[b.inst_count - 1].op.isTerminator()) return;
        if (!inst.op.isTerminator() and b.inst_count >= MAX_INSTS_PER_BLOCK - 1) {
            const cont = self.newBlock();
            if (self.first_error != null) return;
            f.blocks[self.cur_block_idx].insts[b.inst_count] = .{ .op = .jump, .target_block = cont };
            f.blocks[self.cur_block_idx].inst_count += 1;
            self.cur_block_idx = cont;
            b = &f.blocks[self.cur_block_idx];
        }
        if (b.inst_count >= MAX_INSTS_PER_BLOCK) {
            self.recordError(error.CapacityOverflow, 1, 1, "basic block instruction capacity exceeded", .{});
            return;
        }
        b.insts[b.inst_count] = inst;
        b.inst_count += 1;
    }

    fn pushScope(self: *IRGen) void {
        self.scope_depth += 1;
    }

    fn emitDefersDownTo(self: *IRGen, min_scope: u32, pop_entries: bool) void {
        var i: u32 = self.defer_count;
        while (i > 0) {
            i -= 1;
            if (self.defer_scopes[i] < min_scope) break;
            const stmt_idx = self.defer_stmts[i];
            if (pop_entries) {
                self.defer_count = i;
            }
            // Temporarily hide this and inner defers while running it
            const saved_dc = self.defer_count;
            if (!pop_entries) self.defer_count = i;
            self.genStmt(stmt_idx);
            if (!pop_entries) self.defer_count = saved_dc;
        }
    }

    fn popScope(self: *IRGen) void {
        if (!self.blockTerminated(self.cur_block_idx)) {
            self.emitDefersDownTo(self.scope_depth, true);
        } else {
            while (self.defer_count > 0 and self.defer_scopes[self.defer_count - 1] >= self.scope_depth) {
                self.defer_count -= 1;
            }
        }
        while (self.local_count > 0 and self.local_depths[self.local_count - 1] == self.scope_depth) {
            self.local_count -= 1;
        }
        if (self.scope_depth > 0) self.scope_depth -= 1;
    }

    fn allocHiddenSlot(self: *IRGen) u16 {
        const f = self.curFn();
        if (f.total_locals >= 8192) {
            self.recordError(error.TooManyLocals, 1, 1, "too many local slots in function", .{});
            return 1;
        }
        f.total_locals += 1;
        return @intCast(f.total_locals);
    }

    fn allocMultiSlots(self: *IRGen, count: u32) u16 {
        const f = self.curFn();
        const n = @max(count, 1);
        if (f.total_locals + n > 8192) {
            self.recordError(error.TooManyLocals, 1, 1, "local array exceeds stack frame slot limit", .{});
            return 1;
        }
        f.total_locals += n;
        // Return lowest-address slot (highest slot index) so ascending byte offsets stay inside frame
        return @intCast(f.total_locals);
    }

    fn defineLocal(self: *IRGen, name: []const u8) u16 {
        var i: u32 = self.local_count;
        while (i > 0) {
            i -= 1;
            if (self.local_depths[i] < self.scope_depth) break;
            if (eql(self.local_names[i], name)) return self.local_slots[i];
        }
        if (self.local_count >= self.local_names.len) {
            self.recordError(error.TooManyLocals, 1, 1, "too many local variables in scope", .{});
            return 1;
        }
        const slot = self.allocHiddenSlot();
        self.local_names[self.local_count] = name;
        self.local_slots[self.local_count] = slot;
        self.local_depths[self.local_count] = self.scope_depth;
        self.local_count += 1;
        return slot;
    }

    fn findSlot(self: *const IRGen, name: []const u8) ?u16 {
        var i: u32 = self.local_count;
        while (i > 0) {
            i -= 1;
            if (eql(self.local_names[i], name)) return self.local_slots[i];
        }
        return null;
    }

    fn findFn(self: *const IRGen, name: []const u8, owner_struct_plus1: u32) ?u32 {
        for (0..self.mod.fn_count) |i| {
            const f = &self.mod.fns[i];
            if (f.owner_struct_plus1 != owner_struct_plus1) continue;
            const fn_name = self.srcText(f.name_start, f.name_len, f.source_id);
            if (eql(fn_name, name)) return @intCast(i);
        }
        return null;
    }

    fn findFnByAstIdx(self: *const IRGen, ast_idx: u32) ?u32 {
        if (ast_idx == 0) return null;
        for (0..self.mod.fn_count) |i| {
            if (self.mod.fns[i].ast_idx == ast_idx) return @intCast(i);
        }
        return null;
    }

    fn collectSynthFnsInSubtree(self: *IRGen, idx: u32, visited: []bool) void {
        if (idx == 0 or idx >= self.ast.count or idx >= visited.len) return;
        if (visited[idx]) return;
        visited[idx] = true;
        const n = self.ast.nodes[idx];
        if (n.kind == .closure_expr) {
            if (self.mod.fn_count < MAX_FNS) {
                var nbuf: [48]u8 = undefined;
                const cname = std.fmt.bufPrint(&nbuf, "__lir_closure_{d}", .{idx}) catch "__lir_closure";
                const sp = self.mod.addSynthName(cname);
                const fi = self.mod.fn_count;
                ir.IRModule.initFnSlot(&self.mod.fns[fi], sp.start, sp.len, @intCast(parser.SYNTH_SOURCE_ID), idx, 0);
                self.mod.fn_count += 1;
            }
        } else if (n.kind == .spawn_expr and n.child0 != 0 and self.ast.nodes[n.child0].kind != .closure_expr) {
            if (self.mod.fn_count < MAX_FNS) {
                var nbuf: [48]u8 = undefined;
                const sname = std.fmt.bufPrint(&nbuf, "__lir_spawn_{d}", .{idx}) catch "__lir_spawn";
                const sp = self.mod.addSynthName(sname);
                const fi = self.mod.fn_count;
                ir.IRModule.initFnSlot(&self.mod.fns[fi], sp.start, sp.len, @intCast(parser.SYNTH_SOURCE_ID), idx, 0);
                self.mod.fn_count += 1;
            }
        }
        self.collectSynthFnsInSubtree(n.child0, visited);
        self.collectSynthFnsInSubtree(n.child1, visited);
        self.collectSynthFnsInSubtree(n.child2, visited);
        if (n.kind == .list_comp and n.extra != 0) {
            self.collectSynthFnsInSubtree(n.extra, visited);
        }
        if (idx < self.ast.stmt_chains.len) {
            self.collectSynthFnsInSubtree(self.ast.stmt_chains[idx], visited);
        }
    }

    fn getOrCreateFnWrapper(self: *IRGen, target_fi: u32) ?u32 {
        if (target_fi >= MAX_FNS) return null;
        if (self.fn_wrappers[target_fi] >= 0) return @intCast(self.fn_wrappers[target_fi]);
        if (self.mod.fn_count >= MAX_FNS) {
            self.recordError(error.TooManyFunctions, 1, 1, "too many functions for closure wrapper (limit {d})", .{MAX_FNS});
            return null;
        }
        const wfi = self.mod.fn_count;
        var nbuf: [48]u8 = undefined;
        const wname = std.fmt.bufPrint(&nbuf, "__lir_wrap_{d}", .{target_fi}) catch "__lir_wrap";
        const sp = self.mod.addSynthName(wname);
        ir.IRModule.initFnSlot(&self.mod.fns[wfi], sp.start, sp.len, @intCast(parser.SYNTH_SOURCE_ID), 0, 0);
        self.wrapper_target_fn[wfi] = @intCast(target_fi);
        self.fn_wrappers[target_fi] = @intCast(wfi);
        self.mod.fn_count += 1;
        return wfi;
    }

    pub fn generate(self: *IRGen) IRGenError!void {
        self.mod.init();
        @memset(&self.fn_wrappers, -1);
        @memset(&self.wrapper_target_fn, -1);

        if (self.ast.synth_len > 0) {
            const copy_len = @min(self.ast.synth_len, @as(u32, @intCast(self.mod.synth_buf.len)));
            @memcpy(self.mod.synth_buf[0..copy_len], self.ast.synth_buf[0..copy_len]);
            self.mod.synth_len = copy_len;
        }

        if (self.ast.source_count > 0) {
            const sc_src = @min(self.ast.source_count, @as(u32, @intCast(self.mod.sources.len)));
            for (0..sc_src) |si| self.mod.sources[si] = self.ast.sources[si];
            self.mod.source_count = sc_src;
        } else if (self.src.len > 0) {
            self.mod.sources[0] = self.src;
            self.mod.source_count = 1;
        }

        const sc = @min(@as(u32, self.ast.struct_count), @as(u32, @intCast(self.ast.struct_defs.len)));
        for (0..sc) |i| {
            const sd = self.ast.struct_defs[i];
            if (sd.is_generic) continue;
            if (self.mod.struct_count >= self.mod.struct_defs.len) break;
            var si = ir.StructInfo{
                .name_start = sd.name_start,
                .name_len = sd.name_len,
                .source_id = @intCast(sd.source_id),
                .field_offsets = .{0} ** 32,
                .field_count = sd.field_count,
                .total_size = sd.total_size,
                .is_union = sd.is_union,
            };
            const fc = @min(sd.field_count, @as(u32, 32));
            for (0..fc) |fi| si.field_offsets[fi] = sd.fields[fi].offset;
            self.mod.struct_defs[self.mod.struct_count] = si;
            self.mod.struct_count += 1;
        }

        for (1..self.ast.count) |i| {
            const n = self.ast.nodes[i];
            if (n.kind != .fn_decl or (n.flags & 64) != 0) continue;
            if (self.mod.fn_count >= MAX_FNS) {
                self.recordErrorAt(error.TooManyFunctions, n.source_id, n.line, n.col, "too many functions (limit {d})", .{MAX_FNS});
                break;
            }
            const fi = self.mod.fn_count;
            ir.IRModule.initFnSlot(&self.mod.fns[fi], n.text_start, n.text_len, @intCast(n.source_id), @intCast(i), n.extra);
            self.mod.fn_count += 1;
        }

        // Collect synthetic IR functions for closures & spawn blocks inside non-template functions
        var visited_buf: [parser.MAX_AST_NODES]bool = .{false} ** parser.MAX_AST_NODES;
        const base_fn_count = self.mod.fn_count;
        for (0..base_fn_count) |bfi| {
            const fn_ast = self.mod.fns[bfi].ast_idx;
            if (fn_ast != 0 and self.ast.nodes[fn_ast].child2 != 0) {
                self.collectSynthFnsInSubtree(self.ast.nodes[fn_ast].child2, &visited_buf);
            }
        }

        if (self.first_error) |e| return e;

        var fi: u32 = 0;
        while (fi < self.mod.fn_count) : (fi += 1) {
            self.genFn(fi);
            if (self.first_error) |e| return e;
        }
        if (self.mod.string_overflowed) {
            self.recordError(error.CapacityOverflow, 1, 1, "string table capacity exceeded", .{});
            return error.CapacityOverflow;
        }
    }

    fn genFn(self: *IRGen, fi: u32) void {
        self.cur_fn_idx = fi;
        self.next_vreg = 1;
        self.local_count = 0;
        self.scope_depth = 0;
        self.loop_depth = 0;
        self.defer_count = 0;

        self.curFn().total_locals = 0;
        self.curFn().vreg_count = 1;
        self.curFn().block_count = 0;
        self.curFn().param_count = 0;
        @memset(&self.curFn().local_addr_taken, false);

        if (self.wrapper_target_fn[fi] >= 0) {
            const target_fi: u32 = @intCast(self.wrapper_target_fn[fi]);
            const target_fn = &self.mod.fns[target_fi];
            const uparams = @min(target_fn.param_count, 7);
            self.pushScope();
            _ = self.allocHiddenSlot(); // slot 1 = unused __env
            self.curFn().param_slots[0] = 1;
            var uargs: [8]u16 = .{0} ** 8;
            for (0..uparams) |pi| {
                const pslot = self.allocHiddenSlot();
                self.curFn().param_slots[1 + pi] = pslot;
            }
            self.curFn().param_count = 1 + uparams;
            self.cur_block_idx = self.newBlock();
            for (0..uparams) |pi| {
                const av = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = av, .slot = @intCast(self.curFn().param_slots[1 + pi]) });
                uargs[pi] = av;
            }
            const ret_v = self.allocVreg();
            self.emit(.{
                .op = .call,
                .dest = ret_v,
                .fn_name_start = target_fn.name_start,
                .fn_name_len = @intCast(target_fn.name_len),
                .fn_source_id = target_fn.source_id,
                .callee_fn_idx = @intCast(target_fi),
                .args = uargs,
                .arg_count = @intCast(uparams),
            });
            self.popScope();
            self.emit(.{ .op = .ret, .src1 = ret_v });
            return;
        }

        const ast_idx = self.mod.fns[fi].ast_idx;
        const fn_node = self.ast.nodes[ast_idx];
        if (fn_node.kind == .closure_expr) {
            self.pushScope();
            const env_slot = self.allocHiddenSlot();
            self.curFn().param_slots[0] = env_slot;
            var pi: u32 = 1;
            var p = fn_node.child0;
            while (p != 0) : (p = self.ast.nodes[p].child1) {
                if (pi >= 8) {
                    const pn = self.ast.nodes[p];
                    self.recordErrorAt(error.TooManyArgs, pn.source_id, pn.line, pn.col, "closure exceeds 7 parameters", .{});
                    return;
                }
                const slot = self.defineLocal(self.nodeText(p));
                self.curFn().param_slots[pi] = slot;
                pi += 1;
            }
            self.curFn().param_count = pi;
            self.cur_block_idx = self.newBlock();
            if (self.sema_info) |si| {
                const cid1 = si.closure_ids[ast_idx];
                if (cid1 > 0 and cid1 - 1 < si.closure_count) {
                    const ci = si.closures[cid1 - 1];
                    if (ci.capture_count > 0) {
                        const env_v = self.allocVreg();
                        self.emit(.{ .op = .load_local, .dest = env_v, .slot = env_slot });
                        for (0..ci.capture_count) |k| {
                            const cv = self.allocVreg();
                            self.emit(.{ .op = .field_access, .dest = cv, .src1 = env_v, .field_offset = @intCast((1 + k) * 8) });
                            const cslot = self.defineLocal(ci.cap_names[k]);
                            self.emit(.{ .op = .store_local, .src1 = cv, .slot = cslot });
                        }
                    }
                }
            }
            if (fn_node.child2 != 0) {
                if (self.ast.nodes[fn_node.child2].kind == .block) {
                    self.genBlockRoot(fn_node.child2, false, true);
                } else {
                    const rv = self.genExpr(fn_node.child2);
                    if (!self.blockTerminated(self.cur_block_idx)) self.emit(.{ .op = .ret, .src1 = rv });
                }
            }
            self.popScope();
            if (!self.blockTerminated(self.cur_block_idx)) {
                const zero = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = zero, .imm = 0 });
                self.emit(.{ .op = .ret, .src1 = zero });
            }
            return;
        }

        if (fn_node.kind == .spawn_expr) {
            self.pushScope();
            const arg_slot = self.allocHiddenSlot();
            self.curFn().param_slots[0] = arg_slot;
            self.curFn().param_count = 1;
            self.cur_block_idx = self.newBlock();
            const rv = if (fn_node.child0 != 0) self.genExpr(fn_node.child0) else blk: {
                const z = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = z, .imm = 0 });
                break :blk z;
            };
            self.popScope();
            if (!self.blockTerminated(self.cur_block_idx)) {
                self.emit(.{ .op = .ret, .src1 = rv });
            }
            return;
        }

        self.pushScope();
        var p = fn_node.child0;
        var pi: u32 = 0;
        while (p != 0) : (p = self.ast.nodes[p].child1) {
            if (pi >= 8) {
                const pn = self.ast.nodes[p];
                self.recordErrorAt(error.TooManyArgs, pn.source_id, pn.line, pn.col, "function exceeds 8 parameters", .{});
                return;
            }
            const slot = self.defineLocal(self.nodeText(p));
            self.curFn().param_slots[pi] = slot;
            pi += 1;
        }
        self.curFn().param_count = pi;

        self.cur_block_idx = self.newBlock();
        if (fn_node.child2 != 0) {
            self.genBlockRoot(fn_node.child2, false, true);
        }
        self.popScope();

        if (!self.blockTerminated(self.cur_block_idx)) {
            const zero = self.allocVreg();
            self.emit(.{ .op = .const_int, .dest = zero, .imm = 0 });
            self.emit(.{ .op = .ret, .src1 = zero });
        }
    }

    fn genBlockRoot(self: *IRGen, block_idx: u32, create_scope: bool, is_fn_root: bool) void {
        const block = self.ast.nodes[block_idx];
        if (block.kind != .block) return;
        if (create_scope) self.pushScope();
        var stmt = block.child0;
        while (stmt != 0) {
            if (self.blockTerminated(self.cur_block_idx)) break;
            const next = self.ast.stmt_chains[stmt];
            const is_last = (next == 0);
            const is_tail = is_fn_root and is_last and self.isTailReturnExpr(stmt);
            if (is_tail) {
                const v = self.genExpr(stmt);
                if (!self.blockTerminated(self.cur_block_idx)) {
                    self.emitDefersDownTo(1, true);
                    self.emit(.{ .op = .ret, .src1 = v });
                }
            } else {
                self.genStmt(stmt);
            }
            stmt = next;
        }
        if (create_scope) self.popScope();
    }

    fn isTailReturnExpr(self: *const IRGen, stmt: u32) bool {
        if (self.sema_info) |si| {
            return si.is_tail_expr[stmt];
        }
        const k = self.ast.nodes[stmt].kind;
        if (k == .call_expr) {
            const cname = self.nodeText(self.ast.nodes[stmt].child0);
            if (eql(cname, "printInt") or eql(cname, "print") or eql(cname, "println") or
                eql(cname, "exit") or eql(cname, "@exit") or eql(cname, "@print") or
                eql(cname, "@println") or eql(cname, "@array_push") or eql(cname, "@panic")) return false;
            return true;
        }
        return switch (k) {
            .int_literal, .float_literal, .identifier, .binary_expr, .unary_expr, .cast_expr, .field_access, .index_expr, .ternary_expr, .match_expr, .deref, .addr_of, .struct_init, .method_call, .scoped_access, .array_lit, .tuple_lit, .closure_expr, .try_expr, .coalesce_expr, .comptime_expr, .list_comp, .map_lit, .spawn_expr, .interp_string => true,
            else => false,
        };
    }

    fn genStmt(self: *IRGen, idx: u32) void {
        if (idx == 0 or self.first_error != null) return;
        const node = self.ast.nodes[idx];
        switch (node.kind) {
            .block => self.genBlockRoot(idx, true, false),
            .unreachable_stmt => self.emit(.{ .op = .unreachable_trap }),
            .const_decl, .enum_decl, .type_alias, .struct_decl, .module_import, .trait_decl, .union_decl => {},
            .defer_stmt => {
                if (self.defer_count < self.defer_stmts.len) {
                    self.defer_stmts[self.defer_count] = node.child0;
                    self.defer_scopes[self.defer_count] = self.scope_depth;
                    self.defer_count += 1;
                }
            },
            .return_stmt => {
                const v = if (node.child0 != 0) self.genExpr(node.child0) else blk: {
                    const zero = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = zero, .imm = 0 });
                    break :blk zero;
                };
                self.emitDefersDownTo(1, false);
                self.emit(.{ .op = .ret, .src1 = v });
            },
            .let_stmt => {
                if ((node.flags & 4) != 0 and node.child2 != 0) {
                    const tup_v = if (node.child0 != 0) self.genExpr(node.child0) else blk: {
                        const z = self.allocVreg();
                        self.emit(.{ .op = .const_int, .dest = z, .imm = 0 });
                        break :blk z;
                    };
                    const tup_slot = self.allocHiddenSlot();
                    self.emit(.{ .op = .store_local, .src1 = tup_v, .slot = tup_slot });
                    var id_n = if (self.ast.nodes[node.child2].kind == .tuple_pattern) self.ast.nodes[node.child2].child0 else node.child2;
                    var ti: u16 = 0;
                    while (id_n != 0) : ({
                        id_n = self.ast.nodes[id_n].child1;
                        ti += 1;
                    }) {
                        const vname = self.nodeText(id_n);
                        if (!eql(vname, "_")) {
                            const tv = self.allocVreg();
                            self.emit(.{ .op = .load_local, .dest = tv, .slot = tup_slot });
                            const fv = self.allocVreg();
                            self.emit(.{ .op = .field_access, .dest = fv, .src1 = tv, .field_offset = ti * 8 });
                            const vslot = self.defineLocal(vname);
                            self.emit(.{ .op = .store_local, .src1 = fv, .slot = vslot });
                        }
                    }
                    return;
                }
                const fixed_count: ?u32 = if (node.type_tag == .fixed_array)
                    @max(node.extra, 1)
                else if (node.child0 != 0 and self.sema_info != null and self.sema_info.?.node_types[node.child0] == .fixed_array)
                    @max(self.sema_info.?.node_types[node.child0].fixed_array.len, 1)
                else
                    null;

                if (fixed_count) |count| {
                    if (node.child0 == 0 or self.ast.nodes[node.child0].kind == .array_lit) {
                        const base_slot = self.allocMultiSlots(count);
                        const ptr_v = self.allocVreg();
                        self.emit(.{ .op = .alloca, .dest = ptr_v, .slot = base_slot, .imm = @intCast(count * 8) });
                        if (base_slot < self.curFn().local_addr_taken.len) {
                            self.curFn().local_addr_taken[base_slot] = true;
                        }
                        if (node.child0 != 0) {
                            const init_node = self.ast.nodes[node.child0];
                            if ((init_node.flags & 1) != 0) {
                                const fill_v = self.genExpr(init_node.child0);
                                self.emitFixedArrayFill(ptr_v, count, fill_v, 0);
                            } else {
                                var elem = init_node.child0;
                                var off_bytes: i64 = 0;
                                var filled: u32 = 0;
                                const max_bytes: i64 = @as(i64, count) * 8;
                                while (elem != 0 and off_bytes < max_bytes) : (elem = self.ast.nodes[elem].child1) {
                                    const ev = self.genExpr(self.ast.nodes[elem].child0);
                                    const ep = if (off_bytes == 0) ptr_v else blk: {
                                        const ov = self.allocVreg();
                                        self.emit(.{ .op = .const_int, .dest = ov, .imm = off_bytes });
                                        const p = self.allocVreg();
                                        self.emit(.{ .op = .add, .dest = p, .src1 = ptr_v, .src2 = ov });
                                        break :blk p;
                                    };
                                    self.emit(.{ .op = .deref_store, .src1 = ep, .src2 = ev });
                                    off_bytes += 8;
                                    filled += 1;
                                }
                                if (filled < count) {
                                    const zero_v = self.allocVreg();
                                    self.emit(.{ .op = .const_int, .dest = zero_v, .imm = 0 });
                                    self.emitFixedArrayFill(ptr_v, count, zero_v, filled);
                                }
                            }
                        } else {
                            const zero_v = self.allocVreg();
                            self.emit(.{ .op = .const_int, .dest = zero_v, .imm = 0 });
                            self.emitFixedArrayFill(ptr_v, count, zero_v, 0);
                        }
                        const var_slot = self.defineLocal(self.nodeText(idx));
                        self.emit(.{ .op = .store_local, .src1 = ptr_v, .slot = var_slot });
                    } else {
                        const init_v = self.genExpr(node.child0);
                        const slot = self.defineLocal(self.nodeText(idx));
                        self.emit(.{ .op = .store_local, .src1 = init_v, .slot = slot });
                    }
                } else {
                    const init_v = if (node.child0 != 0)
                        self.genExpr(node.child0)
                    else blk: {
                        const z = self.allocVreg();
                        self.emit(.{ .op = .const_int, .dest = z, .imm = 0 });
                        break :blk z;
                    };
                    const slot = self.defineLocal(self.nodeText(idx));
                    self.emit(.{ .op = .store_local, .src1 = init_v, .slot = slot });
                }
            },
            .assign_stmt => self.genAssign(idx),
            .if_stmt => self.genIf(idx),
            .while_stmt => self.genWhile(idx),
            .for_stmt => self.genFor(idx),
            .break_stmt => {
                if (self.loop_depth == 0) {
                    self.recordErrorAt(error.InvalidConstruct, node.source_id, node.line, node.col, "break outside loop", .{});
                    return;
                }
                const ldepth = self.loop_scope_depths[self.loop_depth - 1];
                self.emitDefersDownTo(ldepth + 1, false);
                self.emit(.{ .op = .jump, .target_block = self.loop_break[self.loop_depth - 1] });
            },
            .continue_stmt => {
                if (self.loop_depth == 0) {
                    self.recordErrorAt(error.InvalidConstruct, node.source_id, node.line, node.col, "continue outside loop", .{});
                    return;
                }
                const ldepth = self.loop_scope_depths[self.loop_depth - 1];
                self.emitDefersDownTo(ldepth + 1, false);
                self.emit(.{ .op = .jump, .target_block = self.loop_continue[self.loop_depth - 1] });
            },
            .expr_stmt => {
                if (node.child0 != 0) _ = self.genExpr(node.child0);
            },
            else => {
                _ = self.genExpr(idx);
            },
        }
    }

    fn emitFixedArrayFill(self: *IRGen, ptr_v: u16, count: u32, fill_v: u16, start_idx: u32) void {
        if (start_idx >= count) return;
        const rem = count - start_idx;
        if (rem <= 8) {
            var k: u32 = start_idx;
            while (k < count) : (k += 1) {
                const off_bytes: i64 = @as(i64, k) * 8;
                const ep = if (off_bytes == 0) ptr_v else blk: {
                    const ov = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = ov, .imm = off_bytes });
                    const p = self.allocVreg();
                    self.emit(.{ .op = .add, .dest = p, .src1 = ptr_v, .src2 = ov });
                    break :blk p;
                };
                self.emit(.{ .op = .deref_store, .src1 = ep, .src2 = fill_v });
            }
            return;
        }
        const ptr_slot = self.allocHiddenSlot();
        self.emit(.{ .op = .store_local, .src1 = ptr_v, .slot = ptr_slot });
        const fill_slot = self.allocHiddenSlot();
        self.emit(.{ .op = .store_local, .src1 = fill_v, .slot = fill_slot });
        const idx_slot = self.allocHiddenSlot();
        const init_v = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = init_v, .imm = @intCast(start_idx) });
        self.emit(.{ .op = .store_local, .src1 = init_v, .slot = idx_slot });

        const cond_blk = self.newBlock();
        const body_blk = self.newBlock();
        const done_blk = self.newBlock();
        self.emit(.{ .op = .jump, .target_block = cond_blk });

        self.cur_block_idx = cond_blk;
        const cur_i = self.allocVreg();
        self.emit(.{ .op = .load_local, .dest = cur_i, .slot = idx_slot });
        const lim_v = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = lim_v, .imm = @intCast(count) });
        const cmp_v = self.allocVreg();
        self.emit(.{ .op = .cmp_lt, .dest = cmp_v, .src1 = cur_i, .src2 = lim_v });
        self.emit(.{ .op = .cond_jump, .src1 = cmp_v, .target_block = body_blk, .alt_block = done_blk });

        self.cur_block_idx = body_blk;
        const bi = self.allocVreg();
        self.emit(.{ .op = .load_local, .dest = bi, .slot = idx_slot });
        const three = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = three, .imm = 3 });
        const byte_off = self.allocVreg();
        self.emit(.{ .op = .shl, .dest = byte_off, .src1 = bi, .src2 = three });
        const bp = self.allocVreg();
        self.emit(.{ .op = .load_local, .dest = bp, .slot = ptr_slot });
        const ep = self.allocVreg();
        self.emit(.{ .op = .add, .dest = ep, .src1 = bp, .src2 = byte_off });
        const fv = self.allocVreg();
        self.emit(.{ .op = .load_local, .dest = fv, .slot = fill_slot });
        self.emit(.{ .op = .deref_store, .src1 = ep, .src2 = fv });
        const one = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = one, .imm = 1 });
        const ni = self.allocVreg();
        self.emit(.{ .op = .add, .dest = ni, .src1 = bi, .src2 = one });
        self.emit(.{ .op = .store_local, .src1 = ni, .slot = idx_slot });
        self.emit(.{ .op = .jump, .target_block = cond_blk });

        self.cur_block_idx = done_blk;
    }

    fn applyCompoundOp(self: *IRGen, op: TokenKind, old_v: u16, rhs_v: u16, is_uns: bool, is_flt: bool) u16 {
        if (op == .star_star_eq) return self.genPower(old_v, rhs_v);
        const ir_op: IROp = if (is_flt) switch (op) {
            .plus_eq => .fadd,
            .minus_eq => .fsub,
            .star_eq => .fmul,
            .slash_eq => .fdiv,
            else => return rhs_v,
        } else switch (op) {
            .plus_eq => .add,
            .minus_eq => .sub,
            .star_eq => .mul,
            .slash_eq => if (is_uns) .udiv else .div,
            .percent_eq => if (is_uns) .umod else .mod,
            .amp_eq => .bit_and,
            .pipe_eq => .bit_or,
            .caret_eq => .bit_xor,
            .lshift_eq => .shl,
            .rshift_eq => if (is_uns) .ushr else .shr,
            else => return rhs_v,
        };
        const res = self.allocVreg();
        self.emit(.{ .op = ir_op, .dest = res, .src1 = old_v, .src2 = rhs_v });
        return res;
    }

    fn isContiguousIndexed(self: *const IRGen, index_node_idx: u32) bool {
        if (self.sema_info) |si| {
            const base_idx = self.ast.nodes[index_node_idx].child0;
            const bt = si.node_types[base_idx];
            return bt == .fixed_array or bt == .ptr or bt == .ptr_struct or bt == .ptr_float or bt == .ptr_byte;
        }
        return false;
    }

    fn isByteIndexed(self: *const IRGen, index_node_idx: u32) bool {
        if (self.sema_info) |si| {
            const base_idx = self.ast.nodes[index_node_idx].child0;
            const bt = si.node_types[base_idx];
            if (bt == .ptr_byte) return true;
            if (bt == .fixed_array and (bt.fixed_array.elem == .u8 or bt.fixed_array.elem == .i8)) return true;
            const elem_ty = si.node_types[index_node_idx];
            if (elem_ty.isInt() and elem_ty.int.bits == 8) return true;
        }
        return false;
    }

    fn emitFixedArrayBoundsCheck(self: *IRGen, index_node_idx: u32, idx_v: u16) void {
        const si = self.sema_info orelse return;
        const base_idx = self.ast.nodes[index_node_idx].child0;
        const bt = si.node_types[base_idx];
        const idx_node_idx = self.ast.nodes[index_node_idx].child1;
        if (bt != .fixed_array) {
            if (idx_node_idx != 0 and idx_node_idx < self.ast.count) {
                const inode = self.ast.nodes[idx_node_idx];
                if (inode.kind == .int_literal and inode.int_val >= -(1 << 30) and inode.int_val <= (1 << 30)) return;
            }
            // Prevent (idx << 3) 64-bit integer wraparound on pointer indexing
            const bias_v = self.allocVreg();
            self.emit(.{ .op = .const_int, .dest = bias_v, .imm = @as(i64, 1) << 59 });
            const lim_v = self.allocVreg();
            self.emit(.{ .op = .const_int, .dest = lim_v, .imm = @as(i64, 1) << 60 });
            const sum_v = self.allocVreg();
            self.emit(.{ .op = .add, .dest = sum_v, .src1 = idx_v, .src2 = bias_v });
            const ok_v = self.allocVreg();
            self.emit(.{ .op = .ucmp_lt, .dest = ok_v, .src1 = sum_v, .src2 = lim_v });
            const ok_blk = self.newBlock();
            const trap_blk = self.newBlock();
            self.emit(.{ .op = .cond_jump, .src1 = ok_v, .target_block = ok_blk, .alt_block = trap_blk });
            self.cur_block_idx = trap_blk;
            self.emit(.{ .op = .unreachable_trap });
            self.cur_block_idx = ok_blk;
            return;
        }
        const fa_len: u32 = bt.fixed_array.len;
        if (idx_node_idx != 0 and idx_node_idx < self.ast.count) {
            const inode = self.ast.nodes[idx_node_idx];
            if (inode.kind == .int_literal and inode.int_val >= 0 and inode.int_val < @as(i64, @intCast(fa_len))) {
                return; // Proven in-bounds at compile time
            }
        }
        const len_v = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = len_v, .imm = @intCast(fa_len) });
        const ok_v = self.allocVreg();
        self.emit(.{ .op = .ucmp_lt, .dest = ok_v, .src1 = idx_v, .src2 = len_v });
        const ok_blk = self.newBlock();
        const trap_blk = self.newBlock();
        self.emit(.{ .op = .cond_jump, .src1 = ok_v, .target_block = ok_blk, .alt_block = trap_blk });
        self.cur_block_idx = trap_blk;
        self.emit(.{ .op = .unreachable_trap });
        self.cur_block_idx = ok_blk;
    }

    fn genAssign(self: *IRGen, idx: u32) void {
        const node = self.ast.nodes[idx];
        const op: TokenKind = @enumFromInt(node.op);
        const is_flt = if (self.sema_info) |si| si.is_float_op[idx] else false;
        const is_uns_stmt = if (self.sema_info) |si| si.is_unsigned_op[idx] else false;
        if (node.text_len > 0) {
            const name = self.nodeText(idx);
            const slot = self.findSlot(name) orelse {
                self.recordErrorAt(error.UndefinedVariable, node.source_id, node.line, node.col, "undefined variable '{s}'", .{name});
                return;
            };
            const rhs_v = self.genExpr(node.child0);
            const is_uns = is_uns_stmt or (if (self.sema_info) |si| si.node_types[node.child0].isUnsigned() else false);
            const val_v = if (op == .assign) rhs_v else blk: {
                const old_v = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = old_v, .slot = slot });
                break :blk self.applyCompoundOp(op, old_v, rhs_v, is_uns, is_flt);
            };
            self.emit(.{ .op = .store_local, .src1 = val_v, .slot = slot });
            return;
        }

        const lhs_idx = node.child0;
        const lhs = self.ast.nodes[lhs_idx];
        switch (lhs.kind) {
            .deref => {
                const ptr_v = self.genExpr(lhs.child0);
                const rhs_v = self.genExpr(node.child1);
                const val_v = if (op == .assign) rhs_v else blk: {
                    const old_v = self.allocVreg();
                    self.emit(.{ .op = .deref_load, .dest = old_v, .src1 = ptr_v });
                    break :blk self.applyCompoundOp(op, old_v, rhs_v, is_uns_stmt, is_flt);
                };
                self.emit(.{ .op = .deref_store, .src1 = ptr_v, .src2 = val_v });
            },
            .field_access => {
                const base_v = self.genExpr(lhs.child0);
                const off: u16 = @intCast(self.resolveFieldOffset(lhs_idx));
                const rhs_v = self.genExpr(node.child1);
                const val_v = if (op == .assign) rhs_v else blk: {
                    const old_v = self.allocVreg();
                    self.emit(.{ .op = .field_access, .dest = old_v, .src1 = base_v, .field_offset = off });
                    break :blk self.applyCompoundOp(op, old_v, rhs_v, is_uns_stmt, is_flt);
                };
                self.emit(.{ .op = .field_store, .src1 = base_v, .src2 = val_v, .field_offset = off });
            },
            .index_expr => {
                const arr_v = self.genExpr(lhs.child0);
                const idx_v = self.genExpr(lhs.child1);
                const rhs_v = self.genExpr(node.child1);
                const is_map = if (self.sema_info) |si| si.node_types[lhs.child0] == .map_t else false;
                if (is_map) {
                    const val_v = if (op == .assign) rhs_v else blk: {
                        const old_v = self.allocVreg();
                        var gargs: [8]u16 = .{0} ** 8;
                        gargs[0] = arr_v;
                        gargs[1] = idx_v;
                        self.emit(.{ .op = .call_map_get, .dest = old_v, .args = gargs, .arg_count = 2 });
                        break :blk self.applyCompoundOp(op, old_v, rhs_v, is_uns_stmt, is_flt);
                    };
                    var sargs: [8]u16 = .{0} ** 8;
                    sargs[0] = arr_v;
                    sargs[1] = idx_v;
                    sargs[2] = val_v;
                    self.emit(.{ .op = .call_map_set, .dest = 0, .args = sargs, .arg_count = 3 });
                } else if (self.isContiguousIndexed(lhs_idx)) {
                    self.emitFixedArrayBoundsCheck(lhs_idx, idx_v);
                    const is_byte = self.isByteIndexed(lhs_idx);
                    const elem_ptr = if (is_byte) blk: {
                        const ep = self.allocVreg();
                        self.emit(.{ .op = .add, .dest = ep, .src1 = arr_v, .src2 = idx_v });
                        break :blk ep;
                    } else blk: {
                        const three = self.allocVreg();
                        self.emit(.{ .op = .const_int, .dest = three, .imm = 3 });
                        const off = self.allocVreg();
                        self.emit(.{ .op = .shl, .dest = off, .src1 = idx_v, .src2 = three });
                        const ep = self.allocVreg();
                        self.emit(.{ .op = .add, .dest = ep, .src1 = arr_v, .src2 = off });
                        break :blk ep;
                    };
                    const val_v = if (op == .assign) rhs_v else blk: {
                        const old_v = self.allocVreg();
                        if (is_byte) {
                            var rargs: [8]u16 = .{0} ** 8;
                            rargs[0] = elem_ptr;
                            self.emit(.{ .op = .call_read_byte, .dest = old_v, .args = rargs, .arg_count = 1 });
                        } else {
                            self.emit(.{ .op = .deref_load, .dest = old_v, .src1 = elem_ptr });
                        }
                        break :blk self.applyCompoundOp(op, old_v, rhs_v, is_uns_stmt, is_flt);
                    };
                    if (is_byte) {
                        var wargs: [8]u16 = .{0} ** 8;
                        wargs[0] = elem_ptr;
                        wargs[1] = val_v;
                        self.emit(.{ .op = .call_write_byte, .dest = 0, .args = wargs, .arg_count = 2 });
                    } else {
                        self.emit(.{ .op = .deref_store, .src1 = elem_ptr, .src2 = val_v });
                    }
                } else {
                    const val_v = if (op == .assign) rhs_v else blk: {
                        const old_v = self.allocVreg();
                        var gargs: [8]u16 = .{0} ** 8;
                        gargs[0] = arr_v;
                        gargs[1] = idx_v;
                        self.emit(.{ .op = .call_array_get, .dest = old_v, .args = gargs, .arg_count = 2 });
                        break :blk self.applyCompoundOp(op, old_v, rhs_v, false, is_flt);
                    };
                    var sargs: [8]u16 = .{0} ** 8;
                    sargs[0] = arr_v;
                    sargs[1] = idx_v;
                    sargs[2] = val_v;
                    self.emit(.{ .op = .call_array_set, .dest = 0, .args = sargs, .arg_count = 3 });
                }
            },
            else => {
                self.recordErrorAt(error.InvalidConstruct, node.source_id, node.line, node.col, "invalid assignment target", .{});
            },
        }
    }

    fn genIf(self: *IRGen, idx: u32) void {
        const node = self.ast.nodes[idx];
        const cond_v = self.genExpr(node.child0);
        const then_blk = self.newBlock();
        if (node.child2 == 0) {
            const end_blk = self.newBlock();
            self.emit(.{ .op = .cond_jump, .src1 = cond_v, .target_block = then_blk, .alt_block = end_blk });

            self.cur_block_idx = then_blk;
            self.genStmt(node.child1);
            if (!self.blockTerminated(self.cur_block_idx)) {
                self.emit(.{ .op = .jump, .target_block = end_blk });
            }
            self.cur_block_idx = end_blk;
        } else {
            const else_blk = self.newBlock();
            const end_blk = self.newBlock();
            self.emit(.{ .op = .cond_jump, .src1 = cond_v, .target_block = then_blk, .alt_block = else_blk });

            self.cur_block_idx = then_blk;
            self.genStmt(node.child1);
            if (!self.blockTerminated(self.cur_block_idx)) {
                self.emit(.{ .op = .jump, .target_block = end_blk });
            }

            self.cur_block_idx = else_blk;
            self.genStmt(node.child2);
            if (!self.blockTerminated(self.cur_block_idx)) {
                self.emit(.{ .op = .jump, .target_block = end_blk });
            }

            self.cur_block_idx = end_blk;
        }
    }

    fn genBlockValue(self: *IRGen, block_idx: u32) u16 {
        const block = self.ast.nodes[block_idx];
        if (block.kind != .block) return self.genExpr(block_idx);
        self.pushScope();
        var stmt = block.child0;
        var out_v: u16 = 0;
        while (stmt != 0) {
            if (self.blockTerminated(self.cur_block_idx)) break;
            const next = self.ast.stmt_chains[stmt];
            if (next == 0 and self.isTailReturnExpr(stmt)) {
                out_v = self.genExpr(stmt);
            } else {
                self.genStmt(stmt);
            }
            stmt = next;
        }
        self.popScope();
        if (out_v == 0 and !self.blockTerminated(self.cur_block_idx)) {
            out_v = self.allocVreg();
            self.emit(.{ .op = .const_int, .dest = out_v, .imm = 0 });
        }
        return out_v;
    }

    fn genIfExpr(self: *IRGen, idx: u32) u16 {
        const node = self.ast.nodes[idx];
        const res_slot = self.allocHiddenSlot();
        const cond_v = self.genExpr(node.child0);
        const then_blk = self.newBlock();
        const else_blk = self.newBlock();
        const merge_blk = self.newBlock();

        self.emit(.{ .op = .cond_jump, .src1 = cond_v, .target_block = then_blk, .alt_block = else_blk });

        self.cur_block_idx = then_blk;
        const tv = self.genBlockValue(node.child1);
        if (!self.blockTerminated(self.cur_block_idx)) {
            self.emit(.{ .op = .store_local, .src1 = tv, .slot = res_slot });
            self.emit(.{ .op = .jump, .target_block = merge_blk });
        }

        self.cur_block_idx = else_blk;
        if (node.child2 != 0) {
            const ev = if (self.ast.nodes[node.child2].kind == .if_stmt)
                self.genIfExpr(node.child2)
            else
                self.genBlockValue(node.child2);
            if (!self.blockTerminated(self.cur_block_idx)) {
                self.emit(.{ .op = .store_local, .src1 = ev, .slot = res_slot });
                self.emit(.{ .op = .jump, .target_block = merge_blk });
            }
        } else {
            const zv = self.allocVreg();
            self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
            self.emit(.{ .op = .store_local, .src1 = zv, .slot = res_slot });
            self.emit(.{ .op = .jump, .target_block = merge_blk });
        }

        self.cur_block_idx = merge_blk;
        const rv = self.allocVreg();
        self.emit(.{ .op = .load_local, .dest = rv, .slot = res_slot });
        return rv;
    }

    fn genWhile(self: *IRGen, idx: u32) void {
        const node = self.ast.nodes[idx];
        const cond_blk = self.newBlock();
        const body_blk = self.newBlock();
        const after_blk = self.newBlock();

        self.emit(.{ .op = .jump, .target_block = cond_blk });

        self.cur_block_idx = cond_blk;
        const cond_v = self.genExpr(node.child0);
        self.emit(.{ .op = .cond_jump, .src1 = cond_v, .target_block = body_blk, .alt_block = after_blk });

        if (self.loop_depth < self.loop_break.len) {
            self.loop_break[self.loop_depth] = after_blk;
            self.loop_continue[self.loop_depth] = cond_blk;
            self.loop_scope_depths[self.loop_depth] = self.scope_depth;
            self.loop_depth += 1;
        }

        self.cur_block_idx = body_blk;
        if (node.child1 != 0) self.genStmt(node.child1);
        if (!self.blockTerminated(self.cur_block_idx)) {
            self.emit(.{ .op = .jump, .target_block = cond_blk });
        }

        if (self.loop_depth > 0) self.loop_depth -= 1;
        self.cur_block_idx = after_blk;
    }

    fn genFor(self: *IRGen, idx: u32) void {
        const node = self.ast.nodes[idx];
        const loop_var_name = self.nodeText(idx);

        if (node.int_val == 1) {
            // for i in start..end or start..=end
            const start_v = self.genExpr(node.child0);
            const end_v = self.genExpr(node.child2);
            const end_slot = self.allocHiddenSlot();
            self.emit(.{ .op = .store_local, .src1 = end_v, .slot = end_slot });

            self.pushScope();
            const var_slot = self.defineLocal(loop_var_name);
            self.emit(.{ .op = .store_local, .src1 = start_v, .slot = var_slot });

            const cond_blk = self.newBlock();
            const body_blk = self.newBlock();
            const step_blk = self.newBlock();
            const after_blk = self.newBlock();

            self.emit(.{ .op = .jump, .target_block = cond_blk });

            self.cur_block_idx = cond_blk;
            const cur_i = self.allocVreg();
            self.emit(.{ .op = .load_local, .dest = cur_i, .slot = var_slot });
            const end_loaded = self.allocVreg();
            self.emit(.{ .op = .load_local, .dest = end_loaded, .slot = end_slot });
            const cmp_v = self.allocVreg();
            const cmp_op: IROp = if ((node.flags & 1) != 0) .cmp_le else .cmp_lt;
            self.emit(.{ .op = cmp_op, .dest = cmp_v, .src1 = cur_i, .src2 = end_loaded });
            self.emit(.{ .op = .cond_jump, .src1 = cmp_v, .target_block = body_blk, .alt_block = after_blk });

            if (self.loop_depth < self.loop_break.len) {
                self.loop_break[self.loop_depth] = after_blk;
                self.loop_continue[self.loop_depth] = step_blk;
                self.loop_scope_depths[self.loop_depth] = self.scope_depth;
                self.loop_depth += 1;
            }

            self.cur_block_idx = body_blk;
            if (node.child1 != 0) self.genBlockRoot(node.child1, false, false);
            if (!self.blockTerminated(self.cur_block_idx)) {
                self.emit(.{ .op = .jump, .target_block = step_blk });
            }

            self.cur_block_idx = step_blk;
            const cur_i2 = self.allocVreg();
            self.emit(.{ .op = .load_local, .dest = cur_i2, .slot = var_slot });
            const one = self.allocVreg();
            self.emit(.{ .op = .const_int, .dest = one, .imm = 1 });
            const next_i = self.allocVreg();
            self.emit(.{ .op = .add, .dest = next_i, .src1 = cur_i2, .src2 = one });
            self.emit(.{ .op = .store_local, .src1 = next_i, .slot = var_slot });
            self.emit(.{ .op = .jump, .target_block = cond_blk });

            if (self.loop_depth > 0) self.loop_depth -= 1;
            self.popScope();
            self.cur_block_idx = after_blk;
        } else {
            // for elem in array (dynamic or fixed-size)
            const arr_v = self.genExpr(node.child0);
            const arr_slot = self.allocHiddenSlot();
            self.emit(.{ .op = .store_local, .src1 = arr_v, .slot = arr_slot });

            const idx_slot = self.allocHiddenSlot();
            const zero = self.allocVreg();
            self.emit(.{ .op = .const_int, .dest = zero, .imm = 0 });
            self.emit(.{ .op = .store_local, .src1 = zero, .slot = idx_slot });

            var fixed_len: ?u32 = null;
            if (self.sema_info) |si| {
                if (si.node_types[node.child0] == .fixed_array) {
                    fixed_len = si.node_types[node.child0].fixed_array.len;
                }
            }

            const len_v = self.allocVreg();
            if (fixed_len) |flen| {
                self.emit(.{ .op = .const_int, .dest = len_v, .imm = @intCast(flen) });
            } else {
                var len_args: [8]u16 = .{0} ** 8;
                len_args[0] = arr_v;
                self.emit(.{ .op = .call_array_len, .dest = len_v, .args = len_args, .arg_count = 1 });
            }
            const len_slot = self.allocHiddenSlot();
            self.emit(.{ .op = .store_local, .src1 = len_v, .slot = len_slot });

            self.pushScope();
            const var_slot = self.defineLocal(loop_var_name);

            const cond_blk = self.newBlock();
            const body_blk = self.newBlock();
            const step_blk = self.newBlock();
            const after_blk = self.newBlock();

            self.emit(.{ .op = .jump, .target_block = cond_blk });

            self.cur_block_idx = cond_blk;
            const cur_idx = self.allocVreg();
            self.emit(.{ .op = .load_local, .dest = cur_idx, .slot = idx_slot });
            const cur_len = self.allocVreg();
            self.emit(.{ .op = .load_local, .dest = cur_len, .slot = len_slot });
            const cmp_v = self.allocVreg();
            self.emit(.{ .op = .cmp_lt, .dest = cmp_v, .src1 = cur_idx, .src2 = cur_len });
            self.emit(.{ .op = .cond_jump, .src1 = cmp_v, .target_block = body_blk, .alt_block = after_blk });

            if (self.loop_depth < self.loop_break.len) {
                self.loop_break[self.loop_depth] = after_blk;
                self.loop_continue[self.loop_depth] = step_blk;
                self.loop_scope_depths[self.loop_depth] = self.scope_depth;
                self.loop_depth += 1;
            }

            self.cur_block_idx = body_blk;
            const arr_l = self.allocVreg();
            self.emit(.{ .op = .load_local, .dest = arr_l, .slot = arr_slot });
            const idx_l = self.allocVreg();
            self.emit(.{ .op = .load_local, .dest = idx_l, .slot = idx_slot });
            const elem_v = self.allocVreg();
            if (fixed_len != null) {
                const three = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = three, .imm = 3 });
                const off = self.allocVreg();
                self.emit(.{ .op = .shl, .dest = off, .src1 = idx_l, .src2 = three });
                const ep = self.allocVreg();
                self.emit(.{ .op = .add, .dest = ep, .src1 = arr_l, .src2 = off });
                self.emit(.{ .op = .deref_load, .dest = elem_v, .src1 = ep });
            } else {
                var get_args: [8]u16 = .{0} ** 8;
                get_args[0] = arr_l;
                get_args[1] = idx_l;
                self.emit(.{ .op = .call_array_get, .dest = elem_v, .args = get_args, .arg_count = 2 });
            }
            self.emit(.{ .op = .store_local, .src1 = elem_v, .slot = var_slot });
            if (node.child1 != 0) self.genBlockRoot(node.child1, false, false);
            if (!self.blockTerminated(self.cur_block_idx)) {
                self.emit(.{ .op = .jump, .target_block = step_blk });
            }

            self.cur_block_idx = step_blk;
            const cur_idx2 = self.allocVreg();
            self.emit(.{ .op = .load_local, .dest = cur_idx2, .slot = idx_slot });
            const one = self.allocVreg();
            self.emit(.{ .op = .const_int, .dest = one, .imm = 1 });
            const next_idx = self.allocVreg();
            self.emit(.{ .op = .add, .dest = next_idx, .src1 = cur_idx2, .src2 = one });
            self.emit(.{ .op = .store_local, .src1 = next_idx, .slot = idx_slot });
            self.emit(.{ .op = .jump, .target_block = cond_blk });

            if (self.loop_depth > 0) self.loop_depth -= 1;
            self.popScope();
            self.cur_block_idx = after_blk;
        }
    }

    fn resolveFieldOffset(self: *const IRGen, field_access_idx: u32) u32 {
        if (self.sema_info) |si| {
            return si.field_offsets[field_access_idx];
        }
        const fname = self.nodeText(field_access_idx);
        const sc = @min(@as(u32, self.ast.struct_count), @as(u32, @intCast(self.ast.struct_defs.len)));
        for (0..sc) |i| {
            const sd = self.ast.struct_defs[i];
            const fc = @min(sd.field_count, @as(u32, 32));
            for (0..fc) |fi| {
                const df = sd.fields[fi];
                const dfname = self.srcText(df.name_start, df.name_len, sd.source_id);
                if (eql(dfname, fname)) return df.offset;
            }
        }
        return 0;
    }

    fn unescapeString(raw: []const u8, out: *[4096]u8) []const u8 {
        var len: usize = 0;
        var i: usize = 0;
        while (i < raw.len and len < out.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                i += 1;
                switch (raw[i]) {
                    'n' => out[len] = '\n',
                    'r' => out[len] = '\r',
                    't' => out[len] = '\t',
                    '\\' => out[len] = '\\',
                    '"' => out[len] = '"',
                    '\'' => out[len] = '\'',
                    '0' => out[len] = 0,
                    'x' => {
                        if (i + 2 < raw.len) {
                            out[len] = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch 'x';
                            i += 2;
                        } else {
                            out[len] = 'x';
                        }
                    },
                    else => out[len] = raw[i],
                }
            } else {
                out[len] = raw[i];
            }
            len += 1;
        }
        return out[0..len];
    }

    fn isStringBinOp(self: *const IRGen, expr_idx: u32, node: ASTNode) bool {
        if (self.sema_info) |si| return si.is_string_op[expr_idx];
        return self.looksLikeStringExpr(node.child0) or self.looksLikeStringExpr(node.child1);
    }

    fn looksLikeStringExpr(self: *const IRGen, idx: u32) bool {
        if (idx == 0) return false;
        const n = self.ast.nodes[idx];
        if (n.kind == .string_literal) return true;
        if (n.kind == .call_expr and n.child0 != 0) {
            const cname = self.nodeText(n.child0);
            return eql(cname, "@string_new") or eql(cname, "@string_concat") or
                eql(cname, "@string_sub") or eql(cname, "@string_slice") or eql(cname, "@int_to_string");
        }
        if (n.kind == .binary_expr) {
            const op: TokenKind = @enumFromInt(n.op);
            if (op == .plus) return self.looksLikeStringExpr(n.child0) or self.looksLikeStringExpr(n.child1);
        }
        return false;
    }

    fn genMatchBody(self: *IRGen, body_idx: u32) u16 {
        if (body_idx == 0) {
            const z = self.allocVreg();
            self.emit(.{ .op = .const_int, .dest = z, .imm = 0 });
            return z;
        }
        const bn = self.ast.nodes[body_idx];
        if (bn.kind == .block) {
            self.pushScope();
            var st = bn.child0;
            var last_v: u16 = 0;
            while (st != 0) {
                if (self.blockTerminated(self.cur_block_idx)) break;
                const next = self.ast.stmt_chains[st];
                if (next == 0 and self.isTailReturnExpr(st)) {
                    last_v = self.genExpr(st);
                } else {
                    self.genStmt(st);
                }
                st = next;
            }
            self.popScope();
            if (last_v == 0 and !self.blockTerminated(self.cur_block_idx)) {
                last_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = last_v, .imm = 0 });
            }
            return last_v;
        }
        if (bn.kind == .expr_stmt and bn.child0 != 0) {
            if (sema_mod.Sema.isExprKind(self.ast.nodes[bn.child0].kind)) return self.genExpr(bn.child0);
        }
        if (sema_mod.Sema.isExprKind(bn.kind)) return self.genExpr(body_idx);
        self.genStmt(body_idx);
        if (!self.blockTerminated(self.cur_block_idx)) {
            const z = self.allocVreg();
            self.emit(.{ .op = .const_int, .dest = z, .imm = 0 });
            return z;
        }
        return 0;
    }

    fn genExpr(self: *IRGen, idx: u32) u16 {
        const res_v = self.genExprRaw(idx);
        if (idx != 0 and self.ast.nodes[idx].kind != .cast_expr) {
            return self.wrapDynTraitIfNeeded(idx, res_v);
        }
        return res_v;
    }

    fn wrapDynTraitIfNeeded(self: *IRGen, expr_idx: u32, val_v: u16) u16 {
        const si = self.sema_info orelse return val_v;
        const imp1 = si.trait_impl_idx[expr_idx];
        if (imp1 == 0) return val_v;
        if (self.ast.nodes[expr_idx].kind == .method_call) return val_v;
        const imp_i = imp1 - 1;
        if (imp_i >= self.ast.trait_impl_count) return val_v;
        const imp = self.ast.trait_impls[imp_i];
        if (imp.trait_idx >= self.ast.trait_count) return val_v;
        const td = self.ast.trait_defs[imp.trait_idx];
        const mc = @max(td.method_count, 1);
        const sz_v = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = sz_v, .imm = @intCast((1 + mc) * 8) });
        var margs: [8]u16 = .{0} ** 8;
        margs[0] = sz_v;
        const fat_v = self.allocVreg();
        self.emit(.{ .op = .call_malloc, .dest = fat_v, .args = margs, .arg_count = 1 });
        self.emit(.{ .op = .field_store, .src1 = fat_v, .src2 = val_v, .field_offset = 0 });
        for (0..td.method_count) |mi| {
            const tm = td.methods[mi];
            const mname = self.srcText(tm.name.start, tm.name.len, tm.name.source_id);
            const mfi = self.findFn(mname, imp.struct_idx + 1) orelse continue;
            const mfn = &self.mod.fns[mfi];
            const fptr_v = self.allocVreg();
            self.emit(.{
                .op = .fn_addr,
                .dest = fptr_v,
                .fn_name_start = mfn.name_start,
                .fn_name_len = @intCast(mfn.name_len),
                .fn_source_id = mfn.source_id,
                .callee_fn_idx = @intCast(mfi),
            });
            self.emit(.{ .op = .field_store, .src1 = fat_v, .src2 = fptr_v, .field_offset = @intCast((1 + mi) * 8) });
        }
        return fat_v;
    }

    fn allocEnumVariant(self: *IRGen, ei: u32, vi: u32, arg_vregs: []const u16) u16 {
        const ed = self.ast.enum_defs[ei];
        const ev = ed.variants[vi];
        var max_p: u32 = 1;
        const vc = @min(ed.variant_count, @as(u32, @intCast(ed.variants.len)));
        for (0..vc) |k| max_p = @max(max_p, ed.variants[k].payload_count);
        const sz_v = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = sz_v, .imm = @intCast((1 + max_p) * 8) });
        var margs: [8]u16 = .{0} ** 8;
        margs[0] = sz_v;
        const ptr_v = self.allocVreg();
        self.emit(.{ .op = .call_malloc, .dest = ptr_v, .args = margs, .arg_count = 1 });
        const tag_v = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = tag_v, .imm = ev.value });
        self.emit(.{ .op = .field_store, .src1 = ptr_v, .src2 = tag_v, .field_offset = 0 });
        for (arg_vregs, 0..) |av, pk| {
            self.emit(.{ .op = .field_store, .src1 = ptr_v, .src2 = av, .field_offset = @intCast((1 + pk) * 8) });
        }
        return ptr_v;
    }

    fn emitMatchPatternCheck(self: *IRGen, pat: u32, scrut_v: u16, scrut_tag: u16, is_tagged_enum: bool, scrut_ty: sema_mod.SemaType) u16 {
        const pn = self.ast.nodes[pat];
        if (pn.kind == .tuple_lit) {
            var elem = pn.child0;
            var offset: u16 = 0;
            var result = self.intConst(1);
            while (elem != 0) : (elem = self.ast.nodes[elem].child1) {
                const child = self.ast.nodes[elem].child0;
                const value = self.allocVreg();
                self.emit(.{ .op = .field_access, .dest = value, .src1 = scrut_v, .field_offset = offset });
                const ty = if (self.sema_info) |si| si.node_types[child] else sema_mod.SemaType.unknown;
                const tagged = ty == .enum_t and self.ast.enum_defs[ty.enum_t].has_payloads;
                var tag = value;
                if (tagged) {
                    tag = self.allocVreg();
                    self.emit(.{ .op = .field_access, .dest = tag, .src1 = value, .field_offset = 0 });
                }
                const matched = self.emitMatchPatternCheck(child, value, tag, tagged, ty);
                result = self.intBinary(.bit_and, result, matched);
                offset += 8;
            }
            return result;
        }
        if (pn.kind == .binary_expr) {
            const op: TokenKind = @enumFromInt(pn.op);
            if (op == .dot_dot or op == .dot_dot_eq) {
                const lo_v = self.genExpr(pn.child0);
                const hi_v = self.genExpr(pn.child1);
                const ge_v = self.allocVreg();
                self.emit(.{ .op = if (scrut_ty.isUnsigned()) .ucmp_ge else .cmp_ge, .dest = ge_v, .src1 = scrut_v, .src2 = lo_v });
                const hi_cmp: IROp = if (scrut_ty.isUnsigned())
                    (if (op == .dot_dot_eq) .ucmp_le else .ucmp_lt)
                else
                    (if (op == .dot_dot_eq) .cmp_le else .cmp_lt);
                const lt_v = self.allocVreg();
                self.emit(.{ .op = hi_cmp, .dest = lt_v, .src1 = scrut_v, .src2 = hi_v });
                const both = self.allocVreg();
                self.emit(.{ .op = .bit_and, .dest = both, .src1 = ge_v, .src2 = lt_v });
                return both;
            }
        }
        if (self.sema_info) |si| {
            if (si.enum_def_idx[pat] > 0) {
                const tv = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = tv, .imm = si.const_vals[pat] });
                const eq_v = self.allocVreg();
                const lhs = if (is_tagged_enum) scrut_tag else scrut_v;
                self.emit(.{ .op = .cmp_eq, .dest = eq_v, .src1 = lhs, .src2 = tv });
                // Keep every payload load dominated by the matching tag.
                // An unmatched variant may have fewer fields or other types.
                if (pn.child2 == 0 or (pn.kind != .call_expr and pn.kind != .scoped_access)) return eq_v;
                const result_slot = self.allocHiddenSlot();
                const zero = self.intConst(0);
                self.emit(.{ .op = .store_local, .src1 = zero, .slot = result_slot });
                const payload_block = self.newBlock();
                const done_block = self.newBlock();
                self.emit(.{ .op = .cond_jump, .src1 = eq_v, .target_block = payload_block, .alt_block = done_block });
                self.cur_block_idx = payload_block;
                var result = self.intConst(1);
                var ai = pn.child2;
                var offset: u16 = 8;
                while (ai != 0) : (ai = self.ast.nodes[ai].child1) {
                    const child = self.ast.nodes[ai].child0;
                    const value = self.allocVreg();
                    self.emit(.{ .op = .field_access, .dest = value, .src1 = scrut_v, .field_offset = offset });
                    const ty = si.node_types[child];
                    const tagged = ty == .enum_t and self.ast.enum_defs[ty.enum_t].has_payloads;
                    var tag = value;
                    if (tagged) {
                        tag = self.allocVreg();
                        self.emit(.{ .op = .field_access, .dest = tag, .src1 = value, .field_offset = 0 });
                    }
                    const matched = self.emitMatchPatternCheck(child, value, tag, tagged, ty);
                    result = self.intBinary(.bit_and, result, matched);
                    offset += 8;
                }
                self.emit(.{ .op = .store_local, .src1 = result, .slot = result_slot });
                self.emit(.{ .op = .jump, .target_block = done_block });
                self.cur_block_idx = done_block;
                const matched = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = matched, .slot = result_slot });
                return matched;
            }
        }
        if (pn.kind == .identifier) {
            const pname = self.nodeText(pat);
            if (eql(pname, "_")) {
                const one = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = one, .imm = 1 });
                return one;
            }
            if (if (self.sema_info) |si| si.is_pattern_binding[pat] else false) {
                const one = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = one, .imm = 1 });
                return one;
            }
        }
        const pat_v = self.genExpr(pat);
        if (scrut_ty == .string or pn.kind == .string_literal) {
            var sargs: [8]u16 = .{0} ** 8;
            sargs[0] = scrut_v;
            sargs[1] = pat_v;
            const eq_v = self.allocVreg();
            self.emit(.{ .op = .call_string_eq, .dest = eq_v, .args = sargs, .arg_count = 2 });
            return eq_v;
        }
        if (scrut_ty == .float or pn.kind == .float_literal) {
            const eq_v = self.allocVreg();
            self.emit(.{ .op = .fcmp_eq, .dest = eq_v, .src1 = scrut_v, .src2 = pat_v });
            return eq_v;
        }
        const eq_v = self.allocVreg();
        self.emit(.{ .op = .cmp_eq, .dest = eq_v, .src1 = scrut_v, .src2 = pat_v });
        return eq_v;
    }

    fn bindMatchPatVars(self: *IRGen, pat: u32, scrut_v: u16) void {
        const pn = self.ast.nodes[pat];
        if (pn.kind == .tuple_lit) {
            var elem = pn.child0;
            var offset: u16 = 0;
            while (elem != 0) : (elem = self.ast.nodes[elem].child1) {
                const value = self.allocVreg();
                self.emit(.{ .op = .field_access, .dest = value, .src1 = scrut_v, .field_offset = offset });
                self.bindMatchPatVars(self.ast.nodes[elem].child0, value);
                offset += 8;
            }
            return;
        }
        if (self.sema_info) |si| {
            if (si.enum_def_idx[pat] > 0) {
                var args_head: u32 = 0;
                if (pn.kind == .call_expr or (pn.kind == .scoped_access and pn.flags == 1)) {
                    args_head = pn.child2;
                }
                var ai = args_head;
                var pk: u16 = 0;
                while (ai != 0) : ({
                    ai = self.ast.nodes[ai].child1;
                    pk += 1;
                }) {
                    const arg = self.ast.nodes[ai].child0;
                    if (arg != 0 and arg < self.ast.count) {
                        const pv = self.allocVreg();
                        self.emit(.{ .op = .field_access, .dest = pv, .src1 = scrut_v, .field_offset = (1 + pk) * 8 });
                        self.bindMatchPatVars(arg, pv);
                    }
                }
                return;
            }
        }
        if (pn.kind == .identifier) {
            const pname = self.nodeText(pat);
            if (!eql(pname, "_") and (if (self.sema_info) |si| si.is_pattern_binding[pat] else false)) {
                const pslot = self.defineLocal(pname);
                self.emit(.{ .op = .store_local, .src1 = scrut_v, .slot = pslot });
            }
        }
    }

    fn genExprRaw(self: *IRGen, idx: u32) u16 {
        if (idx == 0 or self.first_error != null) return 0;
        const node = self.ast.nodes[idx];

        // Check Sema-resolved constant value (const ident, non-payload Enum.Variant, fixed_array.len)
        if (self.sema_info) |si| {
            if (si.is_const_val[idx]) {
                const cv = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = cv, .imm = si.const_vals[idx] });
                return cv;
            }
        }

        switch (node.kind) {
            .int_literal, .float_literal => {
                const v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = v, .imm = node.int_val });
                return v;
            },
            .string_literal => {
                const raw = self.srcText(node.text_start, node.text_len, node.source_id);
                var decoded_buf: [4096]u8 = undefined;
                const decoded = unescapeString(raw, &decoded_buf);
                const str_idx = self.mod.addString(decoded);
                const v = self.allocVreg();
                self.emit(.{ .op = .const_str, .dest = v, .str_idx = @intCast(str_idx), .str_len = @intCast(decoded.len) });
                return v;
            },
            .identifier => {
                const name = self.nodeText(idx);
                if (self.findSlot(name)) |slot| {
                    const v = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = v, .slot = slot });
                    return v;
                }
                if (self.findFn(name, 0)) |target_fi| {
                    if (self.getOrCreateFnWrapper(target_fi)) |wfi| {
                        const sz_v = self.allocVreg();
                        self.emit(.{ .op = .const_int, .dest = sz_v, .imm = 8 });
                        var margs: [8]u16 = .{0} ** 8;
                        margs[0] = sz_v;
                        const cl_v = self.allocVreg();
                        self.emit(.{ .op = .call_malloc, .dest = cl_v, .args = margs, .arg_count = 1 });
                        const wfn = &self.mod.fns[wfi];
                        const fptr_v = self.allocVreg();
                        self.emit(.{
                            .op = .fn_addr,
                            .dest = fptr_v,
                            .fn_name_start = wfn.name_start,
                            .fn_name_len = @intCast(wfn.name_len),
                            .fn_source_id = wfn.source_id,
                            .callee_fn_idx = @intCast(wfi),
                        });
                        self.emit(.{ .op = .field_store, .src1 = cl_v, .src2 = fptr_v, .field_offset = 0 });
                        return cl_v;
                    }
                }
                self.recordErrorAt(error.UndefinedVariable, node.source_id, node.line, node.col, "undefined variable '{s}'", .{name});
                return 0;
            },
            .unary_expr => {
                const op: TokenKind = @enumFromInt(node.op);
                const operand_v = self.genExpr(node.child0);
                const is_flt = if (self.sema_info) |si| si.is_float_op[idx] else false;
                const v = self.allocVreg();
                const ir_op: IROp = switch (op) {
                    .plus => .copy,
                    .minus => if (is_flt) .fneg else .neg,
                    .bang => .logic_not,
                    .tilde => .bit_not,
                    else => .neg,
                };
                self.emit(.{ .op = ir_op, .dest = v, .src1 = operand_v });
                return v;
            },
            .cast_expr => {
                const src_v = self.genExpr(node.child0);
                if (self.sema_info) |si| {
                    if (si.trait_impl_idx[idx] > 0) {
                        return self.wrapDynTraitIfNeeded(idx, src_v);
                    }
                    const src_ty = si.node_types[node.child0];
                    const dst_ty = si.node_types[idx];
                    if (src_ty.isInt() and dst_ty == .float) {
                        const dv = self.allocVreg();
                        self.emit(.{ .op = if (src_ty.isUnsigned()) .uitof else .itof, .dest = dv, .src1 = src_v });
                        if (dst_ty.float == 32) {
                            const rounded = self.allocVreg();
                            self.emit(.{ .op = .f64_to_f32, .dest = rounded, .src1 = dv });
                            return rounded;
                        }
                        return dv;
                    }
                    if (src_ty == .float and dst_ty.isInt()) {
                        const converted = self.allocVreg();
                        self.emit(.{ .op = if (dst_ty.isUnsigned()) .ftou else .ftoi, .dest = converted, .src1 = src_v });
                        const narrow_op: ?IROp = switch (node.type_tag) {
                            .i8 => .sext8,
                            .i16 => .sext16,
                            .i32 => .sext32,
                            .u8 => .zext8,
                            .u16 => .zext16,
                            .u32 => .zext32,
                            else => null,
                        };
                        if (narrow_op) |op| {
                            const narrowed = self.allocVreg();
                            self.emit(.{ .op = op, .dest = narrowed, .src1 = converted });
                            return narrowed;
                        }
                        return converted;
                    }
                    if (src_ty == .float and dst_ty == .float and src_ty.float != dst_ty.float) {
                        const dv = self.allocVreg();
                        const cop: IROp = if (dst_ty.float == 32) .f64_to_f32 else .f32_to_f64;
                        self.emit(.{ .op = cop, .dest = dv, .src1 = src_v });
                        return dv;
                    }
                }
                const cast_op: ?IROp = switch (node.type_tag) {
                    .i8 => .sext8,
                    .i16 => .sext16,
                    .i32 => .sext32,
                    .u8 => .zext8,
                    .u16 => .zext16,
                    .u32 => .zext32,
                    else => null,
                };
                if (cast_op) |cop| {
                    const dv = self.allocVreg();
                    self.emit(.{ .op = cop, .dest = dv, .src1 = src_v });
                    return dv;
                }
                return src_v;
            },
            .binary_expr => {
                const op: TokenKind = @enumFromInt(node.op);
                if (op == .and_and) return self.genLogicalAnd(node.child0, node.child1);
                if (op == .pipe_pipe) return self.genLogicalOr(node.child0, node.child1);

                const lhs_v = self.genExpr(node.child0);
                const rhs_v = self.genExpr(node.child1);
                if (op == .star_star) return self.genPower(lhs_v, rhs_v);

                if (self.isStringBinOp(idx, node)) {
                    var sargs: [8]u16 = .{0} ** 8;
                    sargs[0] = lhs_v;
                    sargs[1] = rhs_v;
                    if (op == .plus) {
                        const dest = self.allocVreg();
                        self.emit(.{ .op = .call_string_concat, .dest = dest, .args = sargs, .arg_count = 2 });
                        return dest;
                    } else if (op == .eq) {
                        const dest = self.allocVreg();
                        self.emit(.{ .op = .call_string_eq, .dest = dest, .args = sargs, .arg_count = 2 });
                        return dest;
                    } else if (op == .ne) {
                        const eq_v = self.allocVreg();
                        self.emit(.{ .op = .call_string_eq, .dest = eq_v, .args = sargs, .arg_count = 2 });
                        const dest = self.allocVreg();
                        self.emit(.{ .op = .logic_not, .dest = dest, .src1 = eq_v });
                        return dest;
                    }
                }

                const is_flt = if (self.sema_info) |si| si.is_float_op[idx] else false;
                if (is_flt) {
                    const fv = self.allocVreg();
                    const fop: IROp = switch (op) {
                        .plus => .fadd,
                        .minus => .fsub,
                        .star => .fmul,
                        .slash => .fdiv,
                        .eq => .fcmp_eq,
                        .ne => .fcmp_ne,
                        .lt => .fcmp_lt,
                        .le => .fcmp_le,
                        .gt => .fcmp_gt,
                        .ge => .fcmp_ge,
                        else => .fadd,
                    };
                    self.emit(.{ .op = fop, .dest = fv, .src1 = lhs_v, .src2 = rhs_v });
                    return fv;
                }

                const is_uns = if (self.sema_info) |si| si.is_unsigned_op[idx] else false;
                const v = self.allocVreg();
                const ir_op: IROp = switch (op) {
                    .plus => .add,
                    .minus => .sub,
                    .star => .mul,
                    .slash => if (is_uns) .udiv else .div,
                    .percent => if (is_uns) .umod else .mod,
                    .lshift => .shl,
                    .rshift => if (is_uns) .ushr else .shr,
                    .amp => .bit_and,
                    .pipe => .bit_or,
                    .caret => .bit_xor,
                    .eq => .cmp_eq,
                    .ne => .cmp_ne,
                    .lt => if (is_uns) .ucmp_lt else .cmp_lt,
                    .le => if (is_uns) .ucmp_le else .cmp_le,
                    .gt => if (is_uns) .ucmp_gt else .cmp_gt,
                    .ge => if (is_uns) .ucmp_ge else .cmp_ge,
                    else => .add,
                };
                self.emit(.{ .op = ir_op, .dest = v, .src1 = lhs_v, .src2 = rhs_v });
                return v;
            },
            .if_stmt => return self.genIfExpr(idx),
            .ternary_expr => {
                const res_slot = self.allocHiddenSlot();
                const cond_v = self.genExpr(node.child0);
                const then_blk = self.newBlock();
                const else_blk = self.newBlock();
                const merge_blk = self.newBlock();

                self.emit(.{ .op = .cond_jump, .src1 = cond_v, .target_block = then_blk, .alt_block = else_blk });

                self.cur_block_idx = then_blk;
                const tv = self.genExpr(node.child1);
                if (!self.blockTerminated(self.cur_block_idx)) {
                    self.emit(.{ .op = .store_local, .src1 = tv, .slot = res_slot });
                    self.emit(.{ .op = .jump, .target_block = merge_blk });
                }

                self.cur_block_idx = else_blk;
                const ev = self.genExpr(node.child2);
                if (!self.blockTerminated(self.cur_block_idx)) {
                    self.emit(.{ .op = .store_local, .src1 = ev, .slot = res_slot });
                    self.emit(.{ .op = .jump, .target_block = merge_blk });
                }

                self.cur_block_idx = merge_blk;
                const res_v = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = res_v, .slot = res_slot });
                return res_v;
            },
            .match_expr => {
                const res_slot = self.allocHiddenSlot();
                const zero_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = zero_v, .imm = 0 });
                self.emit(.{ .op = .store_local, .src1 = zero_v, .slot = res_slot });

                const scrut_v = self.genExpr(node.child0);
                const scrut_ty = if (self.sema_info) |si| si.node_types[node.child0] else sema_mod.SemaType.i64_t;
                const is_tagged_enum = (scrut_ty == .enum_t and self.ast.enum_defs[scrut_ty.enum_t].has_payloads);
                var scrut_tag: u16 = scrut_v;
                if (is_tagged_enum) {
                    scrut_tag = self.allocVreg();
                    self.emit(.{ .op = .field_access, .dest = scrut_tag, .src1 = scrut_v, .field_offset = 0 });
                }
                const merge_blk = self.newBlock();

                var arm = node.child1;
                while (arm != 0) : (arm = self.ast.nodes[arm].child2) {
                    const arm_node = self.ast.nodes[arm];
                    const body_blk = self.newBlock();
                    const next_arm_blk = self.newBlock();

                    var pat = arm_node.child0;
                    const first_pat = pat;
                    while (pat != 0) {
                        const next_pat = self.ast.stmt_chains[pat];
                        const eq_v = self.emitMatchPatternCheck(pat, scrut_v, scrut_tag, is_tagged_enum, scrut_ty);
                        if (next_pat != 0) {
                            const try_next_pat = self.newBlock();
                            self.emit(.{ .op = .cond_jump, .src1 = eq_v, .target_block = body_blk, .alt_block = try_next_pat });
                            self.cur_block_idx = try_next_pat;
                        } else {
                            self.emit(.{ .op = .cond_jump, .src1 = eq_v, .target_block = body_blk, .alt_block = next_arm_blk });
                        }
                        pat = next_pat;
                    }

                    self.cur_block_idx = body_blk;
                    self.pushScope();
                    if (first_pat != 0 and self.ast.stmt_chains[first_pat] == 0) {
                        self.bindMatchPatVars(first_pat, scrut_v);
                    }
                    if (arm_node.extra != 0) {
                        const g_v = self.genExpr(arm_node.extra);
                        const run_blk = self.newBlock();
                        const fail_guard_blk = self.newBlock();
                        self.emit(.{ .op = .cond_jump, .src1 = g_v, .target_block = run_blk, .alt_block = fail_guard_blk });
                        self.cur_block_idx = fail_guard_blk;
                        self.popScope();
                        self.emit(.{ .op = .jump, .target_block = next_arm_blk });
                        self.cur_block_idx = run_blk;
                        self.pushScope();
                        if (first_pat != 0 and self.ast.stmt_chains[first_pat] == 0) {
                            self.bindMatchPatVars(first_pat, scrut_v);
                        }
                    }
                    const bv = self.genMatchBody(arm_node.child1);
                    self.popScope();
                    if (!self.blockTerminated(self.cur_block_idx)) {
                        self.emit(.{ .op = .store_local, .src1 = bv, .slot = res_slot });
                        self.emit(.{ .op = .jump, .target_block = merge_blk });
                    }

                    self.cur_block_idx = next_arm_blk;
                }

                if (node.child2 != 0) {
                    const dv = self.genMatchBody(node.child2);
                    if (!self.blockTerminated(self.cur_block_idx)) {
                        self.emit(.{ .op = .store_local, .src1 = dv, .slot = res_slot });
                        self.emit(.{ .op = .jump, .target_block = merge_blk });
                    }
                } else {
                    self.emit(.{ .op = .unreachable_trap });
                }

                self.cur_block_idx = merge_blk;
                const out_v = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = out_v, .slot = res_slot });
                return out_v;
            },
            .tuple_lit => {
                const cnt: u32 = @max(@as(u32, @intCast(node.int_val)), 1);
                const sz_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = sz_v, .imm = @intCast(cnt * 8) });
                var margs: [8]u16 = .{0} ** 8;
                margs[0] = sz_v;
                const tup_v = self.allocVreg();
                self.emit(.{ .op = .call_malloc, .dest = tup_v, .args = margs, .arg_count = 1 });
                var elem = node.child0;
                var off: u16 = 0;
                while (elem != 0) : ({
                    elem = self.ast.nodes[elem].child1;
                    off += 8;
                }) {
                    const ev = self.genExpr(self.ast.nodes[elem].child0);
                    self.emit(.{ .op = .field_store, .src1 = tup_v, .src2 = ev, .field_offset = off });
                }
                return tup_v;
            },
            .closure_expr => {
                const closure_fi = self.findFnByAstIdx(idx) orelse {
                    self.recordErrorAt(error.UndefinedFunctionCall, node.source_id, node.line, node.col, "unregistered closure", .{});
                    return 0;
                };
                var cap_count: u32 = 0;
                if (self.sema_info) |si| {
                    const cid1 = si.closure_ids[idx];
                    if (cid1 > 0 and cid1 - 1 < si.closure_count) {
                        cap_count = si.closures[cid1 - 1].capture_count;
                    }
                }
                const sz_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = sz_v, .imm = @intCast((1 + cap_count) * 8) });
                var margs: [8]u16 = .{0} ** 8;
                margs[0] = sz_v;
                const cl_v = self.allocVreg();
                self.emit(.{ .op = .call_malloc, .dest = cl_v, .args = margs, .arg_count = 1 });
                const cfn = &self.mod.fns[closure_fi];
                const fptr_v = self.allocVreg();
                self.emit(.{
                    .op = .fn_addr,
                    .dest = fptr_v,
                    .fn_name_start = cfn.name_start,
                    .fn_name_len = @intCast(cfn.name_len),
                    .fn_source_id = cfn.source_id,
                    .callee_fn_idx = @intCast(closure_fi),
                });
                self.emit(.{ .op = .field_store, .src1 = cl_v, .src2 = fptr_v, .field_offset = 0 });
                if (cap_count > 0) {
                    const si = self.sema_info.?;
                    const ci = si.closures[si.closure_ids[idx] - 1];
                    for (0..cap_count) |k| {
                        const cslot = self.findSlot(ci.cap_names[k]) orelse 0;
                        const cv = self.allocVreg();
                        if (cslot != 0) {
                            self.emit(.{ .op = .load_local, .dest = cv, .slot = cslot });
                        } else {
                            self.emit(.{ .op = .const_int, .dest = cv, .imm = 0 });
                        }
                        self.emit(.{ .op = .field_store, .src1 = cl_v, .src2 = cv, .field_offset = @intCast((1 + k) * 8) });
                    }
                }
                return cl_v;
            },
            .try_expr => {
                const val_v = self.genExpr(node.child0);
                const tag_v = self.allocVreg();
                self.emit(.{ .op = .field_access, .dest = tag_v, .src1 = val_v, .field_offset = 0 });
                const zero_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = zero_v, .imm = 0 });
                const is_ok = self.allocVreg();
                self.emit(.{ .op = .cmp_eq, .dest = is_ok, .src1 = tag_v, .src2 = zero_v });
                const ok_blk = self.newBlock();
                const err_blk = self.newBlock();
                self.emit(.{ .op = .cond_jump, .src1 = is_ok, .target_block = ok_blk, .alt_block = err_blk });

                self.cur_block_idx = err_blk;
                self.emitDefersDownTo(1, false);
                self.emit(.{ .op = .ret, .src1 = val_v });

                self.cur_block_idx = ok_blk;
                const payload_v = self.allocVreg();
                self.emit(.{ .op = .field_access, .dest = payload_v, .src1 = val_v, .field_offset = 8 });
                return payload_v;
            },
            .coalesce_expr => {
                const res_slot = self.allocHiddenSlot();
                const lhs_v = self.genExpr(node.child0);
                var is_payload_enum = false;
                if (self.sema_info) |si| {
                    const lty = si.node_types[node.child0];
                    if (lty == .enum_t and self.ast.enum_defs[lty.enum_t].has_payloads) {
                        is_payload_enum = true;
                    }
                }
                const some_blk = self.newBlock();
                const none_blk = self.newBlock();
                const merge_blk = self.newBlock();
                if (is_payload_enum) {
                    const tag_v = self.allocVreg();
                    self.emit(.{ .op = .field_access, .dest = tag_v, .src1 = lhs_v, .field_offset = 0 });
                    const zv = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
                    const is_some = self.allocVreg();
                    self.emit(.{ .op = .cmp_eq, .dest = is_some, .src1 = tag_v, .src2 = zv });
                    self.emit(.{ .op = .cond_jump, .src1 = is_some, .target_block = some_blk, .alt_block = none_blk });
                    self.cur_block_idx = some_blk;
                    const pv = self.allocVreg();
                    self.emit(.{ .op = .field_access, .dest = pv, .src1 = lhs_v, .field_offset = 8 });
                    self.emit(.{ .op = .store_local, .src1 = pv, .slot = res_slot });
                    self.emit(.{ .op = .jump, .target_block = merge_blk });
                } else {
                    self.emit(.{ .op = .cond_jump, .src1 = lhs_v, .target_block = some_blk, .alt_block = none_blk });
                    self.cur_block_idx = some_blk;
                    self.emit(.{ .op = .store_local, .src1 = lhs_v, .slot = res_slot });
                    self.emit(.{ .op = .jump, .target_block = merge_blk });
                }
                self.cur_block_idx = none_blk;
                const rhs_v = self.genExpr(node.child1);
                if (!self.blockTerminated(self.cur_block_idx)) {
                    self.emit(.{ .op = .store_local, .src1 = rhs_v, .slot = res_slot });
                    self.emit(.{ .op = .jump, .target_block = merge_blk });
                }
                self.cur_block_idx = merge_blk;
                const out_v = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = out_v, .slot = res_slot });
                return out_v;
            },
            .map_lit => {
                const is_str_key: i64 = if (self.sema_info) |si| @intCast(si.node_types[idx].map_t & 1) else 0;
                const kk_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = kk_v, .imm = is_str_key });
                var margs: [8]u16 = .{0} ** 8;
                margs[0] = kk_v;
                const map_v = self.allocVreg();
                self.emit(.{ .op = .call_map_new, .dest = map_v, .args = margs, .arg_count = 1 });
                var pair = node.child0;
                while (pair != 0) : (pair = self.ast.nodes[pair].child1) {
                    const pn = self.ast.nodes[pair];
                    const kv = self.genExpr(pn.child0);
                    const vv = self.genExpr(pn.child2);
                    var sargs: [8]u16 = .{0} ** 8;
                    sargs[0] = map_v;
                    sargs[1] = kv;
                    sargs[2] = vv;
                    self.emit(.{ .op = .call_map_set, .dest = 0, .args = sargs, .arg_count = 3 });
                }
                return map_v;
            },
            .list_comp => {
                const cap_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = cap_v, .imm = 16 });
                const esize_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = esize_v, .imm = 8 });
                var nargs: [8]u16 = .{0} ** 8;
                nargs[0] = cap_v;
                nargs[1] = esize_v;
                const out_arr = self.allocVreg();
                self.emit(.{ .op = .call_array_new, .dest = out_arr, .args = nargs, .arg_count = 2 });
                const out_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = out_arr, .slot = out_slot });

                const lvar_name = self.nodeText(idx);
                self.pushScope();
                const var_slot = self.defineLocal(lvar_name);

                if ((node.flags & 2) != 0) {
                    const start_v = self.genExpr(node.child1);
                    const end_v = self.genExpr(node.extra);
                    const end_slot = self.allocHiddenSlot();
                    self.emit(.{ .op = .store_local, .src1 = end_v, .slot = end_slot });
                    self.emit(.{ .op = .store_local, .src1 = start_v, .slot = var_slot });
                    const cond_blk = self.newBlock();
                    const body_blk = self.newBlock();
                    const step_blk = self.newBlock();
                    const after_blk = self.newBlock();
                    self.emit(.{ .op = .jump, .target_block = cond_blk });
                    self.cur_block_idx = cond_blk;
                    const cur_i = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = cur_i, .slot = var_slot });
                    const end_l = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = end_l, .slot = end_slot });
                    const cmp_v = self.allocVreg();
                    self.emit(.{ .op = if ((node.flags & 1) != 0) .cmp_le else .cmp_lt, .dest = cmp_v, .src1 = cur_i, .src2 = end_l });
                    self.emit(.{ .op = .cond_jump, .src1 = cmp_v, .target_block = body_blk, .alt_block = after_blk });

                    self.cur_block_idx = body_blk;
                    if (node.child2 != 0) {
                        const pv = self.genExpr(node.child2);
                        const push_blk = self.newBlock();
                        self.emit(.{ .op = .cond_jump, .src1 = pv, .target_block = push_blk, .alt_block = step_blk });
                        self.cur_block_idx = push_blk;
                    }
                    const ev = self.genExpr(node.child0);
                    const oa = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = oa, .slot = out_slot });
                    var pargs: [8]u16 = .{0} ** 8;
                    pargs[0] = oa;
                    pargs[1] = ev;
                    self.emit(.{ .op = .call_array_push, .dest = 0, .args = pargs, .arg_count = 2 });
                    self.emit(.{ .op = .jump, .target_block = step_blk });

                    self.cur_block_idx = step_blk;
                    const ci2 = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = ci2, .slot = var_slot });
                    const one = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = one, .imm = 1 });
                    const ni = self.allocVreg();
                    self.emit(.{ .op = .add, .dest = ni, .src1 = ci2, .src2 = one });
                    self.emit(.{ .op = .store_local, .src1 = ni, .slot = var_slot });
                    self.emit(.{ .op = .jump, .target_block = cond_blk });
                    self.cur_block_idx = after_blk;
                } else {
                    const src_arr = self.genExpr(node.child1);
                    const arr_slot = self.allocHiddenSlot();
                    self.emit(.{ .op = .store_local, .src1 = src_arr, .slot = arr_slot });
                    const idx_slot = self.allocHiddenSlot();
                    const zv = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
                    self.emit(.{ .op = .store_local, .src1 = zv, .slot = idx_slot });
                    var largs: [8]u16 = .{0} ** 8;
                    largs[0] = src_arr;
                    const len_v = self.allocVreg();
                    self.emit(.{ .op = .call_array_len, .dest = len_v, .args = largs, .arg_count = 1 });
                    const len_slot = self.allocHiddenSlot();
                    self.emit(.{ .op = .store_local, .src1 = len_v, .slot = len_slot });
                    const cond_blk = self.newBlock();
                    const body_blk = self.newBlock();
                    const step_blk = self.newBlock();
                    const after_blk = self.newBlock();
                    self.emit(.{ .op = .jump, .target_block = cond_blk });
                    self.cur_block_idx = cond_blk;
                    const ci = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = ci, .slot = idx_slot });
                    const ll = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = ll, .slot = len_slot });
                    const cmp_v = self.allocVreg();
                    self.emit(.{ .op = .cmp_lt, .dest = cmp_v, .src1 = ci, .src2 = ll });
                    self.emit(.{ .op = .cond_jump, .src1 = cmp_v, .target_block = body_blk, .alt_block = after_blk });

                    self.cur_block_idx = body_blk;
                    const sa_l = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = sa_l, .slot = arr_slot });
                    const ix_l = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = ix_l, .slot = idx_slot });
                    var gargs: [8]u16 = .{0} ** 8;
                    gargs[0] = sa_l;
                    gargs[1] = ix_l;
                    const item_v = self.allocVreg();
                    self.emit(.{ .op = .call_array_get, .dest = item_v, .args = gargs, .arg_count = 2 });
                    self.emit(.{ .op = .store_local, .src1 = item_v, .slot = var_slot });
                    if (node.child2 != 0) {
                        const pv = self.genExpr(node.child2);
                        const push_blk = self.newBlock();
                        self.emit(.{ .op = .cond_jump, .src1 = pv, .target_block = push_blk, .alt_block = step_blk });
                        self.cur_block_idx = push_blk;
                    }
                    const ev = self.genExpr(node.child0);
                    const oa = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = oa, .slot = out_slot });
                    var pargs: [8]u16 = .{0} ** 8;
                    pargs[0] = oa;
                    pargs[1] = ev;
                    self.emit(.{ .op = .call_array_push, .dest = 0, .args = pargs, .arg_count = 2 });
                    self.emit(.{ .op = .jump, .target_block = step_blk });

                    self.cur_block_idx = step_blk;
                    const ci2 = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = ci2, .slot = idx_slot });
                    const one = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = one, .imm = 1 });
                    const ni = self.allocVreg();
                    self.emit(.{ .op = .add, .dest = ni, .src1 = ci2, .src2 = one });
                    self.emit(.{ .op = .store_local, .src1 = ni, .slot = idx_slot });
                    self.emit(.{ .op = .jump, .target_block = cond_blk });
                    self.cur_block_idx = after_blk;
                }
                self.popScope();
                const res_v = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = res_v, .slot = out_slot });
                return res_v;
            },
            .interp_string => {
                const empty_idx = self.mod.addString("");
                var acc_v = self.allocVreg();
                self.emit(.{ .op = .const_str, .dest = acc_v, .str_idx = @intCast(empty_idx), .str_len = 0 });
                var seg = node.child0;
                while (seg != 0) : (seg = self.ast.stmt_chains[seg]) {
                    const sv = self.genExpr(seg);
                    var piece_v = sv;
                    if (self.sema_info) |si| {
                        const sty = si.node_types[seg];
                        if (sty == .string) {
                            piece_v = sv;
                        } else if (sty == .float) {
                            var fargs: [8]u16 = .{0} ** 8;
                            fargs[0] = sv;
                            piece_v = self.allocVreg();
                            self.emit(.{ .op = .call_float_to_string, .dest = piece_v, .args = fargs, .arg_count = 1 });
                        } else if (sty == .bool) {
                            const bs_slot = self.allocHiddenSlot();
                            const t_blk = self.newBlock();
                            const f_blk = self.newBlock();
                            const m_blk = self.newBlock();
                            self.emit(.{ .op = .cond_jump, .src1 = sv, .target_block = t_blk, .alt_block = f_blk });
                            self.cur_block_idx = t_blk;
                            const ts_idx = self.mod.addString("true");
                            const tv = self.allocVreg();
                            self.emit(.{ .op = .const_str, .dest = tv, .str_idx = @intCast(ts_idx), .str_len = 4 });
                            self.emit(.{ .op = .store_local, .src1 = tv, .slot = bs_slot });
                            self.emit(.{ .op = .jump, .target_block = m_blk });
                            self.cur_block_idx = f_blk;
                            const fs_idx = self.mod.addString("false");
                            const fv = self.allocVreg();
                            self.emit(.{ .op = .const_str, .dest = fv, .str_idx = @intCast(fs_idx), .str_len = 5 });
                            self.emit(.{ .op = .store_local, .src1 = fv, .slot = bs_slot });
                            self.emit(.{ .op = .jump, .target_block = m_blk });
                            self.cur_block_idx = m_blk;
                            piece_v = self.allocVreg();
                            self.emit(.{ .op = .load_local, .dest = piece_v, .slot = bs_slot });
                        } else {
                            var iargs: [8]u16 = .{0} ** 8;
                            iargs[0] = sv;
                            piece_v = self.allocVreg();
                            self.emit(.{ .op = .call_int_to_string, .dest = piece_v, .args = iargs, .arg_count = 1 });
                        }
                    }
                    var cargs: [8]u16 = .{0} ** 8;
                    cargs[0] = acc_v;
                    cargs[1] = piece_v;
                    const next_acc = self.allocVreg();
                    self.emit(.{ .op = .call_string_concat, .dest = next_acc, .args = cargs, .arg_count = 2 });
                    acc_v = next_acc;
                }
                return acc_v;
            },
            .spawn_expr => {
                if (node.child0 != 0 and self.ast.nodes[node.child0].kind == .closure_expr) {
                    const cl_ptr = self.genExpr(node.child0);
                    const cl_fi = self.findFnByAstIdx(node.child0) orelse 0;
                    const cfn = &self.mod.fns[cl_fi];
                    const zv = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
                    var targs: [8]u16 = .{0} ** 8;
                    targs[0] = zv;
                    targs[1] = cl_ptr;
                    const dest = self.allocVreg();
                    self.emit(.{
                        .op = .call_thread_create,
                        .dest = dest,
                        .args = targs,
                        .arg_count = 2,
                        .fn_name_start = cfn.name_start,
                        .fn_name_len = @intCast(cfn.name_len),
                        .fn_source_id = cfn.source_id,
                        .callee_fn_idx = @intCast(cl_fi),
                    });
                    return dest;
                }
                const sp_fi = self.findFnByAstIdx(idx) orelse 0;
                const sfn = &self.mod.fns[sp_fi];
                const zv = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
                var targs: [8]u16 = .{0} ** 8;
                targs[0] = zv;
                targs[1] = zv;
                const dest = self.allocVreg();
                self.emit(.{
                    .op = .call_thread_create,
                    .dest = dest,
                    .args = targs,
                    .arg_count = 2,
                    .fn_name_start = sfn.name_start,
                    .fn_name_len = @intCast(sfn.name_len),
                    .fn_source_id = sfn.source_id,
                    .callee_fn_idx = @intCast(sp_fi),
                });
                return dest;
            },
            .comptime_expr => {
                if (node.child0 != 0) return self.genMatchBody(node.child0);
                const z = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = z, .imm = 0 });
                return z;
            },
            .array_lit => {
                if ((node.flags & 1) != 0) {
                    const count: u32 = if (self.sema_info) |si|
                        @intCast(@max(si.const_vals[idx], 1))
                    else
                        1;
                    const base_slot = self.allocMultiSlots(count);
                    const ptr_v = self.allocVreg();
                    self.emit(.{ .op = .alloca, .dest = ptr_v, .slot = base_slot, .imm = @intCast(count * 8) });
                    if (base_slot < self.curFn().local_addr_taken.len) {
                        self.curFn().local_addr_taken[base_slot] = true;
                    }
                    const fill_v = self.genExpr(node.child0);
                    self.emitFixedArrayFill(ptr_v, count, fill_v, 0);
                    return ptr_v;
                }
                const cap_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = cap_v, .imm = @max(node.int_val, 4) });
                const esize_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = esize_v, .imm = 8 });
                var nargs: [8]u16 = .{0} ** 8;
                nargs[0] = cap_v;
                nargs[1] = esize_v;
                const arr_v = self.allocVreg();
                self.emit(.{ .op = .call_array_new, .dest = arr_v, .args = nargs, .arg_count = 2 });

                var elem = node.child0;
                while (elem != 0) : (elem = self.ast.nodes[elem].child1) {
                    const ev = self.genExpr(self.ast.nodes[elem].child0);
                    var pargs: [8]u16 = .{0} ** 8;
                    pargs[0] = arr_v;
                    pargs[1] = ev;
                    self.emit(.{ .op = .call_array_push, .dest = 0, .args = pargs, .arg_count = 2 });
                }
                return arr_v;
            },
            .struct_init => {
                const sname = self.nodeText(idx);
                if (eql(sname, "string")) {
                    var ptr_v: u16 = 0;
                    var len_v: u16 = 0;
                    var fi = node.child2;
                    while (fi != 0) : (fi = self.ast.nodes[fi].child1) {
                        const fname = self.nodeText(fi);
                        const fval = self.genExpr(self.ast.nodes[fi].child0);
                        if (eql(fname, "ptr")) ptr_v = fval
                        else if (eql(fname, "len")) len_v = fval;
                    }
                    if (len_v != 0) {
                        var sargs: [8]u16 = .{0} ** 8;
                        sargs[0] = ptr_v;
                        sargs[1] = len_v;
                        const dest = self.allocVreg();
                        self.emit(.{ .op = .call_string_new, .dest = dest, .args = sargs, .arg_count = 2 });
                        return dest;
                    }
                    return ptr_v;
                }
                const sc = @min(@as(u32, self.ast.struct_count), @as(u32, @intCast(self.ast.struct_defs.len)));
                var found_si: ?u32 = null;
                if (self.sema_info) |si| {
                    if (si.struct_indices[idx] < sc) found_si = si.struct_indices[idx];
                }
                if (found_si == null) {
                    for (0..sc) |i| {
                        const sd = self.ast.struct_defs[i];
                        if (eql(self.srcText(sd.name_start, sd.name_len, sd.source_id), sname)) {
                            found_si = @intCast(i);
                            break;
                        }
                    }
                }
                const si_idx = found_si orelse {
                    self.recordErrorAt(error.InvalidConstruct, node.source_id, node.line, node.col, "undefined struct '{s}'", .{sname});
                    return 0;
                };
                const sd = self.ast.struct_defs[si_idx];
                const size_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = size_v, .imm = @intCast(@max(sd.total_size, 8)) });
                var margs: [8]u16 = .{0} ** 8;
                margs[0] = size_v;
                const ptr_v = self.allocVreg();
                self.emit(.{ .op = .call_malloc, .dest = ptr_v, .args = margs, .arg_count = 1 });

                var fi = node.child2;
                while (fi != 0) : (fi = self.ast.nodes[fi].child1) {
                    const fn_node = self.ast.nodes[fi];
                    const fval = self.genExpr(fn_node.child0);
                    var offset: u16 = 0;
                    if (self.sema_info) |si| {
                        offset = @intCast(si.field_offsets[fi]);
                    } else {
                        const fname = self.nodeText(fi);
                        const fc = @min(sd.field_count, @as(u32, 32));
                        for (0..fc) |k| {
                            const df = sd.fields[k];
                            if (eql(self.srcText(df.name_start, df.name_len, sd.source_id), fname)) {
                                offset = @intCast(df.offset);
                                break;
                            }
                        }
                    }
                    self.emit(.{ .op = .field_store, .src1 = ptr_v, .src2 = fval, .field_offset = offset });
                }
                return ptr_v;
            },
            .field_access => {
                if ((node.flags & 1) != 0) {
                    const base_v = self.genExpr(node.child0);
                    const off: u16 = @intCast(@as(u32, @intCast(node.int_val)) * 8);
                    const v = self.allocVreg();
                    self.emit(.{ .op = .field_access, .dest = v, .src1 = base_v, .field_offset = off });
                    return v;
                }
                if (self.sema_info) |si| {
                    if (si.is_ptr_prop[idx]) {
                        return self.genExpr(node.child0);
                    }
                    if (si.is_len_prop[idx]) {
                        const base_v = self.genExpr(node.child0);
                        const bty = si.node_types[node.child0];
                        var largs: [8]u16 = .{0} ** 8;
                        largs[0] = base_v;
                        const dest = self.allocVreg();
                        const op: IROp = if (bty == .string) .call_string_len else if (bty == .map_t) .call_map_len else .call_array_len;
                        self.emit(.{ .op = op, .dest = dest, .args = largs, .arg_count = 1 });
                        return dest;
                    }
                    if (si.enum_def_idx[idx] > 0) {
                        const ei = si.enum_def_idx[idx] - 1;
                        const vi = si.enum_variant_idx[idx];
                        return self.allocEnumVariant(ei, vi, &.{});
                    }
                }
                const base_v = self.genExpr(node.child0);
                const off: u16 = @intCast(self.resolveFieldOffset(idx));
                const v = self.allocVreg();
                self.emit(.{ .op = .field_access, .dest = v, .src1 = base_v, .field_offset = off });
                return v;
            },
            .index_expr => {
                const arr_v = self.genExpr(node.child0);
                const idx_v = self.genExpr(node.child1);
                if (self.sema_info) |si| {
                    const bty = si.node_types[node.child0];
                    if (bty == .map_t) {
                        var gargs: [8]u16 = .{0} ** 8;
                        gargs[0] = arr_v;
                        gargs[1] = idx_v;
                        const v = self.allocVreg();
                        self.emit(.{ .op = .call_map_get, .dest = v, .args = gargs, .arg_count = 2 });
                        return v;
                    }
                    if (bty == .string) {
                        var sargs: [8]u16 = .{0} ** 8;
                        sargs[0] = arr_v;
                        sargs[1] = idx_v;
                        const v = self.allocVreg();
                        self.emit(.{ .op = .call_string_char_at, .dest = v, .args = sargs, .arg_count = 2 });
                        return v;
                    }
                }
                if (self.isContiguousIndexed(idx)) {
                    self.emitFixedArrayBoundsCheck(idx, idx_v);
                    const is_byte = self.isByteIndexed(idx);
                    if (is_byte) {
                        const ep = self.allocVreg();
                        self.emit(.{ .op = .add, .dest = ep, .src1 = arr_v, .src2 = idx_v });
                        const v = self.allocVreg();
                        var rargs: [8]u16 = .{0} ** 8;
                        rargs[0] = ep;
                        self.emit(.{ .op = .call_read_byte, .dest = v, .args = rargs, .arg_count = 1 });
                        return v;
                    }
                    const three = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = three, .imm = 3 });
                    const off = self.allocVreg();
                    self.emit(.{ .op = .shl, .dest = off, .src1 = idx_v, .src2 = three });
                    const ep = self.allocVreg();
                    self.emit(.{ .op = .add, .dest = ep, .src1 = arr_v, .src2 = off });
                    const v = self.allocVreg();
                    self.emit(.{ .op = .deref_load, .dest = v, .src1 = ep });
                    return v;
                } else {
                    var gargs: [8]u16 = .{0} ** 8;
                    gargs[0] = arr_v;
                    gargs[1] = idx_v;
                    const v = self.allocVreg();
                    self.emit(.{ .op = .call_array_get, .dest = v, .args = gargs, .arg_count = 2 });
                    return v;
                }
            },
            .addr_of => {
                const sub = self.ast.nodes[node.child0];
                if (sub.kind == .identifier) {
                    const name = self.nodeText(node.child0);
                    const slot = self.findSlot(name) orelse {
                        self.recordErrorAt(error.UndefinedVariable, sub.source_id, sub.line, sub.col, "undefined variable '{s}'", .{name});
                        return 0;
                    };
                    if (slot < self.curFn().local_addr_taken.len) {
                        self.curFn().local_addr_taken[slot] = true;
                    }
                    const v = self.allocVreg();
                    self.emit(.{ .op = .addr_of, .dest = v, .slot = slot });
                    return v;
                } else if (sub.kind == .field_access) {
                    const base_v = self.genExpr(sub.child0);
                    const off: i64 = @intCast(self.resolveFieldOffset(node.child0));
                    const off_v = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = off_v, .imm = off });
                    const v = self.allocVreg();
                    self.emit(.{ .op = .add, .dest = v, .src1 = base_v, .src2 = off_v });
                    return v;
                } else if (sub.kind == .index_expr) {
                    const arr_v = self.genExpr(sub.child0);
                    const idx_v = self.genExpr(sub.child1);
                    self.emitFixedArrayBoundsCheck(node.child0, idx_v);
                    const is_byte = self.isByteIndexed(node.child0);
                    if (is_byte) {
                        const v = self.allocVreg();
                        self.emit(.{ .op = .add, .dest = v, .src1 = arr_v, .src2 = idx_v });
                        return v;
                    }
                    const three = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = three, .imm = 3 });
                    const byte_off = self.allocVreg();
                    self.emit(.{ .op = .shl, .dest = byte_off, .src1 = idx_v, .src2 = three });
                    const v = self.allocVreg();
                    self.emit(.{ .op = .add, .dest = v, .src1 = arr_v, .src2 = byte_off });
                    return v;
                } else if (sub.kind == .deref) {
                    return self.genExpr(sub.child0);
                }
                self.recordErrorAt(error.InvalidConstruct, node.source_id, node.line, node.col, "cannot take address of non-lvalue", .{});
                return 0;
            },
            .deref => {
                const ptr_v = self.genExpr(node.child0);
                const v = self.allocVreg();
                self.emit(.{ .op = .deref_load, .dest = v, .src1 = ptr_v });
                return v;
            },
            .call_expr => return self.genCall(idx),
            .scoped_access => {
                if (self.sema_info) |si| {
                    if (si.enum_def_idx[idx] > 0) {
                        const ei = si.enum_def_idx[idx] - 1;
                        const vi = si.enum_variant_idx[idx];
                        var pargs: [8]u16 = undefined;
                        var pc: usize = 0;
                        var ai = node.child2;
                        while (ai != 0 and pc < 8) : ({
                            ai = self.ast.nodes[ai].child1;
                            pc += 1;
                        }) {
                            pargs[pc] = self.genExpr(self.ast.nodes[ai].child0);
                        }
                        return self.allocEnumVariant(ei, vi, pargs[0..pc]);
                    }
                }
                return self.genMethodCall(idx);
            },
            .method_call => return self.genMethodCall(idx),
            else => return 0,
        }
    }

    fn genMethodCall(self: *IRGen, idx: u32) u16 {
        const node = self.ast.nodes[idx];
        const si = self.sema_info orelse {
            self.recordErrorAt(error.InvalidConstruct, node.source_id, node.line, node.col, "method call requires semantic resolution", .{});
            return 0;
        };
        const target_ast = si.method_fn_nodes[idx];
        if (target_ast == 0) {
            const mname = self.nodeText(idx);
            const recv_ty = si.node_types[node.child0];
            if (recv_ty == .dyn_trait) {
                const recv_v = self.genExpr(node.child0);
                const obj_v = self.allocVreg();
                self.emit(.{ .op = .field_access, .dest = obj_v, .src1 = recv_v, .field_offset = 0 });
                const mi: u16 = @intCast(si.field_offsets[idx]);
                const fn_v = self.allocVreg();
                self.emit(.{ .op = .field_access, .dest = fn_v, .src1 = recv_v, .field_offset = (1 + mi) * 8 });
                var args: [8]u16 = .{0} ** 8;
                args[0] = obj_v;
                var ac: u8 = 1;
                var ai = node.child2;
                while (ai != 0) : (ai = self.ast.nodes[ai].child1) {
                    if (ac >= 8) {
                        self.recordErrorAt(error.TooManyArgs, node.source_id, node.line, node.col, "method call exceeds 8 arguments", .{});
                        return 0;
                    }
                    args[ac] = self.genExpr(self.ast.nodes[ai].child0);
                    ac += 1;
                }
                const dest = self.allocVreg();
                self.emit(.{ .op = .call_indirect, .dest = dest, .src1 = fn_v, .args = args, .arg_count = ac });
                return dest;
            }
            if (recv_ty == .enum_t) {
                const recv_v = self.genExpr(node.child0);
                const tag_v = self.allocVreg();
                self.emit(.{ .op = .field_access, .dest = tag_v, .src1 = recv_v, .field_offset = 0 });
                if (eql(mname, "is_some") or eql(mname, "is_ok")) {
                    const zv = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
                    const dv = self.allocVreg();
                    self.emit(.{ .op = .cmp_eq, .dest = dv, .src1 = tag_v, .src2 = zv });
                    return dv;
                }
                if (eql(mname, "is_none") or eql(mname, "is_err")) {
                    const ov = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = ov, .imm = 1 });
                    const dv = self.allocVreg();
                    self.emit(.{ .op = .cmp_eq, .dest = dv, .src1 = tag_v, .src2 = ov });
                    return dv;
                }
                if (eql(mname, "unwrap")) {
                    const zv = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
                    const ok_v = self.allocVreg();
                    self.emit(.{ .op = .cmp_eq, .dest = ok_v, .src1 = tag_v, .src2 = zv });
                    const ok_blk = self.newBlock();
                    const trap_blk = self.newBlock();
                    self.emit(.{ .op = .cond_jump, .src1 = ok_v, .target_block = ok_blk, .alt_block = trap_blk });
                    self.cur_block_idx = trap_blk;
                    self.emit(.{ .op = .unreachable_trap });
                    self.cur_block_idx = ok_blk;
                    const pv = self.allocVreg();
                    self.emit(.{ .op = .field_access, .dest = pv, .src1 = recv_v, .field_offset = 8 });
                    return pv;
                }
                if (eql(mname, "unwrap_or")) {
                    const res_slot = self.allocHiddenSlot();
                    const def_v = if (node.child2 != 0) self.genExpr(self.ast.nodes[node.child2].child0) else blk: {
                        const z = self.allocVreg();
                        self.emit(.{ .op = .const_int, .dest = z, .imm = 0 });
                        break :blk z;
                    };
                    const zv = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
                    const ok_v = self.allocVreg();
                    self.emit(.{ .op = .cmp_eq, .dest = ok_v, .src1 = tag_v, .src2 = zv });
                    const ok_blk = self.newBlock();
                    const def_blk = self.newBlock();
                    const merge_blk = self.newBlock();
                    self.emit(.{ .op = .cond_jump, .src1 = ok_v, .target_block = ok_blk, .alt_block = def_blk });
                    self.cur_block_idx = ok_blk;
                    const pv = self.allocVreg();
                    self.emit(.{ .op = .field_access, .dest = pv, .src1 = recv_v, .field_offset = 8 });
                    self.emit(.{ .op = .store_local, .src1 = pv, .slot = res_slot });
                    self.emit(.{ .op = .jump, .target_block = merge_blk });
                    self.cur_block_idx = def_blk;
                    self.emit(.{ .op = .store_local, .src1 = def_v, .slot = res_slot });
                    self.emit(.{ .op = .jump, .target_block = merge_blk });
                    self.cur_block_idx = merge_blk;
                    const out_v = self.allocVreg();
                    self.emit(.{ .op = .load_local, .dest = out_v, .slot = res_slot });
                    return out_v;
                }
            }
            if (recv_ty == .array) {
                const recv_v = self.genExpr(node.child0);
                if (eql(mname, "len")) {
                    var largs: [8]u16 = .{0} ** 8;
                    largs[0] = recv_v;
                    const dv = self.allocVreg();
                    self.emit(.{ .op = .call_array_len, .dest = dv, .args = largs, .arg_count = 1 });
                    return dv;
                }
                if (eql(mname, "push") and node.child2 != 0) {
                    const ev = self.genExpr(self.ast.nodes[node.child2].child0);
                    var pargs: [8]u16 = .{0} ** 8;
                    pargs[0] = recv_v;
                    pargs[1] = ev;
                    self.emit(.{ .op = .call_array_push, .dest = 0, .args = pargs, .arg_count = 2 });
                    const dv = self.allocVreg();
                    self.emit(.{ .op = .const_int, .dest = dv, .imm = 0 });
                    return dv;
                }
            }
        }
        const callee_fi = self.findFnByAstIdx(target_ast) orelse {
            self.recordErrorAt(error.UndefinedFunctionCall, node.source_id, node.line, node.col, "unresolved method '{s}'", .{self.nodeText(idx)});
            return 0;
        };
        const target_fn = &self.mod.fns[callee_fi];

        var args: [8]u16 = .{0} ** 8;
        var ac: u8 = 0;

        const is_static = (node.kind == .scoped_access) or
            (node.kind == .method_call and self.ast.nodes[node.child0].kind == .identifier and self.findSlot(self.nodeText(node.child0)) == null);
        if (!is_static) {
            args[0] = self.genExpr(node.child0);
            ac = 1;
        }
        var ai = node.child2;
        while (ai != 0) : (ai = self.ast.nodes[ai].child1) {
            if (ac >= 8) {
                self.recordErrorAt(error.TooManyArgs, node.source_id, node.line, node.col, "method call exceeds 8 arguments", .{});
                return 0;
            }
            args[ac] = self.genExpr(self.ast.nodes[ai].child0);
            ac += 1;
        }
        const dest = self.allocVreg();
        self.emit(.{
            .op = .call,
            .dest = dest,
            .fn_name_start = target_fn.name_start,
            .fn_name_len = @intCast(target_fn.name_len),
            .fn_source_id = target_fn.source_id,
            .callee_fn_idx = @intCast(callee_fi),
            .args = args,
            .arg_count = ac,
        });
        return dest;
    }

    fn genLogicalAnd(self: *IRGen, lhs_idx: u32, rhs_idx: u32) u16 {
        const res_slot = self.allocHiddenSlot();
        const lhs_v = self.genExpr(lhs_idx);
        const rhs_blk = self.newBlock();
        const false_blk = self.newBlock();
        const merge_blk = self.newBlock();

        self.emit(.{ .op = .cond_jump, .src1 = lhs_v, .target_block = rhs_blk, .alt_block = false_blk });

        self.cur_block_idx = rhs_blk;
        const rhs_v = self.genExpr(rhs_idx);
        const zero = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = zero, .imm = 0 });
        const norm_v = self.allocVreg();
        self.emit(.{ .op = .cmp_ne, .dest = norm_v, .src1 = rhs_v, .src2 = zero });
        self.emit(.{ .op = .store_local, .src1 = norm_v, .slot = res_slot });
        self.emit(.{ .op = .jump, .target_block = merge_blk });

        self.cur_block_idx = false_blk;
        const fz = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = fz, .imm = 0 });
        self.emit(.{ .op = .store_local, .src1 = fz, .slot = res_slot });
        self.emit(.{ .op = .jump, .target_block = merge_blk });

        self.cur_block_idx = merge_blk;
        const res_v = self.allocVreg();
        self.emit(.{ .op = .load_local, .dest = res_v, .slot = res_slot });
        return res_v;
    }

    fn genLogicalOr(self: *IRGen, lhs_idx: u32, rhs_idx: u32) u16 {
        const res_slot = self.allocHiddenSlot();
        const lhs_v = self.genExpr(lhs_idx);
        const true_blk = self.newBlock();
        const rhs_blk = self.newBlock();
        const merge_blk = self.newBlock();

        self.emit(.{ .op = .cond_jump, .src1 = lhs_v, .target_block = true_blk, .alt_block = rhs_blk });

        self.cur_block_idx = true_blk;
        const one = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = one, .imm = 1 });
        self.emit(.{ .op = .store_local, .src1 = one, .slot = res_slot });
        self.emit(.{ .op = .jump, .target_block = merge_blk });

        self.cur_block_idx = rhs_blk;
        const rhs_v = self.genExpr(rhs_idx);
        const zero = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = zero, .imm = 0 });
        const norm_v = self.allocVreg();
        self.emit(.{ .op = .cmp_ne, .dest = norm_v, .src1 = rhs_v, .src2 = zero });
        self.emit(.{ .op = .store_local, .src1 = norm_v, .slot = res_slot });
        self.emit(.{ .op = .jump, .target_block = merge_blk });

        self.cur_block_idx = merge_blk;
        const res_v = self.allocVreg();
        self.emit(.{ .op = .load_local, .dest = res_v, .slot = res_slot });
        return res_v;
    }

    fn emitClosureCall(self: *IRGen, fn_ptr: u16, uargs: []const u16) u16 {
        const code_addr = self.allocVreg();
        self.emit(.{ .op = .field_access, .dest = code_addr, .src1 = fn_ptr, .field_offset = 0 });
        var iargs: [8]u16 = .{0} ** 8;
        iargs[0] = fn_ptr;
        const cnt = @min(uargs.len, 7);
        for (0..cnt) |k| iargs[1 + k] = uargs[k];
        const dest = self.allocVreg();
        self.emit(.{
            .op = .call_indirect,
            .dest = dest,
            .src1 = code_addr,
            .args = iargs,
            .arg_count = @intCast(1 + cnt),
        });
        return dest;
    }

    fn genPower(self: *IRGen, base: u16, exponent: u16) u16 {
        const zero = self.intConst(0);
        const one = self.intConst(1);
        const nonnegative = self.intBinary(.cmp_ge, exponent, zero);
        const init_block = self.newBlock();
        const trap_block = self.newBlock();
        self.emit(.{ .op = .cond_jump, .src1 = nonnegative, .target_block = init_block, .alt_block = trap_block });
        self.cur_block_idx = trap_block;
        self.emit(.{ .op = .unreachable_trap });
        self.cur_block_idx = init_block;
        const result_slot = self.allocHiddenSlot();
        const base_slot = self.allocHiddenSlot();
        const exponent_slot = self.allocHiddenSlot();
        self.emit(.{ .op = .store_local, .src1 = one, .slot = result_slot });
        self.emit(.{ .op = .store_local, .src1 = base, .slot = base_slot });
        self.emit(.{ .op = .store_local, .src1 = exponent, .slot = exponent_slot });
        const cond_block = self.newBlock();
        const body_block = self.newBlock();
        const multiply_block = self.newBlock();
        const step_block = self.newBlock();
        const done_block = self.newBlock();
        self.emit(.{ .op = .jump, .target_block = cond_block });
        self.cur_block_idx = cond_block;
        const e = self.allocVreg();
        self.emit(.{ .op = .load_local, .dest = e, .slot = exponent_slot });
        const active = self.intBinary(.cmp_ne, e, zero);
        self.emit(.{ .op = .cond_jump, .src1 = active, .target_block = body_block, .alt_block = done_block });
        self.cur_block_idx = body_block;
        const b = self.allocVreg();
        self.emit(.{ .op = .load_local, .dest = b, .slot = base_slot });
        const odd = self.intBinary(.bit_and, e, one);
        self.emit(.{ .op = .cond_jump, .src1 = odd, .target_block = multiply_block, .alt_block = step_block });
        self.cur_block_idx = multiply_block;
        const r = self.allocVreg();
        self.emit(.{ .op = .load_local, .dest = r, .slot = result_slot });
        const product = self.intBinary(.mul, r, b);
        self.emit(.{ .op = .store_local, .src1 = product, .slot = result_slot });
        self.emit(.{ .op = .jump, .target_block = step_block });
        self.cur_block_idx = step_block;
        const squared = self.intBinary(.mul, b, b);
        const half = self.intBinary(.ushr, e, one);
        self.emit(.{ .op = .store_local, .src1 = squared, .slot = base_slot });
        self.emit(.{ .op = .store_local, .src1 = half, .slot = exponent_slot });
        self.emit(.{ .op = .jump, .target_block = cond_block });
        self.cur_block_idx = done_block;
        const result = self.allocVreg();
        self.emit(.{ .op = .load_local, .dest = result, .slot = result_slot });
        return result;
    }

    fn intConst(self: *IRGen, value: i64) u16 {
        const dest = self.allocVreg();
        self.emit(.{ .op = .const_int, .dest = dest, .imm = value });
        return dest;
    }

    fn intBinary(self: *IRGen, op: IROp, a: u16, b: u16) u16 {
        const dest = self.allocVreg();
        self.emit(.{ .op = op, .dest = dest, .src1 = a, .src2 = b });
        return dest;
    }

    // Lower integer intrinsics to existing portable IR, keeping semantics shared
    // by all backends. Arguments have already been evaluated exactly once.
    fn genIntegerIntrinsic(self: *IRGen, name: []const u8, args: [8]u16) u16 {
        const a = args[0];
        const b = args[1];
        if (eql(name, "@wrapping_add")) return self.intBinary(.add, a, b);
        if (eql(name, "@wrapping_sub")) return self.intBinary(.sub, a, b);
        if (eql(name, "@wrapping_mul")) return self.intBinary(.mul, a, b);
        const zero = self.intConst(0);
        const one = self.intConst(1);
        if (eql(name, "@signum")) {
            const positive = self.intBinary(.cmp_gt, a, zero);
            const negative = self.intBinary(.cmp_lt, a, zero);
            return self.intBinary(.sub, positive, negative);
        }
        if (eql(name, "@is_power_of_two")) {
            const positive = self.intBinary(.cmp_gt, a, zero);
            const prev = self.intBinary(.sub, a, one);
            const bits = self.intBinary(.bit_and, a, prev);
            const single = self.intBinary(.cmp_eq, bits, zero);
            return self.intBinary(.bit_and, positive, single);
        }
        if (eql(name, "@rotl") or eql(name, "@rotr")) {
            const mask = self.intConst(63);
            const count = self.intBinary(.bit_and, b, mask);
            const neg_count = self.intBinary(.sub, zero, count);
            // Mask the complementary count too: never emit a shift by 64.
            const complement = self.intBinary(.bit_and, neg_count, mask);
            const left = self.intBinary(.shl, a, if (eql(name, "@rotl")) count else complement);
            const right = self.intBinary(.ushr, a, if (eql(name, "@rotl")) complement else count);
            return self.intBinary(.bit_or, left, right);
        }
        // Reverse bits in six stages, swapping adjacent 1/2/4/8/16/32-bit groups.
        var value = a;
        inline for (.{
            .{ @as(i64, 1), @as(i64, 0x5555555555555555) },
            .{ @as(i64, 2), @as(i64, 0x3333333333333333) },
            .{ @as(i64, 4), @as(i64, 0x0f0f0f0f0f0f0f0f) },
            .{ @as(i64, 8), @as(i64, 0x00ff00ff00ff00ff) },
            .{ @as(i64, 16), @as(i64, 0x0000ffff0000ffff) },
            .{ @as(i64, 32), @as(i64, 0x00000000ffffffff) },
        }) |stage| {
            const shift = self.intConst(stage[0]);
            const mask = self.intConst(stage[1]);
            const right = self.intBinary(.bit_and, self.intBinary(.ushr, value, shift), mask);
            const left = self.intBinary(.shl, self.intBinary(.bit_and, value, mask), shift);
            value = self.intBinary(.bit_or, left, right);
        }
        return value;
    }

    fn genCall(self: *IRGen, idx: u32) u16 {
        const node = self.ast.nodes[idx];
        const name_node = self.ast.nodes[node.child0];
        const name = self.nodeText(node.child0);

        var args: [8]u16 = .{0} ** 8;
        var arg_nodes: [8]u32 = .{0} ** 8;
        var ac: u8 = 0;
        var ai = node.child2;
        while (ai != 0) : (ai = self.ast.nodes[ai].child1) {
            if (ac >= 8) {
                self.recordErrorAt(error.TooManyArgs, node.source_id, node.line, node.col, "too many arguments in call to '{s}'", .{name});
                return 0;
            }
            arg_nodes[ac] = self.ast.nodes[ai].child0;
            args[ac] = self.genExpr(arg_nodes[ac]);
            ac += 1;
        }

        if (name_node.kind == .identifier and self.findSlot(name) == null) {
            if (eql(name, "term_size") or eql(name, "@term_size")) {
                const dest = self.allocVreg();
                self.emit(.{ .op = .call_term_size, .dest = dest });
                return dest;
            }
            if (eql(name, "set_raw_mode") or eql(name, "@set_raw_mode")) {
                self.emit(.{ .op = .call_set_raw_mode, .dest = 0, .args = args, .arg_count = ac });
                return 0;
            }
            if (eql(name, "read_key") or eql(name, "@read_key")) {
                const dest = self.allocVreg();
                self.emit(.{ .op = .call_read_key, .dest = dest });
                return dest;
            }
            if (sema_mod.isIntegerIntrinsic(name)) return self.genIntegerIntrinsic(name, args);
            if (eql(name, "@target_os")) {
                const dv = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = dv, .imm = @intFromEnum(self.target.os) });
                return dv;
            }
            if (eql(name, "@target_arch")) {
                const dv = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = dv, .imm = @intFromEnum(self.target.arch) });
                return dv;
            }
            if (eql(name, "@target_ptr_bits")) {
                const dv = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = dv, .imm = @as(i64, self.target.arch.ptrSize()) * 8 });
                return dv;
            }
            if (eql(name, "@panic") and ac >= 1) {
                var largs: [8]u16 = .{0} ** 8;
                largs[0] = args[0];
                const len_v = self.allocVreg();
                self.emit(.{ .op = .call_string_len, .dest = len_v, .args = largs, .arg_count = 1 });
                const fd_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = fd_v, .imm = 2 });
                var wargs: [8]u16 = .{0} ** 8;
                wargs[0] = fd_v;
                wargs[1] = args[0];
                wargs[2] = len_v;
                self.emit(.{ .op = .call_write, .dest = 0, .args = wargs, .arg_count = 3 });
                const nl_idx = self.mod.addString("\n");
                const nl_v = self.allocVreg();
                self.emit(.{ .op = .const_str, .dest = nl_v, .str_idx = @intCast(nl_idx), .str_len = 1 });
                const one_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = one_v, .imm = 1 });
                wargs[1] = nl_v;
                wargs[2] = one_v;
                self.emit(.{ .op = .call_write, .dest = 0, .args = wargs, .arg_count = 3 });
                self.emit(.{ .op = .unreachable_trap });
                return 0;
            }
            if (eql(name, "@thread_create")) {
                var fn_start: u32 = 0;
                var fn_len: u16 = 0;
                var fn_sid: u16 = 0;
                if (node.child2 != 0) {
                    const first_arg_node = self.ast.nodes[self.ast.nodes[node.child2].child0];
                    if (first_arg_node.kind == .string_literal) {
                        fn_start = first_arg_node.text_start;
                        fn_len = @intCast(first_arg_node.text_len);
                        fn_sid = @intCast(first_arg_node.source_id);
                    }
                }
                const dest = self.allocVreg();
                self.emit(.{
                    .op = .call_thread_create,
                    .dest = dest,
                    .args = args,
                    .arg_count = ac,
                    .fn_name_start = fn_start,
                    .fn_name_len = fn_len,
                    .fn_source_id = fn_sid,
                });
                return dest;
            }

            if ((eql(name, "@min") or eql(name, "@max")) and ac == 2) {
                const is_flt = if (self.sema_info) |si| si.is_float_op[idx] else false;
                const res_slot = self.allocHiddenSlot();
                const cmp_v = self.allocVreg();
                const op_cmp: IROp = if (eql(name, "@min"))
                    (if (is_flt) .fcmp_lt else .cmp_lt)
                else
                    (if (is_flt) .fcmp_gt else .cmp_gt);
                self.emit(.{ .op = op_cmp, .dest = cmp_v, .src1 = args[0], .src2 = args[1] });
                const tb = self.newBlock();
                const fb = self.newBlock();
                const mb = self.newBlock();
                self.emit(.{ .op = .cond_jump, .src1 = cmp_v, .target_block = tb, .alt_block = fb });
                self.cur_block_idx = tb;
                self.emit(.{ .op = .store_local, .src1 = args[0], .slot = res_slot });
                self.emit(.{ .op = .jump, .target_block = mb });
                self.cur_block_idx = fb;
                self.emit(.{ .op = .store_local, .src1 = args[1], .slot = res_slot });
                self.emit(.{ .op = .jump, .target_block = mb });
                self.cur_block_idx = mb;
                const rv = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = rv, .slot = res_slot });
                return rv;
            }

            if (eql(name, "@clamp") and ac == 3) {
                const is_flt = if (self.sema_info) |si| si.is_float_op[idx] else false;
                const res_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = args[0], .slot = res_slot });
                const lt_op: IROp = if (is_flt) .fcmp_lt else .cmp_lt;
                const gt_op: IROp = if (is_flt) .fcmp_gt else .cmp_gt;
                const c1 = self.allocVreg();
                self.emit(.{ .op = lt_op, .dest = c1, .src1 = args[0], .src2 = args[1] });
                const b_lo = self.newBlock();
                const b_chk_hi = self.newBlock();
                const b_hi = self.newBlock();
                const b_done = self.newBlock();
                self.emit(.{ .op = .cond_jump, .src1 = c1, .target_block = b_lo, .alt_block = b_chk_hi });
                self.cur_block_idx = b_lo;
                self.emit(.{ .op = .store_local, .src1 = args[1], .slot = res_slot });
                self.emit(.{ .op = .jump, .target_block = b_done });
                self.cur_block_idx = b_chk_hi;
                const c2 = self.allocVreg();
                self.emit(.{ .op = gt_op, .dest = c2, .src1 = args[0], .src2 = args[2] });
                self.emit(.{ .op = .cond_jump, .src1 = c2, .target_block = b_hi, .alt_block = b_done });
                self.cur_block_idx = b_hi;
                self.emit(.{ .op = .store_local, .src1 = args[2], .slot = res_slot });
                self.emit(.{ .op = .jump, .target_block = b_done });
                self.cur_block_idx = b_done;
                const rv = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = rv, .slot = res_slot });
                return rv;
            }

            if (eql(name, "@array_map") and ac == 2) {
                const cap_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = cap_v, .imm = 16 });
                const es_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = es_v, .imm = 8 });
                var nargs: [8]u16 = .{0} ** 8;
                nargs[0] = cap_v;
                nargs[1] = es_v;
                const out_arr = self.allocVreg();
                self.emit(.{ .op = .call_array_new, .dest = out_arr, .args = nargs, .arg_count = 2 });
                const out_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = out_arr, .slot = out_slot });
                const arr_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = args[0], .slot = arr_slot });
                const fn_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = args[1], .slot = fn_slot });
                var largs: [8]u16 = .{0} ** 8;
                largs[0] = args[0];
                const len_v = self.allocVreg();
                self.emit(.{ .op = .call_array_len, .dest = len_v, .args = largs, .arg_count = 1 });
                const len_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = len_v, .slot = len_slot });
                const idx_slot = self.allocHiddenSlot();
                const zv = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
                self.emit(.{ .op = .store_local, .src1 = zv, .slot = idx_slot });
                const cond_blk = self.newBlock();
                const body_blk = self.newBlock();
                const after_blk = self.newBlock();
                self.emit(.{ .op = .jump, .target_block = cond_blk });
                self.cur_block_idx = cond_blk;
                const ci = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = ci, .slot = idx_slot });
                const ll = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = ll, .slot = len_slot });
                const cmp_v = self.allocVreg();
                self.emit(.{ .op = .cmp_lt, .dest = cmp_v, .src1 = ci, .src2 = ll });
                self.emit(.{ .op = .cond_jump, .src1 = cmp_v, .target_block = body_blk, .alt_block = after_blk });
                self.cur_block_idx = body_blk;
                const al = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = al, .slot = arr_slot });
                const il = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = il, .slot = idx_slot });
                var gargs: [8]u16 = .{0} ** 8;
                gargs[0] = al;
                gargs[1] = il;
                const elem_v = self.allocVreg();
                self.emit(.{ .op = .call_array_get, .dest = elem_v, .args = gargs, .arg_count = 2 });
                const fl = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = fl, .slot = fn_slot });
                const mapped_v = self.emitClosureCall(fl, &.{elem_v});
                const ol = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = ol, .slot = out_slot });
                var pargs: [8]u16 = .{0} ** 8;
                pargs[0] = ol;
                pargs[1] = mapped_v;
                self.emit(.{ .op = .call_array_push, .dest = 0, .args = pargs, .arg_count = 2 });
                const one = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = one, .imm = 1 });
                const il2 = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = il2, .slot = idx_slot });
                const ni = self.allocVreg();
                self.emit(.{ .op = .add, .dest = ni, .src1 = il2, .src2 = one });
                self.emit(.{ .op = .store_local, .src1 = ni, .slot = idx_slot });
                self.emit(.{ .op = .jump, .target_block = cond_blk });
                self.cur_block_idx = after_blk;
                const res_v = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = res_v, .slot = out_slot });
                return res_v;
            }

            if (eql(name, "@array_filter") and ac == 2) {
                const cap_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = cap_v, .imm = 16 });
                const es_v = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = es_v, .imm = 8 });
                var nargs: [8]u16 = .{0} ** 8;
                nargs[0] = cap_v;
                nargs[1] = es_v;
                const out_arr = self.allocVreg();
                self.emit(.{ .op = .call_array_new, .dest = out_arr, .args = nargs, .arg_count = 2 });
                const out_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = out_arr, .slot = out_slot });
                const arr_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = args[0], .slot = arr_slot });
                const fn_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = args[1], .slot = fn_slot });
                var largs: [8]u16 = .{0} ** 8;
                largs[0] = args[0];
                const len_v = self.allocVreg();
                self.emit(.{ .op = .call_array_len, .dest = len_v, .args = largs, .arg_count = 1 });
                const len_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = len_v, .slot = len_slot });
                const idx_slot = self.allocHiddenSlot();
                const zv = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
                self.emit(.{ .op = .store_local, .src1 = zv, .slot = idx_slot });
                const cond_blk = self.newBlock();
                const body_blk = self.newBlock();
                const push_blk = self.newBlock();
                const step_blk = self.newBlock();
                const after_blk = self.newBlock();
                self.emit(.{ .op = .jump, .target_block = cond_blk });
                self.cur_block_idx = cond_blk;
                const ci = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = ci, .slot = idx_slot });
                const ll = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = ll, .slot = len_slot });
                const cmp_v = self.allocVreg();
                self.emit(.{ .op = .cmp_lt, .dest = cmp_v, .src1 = ci, .src2 = ll });
                self.emit(.{ .op = .cond_jump, .src1 = cmp_v, .target_block = body_blk, .alt_block = after_blk });
                self.cur_block_idx = body_blk;
                const al = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = al, .slot = arr_slot });
                const il = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = il, .slot = idx_slot });
                var gargs: [8]u16 = .{0} ** 8;
                gargs[0] = al;
                gargs[1] = il;
                const elem_v = self.allocVreg();
                self.emit(.{ .op = .call_array_get, .dest = elem_v, .args = gargs, .arg_count = 2 });
                const elem_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = elem_v, .slot = elem_slot });
                const fl = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = fl, .slot = fn_slot });
                const keep_v = self.emitClosureCall(fl, &.{elem_v});
                self.emit(.{ .op = .cond_jump, .src1 = keep_v, .target_block = push_blk, .alt_block = step_blk });
                self.cur_block_idx = push_blk;
                const ol = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = ol, .slot = out_slot });
                const el2 = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = el2, .slot = elem_slot });
                var pargs: [8]u16 = .{0} ** 8;
                pargs[0] = ol;
                pargs[1] = el2;
                self.emit(.{ .op = .call_array_push, .dest = 0, .args = pargs, .arg_count = 2 });
                self.emit(.{ .op = .jump, .target_block = step_blk });
                self.cur_block_idx = step_blk;
                const one = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = one, .imm = 1 });
                const il2 = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = il2, .slot = idx_slot });
                const ni = self.allocVreg();
                self.emit(.{ .op = .add, .dest = ni, .src1 = il2, .src2 = one });
                self.emit(.{ .op = .store_local, .src1 = ni, .slot = idx_slot });
                self.emit(.{ .op = .jump, .target_block = cond_blk });
                self.cur_block_idx = after_blk;
                const res_v = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = res_v, .slot = out_slot });
                return res_v;
            }

            if (eql(name, "@array_reduce") and ac == 3) {
                const arr_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = args[0], .slot = arr_slot });
                const acc_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = args[1], .slot = acc_slot });
                const fn_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = args[2], .slot = fn_slot });
                var largs: [8]u16 = .{0} ** 8;
                largs[0] = args[0];
                const len_v = self.allocVreg();
                self.emit(.{ .op = .call_array_len, .dest = len_v, .args = largs, .arg_count = 1 });
                const len_slot = self.allocHiddenSlot();
                self.emit(.{ .op = .store_local, .src1 = len_v, .slot = len_slot });
                const idx_slot = self.allocHiddenSlot();
                const zv = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
                self.emit(.{ .op = .store_local, .src1 = zv, .slot = idx_slot });
                const cond_blk = self.newBlock();
                const body_blk = self.newBlock();
                const after_blk = self.newBlock();
                self.emit(.{ .op = .jump, .target_block = cond_blk });
                self.cur_block_idx = cond_blk;
                const ci = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = ci, .slot = idx_slot });
                const ll = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = ll, .slot = len_slot });
                const cmp_v = self.allocVreg();
                self.emit(.{ .op = .cmp_lt, .dest = cmp_v, .src1 = ci, .src2 = ll });
                self.emit(.{ .op = .cond_jump, .src1 = cmp_v, .target_block = body_blk, .alt_block = after_blk });
                self.cur_block_idx = body_blk;
                const al = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = al, .slot = arr_slot });
                const il = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = il, .slot = idx_slot });
                var gargs: [8]u16 = .{0} ** 8;
                gargs[0] = al;
                gargs[1] = il;
                const elem_v = self.allocVreg();
                self.emit(.{ .op = .call_array_get, .dest = elem_v, .args = gargs, .arg_count = 2 });
                const acl = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = acl, .slot = acc_slot });
                const fl = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = fl, .slot = fn_slot });
                const next_acc = self.emitClosureCall(fl, &.{ acl, elem_v });
                self.emit(.{ .op = .store_local, .src1 = next_acc, .slot = acc_slot });
                const one = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = one, .imm = 1 });
                const il2 = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = il2, .slot = idx_slot });
                const ni = self.allocVreg();
                self.emit(.{ .op = .add, .dest = ni, .src1 = il2, .src2 = one });
                self.emit(.{ .op = .store_local, .src1 = ni, .slot = idx_slot });
                self.emit(.{ .op = .jump, .target_block = cond_blk });
                self.cur_block_idx = after_blk;
                const res_v = self.allocVreg();
                self.emit(.{ .op = .load_local, .dest = res_v, .slot = acc_slot });
                return res_v;
            }

            if (eql(name, "@map_new") and ac == 0) {
                const zv = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = zv, .imm = 0 });
                args[0] = zv;
                ac = 1;
            }
            if (eql(name, "@chan_new") and ac == 0) {
                const cv = self.allocVreg();
                self.emit(.{ .op = .const_int, .dest = cv, .imm = 64 });
                args[0] = cv;
                ac = 1;
            }

            const builtin_op: ?IROp = if (eql(name, "printInt"))
                .call_print_int
            else if (eql(name, "printFloat"))
                .call_print_float
            else if (eql(name, "printlnFloat"))
                .call_println_float
            else if (eql(name, "@float_to_string"))
                .call_float_to_string
            else if (eql(name, "@string_to_float"))
                .call_string_to_float
            else if (eql(name, "@sqrt"))
                .call_sqrt
            else if (eql(name, "@fabs"))
                .call_fabs
            else if (eql(name, "@floor"))
                .call_floor
            else if (eql(name, "@ceil"))
                .call_ceil
            else if (eql(name, "@round"))
                .call_round
            else if (eql(name, "@sin"))
                .call_sin
            else if (eql(name, "@cos"))
                .call_cos
            else if (eql(name, "@popcount"))
                .call_popcount
            else if (eql(name, "@clz"))
                .call_clz
            else if (eql(name, "@ctz"))
                .call_ctz
            else if (eql(name, "@bswap"))
                .call_bswap
            else if (eql(name, "@atomic_add"))
                .call_atomic_add
            else if (eql(name, "@atomic_cas"))
                .call_atomic_cas
            else if (eql(name, "@map_new"))
                .call_map_new
            else if (eql(name, "@map_set"))
                .call_map_set
            else if (eql(name, "@map_get"))
                .call_map_get
            else if (eql(name, "@map_has"))
                .call_map_has
            else if (eql(name, "@map_del"))
                .call_map_del
            else if (eql(name, "@map_len"))
                .call_map_len
            else if (eql(name, "@map_free"))
                .call_map_free
            else if (eql(name, "@chan_new"))
                .call_chan_new
            else if (eql(name, "@chan_send"))
                .call_chan_send
            else if (eql(name, "@chan_recv"))
                .call_chan_recv
            else if (eql(name, "@chan_close"))
                .call_chan_close
            else if (eql(name, "@assert"))
                .call_assert
            else if (eql(name, "@assert_eq"))
                .call_assert_eq
            else if (eql(name, "@random_u64"))
                .call_random_u64
            else if (eql(name, "@random_bytes"))
                .call_random_bytes
            else if (eql(name, "@secure_zero"))
                .call_secure_zero
            else if (eql(name, "@const_time_eq"))
                .call_const_time_eq
            else if (eql(name, "@checked_add"))
                .call_checked_add
            else if (eql(name, "@checked_sub"))
                .call_checked_sub
            else if (eql(name, "@checked_mul"))
                .call_checked_mul
            else if (eql(name, "@getenv"))
                .call_getenv
            else if (eql(name, "@sleep_ms"))
                .call_sleep_ms
            else if (eql(name, "@read_u8") or eql(name, "@read_byte"))
                .call_read_byte
            else if (eql(name, "@write_u8") or eql(name, "@write_byte"))
                .call_write_byte
            else if (eql(name, "@read_u32"))
                .call_read_u32
            else if (eql(name, "@write_u32"))
                .call_write_u32
            else if (eql(name, "@read_u64"))
                .call_read_u64
            else if (eql(name, "@write_u64"))
                .call_write_u64
            else if (eql(name, "print") or eql(name, "@print"))
                .call_print
            else if (eql(name, "println") or eql(name, "@println"))
                .call_println
            else if (eql(name, "exit") or eql(name, "@exit"))
                .call_exit
            else if (eql(name, "@panic"))
                .call_panic
            else if (eql(name, "@syscall"))
                .call_syscall
            else if (eql(name, "@memcpy"))
                .call_memcpy
            else if (eql(name, "@memset"))
                .call_memset
            else if (eql(name, "@malloc") or eql(name, "@alloc"))
                .call_malloc
            else if (eql(name, "@free"))
                .call_free
            else if (eql(name, "@ptr_add"))
                .call_ptr_add
            else if (eql(name, "@array_new"))
                .call_array_new
            else if (eql(name, "@array_push"))
                .call_array_push
            else if (eql(name, "@array_get"))
                .call_array_get
            else if (eql(name, "@array_set"))
                .call_array_set
            else if (eql(name, "@array_len"))
                .call_array_len
            else if (eql(name, "@array_free"))
                .call_array_free
            else if (eql(name, "@string_new"))
                .call_string_new
            else if (eql(name, "@string_len"))
                .call_string_len
            else if (eql(name, "@string_sub"))
                .call_string_sub
            else if (eql(name, "@string_slice"))
                .call_string_slice
            else if (eql(name, "@string_char_at"))
                .call_string_char_at
            else if (eql(name, "@string_eq"))
                .call_string_eq
            else if (eql(name, "@string_concat"))
                .call_string_concat
            else if (eql(name, "@string_split"))
                .call_string_split
            else if (eql(name, "@int_to_string"))
                .call_int_to_string
            else if (eql(name, "@string_to_int"))
                .call_string_to_int
            else if (eql(name, "@open"))
                .call_open
            else if (eql(name, "@read"))
                .call_read
            else if (eql(name, "@write"))
                .call_write
            else if (eql(name, "@close"))
                .call_close
            else if (eql(name, "@unlink"))
                .call_unlink
            else if (eql(name, "@mkdir"))
                .call_mkdir
            else if (eql(name, "@stat"))
                .call_stat
            else if (eql(name, "@getpid"))
                .call_getpid
            else if (eql(name, "@getppid"))
                .call_getppid
            else if (eql(name, "@getuid"))
                .call_getuid
            else if (eql(name, "@tcp_socket"))
                .call_tcp_socket
            else if (eql(name, "@tcp_listen"))
                .call_tcp_listen
            else if (eql(name, "@tcp_accept"))
                .call_tcp_accept
            else if (eql(name, "@tcp_connect"))
                .call_tcp_connect
            else if (eql(name, "@sock_send"))
                .call_sock_send
            else if (eql(name, "@sock_recv"))
                .call_sock_recv
            else if (eql(name, "@thread_join"))
                .call_thread_join
            else if (eql(name, "@mutex_create") or eql(name, "@mutex_init"))
                .call_mutex_create
            else if (eql(name, "@mutex_lock"))
                .call_mutex_lock
            else if (eql(name, "@mutex_unlock"))
                .call_mutex_unlock
            else if (eql(name, "@argc"))
                .call_argc
            else if (eql(name, "@argv"))
                .call_argv
            else if (eql(name, "@time_ns"))
                .call_time_ns
            else
                null;

            if (builtin_op) |bop| {
                if (bop == .call_assert_eq and ac >= 2) {
                    if (self.sema_info) |si| {
                        const t0 = si.node_types[arg_nodes[0]];
                        const t1 = si.node_types[arg_nodes[1]];
                        if (t0 == .string or t1 == .string) {
                            const eq_v = self.allocVreg();
                            self.emit(.{ .op = .call_string_eq, .dest = eq_v, .args = args, .arg_count = 2 });
                            var aargs: [8]u16 = .{0} ** 8;
                            aargs[0] = eq_v;
                            const dest = self.allocVreg();
                            self.emit(.{ .op = .call_assert, .dest = dest, .args = aargs, .arg_count = 1 });
                            return dest;
                        } else if (t0.isFloat() or t1.isFloat()) {
                            const eq_v = self.allocVreg();
                            self.emit(.{ .op = .fcmp_eq, .dest = eq_v, .src1 = args[0], .src2 = args[1] });
                            var aargs: [8]u16 = .{0} ** 8;
                            aargs[0] = eq_v;
                            const dest = self.allocVreg();
                            self.emit(.{ .op = .call_assert, .dest = dest, .args = aargs, .arg_count = 1 });
                            return dest;
                        }
                    }
                }
                const dest = self.allocVreg();
                self.emit(.{ .op = bop, .dest = dest, .args = args, .arg_count = ac });
                return dest;
            }

            if (self.findFn(name, 0)) |callee_fi| {
                if (self.sema_info) |si| {
                    const fn_ast = si.direct_call_fns[idx];
                    if (fn_ast != 0) {
                        var ordered: [8]u16 = .{0} ** 8;
                        var wrapper = node.child2;
                        var source_index: usize = 0;
                        while (wrapper != 0) : (source_index += 1) {
                            const target = si.call_arg_targets[wrapper];
                            if (target != 0) ordered[target - 1] = args[source_index];
                            wrapper = self.ast.nodes[wrapper].child1;
                        }
                        var param = self.ast.nodes[fn_ast].child0;
                        var pi: u8 = 0;
                        while (param != 0) : (pi += 1) {
                            if (ordered[pi] == 0) ordered[pi] = self.genExpr(self.ast.nodes[param].child2);
                            param = self.ast.nodes[param].child1;
                        }
                        args = ordered;
                        ac = pi;
                    }
                }
                const dest = self.allocVreg();
                self.emit(.{
                    .op = .call,
                    .dest = dest,
                    .fn_name_start = name_node.text_start,
                    .fn_name_len = @intCast(name_node.text_len),
                    .fn_source_id = @intCast(name_node.source_id),
                    .callee_fn_idx = @intCast(callee_fi),
                    .args = args,
                    .arg_count = ac,
                });
                return dest;
            }

            self.recordErrorAt(error.UndefinedFunctionCall, name_node.source_id, name_node.line, name_node.col, "call to undefined function '{s}'", .{name});
            return 0;
        }

        // Indirect call via closure/fn pointer (local var or complex callee expression)
        if (ac > 7) {
            self.recordErrorAt(error.TooManyArgs, node.source_id, node.line, node.col, "indirect call exceeds 7 arguments", .{});
            return 0;
        }
        const fn_ptr = self.genExpr(node.child0);
        return self.emitClosureCall(fn_ptr, args[0..ac]);
    }
};
