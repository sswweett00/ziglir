// ════════════════════════════════════════════════════════════════════════════
// IR OPTIMIZER — -O0 / -O1 / -O2 passes over CFG Basic-Block IR
// Includes -O2 Inlining, Cytron SSA mem2reg, Dominator-tree GVN, Natural-loop
// LICM, Algebraic/Strength Reduction, Phi-aware CFG Simplification, DCE, and
// Critical-Edge-Safe SSA Destruction.
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const ir = @import("ir.zig");

const IROp = ir.IROp;
const IRInst = ir.IRInst;
const IRBlock = ir.IRBlock;
const IRFn = ir.IRFn;
const IRModule = ir.IRModule;
const MAX_INSTS_PER_BLOCK = ir.MAX_INSTS_PER_BLOCK;
const MAX_BLOCKS_PER_FN = ir.MAX_BLOCKS_PER_FN;

pub const OptLevel = enum(u8) {
    O0 = 0,
    O1 = 1,
    O2 = 2,
};

const MAX_TRACKED_VREGS = 4096;
const MAX_PROMOTED_SLOTS = 256;

pub fn optimize(module: *IRModule, level: OptLevel) void {
    if (level == .O0) return;

    if (level == .O2) {
        var inl_pass: u32 = 0;
        while (inl_pass < 2) : (inl_pass += 1) {
            if (!inlineSmallFunctions(module)) break;
            var fi_cfg: u32 = 0;
            while (fi_cfg < module.fn_count) : (fi_cfg += 1) {
                while (simplifyCFG(&module.fns[fi_cfg])) {}
            }
        }
    }

    var fi: u32 = 0;
    while (fi < module.fn_count) : (fi += 1) {
        optimizeFn(&module.fns[fi], level);
    }
}

fn optimizeFn(f: *IRFn, level: OptLevel) void {
    if (level == .O1) {
        var iter: u32 = 0;
        while (iter < 8) : (iter += 1) {
            var changed = false;
            if (localConstantFoldAndLVN(f)) changed = true;
            if (globalCopyPropagate(f)) changed = true;
            if (simplifyCFG(f)) changed = true;
            if (deadCodeElimination(f, level)) changed = true;
            if (!changed) break;
        }
        return;
    }

    // ── -O2 Pipeline ────────────────────────────────────────────
    // 1. Pre-SSA cleanup
    _ = localStoreToLoadForward(f);
    _ = localConstantFoldAndLVN(f);
    _ = globalCopyPropagate(f);
    _ = simplifyCFG(f);

    // 2. Full SSA construction (mem2reg) across CFG
    const ssa_built = mem2reg(f);

    // 3. Iterative SSA optimization loop (GVN + LICM + Folding + CFG + DCE)
    var iter: u32 = 0;
    while (iter < 8) : (iter += 1) {
        var changed = false;
        if (!ssa_built) {
            if (promoteEntrySingleDefSlots(f)) changed = true;
            if (localStoreToLoadForward(f)) changed = true;
        }
        if (simplifyTrivialPhis(f)) changed = true;
        if (localConstantFoldAndLVN(f)) changed = true;
        if (globalValueNumbering(f)) changed = true;
        if (globalCopyPropagate(f)) changed = true;
        if (simplifyCFG(f)) changed = true;
        if (loopInvariantCodeMotion(f)) changed = true;
        if (deadCodeElimination(f, .O2)) changed = true;
        if (!changed) break;
    }

    // 4. Out-of-SSA destruction & final cleanup
    if (hasAnyPhi(f)) {
        destructSSA(f);
    }
    _ = deadCodeElimination(f, .O2);
    _ = reorderBlocksRPO(f);
    _ = coalesceCopiesPostSSA(f);
    _ = deadCodeElimination(f, .O2);
    _ = simplifyCFG(f);
    _ = rotateLoops(f);
    _ = coalesceCopiesPostSSA(f);
    _ = localConstantFoldAndLVN(f);
    _ = deadCodeElimination(f, .O2);
    _ = simplifyCFG(f);
    _ = reorderBlocksRPO(f);
    _ = unrollCountedLoops(f);

    var post_iter: u32 = 0;
    while (post_iter < 4) : (post_iter += 1) {
        var changed = false;
        if (globalCopyPropagate(f)) changed = true;
        if (coalesceCopiesPostSSA(f)) changed = true;
        if (localConstantFoldAndLVN(f)) changed = true;
        if (simplifyCFG(f)) changed = true;
        if (deadCodeElimination(f, .O2)) changed = true;
        if (!changed) break;
    }
    _ = reorderBlocksRPO(f);
}

// ════════════════════════════════════════════════════════════════════════════
// Function Inlining (-O2)
// ════════════════════════════════════════════════════════════════════════════

fn countFnInsts(f: *const IRFn) u32 {
    var total: u32 = 0;
    for (0..f.block_count) |bi| total += f.blocks[bi].inst_count;
    return total;
}

fn fnInlineEligible(f: *const IRFn) bool {
    if (f.block_count == 0 or f.block_count > 8) return false;
    if (f.total_locals > 48) return false;
    const total = countFnInsts(f);
    if (total == 0 or total > 56) return false;
    for (0..f.block_count) |bi| {
        const b = &f.blocks[bi];
        for (0..b.inst_count) |ii| {
            const op = b.insts[ii].op;
            if (op == .phi or op == .alloca or op == .addr_of or op == .call or op == .call_indirect) return false;
        }
    }
    return true;
}

fn inlineSmallFunctions(module: *IRModule) bool {
    var changed = false;
    var eligible: [ir.MAX_FNS]bool = .{false} ** ir.MAX_FNS;
    for (0..module.fn_count) |i| {
        eligible[i] = fnInlineEligible(&module.fns[i]);
    }

    var fi: u32 = 0;
    while (fi < module.fn_count) : (fi += 1) {
        var f = &module.fns[fi];
        var inlined_count: u32 = 0;
        var bi: u16 = 0;
        while (bi < f.block_count and inlined_count < 8) : (bi += 1) {
            var ii: u16 = 0;
            while (ii < f.blocks[bi].inst_count) : (ii += 1) {
                const inst = f.blocks[bi].insts[ii];
                if (inst.op != .call or inst.callee_fn_idx < 0) continue;
                const callee_i: u32 = @intCast(inst.callee_fn_idx);
                if (callee_i == fi or callee_i >= module.fn_count) continue;
                if (!eligible[callee_i]) continue;

                const c = &module.fns[callee_i];
                if (f.block_count + c.block_count + 2 > MAX_BLOCKS_PER_FN) continue;
                if (f.vreg_count + c.vreg_count + 8 >= MAX_TRACKED_VREGS) continue;
                if (f.total_locals + c.total_locals + 4 > 250) continue;

                // Do not inline if caller would lose self-tail-call? Never happens since c != fi.
                // Check caller block tail copy room for param stores
                if (@as(u32, ii) + @as(u32, c.param_count) + 2 >= MAX_INSTS_PER_BLOCK) continue;

                const vreg_off: u16 = f.vreg_count;
                const slot_off: u16 = @intCast(f.total_locals);
                const blk_off: u16 = f.block_count;
                const after_bi: u16 = blk_off + c.block_count;

                // Move caller instructions after call (ii+1..) into after_bi
                var after_blk = IRBlock{ .label = after_bi, .inst_count = 0 };
                const orig_count = f.blocks[bi].inst_count;
                var tail_k: u16 = ii + 1;
                while (tail_k < orig_count) : (tail_k += 1) {
                    after_blk.insts[after_blk.inst_count] = f.blocks[bi].insts[tail_k];
                    after_blk.inst_count += 1;
                }

                // Truncate caller block at `ii`, emit param stores and jump to callee entry
                f.blocks[bi].inst_count = ii;
                const call_dest = inst.dest;
                const pcnt = @min(inst.arg_count, @as(u8, @intCast(c.param_count)));
                for (0..pcnt) |pi| {
                    const pslot: u16 = @intCast(c.param_slots[pi] + slot_off);
                    f.blocks[bi].insts[f.blocks[bi].inst_count] = .{
                        .op = .store_local,
                        .src1 = inst.args[pi],
                        .slot = pslot,
                    };
                    f.blocks[bi].inst_count += 1;
                }
                f.blocks[bi].insts[f.blocks[bi].inst_count] = .{
                    .op = .jump,
                    .target_block = blk_off,
                };
                f.blocks[bi].inst_count += 1;

                // Clone callee blocks
                for (0..c.block_count) |cbi| {
                    var nb = c.blocks[cbi];
                    nb.label = blk_off + @as(u16, @intCast(cbi));
                    var new_len: u16 = 0;
                    for (0..nb.inst_count) |cii| {
                        var ci = nb.insts[cii];
                        if (ci.dest > 0) ci.dest += vreg_off;
                        if (ci.src1 > 0) ci.src1 += vreg_off;
                        if (ci.src2 > 0) ci.src2 += vreg_off;
                        for (0..@min(ci.arg_count, ci.args.len)) |ai| {
                            if (ci.args[ai] > 0) ci.args[ai] += vreg_off;
                        }
                        if (ci.slot > 0) ci.slot += slot_off;

                        if (ci.op == .ret) {
                            if (call_dest != 0 and ci.src1 != 0) {
                                nb.insts[new_len] = .{ .op = .copy, .dest = call_dest, .src1 = ci.src1 };
                                new_len += 1;
                            } else if (call_dest != 0) {
                                nb.insts[new_len] = .{ .op = .const_int, .dest = call_dest, .imm = 0 };
                                new_len += 1;
                            }
                            nb.insts[new_len] = .{ .op = .jump, .target_block = after_bi };
                            new_len += 1;
                            continue;
                        }
                        if (ci.op == .jump) {
                            ci.target_block += blk_off;
                        } else if (ci.op == .cond_jump) {
                            ci.target_block += blk_off;
                            ci.alt_block += blk_off;
                        }
                        nb.insts[new_len] = ci;
                        new_len += 1;
                    }
                    nb.inst_count = new_len;
                    f.blocks[blk_off + @as(u16, @intCast(cbi))] = nb;
                }
                f.blocks[after_bi] = after_blk;
                f.block_count = after_bi + 1;
                f.vreg_count += c.vreg_count;
                f.total_locals += c.total_locals;

                // Propagate addr_taken flags
                for (1..@min(c.total_locals + 1, c.local_addr_taken.len)) |s| {
                    if (s + slot_off < f.local_addr_taken.len and c.local_addr_taken[s]) {
                        f.local_addr_taken[s + slot_off] = true;
                    }
                }

                inlined_count += 1;
                changed = true;
                break; // Block was split; outer loop visits remaining blocks (including after_bi)
            }
        }
    }
    return changed;
}

// ════════════════════════════════════════════════════════════════════════════
// CFG / Dominators Helpers
// ════════════════════════════════════════════════════════════════════════════

const CFGInfo = struct {
    n: u16 = 0,
    preds: [MAX_BLOCKS_PER_FN][32]u16 = undefined,
    pred_cnt: [MAX_BLOCKS_PER_FN]u16 = .{0} ** MAX_BLOCKS_PER_FN,
    pred_overflow: bool = false,
    rpo: [MAX_BLOCKS_PER_FN]u16 = .{0} ** MAX_BLOCKS_PER_FN,
    rpo_pos: [MAX_BLOCKS_PER_FN]i16 = .{-1} ** MAX_BLOCKS_PER_FN,
    rpo_len: u16 = 0,
    idom: [MAX_BLOCKS_PER_FN]i16 = .{-1} ** MAX_BLOCKS_PER_FN,
    dom_children: [MAX_BLOCKS_PER_FN][MAX_BLOCKS_PER_FN]u16 = undefined,
    dom_child_cnt: [MAX_BLOCKS_PER_FN]u16 = .{0} ** MAX_BLOCKS_PER_FN,
    df: [MAX_BLOCKS_PER_FN]u128 = .{0} ** MAX_BLOCKS_PER_FN,
};

fn getSuccs(b: *const IRBlock, out: *[2]u16) u8 {
    if (b.inst_count == 0) return 0;
    const term = b.insts[b.inst_count - 1];
    if (term.op == .jump) {
        out[0] = term.target_block;
        return 1;
    }
    if (term.op == .cond_jump) {
        out[0] = term.target_block;
        if (term.alt_block != term.target_block) {
            out[1] = term.alt_block;
            return 2;
        }
        return 1;
    }
    return 0;
}

fn buildCFGInfo(f: *const IRFn, info: *CFGInfo) void {
    const n = f.block_count;
    info.n = n;
    info.pred_overflow = false;
    @memset(&info.pred_cnt, 0);
    @memset(&info.rpo_pos, -1);
    @memset(&info.idom, -1);
    @memset(&info.dom_child_cnt, 0);
    @memset(&info.df, 0);
    info.rpo_len = 0;
    if (n == 0) return;

    // Build preds
    for (0..n) |bi| {
        var succs: [2]u16 = undefined;
        const sc = getSuccs(&f.blocks[bi], &succs);
        for (0..sc) |si| {
            const s = succs[si];
            if (s < n) {
                if (info.pred_cnt[s] < 32) {
                    info.preds[s][info.pred_cnt[s]] = @intCast(bi);
                    info.pred_cnt[s] += 1;
                } else {
                    info.pred_overflow = true;
                }
            }
        }
    }

    // Iterative post-order DFS from B0
    var visited: [MAX_BLOCKS_PER_FN]bool = .{false} ** MAX_BLOCKS_PER_FN;
    var post: [MAX_BLOCKS_PER_FN]u16 = undefined;
    var post_len: u16 = 0;
    var stack_blk: [MAX_BLOCKS_PER_FN]u16 = undefined;
    var stack_si: [MAX_BLOCKS_PER_FN]u8 = undefined;
    var sp: usize = 0;

    visited[0] = true;
    stack_blk[0] = 0;
    stack_si[0] = 0;
    sp = 1;

    while (sp > 0) {
        const cur = stack_blk[sp - 1];
        const si = stack_si[sp - 1];
        var succs: [2]u16 = undefined;
        const sc = getSuccs(&f.blocks[cur], &succs);
        if (si < sc) {
            stack_si[sp - 1] = si + 1;
            const nxt = succs[si];
            if (nxt < n and !visited[nxt]) {
                visited[nxt] = true;
                stack_blk[sp] = nxt;
                stack_si[sp] = 0;
                sp += 1;
            }
        } else {
            sp -= 1;
            post[post_len] = cur;
            post_len += 1;
        }
    }

    // Reverse post-order
    info.rpo_len = post_len;
    for (0..post_len) |i| {
        const b = post[post_len - 1 - i];
        info.rpo[i] = b;
        info.rpo_pos[b] = @intCast(i);
    }

    // Cooper-Harvey-Kennedy iterative dominators
    info.idom[0] = 0;
    var changed = true;
    while (changed) {
        changed = false;
        var ri: usize = 1;
        while (ri < info.rpo_len) : (ri += 1) {
            const b = info.rpo[ri];
            var new_idom: i16 = -1;
            for (0..info.pred_cnt[b]) |pi| {
                const p = info.preds[b][pi];
                if (info.idom[p] != -1) {
                    if (new_idom == -1) {
                        new_idom = @intCast(p);
                    } else {
                        new_idom = intersectDom(info, @intCast(p), new_idom);
                    }
                }
            }
            if (new_idom != -1 and info.idom[b] != new_idom) {
                info.idom[b] = new_idom;
                changed = true;
            }
        }
    }

    // Dom children
    for (1..n) |bi| {
        const id = info.idom[bi];
        if (id >= 0) {
            const parent: usize = @intCast(id);
            if (parent != bi and info.dom_child_cnt[parent] < MAX_BLOCKS_PER_FN) {
                info.dom_children[parent][info.dom_child_cnt[parent]] = @intCast(bi);
                info.dom_child_cnt[parent] += 1;
            }
        }
    }

    // Dominance frontiers
    for (0..n) |bi| {
        if (info.pred_cnt[bi] >= 2 and info.idom[bi] >= 0) {
            for (0..info.pred_cnt[bi]) |pi| {
                var runner: i16 = @intCast(info.preds[bi][pi]);
                while (runner >= 0 and runner != info.idom[bi]) {
                    const ru: usize = @intCast(runner);
                    info.df[ru] |= (@as(u128, 1) << @intCast(bi));
                    const next_r = info.idom[ru];
                    if (next_r == runner) break;
                    runner = next_r;
                }
            }
        }
    }
}

fn intersectDom(info: *const CFGInfo, b1_in: i16, b2_in: i16) i16 {
    var f1 = b1_in;
    var f2 = b2_in;
    while (f1 != f2) {
        while (info.rpo_pos[@intCast(f1)] > info.rpo_pos[@intCast(f2)]) {
            const next = info.idom[@intCast(f1)];
            if (next < 0 or next == f1) return 0;
            f1 = next;
        }
        while (info.rpo_pos[@intCast(f2)] > info.rpo_pos[@intCast(f1)]) {
            const next = info.idom[@intCast(f2)];
            if (next < 0 or next == f2) return 0;
            f2 = next;
        }
    }
    return f1;
}

fn dominates(info: *const CFGInfo, a: u16, b: u16) bool {
    var cur: i16 = @intCast(b);
    while (cur >= 0) {
        if (cur == @as(i16, @intCast(a))) return true;
        if (cur == 0) break;
        const p = info.idom[@intCast(cur)];
        if (p == cur) break;
        cur = p;
    }
    return false;
}

// ════════════════════════════════════════════════════════════════════════════
// Cytron SSA mem2reg (-O2)
// ════════════════════════════════════════════════════════════════════════════

const RenameUndoEntry = struct { slot: u16, prev_vreg: u16 };

fn mem2reg(f: *IRFn) bool {
    if (f.block_count == 0 or f.block_count > 128 or f.total_locals == 0 or f.total_locals >= MAX_PROMOTED_SLOTS) return false;
    // Leave ample room for critical-edge splitting during destructSSA
    if (f.block_count + 24 > 128) return false;
    // Skip if already contains phis or has blocks near capacity
    if (hasAnyPhi(f)) return false;

    var cfg: CFGInfo = undefined;
    buildCFGInfo(f, &cfg);
    if (cfg.pred_overflow) return false;

    // Bail out if any reachable block has >8 predecessors (phi args limit)
    for (0..f.block_count) |bi| {
        if (cfg.pred_cnt[bi] > 8 and cfg.rpo_pos[bi] >= 0) return false;
    }

    var promotable: [MAX_PROMOTED_SLOTS]bool = .{false} ** MAX_PROMOTED_SLOTS;
    var slot_read: [MAX_PROMOTED_SLOTS]bool = .{false} ** MAX_PROMOTED_SLOTS;
    var is_param: [MAX_PROMOTED_SLOTS]bool = .{false} ** MAX_PROMOTED_SLOTS;
    var def_blocks: [MAX_PROMOTED_SLOTS]u128 = .{0} ** MAX_PROMOTED_SLOTS;

    for (1..f.total_locals + 1) |s| {
        if (s < f.local_addr_taken.len and !f.local_addr_taken[s]) {
            promotable[s] = true;
        }
    }
    for (0..@min(f.param_count, f.param_slots.len)) |pi| {
        const ps = f.param_slots[pi];
        if (ps > 0 and ps < MAX_PROMOTED_SLOTS) {
            is_param[ps] = true;
            def_blocks[ps] |= 1; // B0 defines params on entry
        }
    }

    // Disqualify slots touched by addr_of / alloca, and collect def blocks
    for (0..f.block_count) |bi| {
        const b = &f.blocks[bi];
        for (0..b.inst_count) |ii| {
            const inst = b.insts[ii];
            switch (inst.op) {
                .addr_of, .alloca => {
                    if (inst.slot > 0 and inst.slot < MAX_PROMOTED_SLOTS) promotable[inst.slot] = false;
                },
                .load_local => {
                    if (inst.slot > 0 and inst.slot < MAX_PROMOTED_SLOTS) slot_read[inst.slot] = true;
                },
                .store_local => {
                    if (inst.slot > 0 and inst.slot < MAX_PROMOTED_SLOTS) {
                        def_blocks[inst.slot] |= (@as(u128, 1) << @intCast(bi));
                    }
                },
                else => {},
            }
        }
    }

    // Inject a single entry load_local at start of B0 for read promotable params
    // ONLY if B0 has room and enough vregs remain.
    var param_load_count: u16 = 0;
    var active_param_slots: [8]u32 = .{0} ** 8;
    for (0..@min(f.param_count, f.param_slots.len)) |pi| {
        const ps = f.param_slots[pi];
        if (ps > 0 and ps < MAX_PROMOTED_SLOTS and promotable[ps] and slot_read[ps]) {
            active_param_slots[param_load_count] = ps;
            param_load_count += 1;
        }
    }
    if (param_load_count > 0) {
        if (@as(u32, f.blocks[0].inst_count) + param_load_count >= MAX_INSTS_PER_BLOCK) {
            for (0..param_load_count) |k| promotable[active_param_slots[k]] = false;
            param_load_count = 0;
        } else {
            // Shift B0 instructions down by param_load_count
            var bi_move: usize = f.blocks[0].inst_count;
            while (bi_move > 0) {
                bi_move -= 1;
                f.blocks[0].insts[bi_move + param_load_count] = f.blocks[0].insts[bi_move];
            }
            f.blocks[0].inst_count += param_load_count;
            for (0..param_load_count) |k| {
                if (f.vreg_count >= MAX_TRACKED_VREGS - 32) {
                    f.blocks[0].insts[k] = .{ .op = .nop };
                    promotable[active_param_slots[k]] = false;
                } else {
                    const pv = f.vreg_count;
                    f.vreg_count += 1;
                    f.blocks[0].insts[k] = .{
                        .op = .load_local,
                        .dest = pv,
                        .slot = @intCast(active_param_slots[k]),
                    };
                }
            }
        }
    }

    // Compute IDF and place phis (track per-block phi insertion count before mutating blocks)
    var phi_slots: [MAX_BLOCKS_PER_FN][32]u16 = undefined;
    var phi_cnt: [MAX_BLOCKS_PER_FN]u8 = .{0} ** MAX_BLOCKS_PER_FN;

    for (1..f.total_locals + 1) |s| {
        if (!promotable[s] or !slot_read[s]) continue;
        var has_phi: u128 = 0;
        var work: u128 = def_blocks[s];
        var ok = true;

        while (work != 0) {
            const b_idx: u7 = @intCast(@ctz(work));
            work &= ~(@as(u128, 1) << b_idx);
            var df_mask = cfg.df[b_idx];
            while (df_mask != 0) {
                const y: u7 = @intCast(@ctz(df_mask));
                df_mask &= ~(@as(u128, 1) << y);
                if (y == 0) continue; // never place phi in entry block B0
                if ((has_phi & (@as(u128, 1) << y)) == 0) {
                    has_phi |= (@as(u128, 1) << y);
                    if (phi_cnt[y] >= 32 or
                        @as(u32, f.blocks[y].inst_count) + phi_cnt[y] + 1 >= MAX_INSTS_PER_BLOCK or
                        f.vreg_count + 1 >= MAX_TRACKED_VREGS)
                    {
                        ok = false;
                        break;
                    }
                    phi_slots[y][phi_cnt[y]] = @intCast(s);
                    phi_cnt[y] += 1;
                    if ((def_blocks[s] & (@as(u128, 1) << y)) == 0) {
                        work |= (@as(u128, 1) << y);
                    }
                }
            }
            if (!ok) break;
        }
        if (!ok) {
            // Roll back this slot's pending phis and disqualify slot
            promotable[s] = false;
            for (0..f.block_count) |bi| {
                var k: u8 = 0;
                while (k < phi_cnt[bi]) {
                    if (phi_slots[bi][k] == s) {
                        phi_cnt[bi] -= 1;
                        phi_slots[bi][k] = phi_slots[bi][phi_cnt[bi]];
                    } else {
                        k += 1;
                    }
                }
            }
        }
    }

    var any_promoted = false;
    for (1..f.total_locals + 1) |s| {
        if (promotable[s] and slot_read[s]) {
            any_promoted = true;
            break;
        }
    }
    if (!any_promoted) return false;

    // Insert pending .phi instructions at the start of each block
    for (1..f.block_count) |bi| {
        const pc = phi_cnt[bi];
        if (pc == 0) continue;
        var b = &f.blocks[bi];
        if (@as(u32, b.inst_count) + pc >= MAX_INSTS_PER_BLOCK or
            @as(u32, f.vreg_count) + pc >= MAX_TRACKED_VREGS) continue;
        var mi: usize = b.inst_count;
        while (mi > 0) {
            mi -= 1;
            b.insts[mi + pc] = b.insts[mi];
        }
        b.inst_count += pc;
        for (0..pc) |k| {
            const pv = f.vreg_count;
            f.vreg_count += 1;
            b.insts[k] = .{
                .op = .phi,
                .dest = pv,
                .slot = phi_slots[bi][k], // temporarily tracks slot during renaming
                .arg_count = 0,
            };
        }
    }

    // Dominator-tree DFS SSA renaming
    var cur_def: [MAX_PROMOTED_SLOTS]u16 = .{0} ** MAX_PROMOTED_SLOTS;
    var undo_buf: [2048]RenameUndoEntry = undefined;
    var undo_len: usize = 0;

    renameBlock(f, &cfg, 0, &promotable, &is_param, param_load_count, &cur_def, &undo_buf, &undo_len);

    // Clear temporary phi.slot metadata
    for (0..f.block_count) |bi| {
        for (0..f.blocks[bi].inst_count) |ii| {
            if (f.blocks[bi].insts[ii].op == .phi) f.blocks[bi].insts[ii].slot = 0;
        }
    }
    return true;
}

fn renameBlock(
    f: *IRFn,
    cfg: *const CFGInfo,
    bi: u16,
    promotable: *const [MAX_PROMOTED_SLOTS]bool,
    is_param: *const [MAX_PROMOTED_SLOTS]bool,
    param_load_count: u16,
    cur_def: *[MAX_PROMOTED_SLOTS]u16,
    undo_buf: *[2048]RenameUndoEntry,
    undo_len: *usize,
) void {
    const saved_undo = undo_len.*;
    const b = &f.blocks[bi];

    for (0..b.inst_count) |ii| {
        const inst = &b.insts[ii];
        if (inst.op == .phi) {
            const s = inst.slot;
            if (s > 0 and s < MAX_PROMOTED_SLOTS and promotable[s]) {
                if (undo_len.* < undo_buf.len) {
                    undo_buf[undo_len.*] = .{ .slot = s, .prev_vreg = cur_def[s] };
                    undo_len.* += 1;
                }
                cur_def[s] = inst.dest;
            }
        } else if (inst.op == .load_local) {
            const s = inst.slot;
            if (s > 0 and s < MAX_PROMOTED_SLOTS and promotable[s]) {
                // Keep entry parameter load_local instructions intact as the initial SSA def!
                if (bi == 0 and ii < param_load_count and is_param[s]) {
                    if (undo_len.* < undo_buf.len) {
                        undo_buf[undo_len.*] = .{ .slot = s, .prev_vreg = cur_def[s] };
                        undo_len.* += 1;
                    }
                    cur_def[s] = inst.dest;
                } else if (cur_def[s] != 0) {
                    inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = cur_def[s] };
                } else {
                    inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = 0 };
                }
            }
        } else if (inst.op == .store_local) {
            const s = inst.slot;
            if (s > 0 and s < MAX_PROMOTED_SLOTS and promotable[s]) {
                if (undo_len.* < undo_buf.len) {
                    undo_buf[undo_len.*] = .{ .slot = s, .prev_vreg = cur_def[s] };
                    undo_len.* += 1;
                }
                cur_def[s] = inst.src1;
                inst.* = .{ .op = .nop };
            }
        }
    }

    // Populate phi operands in successors
    var succs: [2]u16 = undefined;
    const sc = getSuccs(b, &succs);
    for (0..sc) |si| {
        const succ_bi = succs[si];
        if (succ_bi >= f.block_count) continue;
        const sb = &f.blocks[succ_bi];
        for (0..sb.inst_count) |pii| {
            var pinst = &sb.insts[pii];
            if (pinst.op != .phi) break;
            const ps = pinst.slot;
            if (ps > 0 and ps < MAX_PROMOTED_SLOTS and pinst.arg_count < 8) {
                // Avoid duplicate phi entry from same predecessor
                var dup = false;
                for (0..pinst.arg_count) |ek| {
                    if (pinst.phi_blocks[ek] == bi) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    pinst.args[pinst.arg_count] = cur_def[ps]; // 0 means undefined/0 at runtime
                    pinst.phi_blocks[pinst.arg_count] = bi;
                    pinst.arg_count += 1;
                }
            }
        }
    }

    // Recurse on dominator-tree children
    for (0..cfg.dom_child_cnt[bi]) |ci| {
        const child = cfg.dom_children[bi][ci];
        renameBlock(f, cfg, child, promotable, is_param, param_load_count, cur_def, undo_buf, undo_len);
    }

    // Restore cur_def via undo log
    while (undo_len.* > saved_undo) {
        undo_len.* -= 1;
        const e = undo_buf[undo_len.*];
        cur_def[e.slot] = e.prev_vreg;
    }
}

fn hasAnyPhi(f: *const IRFn) bool {
    for (0..f.block_count) |bi| {
        if (f.blocks[bi].inst_count > 0 and f.blocks[bi].insts[0].op == .phi) return true;
    }
    return false;
}

fn simplifyTrivialPhis(f: *IRFn) bool {
    var changed = false;
    for (0..f.block_count) |bi| {
        const b = &f.blocks[bi];
        for (0..b.inst_count) |ii| {
            const inst = &b.insts[ii];
            if (inst.op != .phi) break;
            if (inst.arg_count == 0) {
                inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = 0 };
                changed = true;
                continue;
            }
            var unique: ?u16 = null;
            var all_same = true;
            for (0..inst.arg_count) |ai| {
                const a = inst.args[ai];
                if (a == inst.dest) continue;
                if (unique == null) {
                    unique = a;
                } else if (unique.? != a) {
                    all_same = false;
                    break;
                }
            }
            if (all_same) {
                if (unique) |u| {
                    if (u == 0) {
                        inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = 0 };
                    } else {
                        inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = u };
                    }
                } else {
                    inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = 0 };
                }
                changed = true;
            }
        }
    }
    return changed;
}

// ════════════════════════════════════════════════════════════════════════════
// Dominator-Tree Global Value Numbering (-O2)
// ════════════════════════════════════════════════════════════════════════════

const GVNEntry = struct {
    op: IROp,
    a: u16,
    b: u16,
    imm: i64,
    vreg: u16,
};

fn globalValueNumbering(f: *IRFn) bool {
    if (f.block_count == 0) return false;

    var def_count: [MAX_TRACKED_VREGS]u16 = undefined;
    isSingleDefVregTable(f, &def_count);

    var cfg: CFGInfo = undefined;
    buildCFGInfo(f, &cfg);

    var const_known: [MAX_TRACKED_VREGS]bool = .{false} ** MAX_TRACKED_VREGS;
    var const_val: [MAX_TRACKED_VREGS]i64 = .{0} ** MAX_TRACKED_VREGS;
    var table: [512]GVNEntry = undefined;
    var table_len: usize = 0;
    var changed = false;

    gvnBlock(f, &cfg, 0, &def_count, &const_known, &const_val, &table, &table_len, &changed);
    return changed;
}

fn gvnBlock(
    f: *IRFn,
    cfg: *const CFGInfo,
    bi: u16,
    def_count: *const [MAX_TRACKED_VREGS]u16,
    const_known: *[MAX_TRACKED_VREGS]bool,
    const_val: *[MAX_TRACKED_VREGS]i64,
    table: *[512]GVNEntry,
    table_len: *usize,
    changed: *bool,
) void {
    const saved_len = table_len.*;
    var ck_undo: [256]u16 = undefined;
    var ck_undo_len: usize = 0;

    const b = &f.blocks[bi];
    for (0..b.inst_count) |ii| {
        const inst = &b.insts[ii];
        if (inst.dest == 0 or inst.dest >= MAX_TRACKED_VREGS or def_count[inst.dest] != 1) continue;

        switch (inst.op) {
            .const_int => {
                if (!const_known[inst.dest] and ck_undo_len < ck_undo.len) {
                    ck_undo[ck_undo_len] = inst.dest;
                    ck_undo_len += 1;
                }
                const_known[inst.dest] = true;
                const_val[inst.dest] = inst.imm;

                for (table[0..table_len.*]) |e| {
                    if (e.op == .const_int and e.imm == inst.imm) {
                        inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = e.vreg };
                        changed.* = true;
                        break;
                    }
                } else if (table_len.* < table.len) {
                    table[table_len.*] = .{ .op = .const_int, .a = 0, .b = 0, .imm = inst.imm, .vreg = inst.dest };
                    table_len.* += 1;
                }
            },
            .copy => {
                if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and const_known[inst.src1]) {
                    const v = const_val[inst.src1];
                    inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = v };
                    if (!const_known[inst.dest] and ck_undo_len < ck_undo.len) {
                        ck_undo[ck_undo_len] = inst.dest;
                        ck_undo_len += 1;
                    }
                    const_known[inst.dest] = true;
                    const_val[inst.dest] = v;
                    changed.* = true;
                }
            },
            .add,
            .sub,
            .mul,
            .shl,
            .shr,
            .ushr,
            .bit_and,
            .bit_or,
            .bit_xor,
            .cmp_eq,
            .cmp_ne,
            .cmp_lt,
            .cmp_le,
            .cmp_gt,
            .cmp_ge,
            .ucmp_lt,
            .ucmp_le,
            .ucmp_gt,
            .ucmp_ge,
            => {
                if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and
                    inst.src2 > 0 and inst.src2 < MAX_TRACKED_VREGS and
                    const_known[inst.src1] and const_known[inst.src2])
                {
                    if (foldBinaryConsts(inst.op, const_val[inst.src1], const_val[inst.src2])) |res| {
                        inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = res };
                        if (!const_known[inst.dest] and ck_undo_len < ck_undo.len) {
                            ck_undo[ck_undo_len] = inst.dest;
                            ck_undo_len += 1;
                        }
                        const_known[inst.dest] = true;
                        const_val[inst.dest] = res;
                        changed.* = true;
                        continue;
                    }
                }
                if (inst.src1 > 0 and inst.src2 > 0 and def_count[inst.src1] == 1 and def_count[inst.src2] == 1) {
                    var ka = inst.src1;
                    var kb = inst.src2;
                    if (isCommutative(inst.op) and ka > kb) {
                        const tmp = ka;
                        ka = kb;
                        kb = tmp;
                    }
                    for (table[0..table_len.*]) |e| {
                        if (e.op == inst.op and e.a == ka and e.b == kb) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = e.vreg };
                            changed.* = true;
                            break;
                        }
                    } else if (table_len.* < table.len) {
                        table[table_len.*] = .{ .op = inst.op, .a = ka, .b = kb, .imm = 0, .vreg = inst.dest };
                        table_len.* += 1;
                    }
                }
            },
            .neg, .bit_not, .logic_not, .sext8, .sext16, .sext32, .zext8, .zext16, .zext32 => {
                if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and const_known[inst.src1]) {
                    const res = foldUnaryConst(inst.op, const_val[inst.src1]);
                    inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = res };
                    if (!const_known[inst.dest] and ck_undo_len < ck_undo.len) {
                        ck_undo[ck_undo_len] = inst.dest;
                        ck_undo_len += 1;
                    }
                    const_known[inst.dest] = true;
                    const_val[inst.dest] = res;
                    changed.* = true;
                } else if (inst.src1 > 0 and def_count[inst.src1] == 1) {
                    for (table[0..table_len.*]) |e| {
                        if (e.op == inst.op and e.a == inst.src1) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = e.vreg };
                            changed.* = true;
                            break;
                        }
                    } else if (table_len.* < table.len) {
                        table[table_len.*] = .{ .op = inst.op, .a = inst.src1, .b = 0, .imm = 0, .vreg = inst.dest };
                        table_len.* += 1;
                    }
                }
            },
            else => {},
        }
    }

    // Fold cond_jump using dominated constant condition
    if (b.inst_count > 0) {
        const term = &b.insts[b.inst_count - 1];
        if (term.op == .cond_jump and term.src1 > 0 and term.src1 < MAX_TRACKED_VREGS and const_known[term.src1]) {
            const tgt = if (const_val[term.src1] != 0) term.target_block else term.alt_block;
            term.* = .{ .op = .jump, .target_block = tgt };
            changed.* = true;
        }
    }

    for (0..cfg.dom_child_cnt[bi]) |ci| {
        const child = cfg.dom_children[bi][ci];
        gvnBlock(f, cfg, child, def_count, const_known, const_val, table, table_len, changed);
    }

    table_len.* = saved_len;
    while (ck_undo_len > 0) {
        ck_undo_len -= 1;
        const_known[ck_undo[ck_undo_len]] = false;
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Natural-Loop Invariant Code Motion (-O2)
// ════════════════════════════════════════════════════════════════════════════

fn loopInvariantCodeMotion(f: *IRFn) bool {
    if (f.block_count < 2 or f.block_count > 128) return false;
    var cfg: CFGInfo = undefined;
    buildCFGInfo(f, &cfg);

    // Map each single-def vreg to its defining block + record single-def constants for safe shift LICM
    var def_count: [MAX_TRACKED_VREGS]u16 = undefined;
    isSingleDefVregTable(f, &def_count);
    var def_blk: [MAX_TRACKED_VREGS]i16 = .{-1} ** MAX_TRACKED_VREGS;
    var const_known: [MAX_TRACKED_VREGS]bool = .{false} ** MAX_TRACKED_VREGS;
    var const_val: [MAX_TRACKED_VREGS]i64 = .{0} ** MAX_TRACKED_VREGS;
    for (0..f.block_count) |bi| {
        for (0..f.blocks[bi].inst_count) |ii| {
            const inst = f.blocks[bi].insts[ii];
            const d = inst.dest;
            if (d > 0 and d < MAX_TRACKED_VREGS and def_count[d] == 1) {
                def_blk[d] = @intCast(bi);
                if (inst.op == .const_int) {
                    const_known[d] = true;
                    const_val[d] = inst.imm;
                }
            }
        }
    }

    var changed = false;

    // Find backedges u -> h where h dominates u
    for (0..f.block_count) |u_usize| {
        const u: u16 = @intCast(u_usize);
        var succs: [2]u16 = undefined;
        const sc = getSuccs(&f.blocks[u], &succs);
        for (0..sc) |si| {
            const h = succs[si];
            if (h >= f.block_count or !dominates(&cfg, h, u)) continue;

            // Collect natural loop blocks via reverse DFS from u stopping at h
            var in_loop: u128 = (@as(u128, 1) << @intCast(h)) | (@as(u128, 1) << @intCast(u));
            var work: [MAX_BLOCKS_PER_FN]u16 = undefined;
            var wlen: usize = 0;
            if (u != h) {
                work[0] = u;
                wlen = 1;
            }
            while (wlen > 0) {
                wlen -= 1;
                const cur = work[wlen];
                for (0..cfg.pred_cnt[cur]) |pi| {
                    const p = cfg.preds[cur][pi];
                    if ((in_loop & (@as(u128, 1) << @intCast(p))) == 0) {
                        in_loop |= (@as(u128, 1) << @intCast(p));
                        work[wlen] = p;
                        wlen += 1;
                    }
                }
            }

            // Locate a unique non-loop preheader predecessor ending in jump h
            var non_loop_preds: u16 = 0;
            var preheader: u16 = 0xFFFF;
            for (0..cfg.pred_cnt[h]) |pi| {
                const p = cfg.preds[h][pi];
                if ((in_loop & (@as(u128, 1) << @intCast(p))) == 0) {
                    non_loop_preds += 1;
                    preheader = p;
                }
            }
            if (non_loop_preds != 1 or preheader >= f.block_count) continue;
            const pb = &f.blocks[preheader];
            if (pb.inst_count == 0 or pb.insts[pb.inst_count - 1].op != .jump or pb.insts[pb.inst_count - 1].target_block != h) continue;

            // Hoist pure loop-invariant instructions into preheader (before its jump)
            var hoist_iter: u32 = 0;
            while (hoist_iter < 4) : (hoist_iter += 1) {
                var hoisted_any = false;
                for (0..f.block_count) |bi_usize| {
                    if ((in_loop & (@as(u128, 1) << @intCast(bi_usize))) == 0) continue;
                    // Only hoist from blocks that dominate all loop exits or header itself when pure/non-trapping
                    var lb = &f.blocks[bi_usize];
                    var wi: u16 = 0;
                    var ri: u16 = 0;
                    while (ri < lb.inst_count) : (ri += 1) {
                        const inst = lb.insts[ri];
                        const is_safe_shift = (inst.op == .shl or inst.op == .shr or inst.op == .ushr) and
                            inst.src2 > 0 and inst.src2 < MAX_TRACKED_VREGS and
                            const_known[inst.src2] and const_val[inst.src2] >= 0 and const_val[inst.src2] < 64;
                        const is_shift = (inst.op == .shl or inst.op == .shr or inst.op == .ushr);
                        const can_hoist = (!inst.op.hasSideEffects() and
                            !inst.op.isTerminator() and
                            inst.op != .phi and
                            inst.op != .nop and
                            inst.op != .load_local and
                            inst.op != .addr_of and
                            inst.op != .alloca and
                            (!is_shift or is_safe_shift) and
                            inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS and
                            def_count[inst.dest] == 1 and
                            opDefinedOutside(inst.src1, in_loop, &def_blk, &def_count) and
                            opDefinedOutside(inst.src2, in_loop, &def_blk, &def_count) and
                            argsDefinedOutside(&inst, in_loop, &def_blk, &def_count) and
                            pb.inst_count < MAX_INSTS_PER_BLOCK - 1);

                        if (can_hoist and @as(u16, @intCast(bi_usize)) != preheader) {
                            // Insert before preheader's jump
                            const jmp_inst = pb.insts[pb.inst_count - 1];
                            pb.insts[pb.inst_count - 1] = inst;
                            pb.insts[pb.inst_count] = jmp_inst;
                            pb.inst_count += 1;
                            def_blk[inst.dest] = @intCast(preheader);
                            hoisted_any = true;
                            changed = true;
                            continue;
                        }
                        lb.insts[wi] = inst;
                        wi += 1;
                    }
                    lb.inst_count = wi;
                }
                if (!hoisted_any) break;
            }
        }
    }
    return changed;
}

fn opDefinedOutside(v: u16, in_loop: u128, def_blk: *const [MAX_TRACKED_VREGS]i16, def_count: *const [MAX_TRACKED_VREGS]u16) bool {
    if (v == 0) return true;
    if (v >= MAX_TRACKED_VREGS or def_count[v] != 1) return false;
    const db = def_blk[v];
    if (db < 0) return false;
    return (in_loop & (@as(u128, 1) << @intCast(db))) == 0;
}

fn argsDefinedOutside(inst: *const IRInst, in_loop: u128, def_blk: *const [MAX_TRACKED_VREGS]i16, def_count: *const [MAX_TRACKED_VREGS]u16) bool {
    for (0..@min(inst.arg_count, inst.args.len)) |ai| {
        if (!opDefinedOutside(inst.args[ai], in_loop, def_blk, def_count)) return false;
    }
    return true;
}

// ════════════════════════════════════════════════════════════════════════════
// Critical-Edge-Safe SSA Destruction (-O2)
// ════════════════════════════════════════════════════════════════════════════

fn destructSSA(f: *IRFn) void {
    // 1. Split any critical edge P -> B where P ends in cond_jump and B begins with .phi
    var has_phi_blk: [MAX_BLOCKS_PER_FN]bool = .{false} ** MAX_BLOCKS_PER_FN;
    for (0..f.block_count) |bi| {
        if (f.blocks[bi].inst_count > 0 and f.blocks[bi].insts[0].op == .phi) {
            has_phi_blk[bi] = true;
        }
    }

    var pi: u16 = 0;
    const orig_block_count = f.block_count;
    while (pi < orig_block_count) : (pi += 1) {
        var pb = &f.blocks[pi];
        if (pb.inst_count == 0) continue;
        var term = &pb.insts[pb.inst_count - 1];
        if (term.op != .cond_jump) continue;
        if (term.target_block == term.alt_block) {
            term.* = .{ .op = .jump, .target_block = term.target_block };
            continue;
        }

        if (term.target_block < orig_block_count and has_phi_blk[term.target_block] and f.block_count < MAX_BLOCKS_PER_FN) {
            const tgt = term.target_block;
            const edge_blk = f.block_count;
            f.block_count += 1;
            f.blocks[edge_blk] = .{ .label = edge_blk, .inst_count = 1 };
            f.blocks[edge_blk].insts[0] = .{ .op = .jump, .target_block = tgt };
            term.target_block = edge_blk;
            remapPhiPred(&f.blocks[tgt], pi, edge_blk);
        }
        if (term.alt_block < orig_block_count and has_phi_blk[term.alt_block] and f.block_count < MAX_BLOCKS_PER_FN) {
            const alt = term.alt_block;
            const edge_blk = f.block_count;
            f.block_count += 1;
            f.blocks[edge_blk] = .{ .label = edge_blk, .inst_count = 1 };
            f.blocks[edge_blk].insts[0] = .{ .op = .jump, .target_block = alt };
            term.alt_block = edge_blk;
            remapPhiPred(&f.blocks[alt], pi, edge_blk);
        }
    }

    // 2. For every block B with phis, emit sequentialized parallel copies in each predecessor P
    const CopyPair = struct { dst: u16, src: u16, active: bool };
    for (0..f.block_count) |bi| {
        const b = &f.blocks[bi];
        if (b.inst_count == 0 or b.insts[0].op != .phi) continue;

        // Gather unique predecessors referenced by phis in B
        var preds: [32]u16 = undefined;
        var pcnt: usize = 0;
        for (0..b.inst_count) |ii| {
            const inst = b.insts[ii];
            if (inst.op != .phi) break;
            for (0..inst.arg_count) |ak| {
                const pb_idx = inst.phi_blocks[ak];
                var found = false;
                for (preds[0..pcnt]) |ex| {
                    if (ex == pb_idx) {
                        found = true;
                        break;
                    }
                }
                if (!found and pcnt < preds.len) {
                    preds[pcnt] = pb_idx;
                    pcnt += 1;
                }
            }
        }

        for (preds[0..pcnt]) |pred_bi| {
            if (pred_bi >= f.block_count) continue;
            var pairs: [32]CopyPair = undefined;
            var pair_cnt: usize = 0;
            for (0..b.inst_count) |ii| {
                const inst = b.insts[ii];
                if (inst.op != .phi) break;
                for (0..inst.arg_count) |ak| {
                    if (inst.phi_blocks[ak] == pred_bi) {
                        if (inst.dest != 0 and inst.dest != inst.args[ak] and pair_cnt < pairs.len) {
                            pairs[pair_cnt] = .{ .dst = inst.dest, .src = inst.args[ak], .active = true };
                            pair_cnt += 1;
                        }
                        break;
                    }
                }
            }

            if (pair_cnt == 0) continue;
            var pred_blk = &f.blocks[pred_bi];
            if (pred_blk.inst_count == 0) continue;
            const jmp_inst = pred_blk.insts[pred_blk.inst_count - 1];
            var emit_pos: u16 = pred_blk.inst_count - 1;

            // Emit zero-inits for undef (src == 0)
            for (0..pair_cnt) |k| {
                if (pairs[k].src == 0 and emit_pos < MAX_INSTS_PER_BLOCK - 1) {
                    pred_blk.insts[emit_pos] = .{ .op = .const_int, .dest = pairs[k].dst, .imm = 0 };
                    emit_pos += 1;
                    pairs[k].active = false;
                }
            }

            // Sequentialize remaining parallel copies, breaking cycles with fresh temp vreg
            var remaining = true;
            while (remaining) {
                remaining = false;
                var progressed = false;
                for (0..pair_cnt) |k| {
                    if (!pairs[k].active) continue;
                    remaining = true;
                    // Check if pairs[k].dst is read as src by any other active pair
                    var read_by_other = false;
                    for (0..pair_cnt) |m| {
                        if (m != k and pairs[m].active and pairs[m].src == pairs[k].dst) {
                            read_by_other = true;
                            break;
                        }
                    }
                    if (!read_by_other) {
                        if (emit_pos < MAX_INSTS_PER_BLOCK - 1) {
                            pred_blk.insts[emit_pos] = .{ .op = .copy, .dest = pairs[k].dst, .src1 = pairs[k].src };
                            emit_pos += 1;
                        }
                        pairs[k].active = false;
                        progressed = true;
                        break;
                    }
                }
                if (remaining and !progressed) {
                    // Break cycle by copying first active pair's dst to a fresh temp
                    for (0..pair_cnt) |k| {
                        if (!pairs[k].active) continue;
                        const victim = pairs[k].dst;
                        if (f.vreg_count < MAX_TRACKED_VREGS and emit_pos < MAX_INSTS_PER_BLOCK - 1) {
                            const tmp = f.vreg_count;
                            f.vreg_count += 1;
                            pred_blk.insts[emit_pos] = .{ .op = .copy, .dest = tmp, .src1 = victim };
                            emit_pos += 1;
                            for (0..pair_cnt) |m| {
                                if (pairs[m].active and pairs[m].src == victim) pairs[m].src = tmp;
                            }
                        } else {
                            pairs[k].active = false;
                        }
                        break;
                    }
                }
            }

            pred_blk.insts[emit_pos] = jmp_inst;
            pred_blk.inst_count = emit_pos + 1;
        }
    }

    // 3. Remove all .phi instructions
    for (0..f.block_count) |bi| {
        var b = &f.blocks[bi];
        var wi: u16 = 0;
        for (0..b.inst_count) |ii| {
            if (b.insts[ii].op != .phi) {
                b.insts[wi] = b.insts[ii];
                wi += 1;
            }
        }
        b.inst_count = wi;
    }
}

fn remapPhiPred(b: *IRBlock, old_pred: u16, new_pred: u16) void {
    for (0..b.inst_count) |ii| {
        var inst = &b.insts[ii];
        if (inst.op != .phi) break;
        for (0..inst.arg_count) |ak| {
            if (inst.phi_blocks[ak] == old_pred) inst.phi_blocks[ak] = new_pred;
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Standard Intra/Global Optimization Passes (-O1 and -O2)
// ════════════════════════════════════════════════════════════════════════════

fn isSingleDefVregTable(f: *const IRFn, def_count: *[MAX_TRACKED_VREGS]u16) void {
    @memset(def_count, 0);
    var bi: u16 = 0;
    while (bi < f.block_count) : (bi += 1) {
        const b = &f.blocks[bi];
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            const d = b.insts[ii].dest;
            if (d > 0 and d < MAX_TRACKED_VREGS) {
                def_count[d] = def_count[d] +| 1;
            }
        }
    }
}

fn rewriteInstUses(inst: *IRInst, repl: []const u16) bool {
    var changed = false;
    if (inst.src1 > 0 and inst.src1 < repl.len and repl[inst.src1] != 0 and repl[inst.src1] != inst.src1) {
        inst.src1 = repl[inst.src1];
        changed = true;
    }
    if (inst.src2 > 0 and inst.src2 < repl.len and repl[inst.src2] != 0 and repl[inst.src2] != inst.src2) {
        inst.src2 = repl[inst.src2];
        changed = true;
    }
    var ai: usize = 0;
    while (ai < inst.arg_count and ai < inst.args.len) : (ai += 1) {
        const a = inst.args[ai];
        if (a > 0 and a < repl.len and repl[a] != 0 and repl[a] != a) {
            inst.args[ai] = repl[a];
            changed = true;
        }
    }
    return changed;
}

fn globalCopyPropagate(f: *IRFn) bool {
    var def_count: [MAX_TRACKED_VREGS]u16 = undefined;
    isSingleDefVregTable(f, &def_count);

    var copy_of: [MAX_TRACKED_VREGS]u16 = .{0} ** MAX_TRACKED_VREGS;
    var bi: u16 = 0;
    while (bi < f.block_count) : (bi += 1) {
        const b = &f.blocks[bi];
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            const inst = b.insts[ii];
            if (inst.op == .copy and inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS and
                inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and
                def_count[inst.dest] == 1 and def_count[inst.src1] == 1 and
                inst.dest != inst.src1)
            {
                copy_of[inst.dest] = inst.src1;
            }
        }
    }

    var v: usize = 1;
    while (v < MAX_TRACKED_VREGS) : (v += 1) {
        var cur = copy_of[v];
        if (cur == 0) continue;
        var steps: u32 = 0;
        while (cur > 0 and cur < MAX_TRACKED_VREGS and copy_of[cur] != 0 and steps < 16) : (steps += 1) {
            cur = copy_of[cur];
        }
        copy_of[v] = if (cur != v) cur else 0;
    }

    var changed = false;
    bi = 0;
    while (bi < f.block_count) : (bi += 1) {
        const b = &f.blocks[bi];
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            if (rewriteInstUses(&b.insts[ii], &copy_of)) changed = true;
        }
    }
    return changed;
}

const ExprKey = struct {
    op: IROp,
    a: u16,
    b: u16,
    imm: i64,
    vreg: u16,
};

fn isCommutative(op: IROp) bool {
    return switch (op) {
        .add, .mul, .bit_and, .bit_or, .bit_xor, .cmp_eq, .cmp_ne => true,
        else => false,
    };
}

fn foldUnaryConst(op: IROp, a: i64) i64 {
    const ua: u64 = @bitCast(a);
    return switch (op) {
        .neg => -%a,
        .bit_not => ~a,
        .logic_not => if (a == 0) 1 else 0,
        .sext8 => @as(i8, @truncate(a)),
        .sext16 => @as(i16, @truncate(a)),
        .sext32 => @as(i32, @truncate(a)),
        .zext8 => @intCast(@as(u8, @truncate(ua))),
        .zext16 => @intCast(@as(u16, @truncate(ua))),
        .zext32 => @intCast(@as(u32, @truncate(ua))),
        else => a,
    };
}

fn foldBinaryConsts(op: IROp, a: i64, bv: i64) ?i64 {
    const ua: u64 = @bitCast(a);
    const ub: u64 = @bitCast(bv);
    return switch (op) {
        .add => a +% bv,
        .sub => a -% bv,
        .mul => a *% bv,
        .div => if (bv != 0 and !(a == std.math.minInt(i64) and bv == -1)) @divTrunc(a, bv) else null,
        .udiv => if (ub != 0) @bitCast(ua / ub) else null,
        .@"mod" => if (bv != 0 and !(a == std.math.minInt(i64) and bv == -1)) @rem(a, bv) else null,
        .umod => if (ub != 0) @bitCast(ua % ub) else null,
        .shl => if (bv >= 0 and bv < 64) a << @as(u6, @intCast(bv)) else null,
        .shr => if (bv >= 0 and bv < 64) a >> @as(u6, @intCast(bv)) else null,
        .ushr => if (bv >= 0 and bv < 64) @bitCast(ua >> @as(u6, @intCast(bv))) else null,
        .bit_and => a & bv,
        .bit_or => a | bv,
        .bit_xor => a ^ bv,
        .cmp_eq => if (a == bv) @as(i64, 1) else 0,
        .cmp_ne => if (a != bv) @as(i64, 1) else 0,
        .cmp_lt => if (a < bv) @as(i64, 1) else 0,
        .cmp_le => if (a <= bv) @as(i64, 1) else 0,
        .cmp_gt => if (a > bv) @as(i64, 1) else 0,
        .cmp_ge => if (a >= bv) @as(i64, 1) else 0,
        .ucmp_lt => if (ua < ub) @as(i64, 1) else 0,
        .ucmp_le => if (ua <= ub) @as(i64, 1) else 0,
        .ucmp_gt => if (ua > ub) @as(i64, 1) else 0,
        .ucmp_ge => if (ua >= ub) @as(i64, 1) else 0,
        else => null,
    };
}

fn ensureBlockConst(
    f: *IRFn,
    b: *IRBlock,
    expr_table: *[128]ExprKey,
    expr_count: *usize,
    const_known: *[MAX_TRACKED_VREGS]bool,
    const_val: *[MAX_TRACKED_VREGS]i64,
    ii: *u16,
    val: i64,
) ?u16 {
    for (expr_table[0..expr_count.*]) |ek| {
        if (ek.op == .const_int and ek.imm == val) return ek.vreg;
    }
    if (b.inst_count + 1 > MAX_INSTS_PER_BLOCK or f.vreg_count + 1 >= MAX_TRACKED_VREGS) return null;
    const v = f.vreg_count;
    f.vreg_count += 1;
    var k: u16 = b.inst_count;
    while (k > ii.*) : (k -= 1) {
        b.insts[k] = b.insts[k - 1];
    }
    b.insts[ii.*] = .{ .op = .const_int, .dest = v, .imm = val };
    b.inst_count += 1;
    ii.* += 1;
    const_known[v] = true;
    const_val[v] = val;
    if (expr_count.* < expr_table.len) {
        expr_table[expr_count.*] = .{ .op = .const_int, .a = 0, .b = 0, .imm = val, .vreg = v };
        expr_count.* += 1;
    }
    return v;
}

fn localConstantFoldAndLVN(f: *IRFn) bool {
    var changed = false;

    var const_known: [MAX_TRACKED_VREGS]bool = undefined;
    var const_val: [MAX_TRACKED_VREGS]i64 = undefined;
    var expr_table: [128]ExprKey = undefined;

    var bi: u16 = 0;
    while (bi < f.block_count) : (bi += 1) {
        var b = &f.blocks[bi];
        @memset(&const_known, false);
        var expr_count: usize = 0;

        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            var inst = &b.insts[ii];

            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                const_known[inst.dest] = false;
                var ei: usize = 0;
                while (ei < expr_count) {
                    if (expr_table[ei].a == inst.dest or expr_table[ei].b == inst.dest or expr_table[ei].vreg == inst.dest) {
                        expr_table[ei] = expr_table[expr_count - 1];
                        expr_count -= 1;
                    } else {
                        ei += 1;
                    }
                }
            }

            switch (inst.op) {
                .const_int => {
                    if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                        const_known[inst.dest] = true;
                        const_val[inst.dest] = inst.imm;
                    }
                    for (expr_table[0..expr_count]) |ek| {
                        if (ek.op == .const_int and ek.imm == inst.imm) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = ek.vreg };
                            changed = true;
                            break;
                        }
                    } else if (inst.dest > 0 and expr_count < expr_table.len) {
                        expr_table[expr_count] = .{ .op = .const_int, .a = 0, .b = 0, .imm = inst.imm, .vreg = inst.dest };
                        expr_count += 1;
                    }
                },
                .copy => {
                    if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and const_known[inst.src1]) {
                        const val = const_val[inst.src1];
                        inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = val };
                        if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                            const_known[inst.dest] = true;
                            const_val[inst.dest] = val;
                        }
                        changed = true;
                    }
                },
                .neg, .bit_not, .logic_not, .sext8, .sext16, .sext32, .zext8, .zext16, .zext32 => {
                    const s1_known = inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and const_known[inst.src1];
                    if (s1_known) {
                        const res = foldUnaryConst(inst.op, const_val[inst.src1]);
                        inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = res };
                        if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                            const_known[inst.dest] = true;
                            const_val[inst.dest] = res;
                        }
                        changed = true;
                    } else if (inst.dest > 0) {
                        for (expr_table[0..expr_count]) |ek| {
                            if (ek.op == inst.op and ek.a == inst.src1) {
                                inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = ek.vreg };
                                changed = true;
                                break;
                            }
                        } else if (expr_count < expr_table.len) {
                            expr_table[expr_count] = .{ .op = inst.op, .a = inst.src1, .b = 0, .imm = 0, .vreg = inst.dest };
                            expr_count += 1;
                        }
                    }
                },
                .add,
                .sub,
                .mul,
                .div,
                .udiv,
                .@"mod",
                .umod,
                .shl,
                .shr,
                .ushr,
                .bit_and,
                .bit_or,
                .bit_xor,
                .cmp_eq,
                .cmp_ne,
                .cmp_lt,
                .cmp_le,
                .cmp_gt,
                .cmp_ge,
                .ucmp_lt,
                .ucmp_le,
                .ucmp_gt,
                .ucmp_ge,
                => {
                    const s1_k = inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and const_known[inst.src1];
                    const s2_k = inst.src2 > 0 and inst.src2 < MAX_TRACKED_VREGS and const_known[inst.src2];

                    if (s1_k and s2_k) {
                        if (foldBinaryConsts(inst.op, const_val[inst.src1], const_val[inst.src2])) |res| {
                            inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = res };
                            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                                const_known[inst.dest] = true;
                                const_val[inst.dest] = res;
                            }
                            changed = true;
                            continue;
                        }
                    }

                    if (s2_k) {
                        const bv = const_val[inst.src2];
                        if ((inst.op == .add or inst.op == .sub or inst.op == .bit_or or inst.op == .bit_xor or inst.op == .shl or inst.op == .shr or inst.op == .ushr) and bv == 0) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = inst.src1 };
                            changed = true;
                            continue;
                        }
                        if ((inst.op == .mul or inst.op == .div or inst.op == .udiv) and bv == 1) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = inst.src1 };
                            changed = true;
                            continue;
                        }
                        if (inst.op == .bit_and and bv == -1) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = inst.src1 };
                            changed = true;
                            continue;
                        }
                        if (inst.op == .bit_or and bv == -1) {
                            inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = -1 };
                            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                                const_known[inst.dest] = true;
                                const_val[inst.dest] = -1;
                            }
                            changed = true;
                            continue;
                        }
                        if (inst.op == .mul and bv == -1) {
                            inst.* = .{ .op = .neg, .dest = inst.dest, .src1 = inst.src1 };
                            changed = true;
                            continue;
                        }
                        if ((inst.op == .mul or inst.op == .bit_and or inst.op == .@"mod" or inst.op == .umod) and
                            ((inst.op != .@"mod" and inst.op != .umod and bv == 0) or ((inst.op == .@"mod" or inst.op == .umod) and bv == 1)))
                        {
                            inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = 0 };
                            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                                const_known[inst.dest] = true;
                                const_val[inst.dest] = 0;
                            }
                            changed = true;
                            continue;
                        }
                        if (inst.op == .mul and bv > 1 and (bv & (bv - 1)) == 0) {
                            const shift_amt: i64 = @intCast(@ctz(@as(u64, @bitCast(bv))));
                            if (shift_amt < 63) {
                                if (ensureBlockConst(f, b, &expr_table, &expr_count, &const_known, &const_val, &ii, shift_amt)) |sv| {
                                    inst = &b.insts[ii];
                                    inst.op = .shl;
                                    inst.src2 = sv;
                                    changed = true;
                                }
                            }
                        }
                        // Unsigned power-of-2 mod -> bit_and (x & (2^k - 1)), div -> ushr (x >> k)
                        if (inst.op == .umod and bv > 1 and (bv & (bv - 1)) == 0) {
                            const mask: i64 = bv - 1;
                            if (ensureBlockConst(f, b, &expr_table, &expr_count, &const_known, &const_val, &ii, mask)) |mv| {
                                inst = &b.insts[ii];
                                inst.op = .bit_and;
                                inst.src2 = mv;
                                changed = true;
                            }
                        }
                        if (inst.op == .udiv and bv > 1 and (bv & (bv - 1)) == 0) {
                            const shift_amt: i64 = @intCast(@ctz(@as(u64, @bitCast(bv))));
                            if (shift_amt < 63) {
                                if (ensureBlockConst(f, b, &expr_table, &expr_count, &const_known, &const_val, &ii, shift_amt)) |sv| {
                                    inst = &b.insts[ii];
                                    inst.op = .ushr;
                                    inst.src2 = sv;
                                    changed = true;
                                }
                            }
                        }
                    }

                    if (s1_k) {
                        const av = const_val[inst.src1];
                        if ((inst.op == .add or inst.op == .bit_or or inst.op == .bit_xor) and av == 0) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = inst.src2 };
                            changed = true;
                            continue;
                        }
                        if (inst.op == .mul and av == 1) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = inst.src2 };
                            changed = true;
                            continue;
                        }
                        if (inst.op == .bit_and and av == -1) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = inst.src2 };
                            changed = true;
                            continue;
                        }
                        if (inst.op == .bit_or and av == -1) {
                            inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = -1 };
                            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                                const_known[inst.dest] = true;
                                const_val[inst.dest] = -1;
                            }
                            changed = true;
                            continue;
                        }
                        if (inst.op == .mul and av == -1) {
                            inst.* = .{ .op = .neg, .dest = inst.dest, .src1 = inst.src2 };
                            changed = true;
                            continue;
                        }
                        if ((inst.op == .mul or inst.op == .bit_and) and av == 0) {
                            inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = 0 };
                            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                                const_known[inst.dest] = true;
                                const_val[inst.dest] = 0;
                            }
                            changed = true;
                            continue;
                        }
                        if (inst.op == .mul and av > 1 and (av & (av - 1)) == 0) {
                            const shift_amt: i64 = @intCast(@ctz(@as(u64, @bitCast(av))));
                            if (shift_amt < 63) {
                                const orig_s2 = inst.src2;
                                if (ensureBlockConst(f, b, &expr_table, &expr_count, &const_known, &const_val, &ii, shift_amt)) |sv| {
                                    inst = &b.insts[ii];
                                    inst.op = .shl;
                                    inst.src1 = orig_s2;
                                    inst.src2 = sv;
                                    changed = true;
                                }
                            }
                        }
                    }

                    if (inst.src1 == inst.src2 and inst.src1 != 0) {
                        const self_res: ?i64 = switch (inst.op) {
                            .sub, .bit_xor, .cmp_ne, .cmp_lt, .cmp_gt, .ucmp_lt, .ucmp_gt => 0,
                            .cmp_eq, .cmp_le, .cmp_ge, .ucmp_le, .ucmp_ge => 1,
                            else => null,
                        };
                        if (self_res) |sr| {
                            inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = sr };
                            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                                const_known[inst.dest] = true;
                                const_val[inst.dest] = sr;
                            }
                            changed = true;
                            continue;
                        }
                    }

                    if (inst.op != .div and inst.op != .udiv and inst.op != .@"mod" and inst.op != .umod and inst.dest > 0) {
                        var ka = inst.src1;
                        var kb = inst.src2;
                        if (isCommutative(inst.op) and ka > kb) {
                            const tmp = ka;
                            ka = kb;
                            kb = tmp;
                        }
                        for (expr_table[0..expr_count]) |ek| {
                            if (ek.op == inst.op and ek.a == ka and ek.b == kb) {
                                inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = ek.vreg };
                                changed = true;
                                break;
                            }
                        } else if (expr_count < expr_table.len) {
                            expr_table[expr_count] = .{ .op = inst.op, .a = ka, .b = kb, .imm = 0, .vreg = inst.dest };
                            expr_count += 1;
                        }
                    }
                },
                .cond_jump => {
                    if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and const_known[inst.src1]) {
                        const tgt = if (const_val[inst.src1] != 0) inst.target_block else inst.alt_block;
                        inst.* = .{ .op = .jump, .target_block = tgt };
                        changed = true;
                    } else if (inst.target_block == inst.alt_block) {
                        inst.* = .{ .op = .jump, .target_block = inst.target_block };
                        changed = true;
                    }
                },
                else => {},
            }
        }
    }

    return changed;
}

fn localStoreToLoadForward(f: *IRFn) bool {
    var changed = false;
    var slot_val: [256]u16 = undefined;
    var bi: u16 = 0;
    while (bi < f.block_count) : (bi += 1) {
        const b = &f.blocks[bi];
        @memset(&slot_val, 0);
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            const inst = &b.insts[ii];
            switch (inst.op) {
                .store_local => {
                    if (inst.slot < slot_val.len and inst.slot < f.local_addr_taken.len and !f.local_addr_taken[inst.slot]) {
                        slot_val[inst.slot] = inst.src1;
                    }
                },
                .load_local => {
                    if (inst.slot < slot_val.len and inst.slot < f.local_addr_taken.len and !f.local_addr_taken[inst.slot]) {
                        if (slot_val[inst.slot] != 0) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = slot_val[inst.slot] };
                            changed = true;
                        } else {
                            slot_val[inst.slot] = inst.dest;
                        }
                    }
                },
                else => {},
            }
        }
    }
    return changed;
}

fn promoteEntrySingleDefSlots(f: *IRFn) bool {
    if (f.block_count == 0 or f.total_locals > 255) return false;

    var is_param: [256]bool = .{false} ** 256;
    for (0..@min(f.param_count, f.param_slots.len)) |pi| {
        const ps = f.param_slots[pi];
        if (ps < is_param.len) is_param[ps] = true;
    }

    var store_count: [256]u32 = .{0} ** 256;
    var def_block: [256]u16 = .{0} ** 256;
    var def_idx: [256]u16 = .{0} ** 256;
    var def_vreg: [256]u16 = .{0} ** 256;

    var bi: u16 = 0;
    while (bi < f.block_count) : (bi += 1) {
        const b = &f.blocks[bi];
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            const inst = b.insts[ii];
            if (inst.op == .store_local and inst.slot < 256) {
                store_count[inst.slot] += 1;
                def_block[inst.slot] = bi;
                def_idx[inst.slot] = ii;
                def_vreg[inst.slot] = inst.src1;
            }
        }
    }

    var def_count: [MAX_TRACKED_VREGS]u16 = undefined;
    isSingleDefVregTable(f, &def_count);

    var promotable: [256]bool = .{false} ** 256;
    var slot: usize = 1;
    while (slot <= @min(f.total_locals, 255)) : (slot += 1) {
        if (!is_param[slot] and !f.local_addr_taken[slot] and store_count[slot] == 1 and
            def_block[slot] == 0 and def_vreg[slot] > 0 and def_vreg[slot] < MAX_TRACKED_VREGS and
            def_count[def_vreg[slot]] == 1)
        {
            promotable[slot] = true;
        }
    }

    const b0 = &f.blocks[0];
    var idx0: u16 = 0;
    while (idx0 < b0.inst_count) : (idx0 += 1) {
        const inst = b0.insts[idx0];
        if (inst.op == .load_local and inst.slot < 256 and promotable[inst.slot] and idx0 < def_idx[inst.slot]) {
            promotable[inst.slot] = false;
        }
    }

    var changed = false;
    bi = 0;
    while (bi < f.block_count) : (bi += 1) {
        const b = &f.blocks[bi];
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            const inst = &b.insts[ii];
            if (inst.op == .load_local and inst.slot < 256 and promotable[inst.slot]) {
                inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = def_vreg[inst.slot] };
                changed = true;
            }
        }
    }
    return changed;
}

fn blockHasPhis(b: *const IRBlock) bool {
    return b.inst_count > 0 and b.insts[0].op == .phi;
}

fn simplifyCFG(f: *IRFn) bool {
    if (f.block_count == 0) return false;
    var changed = false;

    // 1. Thread jumps through pure jump-only blocks (B != 0, target has no phis)
    var bi: u16 = 0;
    while (bi < f.block_count) : (bi += 1) {
        const b = &f.blocks[bi];
        if (b.inst_count == 0) continue;
        var last = &b.insts[b.inst_count - 1];
        if (last.op == .jump) {
            var tgt = last.target_block;
            var steps: u32 = 0;
            while (tgt != 0 and tgt < f.block_count and tgt != bi and steps < 16) : (steps += 1) {
                const tb = &f.blocks[tgt];
                if (tb.inst_count == 1 and tb.insts[0].op == .jump and tb.insts[0].target_block != tgt and !blockHasPhis(&f.blocks[tb.insts[0].target_block])) {
                    tgt = tb.insts[0].target_block;
                } else break;
            }
            if (tgt != last.target_block) {
                last.target_block = tgt;
                changed = true;
            }
        } else if (last.op == .cond_jump) {
            var t1 = last.target_block;
            var s1: u32 = 0;
            while (t1 != 0 and t1 < f.block_count and s1 < 16) : (s1 += 1) {
                const tb = &f.blocks[t1];
                if (tb.inst_count == 1 and tb.insts[0].op == .jump and tb.insts[0].target_block != t1 and !blockHasPhis(&f.blocks[tb.insts[0].target_block])) {
                    t1 = tb.insts[0].target_block;
                } else break;
            }
            var t2 = last.alt_block;
            var s2: u32 = 0;
            while (t2 != 0 and t2 < f.block_count and s2 < 16) : (s2 += 1) {
                const tb = &f.blocks[t2];
                if (tb.inst_count == 1 and tb.insts[0].op == .jump and tb.insts[0].target_block != t2 and !blockHasPhis(&f.blocks[tb.insts[0].target_block])) {
                    t2 = tb.insts[0].target_block;
                } else break;
            }
            if (t1 != last.target_block or t2 != last.alt_block) {
                last.target_block = t1;
                last.alt_block = t2;
                changed = true;
            }
        }
    }

    // 2. Reachability BFS from B0 & compact unreachable blocks
    var reachable: [MAX_BLOCKS_PER_FN]bool = .{false} ** MAX_BLOCKS_PER_FN;
    var queue: [MAX_BLOCKS_PER_FN]u16 = undefined;
    var qh: usize = 0;
    var qt: usize = 0;
    reachable[0] = true;
    queue[qt] = 0;
    qt += 1;

    while (qh < qt) {
        const cur = queue[qh];
        qh += 1;
        const b = &f.blocks[cur];
        if (b.inst_count == 0) continue;
        const term = b.insts[b.inst_count - 1];
        if (term.op == .jump) {
            if (term.target_block < f.block_count and !reachable[term.target_block]) {
                reachable[term.target_block] = true;
                queue[qt] = term.target_block;
                qt += 1;
            }
        } else if (term.op == .cond_jump) {
            if (term.target_block < f.block_count and !reachable[term.target_block]) {
                reachable[term.target_block] = true;
                queue[qt] = term.target_block;
                qt += 1;
            }
            if (term.alt_block < f.block_count and !reachable[term.alt_block]) {
                reachable[term.alt_block] = true;
                queue[qt] = term.alt_block;
                qt += 1;
            }
        }
    }

    var remap: [MAX_BLOCKS_PER_FN]u16 = .{0} ** MAX_BLOCKS_PER_FN;
    var new_count: u16 = 0;
    bi = 0;
    while (bi < f.block_count) : (bi += 1) {
        if (reachable[bi]) {
            remap[bi] = new_count;
            if (new_count != bi) {
                f.blocks[new_count] = f.blocks[bi];
                f.blocks[new_count].label = new_count;
                changed = true;
            }
            new_count += 1;
        } else {
            changed = true;
        }
    }
    f.block_count = new_count;

    // Update branch targets and phi_blocks after compaction
    bi = 0;
    while (bi < f.block_count) : (bi += 1) {
        const b = &f.blocks[bi];
        if (b.inst_count == 0) continue;
        // Strip unreachable phi predecessors and remap surviving phi_blocks
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            var p = &b.insts[ii];
            if (p.op != .phi) break;
            var new_ac: u8 = 0;
            for (0..p.arg_count) |ak| {
                const old_pb = p.phi_blocks[ak];
                if (old_pb < reachable.len and reachable[old_pb]) {
                    p.args[new_ac] = p.args[ak];
                    p.phi_blocks[new_ac] = remap[old_pb];
                    new_ac += 1;
                }
            }
            p.arg_count = new_ac;
        }
        var last = &b.insts[b.inst_count - 1];
        if (last.op == .jump) {
            last.target_block = remap[last.target_block];
        } else if (last.op == .cond_jump) {
            last.target_block = remap[last.target_block];
            last.alt_block = remap[last.alt_block];
        }
    }

    // 3. Merge A -> B when A ends in jump B, in_deg[B] == 1, B != 0, and B has no phis
    var in_deg: [MAX_BLOCKS_PER_FN]u16 = .{0} ** MAX_BLOCKS_PER_FN;
    bi = 0;
    while (bi < f.block_count) : (bi += 1) {
        const b = &f.blocks[bi];
        if (b.inst_count == 0) continue;
        const term = b.insts[b.inst_count - 1];
        if (term.op == .jump and term.target_block < f.block_count) {
            in_deg[term.target_block] += 1;
        } else if (term.op == .cond_jump) {
            if (term.target_block < f.block_count) in_deg[term.target_block] += 1;
            if (term.alt_block < f.block_count) in_deg[term.alt_block] += 1;
        }
    }

    bi = 0;
    while (bi < f.block_count) : (bi += 1) {
        var b = &f.blocks[bi];
        if (b.inst_count == 0) continue;
        const last = b.insts[b.inst_count - 1];
        if (last.op == .jump) {
            const tgt = last.target_block;
            if (tgt != bi and tgt != 0 and tgt < f.block_count and in_deg[tgt] == 1 and
                f.blocks[tgt].inst_count > 0 and !blockHasPhis(&f.blocks[tgt]))
            {
                const tb = &f.blocks[tgt];
                const combined: u32 = @as(u32, b.inst_count - 1) + @as(u32, tb.inst_count);
                if (combined <= MAX_INSTS_PER_BLOCK) {
                    var copy_i: u16 = 0;
                    while (copy_i < tb.inst_count) : (copy_i += 1) {
                        b.insts[b.inst_count - 1 + copy_i] = tb.insts[copy_i];
                    }
                    b.inst_count = @intCast(combined);
                    tb.inst_count = 0;
                    // Also update any phi in successors of `tgt` that named `tgt` as predecessor -> now `bi`
                    if (b.inst_count > 0) {
                        var succs: [2]u16 = undefined;
                        const sc = getSuccs(b, &succs);
                        for (0..sc) |si| {
                            if (succs[si] < f.block_count) {
                                remapPhiPred(&f.blocks[succs[si]], tgt, bi);
                            }
                        }
                    }
                    changed = true;
                }
            }
        }
    }

    return changed;
}

fn isVoidUnusedDestSafe(op: IROp) bool {
    return switch (op) {
        .call_write_byte,
        .call_write_u32,
        .call_write_u64,
        .call_free,
        .call_array_set,
        .call_array_free,
        .call_map_set,
        .call_map_del,
        .call_map_free,
        .call_memcpy,
        .call_memset,
        .call_print,
        .call_println,
        .call_print_int,
        .call_print_float,
        .call_println_float,
        => true,
        else => false,
    };
}

fn deadCodeElimination(f: *IRFn, level: OptLevel) bool {
    var slot_read: [1024]bool = .{false} ** 1024;
    var bi: u16 = 0;
    while (bi < f.block_count) : (bi += 1) {
        const b = &f.blocks[bi];
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            const inst = b.insts[ii];
            if (inst.op == .load_local or inst.op == .addr_of or inst.op == .alloca) {
                if (inst.slot < slot_read.len) slot_read[inst.slot] = true;
            }
        }
    }

    var vreg_live: [MAX_TRACKED_VREGS]bool = .{false} ** MAX_TRACKED_VREGS;
    var inst_live: [MAX_BLOCKS_PER_FN][MAX_INSTS_PER_BLOCK]bool = .{.{false} ** MAX_INSTS_PER_BLOCK} ** MAX_BLOCKS_PER_FN;

    const markInputs = struct {
        fn call(inst: IRInst, vlive: *[MAX_TRACKED_VREGS]bool) bool {
            var added = false;
            if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and !vlive[inst.src1]) {
                vlive[inst.src1] = true;
                added = true;
            }
            if (inst.src2 > 0 and inst.src2 < MAX_TRACKED_VREGS and !vlive[inst.src2]) {
                vlive[inst.src2] = true;
                added = true;
            }
            var ai: usize = 0;
            while (ai < inst.arg_count and ai < inst.args.len) : (ai += 1) {
                const a = inst.args[ai];
                if (a > 0 and a < MAX_TRACKED_VREGS and !vlive[a]) {
                    vlive[a] = true;
                    added = true;
                }
            }
            return added;
        }
    }.call;

    // Seed roots: terminators, side-effecting instructions, and live stores
    bi = 0;
    while (bi < f.block_count) : (bi += 1) {
        const b = &f.blocks[bi];
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            const inst = b.insts[ii];
            if (inst.op == .nop) continue;
            const is_dead_local_store = (level == .O2 and inst.op == .store_local and
                inst.slot < slot_read.len and
                (inst.slot >= f.local_addr_taken.len or !f.local_addr_taken[inst.slot]) and
                !slot_read[inst.slot]);
            if (is_dead_local_store) continue;
            if (inst.op.hasSideEffects() or inst.op.isTerminator() or inst.op == .store_local) {
                inst_live[bi][ii] = true;
                _ = markInputs(inst, &vreg_live);
            }
        }
    }

    // Backward liveness propagation over definitions (handles circular dead copy/phi chains)
    var prop = true;
    while (prop) {
        prop = false;
        bi = 0;
        while (bi < f.block_count) : (bi += 1) {
            const b = &f.blocks[bi];
            var ii: u16 = 0;
            while (ii < b.inst_count) : (ii += 1) {
                if (inst_live[bi][ii]) continue;
                const inst = b.insts[ii];
                if (inst.op == .nop) continue;
                if (inst.op == .store_local) continue;
                if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS and vreg_live[inst.dest]) {
                    inst_live[bi][ii] = true;
                    if (markInputs(inst, &vreg_live)) prop = true;
                }
            }
        }
    }

    var changed = false;
    bi = 0;
    while (bi < f.block_count) : (bi += 1) {
        var b = &f.blocks[bi];
        var write_i: u16 = 0;
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            var inst = b.insts[ii];
            if (!inst_live[bi][ii]) {
                changed = true;
                continue;
            }
            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS and !vreg_live[inst.dest] and isVoidUnusedDestSafe(inst.op)) {
                inst.dest = 0;
                changed = true;
            }
            b.insts[write_i] = inst;
            write_i += 1;
        }
        b.inst_count = write_i;
    }

    return changed;
}

fn reorderBlocksRPO(f: *IRFn) bool {
    if (f.block_count <= 1 or f.block_count > MAX_BLOCKS_PER_FN) return false;
    const n: usize = f.block_count;

    var visited: [MAX_BLOCKS_PER_FN]bool = .{false} ** MAX_BLOCKS_PER_FN;
    var post: [MAX_BLOCKS_PER_FN]u16 = undefined;
    var post_len: usize = 0;
    var stack_blk: [MAX_BLOCKS_PER_FN]u16 = undefined;
    var stack_si: [MAX_BLOCKS_PER_FN]u8 = undefined;

    visited[0] = true;
    stack_blk[0] = 0;
    stack_si[0] = 0;
    var sp: usize = 1;

    while (sp > 0) {
        const cur = stack_blk[sp - 1];
        const si = stack_si[sp - 1];
        var succs: [2]u16 = undefined;
        var sc: u8 = 0;
        const b = &f.blocks[cur];
        if (b.inst_count > 0) {
            const term = b.insts[b.inst_count - 1];
            if (term.op == .jump) {
                succs[0] = term.target_block;
                sc = 1;
            } else if (term.op == .cond_jump) {
                // Push alt_block first so target_block (loop body / true branch) lands earlier in RPO
                succs[0] = term.alt_block;
                succs[1] = term.target_block;
                sc = 2;
            }
        }
        if (si < sc) {
            stack_si[sp - 1] = si + 1;
            const nxt = succs[si];
            if (nxt < n and !visited[nxt]) {
                visited[nxt] = true;
                stack_blk[sp] = nxt;
                stack_si[sp] = 0;
                sp += 1;
            }
        } else {
            sp -= 1;
            post[post_len] = cur;
            post_len += 1;
        }
    }

    if (post_len == 0) return false;
    var rpo: [MAX_BLOCKS_PER_FN]u16 = undefined;
    var old_to_new: [MAX_BLOCKS_PER_FN]u16 = .{0} ** MAX_BLOCKS_PER_FN;
    for (0..post_len) |i| {
        const old_b = post[post_len - 1 - i];
        rpo[i] = old_b;
        old_to_new[old_b] = @intCast(i);
    }

    var is_identity = (post_len == n);
    if (is_identity) {
        for (0..post_len) |i| {
            if (rpo[i] != @as(u16, @intCast(i))) {
                is_identity = false;
                break;
            }
        }
    }
    if (is_identity) return false;

    // Remap block references before permuting slots
    for (0..post_len) |i| {
        var b = &f.blocks[rpo[i]];
        if (b.inst_count == 0) continue;
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            if (b.insts[ii].op != .phi) break;
            var p = &b.insts[ii];
            var ak: u8 = 0;
            var keep: u8 = 0;
            while (ak < p.arg_count) : (ak += 1) {
                const pb = p.phi_blocks[ak];
                if (pb < n and visited[pb]) {
                    p.args[keep] = p.args[ak];
                    p.phi_blocks[keep] = old_to_new[pb];
                    keep += 1;
                }
            }
            p.arg_count = keep;
        }
        var last = &b.insts[b.inst_count - 1];
        if (last.op == .jump and last.target_block < n) {
            last.target_block = old_to_new[last.target_block];
        } else if (last.op == .cond_jump) {
            if (last.target_block < n) last.target_block = old_to_new[last.target_block];
            if (last.alt_block < n) last.alt_block = old_to_new[last.alt_block];
        }
    }

    // In-place block permutation using a single scratch IRBlock
    var cur_at: [MAX_BLOCKS_PER_FN]u16 = undefined;
    var where_is: [MAX_BLOCKS_PER_FN]u16 = undefined;
    for (0..n) |i| {
        cur_at[i] = @intCast(i);
        where_is[i] = @intCast(i);
    }
    for (0..post_len) |dst_u| {
        const dst: u16 = @intCast(dst_u);
        const want_old = rpo[dst];
        if (cur_at[dst] != want_old) {
            const src = where_is[want_old];
            const disp_old = cur_at[dst];
            const tmp_blk = f.blocks[dst];
            f.blocks[dst] = f.blocks[src];
            f.blocks[src] = tmp_blk;
            cur_at[dst] = want_old;
            cur_at[src] = disp_old;
            where_is[want_old] = dst;
            where_is[disp_old] = src;
        }
    }
    f.block_count = @intCast(post_len);
    return true;
}

fn instReadsVreg(inst: IRInst, v: u16) bool {
    if (v == 0) return false;
    if (inst.src1 == v or inst.src2 == v) return true;
    var ai: usize = 0;
    while (ai < inst.arg_count and ai < inst.args.len) : (ai += 1) {
        if (inst.args[ai] == v) return true;
    }
    return false;
}

fn coalesceCopiesPostSSA(f: *IRFn) bool {
    var def_cnt: [MAX_TRACKED_VREGS]u16 = undefined;
    var use_cnt: [MAX_TRACKED_VREGS]u16 = .{0} ** MAX_TRACKED_VREGS;
    isSingleDefVregTable(f, &def_cnt);

    for (0..f.block_count) |bi| {
        const b = &f.blocks[bi];
        for (0..b.inst_count) |ii| {
            const inst = b.insts[ii];
            if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS) use_cnt[inst.src1] +|= 1;
            if (inst.src2 > 0 and inst.src2 < MAX_TRACKED_VREGS) use_cnt[inst.src2] +|= 1;
            for (0..@min(inst.arg_count, inst.args.len)) |ai| {
                const a = inst.args[ai];
                if (a > 0 and a < MAX_TRACKED_VREGS) use_cnt[a] +|= 1;
            }
        }
    }

    var changed = false;
    for (0..f.block_count) |bi| {
        var b = &f.blocks[bi];
        // Pass A: dst = copy src where src is single-def and single-use in this block
        var j: u16 = 0;
        while (j < b.inst_count) : (j += 1) {
            const cj = b.insts[j];
            if (cj.op != .copy or cj.dest == 0 or cj.src1 == 0 or cj.dest == cj.src1) continue;
            const dst = cj.dest;
            const src = cj.src1;
            if (src >= MAX_TRACKED_VREGS or def_cnt[src] != 1 or use_cnt[src] != 1) continue;

            var def_i: ?u16 = null;
            var k: u16 = j;
            while (k > 0) {
                k -= 1;
                if (b.insts[k].dest == src) {
                    def_i = k;
                    break;
                }
            }
            const di = def_i orelse continue;
            if (b.insts[di].op == .phi or b.insts[di].op.isTerminator()) continue;

            var safe = true;
            var m: u16 = di + 1;
            while (m < j) : (m += 1) {
                const mi = b.insts[m];
                if (mi.dest == dst or instReadsVreg(mi, dst)) {
                    safe = false;
                    break;
                }
            }
            if (safe) {
                b.insts[di].dest = dst;
                b.insts[j].op = .nop;
                if (dst < MAX_TRACKED_VREGS) def_cnt[dst] +|= 1;
                def_cnt[src] = 0;
                use_cnt[src] = 0;
                changed = true;
            }
        }

        // Pass B: two-address chain tmp = op1(dst, a); dst = op2(tmp, b) -> dst = op1(dst, a); dst = op2(dst, b)
        var i: u16 = 0;
        while (i + 1 < b.inst_count) : (i += 1) {
            const inst0 = b.insts[i];
            const inst1 = b.insts[i + 1];
            if (inst0.op == .nop or inst0.op == .phi or inst0.op.isTerminator()) continue;
            if (inst0.dest == 0 or inst0.dest >= MAX_TRACKED_VREGS) continue;
            const tmp = inst0.dest;
            if (def_cnt[tmp] != 1 or use_cnt[tmp] != 1) continue;
            if (inst1.dest == 0 or inst1.dest == tmp) continue;
            const dst = inst1.dest;
            const is_two_addr = switch (inst1.op) {
                .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => true,
                else => false,
            };
            if (!is_two_addr) continue;
            if (inst1.src1 == tmp and inst1.src2 != dst) {
                b.insts[i].dest = dst;
                b.insts[i + 1].src1 = dst;
                def_cnt[tmp] = 0;
                use_cnt[tmp] = 0;
                if (dst < MAX_TRACKED_VREGS) def_cnt[dst] +|= 1;
                changed = true;
            } else if ((inst1.op == .add or inst1.op == .mul or inst1.op == .bit_and or inst1.op == .bit_or or inst1.op == .bit_xor) and
                inst1.src2 == tmp and inst1.src1 != dst)
            {
                b.insts[i].dest = dst;
                b.insts[i + 1].src1 = dst;
                b.insts[i + 1].src2 = inst1.src1;
                def_cnt[tmp] = 0;
                use_cnt[tmp] = 0;
                if (dst < MAX_TRACKED_VREGS) def_cnt[dst] +|= 1;
                changed = true;
            }
        }

        if (changed) {
            var wi: u16 = 0;
            for (0..b.inst_count) |ri| {
                if (b.insts[ri].op != .nop) {
                    b.insts[wi] = b.insts[ri];
                    wi += 1;
                }
            }
            b.inst_count = wi;
        }
    }

    return changed;
}

fn isPureHeaderOp(op: IROp) bool {
    return switch (op) {
        .const_int,
        .copy,
        .add,
        .sub,
        .mul,
        .neg,
        .bit_and,
        .bit_or,
        .bit_xor,
        .bit_not,
        .logic_not,
        .cmp_eq,
        .cmp_ne,
        .cmp_lt,
        .cmp_le,
        .cmp_gt,
        .cmp_ge,
        .ucmp_lt,
        .ucmp_le,
        .ucmp_gt,
        .ucmp_ge,
        => true,
        else => false,
    };
}

fn rotateLoops(f: *IRFn) bool {
    if (f.block_count < 2 or f.block_count > 128) return false;
    var cfg: CFGInfo = undefined;
    buildCFGInfo(f, &cfg);

    var changed = false;
    var h_u: usize = 1;
    while (h_u < f.block_count) : (h_u += 1) {
        const h: u16 = @intCast(h_u);
        const hb = &f.blocks[h];
        if (hb.inst_count < 2 or hb.inst_count > 8) continue;
        const term = hb.insts[hb.inst_count - 1];
        if (term.op != .cond_jump or term.target_block == term.alt_block or
            term.target_block == h or term.alt_block == h or
            term.target_block >= f.block_count or term.alt_block >= f.block_count) continue;

        var header_pure = true;
        for (0..hb.inst_count - 1) |ii| {
            if (!isPureHeaderOp(hb.insts[ii].op)) {
                header_pure = false;
                break;
            }
        }
        if (!header_pure) continue;

        // Collect all natural loop blocks reaching any backedge u -> h where h dom u
        var in_loop: u128 = @as(u128, 1) << @intCast(h);
        var has_backedge = false;
        for (0..cfg.pred_cnt[h]) |pi| {
            const u = cfg.preds[h][pi];
            if (u < f.block_count and dominates(&cfg, h, u)) {
                has_backedge = true;
                in_loop |= @as(u128, 1) << @intCast(u);
                if (u != h) {
                    var work: [MAX_BLOCKS_PER_FN]u16 = undefined;
                    work[0] = u;
                    var wlen: usize = 1;
                    while (wlen > 0) {
                        wlen -= 1;
                        const cur = work[wlen];
                        for (0..cfg.pred_cnt[cur]) |ppi| {
                            const pp = cfg.preds[cur][ppi];
                            if ((in_loop & (@as(u128, 1) << @intCast(pp))) == 0) {
                                in_loop |= @as(u128, 1) << @intCast(pp);
                                work[wlen] = pp;
                                wlen += 1;
                            }
                        }
                    }
                }
            }
        }
        if (!has_backedge) continue;

        // Ensure one branch goes into the loop and the other exits the loop
        const t_in = (in_loop & (@as(u128, 1) << @intCast(term.target_block))) != 0;
        const a_in = (in_loop & (@as(u128, 1) << @intCast(term.alt_block))) != 0;
        if (t_in == a_in) continue;

        // Every predecessor of `h` (outside and inside loop) must end in unconditional `jump h` and fit copied header
        if (cfg.pred_cnt[h] == 0 or cfg.pred_cnt[h] > 4) continue;
        var all_preds_ok = true;
        for (0..cfg.pred_cnt[h]) |pi| {
            const p = cfg.preds[h][pi];
            if (p >= f.block_count or p == h) {
                all_preds_ok = false;
                break;
            }
            const pb = &f.blocks[p];
            if (pb.inst_count == 0 or pb.insts[pb.inst_count - 1].op != .jump or pb.insts[pb.inst_count - 1].target_block != h) {
                all_preds_ok = false;
                break;
            }
            if (@as(u32, pb.inst_count - 1) + @as(u32, hb.inst_count) > MAX_INSTS_PER_BLOCK) {
                all_preds_ok = false;
                break;
            }
        }
        if (!all_preds_ok) continue;

        // Find vregs defined in `h` that are ONLY read inside `h` (so cloning them gets fresh single-def vregs)
        var def_in_h: [MAX_TRACKED_VREGS]bool = .{false} ** MAX_TRACKED_VREGS;
        var used_outside_h: [MAX_TRACKED_VREGS]bool = .{false} ** MAX_TRACKED_VREGS;
        for (0..hb.inst_count) |hi| {
            const d = hb.insts[hi].dest;
            if (d > 0 and d < MAX_TRACKED_VREGS) def_in_h[d] = true;
        }
        for (0..f.block_count) |obi| {
            if (obi == h) continue;
            const ob = &f.blocks[obi];
            for (0..ob.inst_count) |oii| {
                const oi = ob.insts[oii];
                if (oi.src1 > 0 and oi.src1 < MAX_TRACKED_VREGS and def_in_h[oi.src1]) used_outside_h[oi.src1] = true;
                if (oi.src2 > 0 and oi.src2 < MAX_TRACKED_VREGS and def_in_h[oi.src2]) used_outside_h[oi.src2] = true;
                for (0..@min(oi.arg_count, oi.args.len)) |ai| {
                    const a = oi.args[ai];
                    if (a > 0 and a < MAX_TRACKED_VREGS and def_in_h[a]) used_outside_h[a] = true;
                }
            }
        }

        // Replace `jump h` in every predecessor with a copy of header `h`
        const hdr_copy = hb.*;
        for (0..cfg.pred_cnt[h]) |pi| {
            const p = cfg.preds[h][pi];
            var pb = &f.blocks[p];
            const base: u16 = pb.inst_count - 1;
            var local_remap: [MAX_TRACKED_VREGS]u16 = .{0} ** MAX_TRACKED_VREGS;
            for (0..hdr_copy.inst_count) |hi| {
                var ni = hdr_copy.insts[hi];
                if (ni.src1 > 0 and ni.src1 < MAX_TRACKED_VREGS and local_remap[ni.src1] != 0) ni.src1 = local_remap[ni.src1];
                if (ni.src2 > 0 and ni.src2 < MAX_TRACKED_VREGS and local_remap[ni.src2] != 0) ni.src2 = local_remap[ni.src2];
                for (0..@min(ni.arg_count, ni.args.len)) |ai| {
                    const a = ni.args[ai];
                    if (a > 0 and a < MAX_TRACKED_VREGS and local_remap[a] != 0) ni.args[ai] = local_remap[a];
                }
                if (pi > 0 and ni.dest > 0 and ni.dest < MAX_TRACKED_VREGS and
                    def_in_h[ni.dest] and !used_outside_h[ni.dest] and f.vreg_count < MAX_TRACKED_VREGS)
                {
                    const fv = f.vreg_count;
                    f.vreg_count += 1;
                    local_remap[ni.dest] = fv;
                    ni.dest = fv;
                }
                pb.insts[base + hi] = ni;
            }
            pb.inst_count = base + hdr_copy.inst_count;
        }
        changed = true;
        // Rebuild CFG before rotating further headers
        buildCFGInfo(f, &cfg);
    }

    return changed;
}

fn unrollCountedLoops(f: *IRFn) bool {
    if (f.block_count < 2 or f.block_count + 4 > MAX_BLOCKS_PER_FN) return false;
    if (f.vreg_count + 64 >= MAX_TRACKED_VREGS) return false;

    var def_cnt: [MAX_TRACKED_VREGS]u16 = undefined;
    isSingleDefVregTable(f, &def_cnt);
    var const_known: [MAX_TRACKED_VREGS]bool = .{false} ** MAX_TRACKED_VREGS;
    var const_val: [MAX_TRACKED_VREGS]i64 = .{0} ** MAX_TRACKED_VREGS;
    for (0..f.block_count) |bi| {
        for (0..f.blocks[bi].inst_count) |ii| {
            const inst = f.blocks[bi].insts[ii];
            if (inst.op == .const_int and inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS and def_cnt[inst.dest] == 1) {
                const_known[inst.dest] = true;
                const_val[inst.dest] = inst.imm;
            }
        }
    }

    var in_deg: [MAX_BLOCKS_PER_FN]u16 = .{0} ** MAX_BLOCKS_PER_FN;
    for (0..f.block_count) |bi| {
        const b = &f.blocks[bi];
        if (b.inst_count == 0) continue;
        const term = b.insts[b.inst_count - 1];
        if (term.op == .jump and term.target_block < f.block_count) {
            in_deg[term.target_block] += 1;
        } else if (term.op == .cond_jump) {
            if (term.target_block < f.block_count) in_deg[term.target_block] += 1;
            if (term.alt_block < f.block_count) in_deg[term.alt_block] += 1;
        }
    }

    var changed = false;
    const orig_bc = f.block_count;
    var bi_u: usize = 1;
    while (bi_u < orig_bc) : (bi_u += 1) {
        if (f.block_count + 4 > MAX_BLOCKS_PER_FN or f.vreg_count + 96 >= MAX_TRACKED_VREGS) break;
        const bi: u16 = @intCast(bi_u);
        const b = &f.blocks[bi];
        if (b.inst_count < 3 or b.inst_count > 14) continue;
        if (in_deg[bi] != 2) continue;

        const term = b.insts[b.inst_count - 1];
        if (term.op != .cond_jump or term.target_block != bi or term.alt_block == bi) continue;
        const exit_bi = term.alt_block;
        if (exit_bi >= f.block_count) continue;

        const cmp_inst = b.insts[b.inst_count - 2];
        if (cmp_inst.op != .cmp_lt or cmp_inst.dest == 0 or cmp_inst.dest != term.src1) continue;
        const iv = cmp_inst.src1;
        const limit = cmp_inst.src2;
        if (iv == 0 or limit == 0 or iv == limit) continue;

        // Verify pure loop body and count writes to `iv` and `limit`
        var body_pure = true;
        var iv_defs: u16 = 0;
        var iv_def_idx: u16 = 0;
        var limit_defs: u16 = 0;
        const body_len: u16 = b.inst_count - 2;
        for (0..body_len) |ii| {
            const inst = b.insts[ii];
            if (!isPureHeaderOp(inst.op)) {
                body_pure = false;
                break;
            }
            if (inst.dest == limit) limit_defs += 1;
            if (inst.dest == iv) {
                iv_defs += 1;
                iv_def_idx = @intCast(ii);
            }
        }
        if (!body_pure or limit_defs != 0 or iv_defs != 1) continue;

        // Verify `iv` is incremented by constant +1 and not read inside body after update
        const iv_inst = b.insts[iv_def_idx];
        var step_ok = false;
        if (iv_inst.op == .add) {
            if (iv_inst.src1 == iv and iv_inst.src2 < MAX_TRACKED_VREGS and const_known[iv_inst.src2] and const_val[iv_inst.src2] == 1) {
                step_ok = true;
            } else if (iv_inst.src2 == iv and iv_inst.src1 < MAX_TRACKED_VREGS and const_known[iv_inst.src1] and const_val[iv_inst.src1] == 1) {
                step_ok = true;
            }
        }
        if (!step_ok) continue;

        var read_after_iv = false;
        for (iv_def_idx + 1..body_len) |ii| {
            if (instReadsVreg(b.insts[ii], iv)) {
                read_after_iv = true;
                break;
            }
        }
        if (read_after_iv) continue;

        // Find the unique outside predecessor entering `bi`
        var pre_bi: u16 = 0xFFFF;
        for (0..orig_bc) |pi| {
            if (pi == bi) continue;
            const pb = &f.blocks[pi];
            if (pb.inst_count == 0) continue;
            const pt = pb.insts[pb.inst_count - 1];
            if ((pt.op == .jump and pt.target_block == bi) or
                (pt.op == .cond_jump and (pt.target_block == bi or pt.alt_block == bi)))
            {
                if (pre_bi != 0xFFFF) {
                    pre_bi = 0xFFFE;
                    break;
                }
                pre_bi = @intCast(pi);
            }
        }
        if (pre_bi >= orig_bc) continue;

        // Allocate 4 blocks: b_chk_min, b_chk_4x, b_4x, b_tail_hdr
        const b_chk_min: u16 = f.block_count;
        const b_chk_4x: u16 = f.block_count + 1;
        const b_4x: u16 = f.block_count + 2;
        const b_tail_hdr: u16 = f.block_count + 3;
        f.block_count += 4;

        // Redirect outside predecessor -> b_chk_min
        var pt = &f.blocks[pre_bi].insts[f.blocks[pre_bi].inst_count - 1];
        if (pt.op == .jump) {
            pt.target_block = b_chk_min;
        } else if (pt.op == .cond_jump) {
            if (pt.target_block == bi) pt.target_block = b_chk_min;
            if (pt.alt_block == bi) pt.alt_block = b_chk_min;
        }

        const c_min_v = f.vreg_count;
        const ok_min_v = f.vreg_count + 1;
        const c3_v = f.vreg_count + 2;
        const limit_m3_v = f.vreg_count + 3;
        const ok4_v = f.vreg_count + 4;
        const cmp4_v = f.vreg_count + 5;
        const cmpt_v = f.vreg_count + 6;
        f.vreg_count += 7;

        f.blocks[b_chk_min].inst_count = 3;
        f.blocks[b_chk_min].insts[0] = .{ .op = .const_int, .dest = c_min_v, .imm = -9000000000000000000 };
        f.blocks[b_chk_min].insts[1] = .{ .op = .cmp_ge, .dest = ok_min_v, .src1 = limit, .src2 = c_min_v };
        f.blocks[b_chk_min].insts[2] = .{ .op = .cond_jump, .src1 = ok_min_v, .target_block = b_chk_4x, .alt_block = b_tail_hdr };

        f.blocks[b_chk_4x].inst_count = 4;
        f.blocks[b_chk_4x].insts[0] = .{ .op = .const_int, .dest = c3_v, .imm = 3 };
        f.blocks[b_chk_4x].insts[1] = .{ .op = .sub, .dest = limit_m3_v, .src1 = limit, .src2 = c3_v };
        f.blocks[b_chk_4x].insts[2] = .{ .op = .cmp_lt, .dest = ok4_v, .src1 = iv, .src2 = limit_m3_v };
        f.blocks[b_chk_4x].insts[3] = .{ .op = .cond_jump, .src1 = ok4_v, .target_block = b_4x, .alt_block = b_tail_hdr };

        // Identify loop-local single-def temps (defined & only read within this body after definition)
        var blk_def_cnt: [MAX_TRACKED_VREGS]u16 = .{0} ** MAX_TRACKED_VREGS;
        for (0..body_len) |ii| {
            const d = b.insts[ii].dest;
            if (d > 0 and d < MAX_TRACKED_VREGS) blk_def_cnt[d] += 1;
        }
        var total_uses: [MAX_TRACKED_VREGS]u16 = .{0} ** MAX_TRACKED_VREGS;
        for (0..orig_bc) |obi| {
            for (0..f.blocks[obi].inst_count) |oii| {
                const oi = f.blocks[obi].insts[oii];
                if (oi.src1 > 0 and oi.src1 < MAX_TRACKED_VREGS) total_uses[oi.src1] +|= 1;
                if (oi.src2 > 0 and oi.src2 < MAX_TRACKED_VREGS) total_uses[oi.src2] +|= 1;
                for (0..@min(oi.arg_count, oi.args.len)) |ai| {
                    const a = oi.args[ai];
                    if (a > 0 and a < MAX_TRACKED_VREGS) total_uses[a] +|= 1;
                }
            }
        }
        var body_uses: [MAX_TRACKED_VREGS]u16 = .{0} ** MAX_TRACKED_VREGS;
        for (0..body_len) |ii| {
            const bi_inst = b.insts[ii];
            if (bi_inst.src1 > 0 and bi_inst.src1 < MAX_TRACKED_VREGS) body_uses[bi_inst.src1] +|= 1;
            if (bi_inst.src2 > 0 and bi_inst.src2 < MAX_TRACKED_VREGS) body_uses[bi_inst.src2] +|= 1;
        }
        var is_local_temp: [MAX_TRACKED_VREGS]bool = .{false} ** MAX_TRACKED_VREGS;
        for (0..body_len) |ii| {
            const d = b.insts[ii].dest;
            if (d > 0 and d < MAX_TRACKED_VREGS and d != iv and def_cnt[d] == 1 and
                blk_def_cnt[d] == 1 and body_uses[d] == total_uses[d])
            {
                // Make sure it is not read before it is defined in the loop body
                var read_before = false;
                for (0..ii) |prev_i| {
                    if (instReadsVreg(b.insts[prev_i], d)) {
                        read_before = true;
                        break;
                    }
                }
                if (!read_before) is_local_temp[d] = true;
            }
        }

        var w4: u16 = 0;
        var rep: usize = 0;
        while (rep < 4) : (rep += 1) {
            var temp_map: [MAX_TRACKED_VREGS]u16 = .{0} ** MAX_TRACKED_VREGS;
            for (0..body_len) |ii| {
                var ni = b.insts[ii];
                if (ni.src1 > 0 and ni.src1 < MAX_TRACKED_VREGS and temp_map[ni.src1] != 0) ni.src1 = temp_map[ni.src1];
                if (ni.src2 > 0 and ni.src2 < MAX_TRACKED_VREGS and temp_map[ni.src2] != 0) ni.src2 = temp_map[ni.src2];
                if (ni.dest > 0 and ni.dest < MAX_TRACKED_VREGS and is_local_temp[ni.dest] and f.vreg_count < MAX_TRACKED_VREGS) {
                    const fv = f.vreg_count;
                    f.vreg_count += 1;
                    temp_map[ni.dest] = fv;
                    ni.dest = fv;
                }
                f.blocks[b_4x].insts[w4] = ni;
                w4 += 1;
            }
        }
        f.blocks[b_4x].insts[w4] = .{ .op = .cmp_lt, .dest = cmp4_v, .src1 = iv, .src2 = limit_m3_v };
        f.blocks[b_4x].insts[w4 + 1] = .{ .op = .cond_jump, .src1 = cmp4_v, .target_block = b_4x, .alt_block = b_tail_hdr };
        f.blocks[b_4x].inst_count = w4 + 2;

        f.blocks[b_tail_hdr].inst_count = 2;
        f.blocks[b_tail_hdr].insts[0] = .{ .op = .cmp_lt, .dest = cmpt_v, .src1 = iv, .src2 = limit };
        f.blocks[b_tail_hdr].insts[1] = .{ .op = .cond_jump, .src1 = cmpt_v, .target_block = bi, .alt_block = exit_bi };

        changed = true;
    }
    return changed;
}

