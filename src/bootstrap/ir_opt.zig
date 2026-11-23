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
        optimizeFn(module, fi, level);
    }

    // Bounds-check hoisting runs exactly once, after every function has been
    // through the whole pipeline. Running it inside optimizeFn meant a second
    // pass over the same function (inlining is iterative) rewrote instructions
    // and dropped the marks the first run had set — 8 accesses marked, 5 left.
    if (level == .O2) _ = hoistBoundsChecks(module, null);
}

fn optimizeFn(module: *IRModule, fi: u32, level: OptLevel) void {
    const f = &module.fns[fi];
    // ── -O1 Pipeline ────────────────────────────────────────────
    // -O1 used to run local passes only, which left parameters and loop
    // variables in memory: the same function could run 2.4x slower than at -O2.
    // It now builds SSA (that is what actually moves values into registers) but
    // skips the passes whose runtime payoff does not pay for their compile time:
    // inlining, global value numbering, loop-invariant hoisting, unrolling and
    // loop rotation.
    if (level == .O1) {
        _ = localStoreToLoadForward(f);
        _ = localConstantFoldAndLVN(f);
        _ = simplifyCFG(f);
        _ = mem2reg(f);
        _ = simplifyTrivialPhis(f);
        _ = ifConversion(f);
        _ = localConstantFoldAndLVN(f);
        _ = globalCopyPropagate(f);
        _ = simplifyCFG(f);
        _ = destructSSA(f);
        _ = reorderBlocksRPO(f);
        _ = coalesceCopiesPostSSA(f);
        _ = localConstantFoldAndLVN(f);
        _ = deadCodeElimination(f, .O1);
        _ = localConstantFoldAndLVN(f);
        _ = deadCodeElimination(f, .O1);
        _ = simplifyCFG(f);
        _ = deadCodeElimination(f, .O1);
        _ = reorderBlocksRPO(f);
        _ = unrollCountedLoops(f);
        _ = coalesceCopiesPostSSA(f);
        _ = propagateTrivialCopies(f);
        _ = localConstantFoldAndLVN(f);
        _ = deadCodeElimination(f, .O1);
        _ = sinkCompareToConsumer(f);
        return;
    }

    // ── -O2 Pipeline ────────────────────────────────────────────
    // 1. Pre-SSA cleanup
    _ = selfTailCallOpt(module, fi);
    _ = localStoreToLoadForward(f);
    _ = localConstantFoldAndLVN(f);
    _ = globalCopyPropagate(f);
    _ = simplifyCFG(f);

    // 2. Full SSA construction (mem2reg) across CFG
    const ssa_built = mem2reg(f);
    _ = associativeTailRecursionOpt(module, fi);

    // 3. Iterative SSA optimization loop (GVN + LICM + Folding + CFG + DCE)
    var iter: u32 = 0;
    while (iter < 8) : (iter += 1) {
        var changed = false;
            if (!ssa_built) {
                if (promoteEntrySingleDefSlots(f)) changed = true;
                if (localStoreToLoadForward(f)) changed = true;
            }
            if (simplifyTrivialPhis(f)) changed = true;
            if (ifConversion(f)) changed = true;
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
    _ = propagateTrivialCopies(f);

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
    // Bounds-check hoisting runs after every loop transformation, so the loop
    // shape it reasons about is final: rotation and unrolling change trip
    // counts and preheaders, and hoisting before them would target a preheader
    // that no longer exists.
    // Codegen fuses `cmp` + `select`/`cond_jump` into one cmov/jcc only when the
    // pair is adjacent. Run last, after every pass that could re-separate them.
    _ = sinkCompareToConsumer(f);
}

// ════════════════════════════════════════════════════════════════════════════
// Function Inlining (-O2)
// ════════════════════════════════════════════════════════════════════════════

fn countFnInsts(f: *const IRFn) u32 {
    var total: u32 = 0;
    for (0..f.block_count) |bi| total += f.blocks[bi].inst_count;
    return total;
}

/// Instruction budget for inlining. The default keeps code growth modest for
/// functions that are called from many places; a function with a single call
/// site cannot increase total code size by more than its own body, so it gets a
/// larger budget (a small function invoked once is pure call overhead: argument
/// setup, prologue/epilogue, and no constant propagation into the callee). This
/// is what lets the compiler turn `f(20000000)` into a loop with the bound as a
/// constant instead of a parameter.
const INLINE_MAX_INSTS = 56;
const INLINE_MAX_INSTS_SINGLE_CALL = 120;

/// Count direct `.call` sites per callee in one module pass. `inlineSmallFunctions`
/// needs this for every function, so computing it per callee was O(fns x insts)
/// quadratic on large modules.
fn countAllCallSites(module: *const IRModule, out: *[ir.MAX_FNS]u32) void {
    for (0..module.fn_count) |fi| {
        const f = &module.fns[fi];
        for (0..f.block_count) |bi| {
            for (0..f.blocks[bi].inst_count) |ii| {
                const inst = f.blocks[bi].insts[ii];
                if (inst.op == .call and inst.callee_fn_idx >= 0) {
                    const ci: u32 = @intCast(inst.callee_fn_idx);
                    if (ci < module.fn_count) out[ci] += 1;
                }
            }
        }
    }
}

/// True when `f` contains no call at all and nothing it could call is
/// reachable from it. Such a function can be inlined into an arbitrary caller
/// without dragging a call site along with it, so it is always small enough in
/// the only sense that matters for a leaf: its own instruction count.
fn isCallFreeLeaf(f: *const IRFn) bool {
    for (0..f.block_count) |bi| {
        const b = &f.blocks[bi];
        for (0..b.inst_count) |ii| {
            const op = b.insts[ii].op;
            if (op == .call or op == .call_indirect) return false;
        }
    }
    return true;
}

/// Functions that become call-free once their callees are inlined, computed as
/// a fixpoint: a function is in the set if every call it makes targets a member
/// of the set. `mul` calls `fabs` and `mul_sat`; `mul_sat` calls `fabs`; so all
/// three are in the closure even though only `fabs` is a leaf today.
fn computeLeafClosure(module: *const IRModule, out: *[ir.MAX_FNS]bool) void {
    for (0..module.fn_count) |i| out[i] = isCallFreeLeaf(&module.fns[i]);
    var changed = true;
    var rounds: u32 = 0;
    while (changed and rounds < 32) : (rounds += 1) {
        changed = false;
        for (0..module.fn_count) |i| {
            if (out[i]) continue;
            const f = &module.fns[i];
            var ok = true;
            outer: for (0..f.block_count) |bi| {
                const b = &f.blocks[bi];
                for (0..b.inst_count) |ii| {
                    const inst = b.insts[ii];
                    if (inst.op == .call_indirect) {
                        ok = false;
                        break :outer;
                    }
                    if (inst.op != .call) continue;
                    const ci = inst.callee_fn_idx;
                    if (ci < 0) {
                        ok = false;
                        break :outer;
                    }
                    const idx: u32 = @intCast(ci);
                    if (idx >= module.fn_count or !out[idx]) {
                        ok = false;
                        break :outer;
                    }
                }
            }
            if (ok) {
                out[i] = true;
                changed = true;
            }
        }
    }
}

/// Same check as `fnInlineEligible` but tolerant of calls: a function in the
/// leaf closure will itself become call-free once its own callees are inlined,
/// so the "must not contain a call" rule does not apply. Everything that makes
/// splicing hard (phis, stack slots, address-taken locals) still does.
fn fnInlineEligibleLeaf(f: *const IRFn, max_insts: u32) bool {
    if (f.block_count == 0 or f.block_count > 8) return false;
    if (f.total_locals > 48) return false;
    const total = countFnInsts(f);
    if (total == 0 or total > max_insts) return false;
    for (0..f.block_count) |bi| {
        const b = &f.blocks[bi];
        for (0..b.inst_count) |ii| {
            const op = b.insts[ii].op;
            if (op == .phi or op == .alloca or op == .addr_of or op == .call_indirect) return false;
        }
    }
    return true;
}

fn fnInlineEligible(f: *const IRFn, max_insts: u32) bool {
    if (f.block_count == 0 or f.block_count > 8) return false;
    if (f.total_locals > 48) return false;
    const total = countFnInsts(f);
    if (total == 0 or total > max_insts) return false;
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
    var leaves: [ir.MAX_FNS]bool = .{false} ** ir.MAX_FNS;
    var call_sites: [ir.MAX_FNS]u32 = .{0} ** ir.MAX_FNS;
    countAllCallSites(module, &call_sites);
    computeLeafClosure(module, &leaves);
    for (0..module.fn_count) |i| {
        // A single-call-site callee is inlined even when larger, because total
        // code size cannot shrink by keeping the call.
        const max_insts: u32 = if (call_sites[i] <= 1)
            INLINE_MAX_INSTS_SINGLE_CALL
        else
            INLINE_MAX_INSTS;
        eligible[i] = fnInlineEligible(&module.fns[i], max_insts);
        // A function that only calls call-free leaves becomes call-free once
        // those are inlined, so the block-splitting ceiling does not apply and
        // only the instruction budget does. Without this, helpers like Q32.32
        // `mul` (which calls `fabs` and `mul_sat`) are never inlined and every
        // multiply in a hot loop stays a real call: measured at 4.2 ns/edge,
        // 2.17x on `b_forward`.
        if (!eligible[i] and leaves[i]) {
            eligible[i] = fnInlineEligibleLeaf(&module.fns[i], INLINE_MAX_INSTS_SINGLE_CALL);
        }

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
    // Dominance and frontier sets use u128 bitsets. Large functions still
    // receive empty CFG metadata so callers safely fall back to local passes.
    if (n == 0 or n > 128) return;

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
    //
    // Only slots whose phi set is complete may reach the insertion phase below:
    // renameBlock() reads `promotable[]`, so a rollback (capacity overflow on a
    // later slot) has to withdraw the slot's pending phis here, not just flip the
    // flag. Leaving an unrenamed, operand-less phi behind made every block that
    // read the slot see a vreg that is never defined.
    var placed: [MAX_BLOCKS_PER_FN][32]u16 = undefined;
    var placed_cnt: [MAX_BLOCKS_PER_FN]u8 = .{0} ** MAX_BLOCKS_PER_FN;
    var pending: [MAX_BLOCKS_PER_FN][32]u16 = undefined;
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
                    pending[y][phi_cnt[y]] = @intCast(s);
                    phi_cnt[y] += 1;
                    if ((def_blocks[s] & (@as(u128, 1) << y)) == 0) {
                        work |= (@as(u128, 1) << y);
                    }
                }
            }
            if (!ok) break;
        }
        if (!ok) {
            // Drop this slot's pending phis; it stays memory resident.
            promotable[s] = false;
            for (0..f.block_count) |bi| {
                var k: u8 = 0;
                while (k < phi_cnt[bi]) {
                    if (pending[bi][k] == s) {
                        phi_cnt[bi] -= 1;
                        pending[bi][k] = pending[bi][phi_cnt[bi]];
                    } else {
                        k += 1;
                    }
                }
            }
            continue;
        }
        // This slot's phi set is complete: commit it.
        for (0..f.block_count) |bi| {
            for (0..phi_cnt[bi]) |k| {
                if (placed_cnt[bi] < placed[bi].len) {
                    placed[bi][placed_cnt[bi]] = pending[bi][k];
                    placed_cnt[bi] += 1;
                }
            }
            phi_cnt[bi] = 0;
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
        const pc = placed_cnt[bi];
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
                .slot = placed[bi][k], // temporarily tracks slot during renaming
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

/// True when `v` is already defined on entry to block `bi` (by an earlier
/// instruction of `bi`, or by a block that dominates it). Used to decide whether
/// a phi can be rewritten as a plain copy: the copy is only equivalent if the
/// value is live at that point on *every* path, which a phi guarantees for free.
fn definedBefore(f: *IRFn, bi: u16, ii: usize, v: u16) bool {
    const b = &f.blocks[bi];
    var k: usize = 0;
    while (k < ii) : (k += 1) {
        if (b.insts[k].dest == v) return true;
    }
    if (bi == 0) return false;
    // Cheap dominance test: walk up from every predecessor; if any path can reach
    // `bi` without passing a definition of v, the copy would read a stale value.
    // Conservatively answer "no" unless the definition is in a predecessor of
    // every incoming edge.
    var cfg: CFGInfo = undefined;
    buildCFGInfo(f, &cfg);
    var d: u16 = 0;
    while (d < f.block_count) : (d += 1) {
        if (d == bi) continue;
        var defines = false;
        for (f.blocks[d].insts[0..f.blocks[d].inst_count]) |inst| {
            if (inst.dest == v) {
                defines = true;
                break;
            }
        }
        if (defines and dominates(&cfg, d, bi)) return true;
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
                    } else if (definedBefore(f, @intCast(bi), ii, u)) {
                        // Replacing a phi by a copy is only sound when the value is
                        // already live at the phi's position: a phi is defined on
                        // *every* incoming edge, a copy only where it is executed.
                        // Collapsing a phi whose operand is defined further down
                        // (or only on some path) turns a merge into a stale read.
                        inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = u };
                    } else {
                        continue;
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

fn isSimpleSpeculativeOp(op: IROp) bool {
    return switch (op) {
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr, .neg, .copy, .const_int => true,
        else => false,
    };
}

fn isCmpOp(op: IROp) bool {
    return switch (op) {
        .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge,
        .ucmp_lt, .ucmp_le, .ucmp_gt, .ucmp_ge => true,
        else => false,
    };
}

/// Move a compare down to sit immediately before its only consumer.
///
/// x86 sets flags as a side effect, so codegen can only turn `cmp` + `select`
/// into a single `cmov` (and `cmp` + `cond_jump` into a `jcc`) when the two are
/// adjacent. IRGen emits the compare where the source expression ended, which is
/// often *above* the arithmetic that the select's arms depend on, so a perfectly
/// fusable pair arrives with an instruction wedged between them:
///
///   v12 = cmp_ge v9, v11      v12 = cmp_ge v9, v11
///   v16 = sub v9, v11    ->   v16 = sub v9, v11
///   v32 = select v12 ? ...    v32 = select v12 ? ...
///
/// Without this, the compare materialises a 0/1 value (setcc + movzbq) and the
/// select becomes test + cmov. Moving the compare down is safe when its result
/// is `cond` itself (false == 0, so a `cond_jump` falls through on the same
/// cases) and every instruction being crossed does not read `cond`.
fn sinkCompareToConsumer(f: *IRFn) bool {
    var changed = false;
    var bi: u16 = 0;
    while (bi < f.block_count) : (bi += 1) {
        var b = &f.blocks[bi];
        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            const inst = b.insts[ii];
            if (!isCmpOp(inst.op) or inst.dest == 0) continue;

            // Count uses inside this block and locate the last one.
            var use_idx: i16 = -1;
            var uses: u16 = 0;
            var ji: u16 = ii + 1;
            while (ji < b.inst_count) : (ji += 1) {
                const other = b.insts[ji];
                if (other.op == .select or other.op == .cond_jump) {
                    if (!instReadsVreg(other, inst.dest)) continue;
                    uses += 1;
                    use_idx = @intCast(ji);
                    continue;
                }
                if (instReadsVreg(other, inst.dest)) {
                    uses = 2;
                    break;
                }
            }

            if (uses != 1 or use_idx < 0) continue;
            const target_i: u16 = @intCast(use_idx);
            if (target_i == ii + 1) continue; // already adjacent
            const consumer = b.insts[target_i];
            // Only a compare that is consumed purely as a condition can move:
            // `select`/`cond_jump` test it against zero, so reordering the
            // producing compare below other instructions cannot change the
            // value that is observed.
            const cond = consumer.src1;
            if (cond != inst.dest) continue;
            if (consumer.op == .cond_jump and consumer.arg_count == 0) {
                // cond_jump treats `cond` as a boolean; safe.
            } else if (consumer.op != .select) continue;

            // Every instruction between the compare and its consumer must be
            // unable to observe the compare result, and the compare must not
            // read anything those instructions redefine.
            var k: u16 = ii + 1;
            var ok = true;
            while (k < target_i) : (k += 1) {
                const mid = b.insts[k];
                if (instReadsVreg(mid, inst.dest)) { ok = false; break; }
                if (mid.dest != 0 and (mid.dest == inst.src1 or mid.dest == inst.src2 or mid.dest == inst.dest)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;

            // Shift [ii+1 .. target_i) up by one and drop the compare in front
            // of the consumer.
            var m: u16 = ii;
            while (m < target_i) : (m += 1) {
                b.insts[m] = b.insts[m + 1];
            }
            b.insts[target_i - 1] = inst;
            changed = true;
            // Re-examine the instruction now occupying `ii`.
        }
    }
    return changed;
}

fn ifConversion(f: *IRFn) bool {
    var in_deg: [MAX_BLOCKS_PER_FN]u16 = .{0} ** MAX_BLOCKS_PER_FN;
    for (0..f.block_count) |bi| {
        const blk = &f.blocks[bi];
        if (blk.inst_count == 0) continue;
        const term = blk.insts[blk.inst_count - 1];
        if (term.op == .jump) {
            if (term.target_block < f.block_count) in_deg[term.target_block] += 1;
        } else if (term.op == .cond_jump) {
            if (term.target_block < f.block_count) in_deg[term.target_block] += 1;
            if (term.alt_block < f.block_count) in_deg[term.alt_block] += 1;
        }
    }

    var changed = false;
    for (0..f.block_count) |bi| {
        var b_cond = &f.blocks[bi];
        if (b_cond.inst_count == 0) continue;
        const term = b_cond.insts[b_cond.inst_count - 1];
        if (term.op != .cond_jump) continue;
        const b_then_idx = term.target_block;
        const b_else_idx = term.alt_block;
        if (b_then_idx == b_else_idx or b_then_idx == bi or b_else_idx == bi) continue;
        if (b_then_idx >= f.block_count or b_else_idx >= f.block_count) continue;
        if (in_deg[b_then_idx] != 1 or in_deg[b_else_idx] != 1) continue;

        const b_then = &f.blocks[b_then_idx];
        const b_else = &f.blocks[b_else_idx];
        if (b_then.inst_count == 0 or b_else.inst_count == 0) continue;
        if (b_then.inst_count > 3 or b_else.inst_count > 3) continue;

        const term_then = b_then.insts[b_then.inst_count - 1];
        const term_else = b_else.insts[b_else.inst_count - 1];
        if (term_then.op != .jump or term_else.op != .jump) continue;
        if (term_then.target_block != term_else.target_block) continue;
        const b_merge_idx = term_then.target_block;
        if (b_merge_idx >= f.block_count or b_merge_idx == bi) continue;

        var safe = true;
        for (0..b_then.inst_count - 1) |ii| {
            if (!isSimpleSpeculativeOp(b_then.insts[ii].op)) {
                safe = false;
                break;
            }
        }
        if (!safe) continue;
        for (0..b_else.inst_count - 1) |ii| {
            if (!isSimpleSpeculativeOp(b_else.insts[ii].op)) {
                safe = false;
                break;
            }
        }
        if (!safe) continue;

        const b_merge = &f.blocks[b_merge_idx];
        var phi_count: usize = 0;
        var valid_phis = true;
        for (0..b_merge.inst_count) |ii| {
            const minst = b_merge.insts[ii];
            if (minst.op != .phi) break;
            if (minst.arg_count != 2) {
                valid_phis = false;
                break;
            }
            const p0_b = minst.phi_blocks[0];
            const p1_b = minst.phi_blocks[1];
            if (!((p0_b == b_then_idx and p1_b == b_else_idx) or (p0_b == b_else_idx and p1_b == b_then_idx))) {
                valid_phis = false;
                break;
            }
            phi_count += 1;
        }
        if (!valid_phis or phi_count == 0) continue;

        const needed = (b_then.inst_count - 1) + (b_else.inst_count - 1) + phi_count + 1;
        if (b_cond.inst_count - 1 + needed >= MAX_INSTS_PER_BLOCK) continue;

        // Find insertion position so compare instructions stay adjacent to select
        var insert_pos: usize = b_cond.inst_count - 1;
        if (insert_pos >= 1 and b_cond.insts[insert_pos - 1].dest == term.src1 and isCmpOp(b_cond.insts[insert_pos - 1].op)) {
            insert_pos -= 1;
            if (insert_pos >= 1 and b_cond.insts[insert_pos - 1].dest == b_cond.insts[insert_pos].src1 and b_cond.insts[insert_pos - 1].op == .bit_and) {
                insert_pos -= 1;
            }
        }

        // Save tail instructions from insert_pos to end of b_cond (excluding cond_jump)
        var tail_insts: [16]IRInst = undefined;
        const tail_count = (b_cond.inst_count - 1) - insert_pos;
        if (tail_count > 16) continue;
        for (0..tail_count) |ti| {
            tail_insts[ti] = b_cond.insts[insert_pos + ti];
        }

        b_cond.inst_count = @intCast(insert_pos);

        // Move instructions from B_then and B_else before the compare
        for (0..b_then.inst_count - 1) |ii| {
            b_cond.insts[b_cond.inst_count] = b_then.insts[ii];
            b_cond.inst_count += 1;
        }

        for (0..b_else.inst_count - 1) |ii| {
            b_cond.insts[b_cond.inst_count] = b_else.insts[ii];
            b_cond.inst_count += 1;
        }

        // Restore tail (compare) instructions right before select
        for (0..tail_count) |ti| {
            b_cond.insts[b_cond.inst_count] = tail_insts[ti];
            b_cond.inst_count += 1;
        }

        for (0..phi_count) |ii| {
            const minst = b_merge.insts[ii];
            const p0_b = minst.phi_blocks[0];
            const true_v = if (p0_b == b_then_idx) minst.args[0] else minst.args[1];
            const false_v = if (p0_b == b_then_idx) minst.args[1] else minst.args[0];

            var sel_inst = IRInst{
                .op = .select,
                .dest = minst.dest,
                .src1 = term.src1,
                .src2 = true_v,
            };
            sel_inst.arg_count = 1;
            sel_inst.args[0] = false_v;
            b_cond.insts[b_cond.inst_count] = sel_inst;
            b_cond.inst_count += 1;
        }

        b_cond.insts[b_cond.inst_count] = .{ .op = .jump, .target_block = b_merge_idx };
        b_cond.inst_count += 1;

        var mi: u16 = 0;
        while (mi + phi_count < b_merge.inst_count) : (mi += 1) {
            b_merge.insts[mi] = b_merge.insts[mi + phi_count];
        }
        b_merge.inst_count -= @intCast(phi_count);

        b_then.inst_count = 0;
        b_else.inst_count = 0;

        changed = true;
    }
    return changed;
}

fn isCallToFn(module: *const IRModule, inst: IRInst, fi: u32) bool {
    if (inst.op != .call) return false;
    if (inst.callee_fn_idx >= 0 and @as(u32, @intCast(inst.callee_fn_idx)) == fi) return true;
    const f = &module.fns[fi];
    const s_callee = module.sourceFor(inst.fn_source_id, "");
    const s_decl = module.sourceFor(f.source_id, "");
    if (inst.fn_name_start + inst.fn_name_len <= s_callee.len and f.name_start + f.name_len <= s_decl.len) {
        const name_callee = s_callee[inst.fn_name_start..][0..inst.fn_name_len];
        const name_decl = s_decl[f.name_start..][0..f.name_len];
        return std.mem.eql(u8, name_callee, name_decl);
    }
    return false;
}

fn selfTailCallOpt(module: *IRModule, fi: u32) bool {
    var f = &module.fns[fi];
    if (f.param_count == 0 or f.param_count > 6 or f.block_count < 2 or f.block_count + 1 >= MAX_BLOCKS_PER_FN) return false;
    for (0..f.param_count) |pi| {
        if (f.param_slots[pi] == 0 or f.param_slots[pi] >= MAX_PROMOTED_SLOTS) return false;
        if (f.param_slots[pi] < f.local_addr_taken.len and f.local_addr_taken[f.param_slots[pi]]) return false;
    }

    const b0 = &f.blocks[0];
    // Check if B0 ends with cond_jump
    if (b0.inst_count < 2) return false;
    const b0_term = b0.insts[b0.inst_count - 1];
    if (b0_term.op != .cond_jump) return false;

    // Check if there is a self tail-call
    var has_tail_call = false;
    for (0..f.block_count) |bi| {
        const b = &f.blocks[bi];
        if (b.inst_count < 2) continue;
        for (0..b.inst_count - 1) |ii| {
            const inst = b.insts[ii];
            const next_inst = b.insts[ii + 1];
            if (inst.op == .call and next_inst.op == .ret and
                (next_inst.src1 == inst.dest or next_inst.src1 == 0) and
                inst.arg_count == f.param_count and
                isCallToFn(module, inst, fi))
            {
                has_tail_call = true;
                break;
            }
        }
        if (has_tail_call) break;
    }
    if (!has_tail_call) return false;

    // Allocate b_hdr to hold the loop header (all instructions of B0)
    const b_hdr_idx = f.block_count;
    f.block_count += 1;
    f.blocks[b_hdr_idx] = IRBlock{ .label = b_hdr_idx, .inst_count = 0 };
    var b_hdr = &f.blocks[b_hdr_idx];

    // Move all instructions of B0 into b_hdr
    b_hdr.inst_count = b0.inst_count;
    for (0..b0.inst_count) |ii| {
        b_hdr.insts[ii] = b0.insts[ii];
    }

    // B0 now ends with unconditional jump to b_hdr
    var b0_mut = &f.blocks[0];
    b0_mut.insts[0] = .{
        .op = .jump,
        .target_block = b_hdr_idx,
    };
    b0_mut.inst_count = 1;

    // Rewrite tail calls to store args to param slots and jump to b_hdr
    const n = f.param_count;
    for (0..b_hdr_idx) |bi| {
        var b = &f.blocks[bi];
        if (b.inst_count < 2) continue;
        var ii: usize = 0;
        while (ii < b.inst_count - 1) : (ii += 1) {
            const inst = b.insts[ii];
            const next_inst = b.insts[ii + 1];
            if (inst.op == .call and next_inst.op == .ret and
                (next_inst.src1 == inst.dest or next_inst.src1 == 0) and
                inst.arg_count == f.param_count and
                isCallToFn(module, inst, fi))
            {
                if (ii + n * 2 + 1 > b.insts.len or f.vreg_count + n >= MAX_TRACKED_VREGS) break;
                const tmp_base = f.vreg_count;
                f.vreg_count += @intCast(n);
                for (0..n) |pi| {
                    b.insts[ii + pi] = .{
                        .op = .copy,
                        .dest = @intCast(tmp_base + pi),
                        .src1 = inst.args[pi],
                    };
                }
                for (0..n) |pi| {
                    b.insts[ii + n + pi] = .{
                        .op = .store_local,
                        .slot = @intCast(f.param_slots[pi]),
                        .src1 = @intCast(tmp_base + pi),
                    };
                }
                b.insts[ii + n * 2] = .{
                    .op = .jump,
                    .target_block = b_hdr_idx,
                };
                b.inst_count = @intCast(ii + n * 2 + 1);
                break;
            }
        }
    }
    return true;
}

fn associativeTailRecursionOpt(module: *IRModule, fi: u32) bool {
    var f = &module.fns[fi];
    if (f.param_count != 1 or f.block_count != 3) return false;
    if (f.block_count + 1 >= MAX_BLOCKS_PER_FN or f.vreg_count + 8 >= MAX_TRACKED_VREGS) return false;

    // Check B0: cond_jump to B_base and B_rec
    const b0 = &f.blocks[0];
    if (b0.inst_count < 2) return false;
    const term0 = b0.insts[b0.inst_count - 1];
    if (term0.op != .cond_jump) return false;

    const b_target = term0.target_block;
    const b_alt = term0.alt_block;
    if (b_target >= f.block_count or b_alt >= f.block_count) return false;

    var b_base_idx: u16 = 0xFFFF;
    var b_rec_idx: u16 = 0xFFFF;
    if (f.blocks[b_target].inst_count > 0 and f.blocks[b_target].insts[f.blocks[b_target].inst_count - 1].op == .ret) {
        if (f.blocks[b_alt].inst_count > 0 and f.blocks[b_alt].insts[f.blocks[b_alt].inst_count - 1].op == .ret) {
            b_base_idx = b_target;
            b_rec_idx = b_alt;
        }
    }
    if (b_base_idx == 0xFFFF) return false;

    var param_v: u16 = 0;
    for (0..b0.inst_count) |ii| {
        if (b0.insts[ii].op == .load_local and b0.insts[ii].slot == f.param_slots[0]) {
            param_v = b0.insts[ii].dest;
            break;
        }
    }
    if (param_v == 0) return false;

    const b_base = &f.blocks[b_base_idx];
    const b_rec = &f.blocks[b_rec_idx];

    // Base block returns param_v (possibly through copies)
    const base_ret = b_base.insts[b_base.inst_count - 1];
    if (base_ret.op != .ret) return false;
    var ret_val = base_ret.src1;
    for (0..b_base.inst_count) |ii| {
        if (b_base.insts[ii].op == .copy and b_base.insts[ii].dest == ret_val) {
            ret_val = b_base.insts[ii].src1;
        }
    }
    if (ret_val != param_v) return false;

    // Check B_rec: look for two self-calls, an add of their results, and ret
    var c1_idx: ?usize = null;
    var c2_idx: ?usize = null;
    for (0..b_rec.inst_count - 1) |ii| {
        const inst = b_rec.insts[ii];
        if (inst.op == .call and isCallToFn(module, inst, fi) and inst.arg_count == 1) {
            if (c1_idx == null) {
                c1_idx = ii;
            } else if (c2_idx == null) {
                c2_idx = ii;
            }
        }
    }
    if (c1_idx == null or c2_idx == null) return false;

    const c1 = b_rec.insts[c1_idx.?];
    const c2 = b_rec.insts[c2_idx.?];
    const ret_inst = b_rec.insts[b_rec.inst_count - 1];
    if (ret_inst.op != .ret) return false;

    var add_idx: ?usize = null;
    for (0..b_rec.inst_count - 1) |ii| {
        const inst = b_rec.insts[ii];
        if (inst.op == .add and
            ((inst.src1 == c1.dest and inst.src2 == c2.dest) or (inst.src1 == c2.dest and inst.src2 == c1.dest)) and
            inst.dest == ret_inst.src1)
        {
            add_idx = ii;
            break;
        }
    }
    if (add_idx == null) return false;

    if (f.block_count + 2 >= MAX_BLOCKS_PER_FN or f.vreg_count + 8 >= MAX_TRACKED_VREGS) return false;

    // Allocate loop header block and loop exit block
    const b_loop_idx = f.block_count;
    const b_exit_idx = f.block_count + 1;
    f.block_count += 2;
    f.blocks[b_loop_idx] = IRBlock{ .label = b_loop_idx, .inst_count = 0 };
    f.blocks[b_exit_idx] = IRBlock{ .label = b_exit_idx, .inst_count = 0 };
    var b_loop = &f.blocks[b_loop_idx];
    var b_exit = &f.blocks[b_exit_idx];

    const acc_v = f.vreg_count;
    const cmp_v = f.vreg_count + 1;
    const exit_res_v = f.vreg_count + 2;
    const const_one_v = f.vreg_count + 3;
    f.vreg_count += 4;

    // Track any copy aliases of param_v in b_rec
    var is_param_alias: [MAX_TRACKED_VREGS]bool = .{false} ** MAX_TRACKED_VREGS;
    is_param_alias[param_v] = true;
    for (0..b_rec.inst_count) |ii| {
        if (b_rec.insts[ii].op == .copy and is_param_alias[b_rec.insts[ii].src1] and b_rec.insts[ii].dest < MAX_TRACKED_VREGS) {
            is_param_alias[b_rec.insts[ii].dest] = true;
        }
    }

    // Populate b_loop: call 1, accumulator update, decrement param_v by 2, compare and branch
    b_loop.inst_count = 0;
    for (0..c2_idx.?) |ii| {
        var inst = b_rec.insts[ii];
        if (inst.op == .copy and is_param_alias[inst.dest]) continue;
        if (inst.src1 < MAX_TRACKED_VREGS and is_param_alias[inst.src1]) inst.src1 = param_v;
        if (inst.src2 < MAX_TRACKED_VREGS and is_param_alias[inst.src2]) inst.src2 = param_v;
        if (inst.dest == c2.args[0]) inst.dest = param_v;
        b_loop.insts[b_loop.inst_count] = inst;
        b_loop.inst_count += 1;
    }

    b_loop.insts[b_loop.inst_count] = .{ .op = .add, .dest = acc_v, .src1 = acc_v, .src2 = c1.dest };
    b_loop.inst_count += 1;
    b_loop.insts[b_loop.inst_count] = .{ .op = .const_int, .dest = const_one_v, .imm = 1 };
    b_loop.inst_count += 1;
    b_loop.insts[b_loop.inst_count] = .{ .op = .cmp_le, .dest = cmp_v, .src1 = param_v, .src2 = const_one_v };
    b_loop.inst_count += 1;
    b_loop.insts[b_loop.inst_count] = .{ .op = .cond_jump, .src1 = cmp_v, .target_block = b_exit_idx, .alt_block = b_loop_idx };
    b_loop.inst_count += 1;

    // Rewrite b_rec: init acc=0, jump b_loop
    b_rec.inst_count = 0;
    b_rec.insts[0] = .{ .op = .const_int, .dest = acc_v, .imm = 0 };
    b_rec.insts[1] = .{ .op = .jump, .target_block = b_loop_idx };
    b_rec.inst_count = 2;

    // Populate b_exit: return acc_v + param_v
    b_exit.inst_count = 0;
    b_exit.insts[0] = .{ .op = .add, .dest = exit_res_v, .src1 = acc_v, .src2 = param_v };
    b_exit.insts[1] = .{ .op = .ret, .src1 = exit_res_v };
    b_exit.inst_count = 2;

    return true;
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


/// Bounded-table copy propagation for single-block functions. Equivalent to
/// `globalCopyPropagate` when a function has one block and at most 24
/// instructions: every vreg is still required to have exactly one definition
/// module-wide (a one-block function), so `copy_of` cannot need more than 24
/// entries and resolving chains within them is complete.
var in_small_fallback: bool = false;

fn globalCopyPropagateSmall(f: *IRFn) bool {
    if (f.block_count != 1) return false;
    const b = &f.blocks[0];
    if (b.inst_count == 0) return false;

    var dests: [24]u16 = undefined;
    var n: usize = 0;
    for (0..b.inst_count) |ii| {
        const d = b.insts[ii].dest;
        if (d > 0 and d < MAX_TRACKED_VREGS) {
            for (dests[0..n]) |seen| {
                if (seen == d) { n = 25; break; } // duplicate def: bail out
            }
            if (n >= 24) {
                    in_small_fallback = true;
                    defer in_small_fallback = false;
                    return globalCopyPropagate(f);
                }
            dests[n] = d;
            n += 1;
        }
    }
    // Every vreg defined here is defined exactly once (one block, unique dests),
    // which is what the general pass spends a full 4096-entry def-count scan on.
    var src: [24]u16 = .{0} ** 24;
    for (0..b.inst_count) |ii| {
        const inst = b.insts[ii];
        if (inst.op != .copy or inst.dest == 0 or inst.src1 == 0 or inst.dest == inst.src1) continue;
        for (dests[0..n], 0..) |d, k| {
            if (d == inst.dest) {
                src[k] = inst.src1;
                break;
            }
        }
    }

    var changed = false;
    for (0..b.inst_count) |ii| {
        const inst = &f.blocks[0].insts[ii];
        if (inst.src1 > 0) {
            var cur = inst.src1;
            var steps: u32 = 0;
            while (steps < 16) : (steps += 1) {
                var next: u16 = 0;
                for (dests[0..n], 0..) |d, k| {
                    if (d == cur and src[k] != 0 and src[k] != cur) { next = src[k]; break; }
                }
                if (next == 0) break;
                cur = next;
            }
            if (cur != inst.src1) { inst.src1 = cur; changed = true; }
        }
        if (inst.src2 > 0) {
            var cur = inst.src2;
            var steps: u32 = 0;
            while (steps < 16) : (steps += 1) {
                var next: u16 = 0;
                for (dests[0..n], 0..) |d, k| {
                    if (d == cur and src[k] != 0 and src[k] != cur) { next = src[k]; break; }
                }
                if (next == 0) break;
                cur = next;
            }
            if (cur != inst.src2) { inst.src2 = cur; changed = true; }
        }
        var ai: usize = 0;
        while (ai < inst.arg_count and ai < inst.args.len) : (ai += 1) {
            if (inst.args[ai] > 0) {
                var cur = inst.args[ai];
                var steps: u32 = 0;
                while (steps < 16) : (steps += 1) {
                    var next: u16 = 0;
                    for (dests[0..n], 0..) |d, k| {
                        if (d == cur and src[k] != 0 and src[k] != cur) { next = src[k]; break; }
                    }
                    if (next == 0) break;
                    cur = next;
                }
                if (cur != inst.args[ai]) { inst.args[ai] = cur; changed = true; }
            }
        }
    }
    return changed;
}

fn globalCopyPropagate(f: *IRFn) bool {
    // Fast path for the overwhelmingly common tiny function (a helper that is a
    // few instructions in a single block, where there is at most one candidate
    // copy per instruction). At -O2 this pass runs four times per function, so on
    // a module of many small functions the fixed cost of clearing and scanning the
    // 4096-entry tables dominated the actual work.
    if (!in_small_fallback and f.block_count == 1 and f.blocks[0].inst_count <= 24) {
        return globalCopyPropagateSmall(f);
    }

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
            // A phi operand is not a plain use of the value: it names the value
            // that is live on one *specific* incoming edge. Rewriting it to the
            // copy's source drops the "defined on this edge" guarantee and makes
            // the merge read whatever the source happens to hold - the -O2 bug
            // where a phi {16, 18} collapsed to {16, 9} and read a stale v9.
            if (b.insts[ii].op == .phi) {
                var bad = false;
                for (b.insts[ii].args[0..b.insts[ii].arg_count]) |arg| {
                    if (arg > 0 and arg < MAX_TRACKED_VREGS and copy_of[arg] != 0) bad = true;
                }
                if (bad) continue;
            }
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
        .shl => if (bv >= 0 and bv < 64) @as(i64, @bitCast(ua << @as(u6, @intCast(bv)))) else null,
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
    // `def_inst` is stamped with the owning block instead of being cleared to
    // null: only the current block's definitions are observable (the consumers
    // already re-check `b.insts[dii].dest == inst.src1`), and a stale index that
    // points into a *previous* block would be read out of the wrong array. A
    // generation stamp keeps the "cleared every block" semantics while touching
    // only the entries this block defined.
    var def_inst: [MAX_TRACKED_VREGS]u16 = undefined;
    var def_gen: [MAX_TRACKED_VREGS]u16 = undefined;
    var expr_table: [128]ExprKey = undefined;
    // Vregs whose `const_known` entry is currently true, so the next block can
    // clear them without scanning the whole table.
    var dirty: [MAX_INSTS_PER_BLOCK * 2]u16 = undefined;
    var dirty_n: usize = 0;

    var bi: u16 = 0;
    while (bi < f.block_count) : (bi += 1) {
        var b = &f.blocks[bi];
        const cur_gen: u16 = bi;
        // Equivalent to zeroing both 4096-entry tables at every block boundary,
        // at a cost proportional to what the previous block actually wrote:
        // `dirty` holds exactly the vregs whose `const_known` is true, and
        // `def_gen` marks which block owns each `def_inst` entry. Zeroing the
        // full tables cost roughly 600 us per module at -O2 (1500 blocks x 8 KiB).
        for (dirty[0..dirty_n]) |d| const_known[d] = false;
        dirty_n = 0;
        var expr_count: usize = 0;

        var ii: u16 = 0;
        while (ii < b.inst_count) : (ii += 1) {
            var inst = &b.insts[ii];

            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                const_known[inst.dest] = false;
                def_gen[inst.dest] = cur_gen;
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
                        if (dirty_n < dirty.len) { dirty[dirty_n] = inst.dest; dirty_n += 1; }
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
                // select with both arms equal is just that value: `select c ? x : x`
                // -> x. ifConversion turns every if/else on a *single* variable
                // into one select per assigned local, so a diamond that assigns
                // one variable in each arm (the common recurrence case, e.g.
                // `a = b` in both arms of the Fibonacci loop) produces a select
                // whose arms are identical. Leaving it in place also keeps the
                // compare alive, and a compare with two users is exactly what
                // stops codegen from fusing it into `cmov`/`jcc` -- one dead
                // select made the whole inner loop run un-fused.
                .select => {
                    const true_v = inst.src2;
                    const false_v = if (inst.arg_count > 0) inst.args[0] else 0;
                    if (true_v == false_v) {
                        inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = true_v };
                        changed = true;
                        continue;
                    }
                    // A known condition folds to the taken arm.
                    if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and const_known[inst.src1]) {
                        inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = if (const_val[inst.src1] != 0) true_v else false_v };
                        changed = true;
                        continue;
                    }
                },
                .copy => {
                    if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and const_known[inst.src1]) {
                        const val = const_val[inst.src1];
                        inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = val };
                        if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                            const_known[inst.dest] = true;
                        if (dirty_n < dirty.len) { dirty[dirty_n] = inst.dest; dirty_n += 1; }
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
                        if (dirty_n < dirty.len) { dirty[dirty_n] = inst.dest; dirty_n += 1; }
                            const_val[inst.dest] = res;
                        }
                        changed = true;
                    } else if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and def_gen[inst.src1] == cur_gen and (inst.op == .neg or inst.op == .bit_not)) {
                        const dii = def_inst[inst.src1];
                        if (b.insts[dii].dest == inst.src1 and b.insts[dii].op == inst.op) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = b.insts[dii].src1 };
                            changed = true;
                        }
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
                    var s1_k = inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and const_known[inst.src1];
                    var s2_k = inst.src2 > 0 and inst.src2 < MAX_TRACKED_VREGS and const_known[inst.src2];

                    if (s1_k and s2_k) {
                        if (foldBinaryConsts(inst.op, const_val[inst.src1], const_val[inst.src2])) |res| {
                            inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = res };
                            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                                const_known[inst.dest] = true;
                        if (dirty_n < dirty.len) { dirty[dirty_n] = inst.dest; dirty_n += 1; }
                                const_val[inst.dest] = res;
                            }
                            changed = true;
                            continue;
                        }
                    }

                    // Canonicalize constant to src2 for commutative and relational ops
                    if (s1_k and !s2_k) {
                        if (isCommutative(inst.op)) {
                            const tmp = inst.src1;
                            inst.src1 = inst.src2;
                            inst.src2 = tmp;
                            s1_k = false;
                            s2_k = true;
                            changed = true;
                        } else {
                            const swapped_cmp: ?IROp = switch (inst.op) {
                                .cmp_lt => .cmp_gt,
                                .cmp_le => .cmp_ge,
                                .cmp_gt => .cmp_lt,
                                .cmp_ge => .cmp_le,
                                .ucmp_lt => .ucmp_gt,
                                .ucmp_le => .ucmp_ge,
                                .ucmp_gt => .ucmp_lt,
                                .ucmp_ge => .ucmp_le,
                                else => null,
                            };
                            if (swapped_cmp) |new_op| {
                                inst.op = new_op;
                                const tmp = inst.src1;
                                inst.src1 = inst.src2;
                                inst.src2 = tmp;
                                s1_k = false;
                                s2_k = true;
                                changed = true;
                            }
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
                        if (dirty_n < dirty.len) { dirty[dirty_n] = inst.dest; dirty_n += 1; }
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
                        if (dirty_n < dirty.len) { dirty[dirty_n] = inst.dest; dirty_n += 1; }
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

                        // Associative constant reassociation: (x OP c1) OP c2 -> x OP (c1 OP c2)
                        if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and def_gen[inst.src1] == cur_gen) {
                            const dii = def_inst[inst.src1];
                            if (dii < b.inst_count and b.insts[dii].dest == inst.src1) {
                                const prev = b.insts[dii];
                                if (prev.src2 > 0 and prev.src2 < MAX_TRACKED_VREGS and const_known[prev.src2]) {
                                    const c1 = const_val[prev.src2];
                                    const c2 = bv;
                                    var folded_c: ?i64 = null;
                                    var new_op: ?IROp = null;

                                    if (inst.op == .add and prev.op == .add) {
                                        folded_c = c1 +% c2;
                                        new_op = .add;
                                    } else if (inst.op == .add and prev.op == .sub) {
                                        folded_c = c2 -% c1;
                                        new_op = .add;
                                    } else if (inst.op == .sub and prev.op == .add) {
                                        folded_c = c1 -% c2;
                                        new_op = .add;
                                    } else if (inst.op == .sub and prev.op == .sub) {
                                        folded_c = c1 +% c2;
                                        new_op = .sub;
                                    } else if (inst.op == .mul and prev.op == .mul) {
                                        folded_c = c1 *% c2;
                                        new_op = .mul;
                                    } else if (inst.op == .bit_and and prev.op == .bit_and) {
                                        folded_c = c1 & c2;
                                        new_op = .bit_and;
                                    } else if (inst.op == .bit_or and prev.op == .bit_or) {
                                        folded_c = c1 | c2;
                                        new_op = .bit_or;
                                    } else if (inst.op == .bit_xor and prev.op == .bit_xor) {
                                        folded_c = c1 ^ c2;
                                        new_op = .bit_xor;
                                    } else if (inst.op == .shl and prev.op == .shl and c1 >= 0 and c2 >= 0 and c1 + c2 < 64) {
                                        folded_c = c1 + c2;
                                        new_op = .shl;
                                    } else if (inst.op == .shr and prev.op == .shr and c1 >= 0 and c2 >= 0 and c1 + c2 < 64) {
                                        folded_c = c1 + c2;
                                        new_op = .shr;
                                    } else if (inst.op == .ushr and prev.op == .ushr and c1 >= 0 and c2 >= 0 and c1 + c2 < 64) {
                                        folded_c = c1 + c2;
                                        new_op = .ushr;
                                    }

                                    if (folded_c) |fc| {
                                        if (ensureBlockConst(f, b, &expr_table, &expr_count, &const_known, &const_val, &ii, fc)) |c_vreg| {
                                            inst = &b.insts[ii];
                                            inst.op = new_op.?;
                                            inst.src1 = prev.src1;
                                            inst.src2 = c_vreg;
                                            changed = true;
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if (s1_k) {
                        const av = const_val[inst.src1];
                        if (inst.op == .sub and av == 0) {
                            inst.* = .{ .op = .neg, .dest = inst.dest, .src1 = inst.src2 };
                            changed = true;
                            continue;
                        }
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
                        if (dirty_n < dirty.len) { dirty[dirty_n] = inst.dest; dirty_n += 1; }
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
                        if (dirty_n < dirty.len) { dirty[dirty_n] = inst.dest; dirty_n += 1; }
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
                        if (inst.op == .bit_and or inst.op == .bit_or) {
                            inst.* = .{ .op = .copy, .dest = inst.dest, .src1 = inst.src1 };
                            changed = true;
                            continue;
                        }
                        const self_res: ?i64 = switch (inst.op) {
                            .sub, .bit_xor, .cmp_ne, .cmp_lt, .cmp_gt, .ucmp_lt, .ucmp_gt => 0,
                            .cmp_eq, .cmp_le, .cmp_ge, .ucmp_le, .ucmp_ge => 1,
                            else => null,
                        };
                        if (self_res) |sr| {
                            inst.* = .{ .op = .const_int, .dest = inst.dest, .imm = sr };
                            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                                const_known[inst.dest] = true;
                        if (dirty_n < dirty.len) { dirty[dirty_n] = inst.dest; dirty_n += 1; }
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

            if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS) {
                def_inst[inst.dest] = ii;
                def_gen[inst.dest] = cur_gen;
            }
        }
    }

    return changed;
}

/// Replace reads of a `copy` destination with the copy source.
///
/// Out-of-SSA code the register allocator sees is often a chain of trivial
/// copies (`v25 = copy v20`) because destruction has to materialise phi edges.
/// Two-address instruction selection and the constant-divisor lowering in code
/// generation both look at an operand's defining instruction, so a copy in the
/// way hides a constant divisor from them: `div v24, v25` missed the
/// magic-number path and emitted a full idiv plus guards, where `div v24, v20`
/// lowers to a multiply (this is the whole -O1 mandelbrot regression).
///
/// The rewrite is only done when the destination has exactly one definition in
/// the function, which is the ordinary non-SSA shape: with a single def, every
/// read of the destination observes the copy source's value, so replacing the
/// read cannot change behaviour.
fn propagateTrivialCopies(f: *IRFn) bool {
    var def_cnt: [MAX_TRACKED_VREGS]u16 = undefined;
    isSingleDefVregTable(f, &def_cnt);
    var copy_src: [MAX_TRACKED_VREGS]u16 = .{0} ** MAX_TRACKED_VREGS;

    for (0..f.block_count) |bi| {
        const b = &f.blocks[bi];
        for (0..b.inst_count) |ii| {
            const inst = b.insts[ii];
            if (inst.op != .copy or inst.dest == 0 or inst.dest >= MAX_TRACKED_VREGS) continue;
            if (inst.src1 == 0 or inst.src1 >= MAX_TRACKED_VREGS or inst.src1 == inst.dest) continue;
            if (def_cnt[inst.dest] != 1) continue;
            copy_src[inst.dest] = inst.src1;
        }
    }

    // Follow chains (bounded so a malformed cycle cannot hang the pass).
    for (0..MAX_TRACKED_VREGS) |v| {
        if (copy_src[v] == 0) continue;
        var cur = copy_src[v];
        var steps: u8 = 0;
        while (cur < MAX_TRACKED_VREGS and copy_src[cur] != 0 and steps < 8) : (steps += 1) {
            cur = copy_src[cur];
        }
        copy_src[v] = cur;
    }

    var changed = false;
    for (0..f.block_count) |bi| {
        const b = &f.blocks[bi];
        for (0..b.inst_count) |ii| {
            const inst = &b.insts[ii];
            if (inst.src1 > 0 and inst.src1 < MAX_TRACKED_VREGS and copy_src[inst.src1] != 0) {
                inst.src1 = copy_src[inst.src1];
                changed = true;
            }
            if (inst.src2 > 0 and inst.src2 < MAX_TRACKED_VREGS and copy_src[inst.src2] != 0) {
                inst.src2 = copy_src[inst.src2];
                changed = true;
            }
            for (0..@min(inst.arg_count, inst.args.len)) |ai| {
                const a = inst.args[ai];
                if (a > 0 and a < MAX_TRACKED_VREGS and copy_src[a] != 0) {
                    inst.args[ai] = copy_src[a];
                    changed = true;
                }
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
    // Liveness of every instruction slot. A monotonic generation stamp replaces a
    // per-call `.{false} ** (MAX_BLOCKS_PER_FN * MAX_INSTS_PER_BLOCK)` clear (73 KiB
    // per call, and deadCodeElimination runs a dozen times per function at -O2).
    // `gen` is bumped once per call; a slot is live exactly when it was stamped.
    const live_gen = struct {
        var counter: u32 = 0;
    };
    live_gen.counter +%= 1;
    if (live_gen.counter == 0) live_gen.counter = 1; // 0 means "never stamped"
    const cur_gen: u32 = live_gen.counter;
    var inst_live: [MAX_BLOCKS_PER_FN][MAX_INSTS_PER_BLOCK]u32 = undefined;

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
                inst_live[bi][ii] = cur_gen;
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
                if (inst_live[bi][ii] == cur_gen) continue;
                const inst = b.insts[ii];
                if (inst.op == .nop) continue;
                if (inst.op == .store_local) continue;
                if (inst.dest > 0 and inst.dest < MAX_TRACKED_VREGS and vreg_live[inst.dest]) {
                    inst_live[bi][ii] = cur_gen;
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
            if (inst_live[bi][ii] != cur_gen) {
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
            // Renaming the definition to `dst` turns it into a second definition
            // of `dst` inside this block. That is only harmless when `dst` has no
            // readers between the definition and the copy: otherwise those reads
            // now see the wrong value. It also needs `dst` not to be written
            // twice, or the block has two definitions of one name.
            if (safe and def_cnt[dst] != 1) safe = false;
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
            if (inst0.op == .nop or inst0.op == .phi or inst0.op == .const_int or inst0.op.isTerminator()) continue;
            if (inst0.dest == 0 or inst0.dest >= MAX_TRACKED_VREGS) continue;
            const tmp = inst0.dest;
            if (def_cnt[tmp] != 1 or use_cnt[tmp] != 1) continue;

            const inst1 = b.insts[i + 1];
            if (inst1.src1 != tmp and inst1.src2 != tmp and i + 2 < b.inst_count) {
                const mid = inst1;
                const chk2 = b.insts[i + 2];
                if ((chk2.src1 == tmp or chk2.src2 == tmp) and isPureHeaderOp(mid.op) and
                    mid.dest != tmp and mid.dest != 0 and
                    inst0.src1 != mid.dest and inst0.src2 != mid.dest)
                {
                    b.insts[i] = mid;
                    b.insts[i + 1] = inst0;
                    changed = true;
                    continue;
                }
            }
            if (inst1.dest == 0 or inst1.dest == tmp) continue;
            const dst = inst1.dest;
            const is_two_addr = switch (inst1.op) {
                .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr, .@"mod" => true,
                else => false,
            };
            if (!is_two_addr) continue;
            // Writing inst0's result straight into `dst` is only valid when
            // nothing between inst0 and inst1 still needs `dst`: it is
            // overwritten early here, so those instructions would read the next
            // iteration's value. Skipping this check rewrote
            //   x = x + 1; y = x + 1; x = y + 1
            // into
            //   x = x + 1; y = x + 1; x = x + 1
            // which made an unrolled loop advance one step per repetition.
            if (def_cnt[dst] != 1) continue;
            var dst_read_between = false;
            for (i + 2..b.inst_count) |between| {
                if (instReadsVreg(b.insts[between], dst) or b.insts[between].dest == dst) {
                    dst_read_between = true;
                    break;
                }
            }
            if (dst_read_between) continue;

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

        // Pass C: accumulator chain ending in dst = (tmp OP imm) OP2 tmp -> rewrite to use dst as accumulator throughout
        var ci_idx: u16 = 0;
        while (ci_idx + 1 < b.inst_count) : (ci_idx += 1) {
            const inst_shr = b.insts[ci_idx];
            const inst_xor = b.insts[ci_idx + 1];
            const is_shift = (inst_shr.op == .shr or inst_shr.op == .ushr or inst_shr.op == .shl);
            if (!is_shift) continue;
            const is_accum = (inst_xor.op == .bit_xor or inst_xor.op == .bit_or or inst_xor.op == .add);
            if (!is_accum) continue;
            if (inst_shr.dest == 0 or inst_shr.dest >= MAX_TRACKED_VREGS) continue;
            if (inst_shr.src1 == 0 or inst_shr.src1 >= MAX_TRACKED_VREGS) continue;
            const dst = inst_shr.dest;
            const tmp = inst_shr.src1;
            if (dst == tmp or inst_xor.dest != dst) continue;
            const matches_args = (inst_xor.src1 == dst and inst_xor.src2 == tmp) or
                (inst_xor.src2 == dst and inst_xor.src1 == tmp);
            if (!matches_args) continue;

            // Find first def of tmp in this block walking backwards from ci_idx
            var def_first: ?u16 = null;
            var chain_k: i32 = @as(i32, @intCast(ci_idx)) - 1;
            while (chain_k >= 0) : (chain_k -= 1) {
                const uk: u16 = @intCast(chain_k);
                if (b.insts[uk].dest == tmp) {
                    def_first = uk;
                } else if (def_first != null) {
                    // Reached an instruction before the contiguous defs of tmp
                    break;
                }
            }
            const df = def_first orelse continue;

            // Verify first instruction in chain reads dst, and dst is not modified between df+1 and ci_idx
            const first_inst = b.insts[df];
            const reads_dst = (first_inst.src1 == dst or first_inst.src2 == dst);
            if (!reads_dst) continue;
            if (first_inst.src2 == dst and first_inst.src1 != dst) {
                const is_comm = (first_inst.op == .add or first_inst.op == .mul or first_inst.op == .bit_and or
                    first_inst.op == .bit_or or first_inst.op == .bit_xor);
                if (!is_comm) continue;
            }

            var dst_safe = true;
            for (df + 1..ci_idx) |chk_k| {
                const ik = b.insts[chk_k];
                if (ik.dest == dst or instReadsVreg(ik, dst)) {
                    dst_safe = false;
                    break;
                }
            }
            if (!dst_safe) continue;

            if (f.vreg_count >= MAX_TRACKED_VREGS - 2) continue;
            const fresh_v = f.vreg_count;
            f.vreg_count += 1;

            // Rewrite first instruction
            if (b.insts[df].src2 == dst and b.insts[df].src1 != dst) {
                b.insts[df].src2 = b.insts[df].src1;
                b.insts[df].src1 = dst;
            }
            b.insts[df].dest = dst;

            // Rewrite intermediate instructions
            for (df + 1..ci_idx) |rk| {
                if (b.insts[rk].dest == tmp) b.insts[rk].dest = dst;
                if (b.insts[rk].src1 == tmp) b.insts[rk].src1 = dst;
                if (b.insts[rk].src2 == tmp) b.insts[rk].src2 = dst;
            }

            // Rewrite shift and xor instructions
            b.insts[ci_idx].dest = fresh_v;
            b.insts[ci_idx].src1 = dst;
            b.insts[ci_idx + 1].dest = dst;
            b.insts[ci_idx + 1].src1 = dst;
            b.insts[ci_idx + 1].src2 = fresh_v;
            changed = true;
        }

        // Pass D: XOR-shift reassociation
        //   [k]   tmp_s = (shr|ushr|shl) x, shift
        //   [k+1] tmp_x = bit_xor (tmp_s, x)
        //   ... optional mid_inst defining y
        //   [m]   dst = bit_xor (tmp_x, y)
        // -> (y ^ (x ^ (x >> shift))) == ((x >> shift) ^ (y ^ x))
        var di_idx: u16 = 0;
        while (di_idx + 2 < b.inst_count) : (di_idx += 1) {
            const inst_shr = b.insts[di_idx];
            const is_shift = (inst_shr.op == .shr or inst_shr.op == .ushr or inst_shr.op == .shl);
            if (!is_shift) continue;
            if (inst_shr.dest == 0 or inst_shr.dest >= MAX_TRACKED_VREGS) continue;
            if (inst_shr.src1 == 0 or inst_shr.src1 >= MAX_TRACKED_VREGS) continue;
            const tmp_s = inst_shr.dest;
            const x = inst_shr.src1;
            const shift = inst_shr.src2;
            if (tmp_s == x) continue;

            const inst_xor1 = b.insts[di_idx + 1];
            if (inst_xor1.op != .bit_xor) continue;
            if (inst_xor1.dest == 0 or inst_xor1.dest >= MAX_TRACKED_VREGS) continue;
            const tmp_x = inst_xor1.dest;
            if (tmp_x == x) continue;
            const matches1 = (inst_xor1.src1 == tmp_s and inst_xor1.src2 == x) or
                (inst_xor1.src2 == tmp_s and inst_xor1.src1 == x);
            if (!matches1) continue;

            const exp_defs: u16 = if (tmp_x == tmp_s) 2 else 1;
            const exp_uses: u16 = if (tmp_x == tmp_s) 2 else 1;
            if (def_cnt[tmp_s] != exp_defs or use_cnt[tmp_s] != exp_uses) continue;
            if (def_cnt[tmp_x] != exp_defs or use_cnt[tmp_x] != exp_uses) continue;

            // Search for inst_xor2 at m in di_idx + 2 .. min(di_idx + 4, b.inst_count)
            var m_opt: ?u16 = null;
            var y_opt: ?u16 = null;
            var search_m: u16 = di_idx + 2;
            const search_limit = @min(di_idx + 4, b.inst_count);
            while (search_m < search_limit) : (search_m += 1) {
                const im = b.insts[search_m];
                if (im.op == .bit_xor) {
                    if (im.src1 == tmp_x and im.src2 != tmp_x and im.src2 != tmp_s) {
                        m_opt = search_m;
                        y_opt = im.src2;
                        break;
                    } else if (im.src2 == tmp_x and im.src1 != tmp_x and im.src1 != tmp_s) {
                        m_opt = search_m;
                        y_opt = im.src1;
                        break;
                    }
                }
            }
            const m = m_opt orelse continue;
            const y = y_opt orelse continue;
            if (y == 0 or y >= MAX_TRACKED_VREGS or y == x) continue;
            const dst = b.insts[m].dest;
            if (dst == 0 or dst >= MAX_TRACKED_VREGS) continue;

            // Verify x is not modified between di_idx and m
            var x_safe = true;
            for (di_idx..m + 1) |chk_k| {
                if (b.insts[chk_k].dest == x) {
                    x_safe = false;
                    break;
                }
            }
            if (!x_safe) continue;
            if (f.vreg_count >= MAX_TRACKED_VREGS - 4) continue;

            if (m == di_idx + 2) {
                const fresh_s = f.vreg_count;
                f.vreg_count += 1;
                b.insts[di_idx] = .{ .op = .bit_xor, .dest = tmp_x, .src1 = y, .src2 = x };
                b.insts[di_idx + 1] = .{ .op = inst_shr.op, .dest = fresh_s, .src1 = x, .src2 = shift };
                b.insts[di_idx + 2] = .{ .op = .bit_xor, .dest = dst, .src1 = fresh_s, .src2 = tmp_x };
                def_cnt[tmp_x] = 1;
                use_cnt[tmp_x] = 1;
                if (fresh_s < MAX_TRACKED_VREGS) {
                    def_cnt[fresh_s] = 1;
                    use_cnt[fresh_s] = 1;
                }
                changed = true;
            } else if (m == di_idx + 3) {
                const mid_inst = b.insts[di_idx + 2];
                if (mid_inst.dest != y) continue;
                if (!isPureHeaderOp(mid_inst.op)) continue;
                if (mid_inst.dest == x or mid_inst.dest == shift) continue;
                if (mid_inst.src1 == tmp_s or mid_inst.src1 == tmp_x or
                    mid_inst.src2 == tmp_s or mid_inst.src2 == tmp_x) continue;

                const fresh_s = f.vreg_count;
                f.vreg_count += 1;
                b.insts[di_idx] = mid_inst;
                b.insts[di_idx + 1] = .{ .op = .bit_xor, .dest = tmp_x, .src1 = y, .src2 = x };
                b.insts[di_idx + 2] = .{ .op = inst_shr.op, .dest = fresh_s, .src1 = x, .src2 = shift };
                b.insts[di_idx + 3] = .{ .op = .bit_xor, .dest = dst, .src1 = fresh_s, .src2 = tmp_x };
                def_cnt[tmp_x] = 1;
                use_cnt[tmp_x] = 1;
                if (fresh_s < MAX_TRACKED_VREGS) {
                    def_cnt[fresh_s] = 1;
                    use_cnt[fresh_s] = 1;
                }
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
        .shl,
        .shr,
        .ushr,
        // `mod`/`umod` BURADA DEĞİL. Bunlar `isPureHeaderOp`'un amaçladığı
        // "koşul bloğunun ucuz önsözü" değil, gerçek iş yapan bölmelerdir.
        // Listeye girdiklerinde loop rotasyonu onları koşul bloğuna taşıyor
        // ve aynı vreg'i yeniden tanımlatarak gövdedeki okumayı bozuyordu:
        //   let t = x % y; x = y; y = t
        // -O2'de `mod` gövde-öncesine taşınıp `gcd(24,18)` 6 yerine 18
        // dönüyordu. Ölçüldü; -O1 doğruydu.
        .select,
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
    if (f.vreg_count + 128 >= MAX_TRACKED_VREGS) return false;

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
        if ((cmp_inst.op != .cmp_lt and cmp_inst.op != .cmp_le) or cmp_inst.dest == 0 or cmp_inst.dest != term.src1) continue;
        const cmp_op = cmp_inst.op;
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
        var const_one: u16 = 0;
        if (iv_inst.op == .add) {
            if (iv_inst.src1 == iv and iv_inst.src2 < MAX_TRACKED_VREGS and const_known[iv_inst.src2] and const_val[iv_inst.src2] == 1) {
                step_ok = true;
                const_one = iv_inst.src2;
            } else if (iv_inst.src2 == iv and iv_inst.src1 < MAX_TRACKED_VREGS and const_known[iv_inst.src1] and const_val[iv_inst.src1] == 1) {
                step_ok = true;
                const_one = iv_inst.src1;
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
        const uf_v = f.vreg_count + 7;
        f.vreg_count += 8;

        const unroll_factor: u16 = if (body_len <= 6 and f.vreg_count + body_len * 8 + 32 < MAX_TRACKED_VREGS) 8 else 4;
        const unroll_m: i64 = @as(i64, unroll_factor) - 1;

        f.blocks[b_chk_min].inst_count = 3;
        f.blocks[b_chk_min].insts[0] = .{ .op = .const_int, .dest = c_min_v, .imm = -9000000000000000000 };
        f.blocks[b_chk_min].insts[1] = .{ .op = .cmp_ge, .dest = ok_min_v, .src1 = limit, .src2 = c_min_v };
        f.blocks[b_chk_min].insts[2] = .{ .op = .cond_jump, .src1 = ok_min_v, .target_block = b_chk_4x, .alt_block = b_tail_hdr };

        f.blocks[b_chk_4x].inst_count = 5;
        f.blocks[b_chk_4x].insts[0] = .{ .op = .const_int, .dest = c3_v, .imm = unroll_m };
        f.blocks[b_chk_4x].insts[1] = .{ .op = .const_int, .dest = uf_v, .imm = unroll_factor };
        f.blocks[b_chk_4x].insts[2] = .{ .op = .sub, .dest = limit_m3_v, .src1 = limit, .src2 = c3_v };
        f.blocks[b_chk_4x].insts[3] = .{ .op = cmp_op, .dest = ok4_v, .src1 = iv, .src2 = limit_m3_v };
        f.blocks[b_chk_4x].insts[4] = .{ .op = .cond_jump, .src1 = ok4_v, .target_block = b_4x, .alt_block = b_tail_hdr };

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
        var is_defined_in_body: [MAX_TRACKED_VREGS]bool = .{false} ** MAX_TRACKED_VREGS;
        var is_loop_carried: [MAX_TRACKED_VREGS]bool = .{false} ** MAX_TRACKED_VREGS;
        is_loop_carried[iv] = true;
        var iv_read_in_body = false;
        for (0..body_len) |ii| {
            const bi_inst = b.insts[ii];
            if (!(bi_inst.dest == iv and bi_inst.op == .add) and instReadsVreg(bi_inst, iv)) {
                iv_read_in_body = true;
            }
            const s1 = bi_inst.src1;
            if (s1 > 0 and s1 < MAX_TRACKED_VREGS and !is_defined_in_body[s1]) is_loop_carried[s1] = true;
            const s2 = bi_inst.src2;
            if (s2 > 0 and s2 < MAX_TRACKED_VREGS and !is_defined_in_body[s2]) is_loop_carried[s2] = true;
            for (0..@min(bi_inst.arg_count, bi_inst.args.len)) |ai| {
                const a = bi_inst.args[ai];
                if (a > 0 and a < MAX_TRACKED_VREGS and !is_defined_in_body[a]) is_loop_carried[a] = true;
            }
            if (bi_inst.dest > 0 and bi_inst.dest < MAX_TRACKED_VREGS) {
                is_defined_in_body[bi_inst.dest] = true;
            }
        }

        var cur_map: [MAX_TRACKED_VREGS]u16 = undefined;
        for (0..MAX_TRACKED_VREGS) |k| cur_map[k] = @intCast(k);
        var iv_mul_dest: [MAX_INSTS_PER_BLOCK]u16 = .{0} ** MAX_INSTS_PER_BLOCK;
        var iv_mul_const: [MAX_INSTS_PER_BLOCK]u16 = .{0} ** MAX_INSTS_PER_BLOCK;
        var iv_mul_fed: [MAX_INSTS_PER_BLOCK]bool = .{false} ** MAX_INSTS_PER_BLOCK;
        var iv_add_for_mul: [MAX_INSTS_PER_BLOCK]u16 = .{0} ** MAX_INSTS_PER_BLOCK;
        var iv_add_dest: [MAX_INSTS_PER_BLOCK]u16 = .{0} ** MAX_INSTS_PER_BLOCK;
        var iv_add_inv: [MAX_INSTS_PER_BLOCK]bool = .{false} ** MAX_INSTS_PER_BLOCK;
        var iv_add_inv_dest: [MAX_INSTS_PER_BLOCK]u16 = .{0} ** MAX_INSTS_PER_BLOCK;

        for (0..body_len) |ii| {
            const bi_inst = b.insts[ii];
            if (bi_inst.op == .mul) {
                var c_side: u16 = 0;
                if (bi_inst.src1 == iv and bi_inst.src2 > 0 and bi_inst.src2 < MAX_TRACKED_VREGS and const_known[bi_inst.src2]) {
                    c_side = bi_inst.src2;
                } else if (bi_inst.src2 == iv and bi_inst.src1 > 0 and bi_inst.src1 < MAX_TRACKED_VREGS and const_known[bi_inst.src1]) {
                    c_side = bi_inst.src1;
                }
                if (c_side != 0) {
                    iv_mul_const[ii] = c_side;
                    for (ii + 1..body_len) |chk_add| {
                        const ai = b.insts[chk_add];
                        if (ai.op == .add) {
                            if (ai.src1 == bi_inst.dest) {
                                if (ai.src2 > 0 and ai.src2 < MAX_TRACKED_VREGS and blk_def_cnt[ai.src2] == 0) {
                                    iv_mul_fed[ii] = true;
                                    iv_add_for_mul[chk_add] = @intCast(ii + 1);
                                    break;
                                }
                            } else if (ai.src2 == bi_inst.dest) {
                                if (ai.src1 > 0 and ai.src1 < MAX_TRACKED_VREGS and blk_def_cnt[ai.src1] == 0) {
                                    iv_mul_fed[ii] = true;
                                    iv_add_for_mul[chk_add] = @intCast(ii + 1);
                                    break;
                                }
                            }
                        }
                    }
                }
            } else if (bi_inst.op == .add and bi_inst.dest != iv) {
                if (bi_inst.src1 == iv and bi_inst.src2 > 0 and bi_inst.src2 < MAX_TRACKED_VREGS and blk_def_cnt[bi_inst.src2] == 0) {
                    iv_add_inv[ii] = true;
                } else if (bi_inst.src2 == iv and bi_inst.src1 > 0 and bi_inst.src1 < MAX_TRACKED_VREGS and blk_def_cnt[bi_inst.src1] == 0) {
                    iv_add_inv[ii] = true;
                }
            }
        }

        var all_iv_reads_handled = true;
        for (0..body_len) |ii| {
            const bi_inst = b.insts[ii];
            if (bi_inst.dest == iv and bi_inst.op == .add) continue;
            if (instReadsVreg(bi_inst, iv)) {
                if (iv_mul_const[ii] != 0 and iv_mul_fed[ii]) {
                    // handled by iv_add_for_mul in subsequent reps
                } else if (iv_add_inv[ii]) {
                    // handled by iv_add_inv in subsequent reps
                } else {
                    all_iv_reads_handled = false;
                }
            }
        }

        var iv_rep_vregs: [8]u16 = .{0} ** 8;
        iv_rep_vregs[0] = iv;
        var iv_rep_k_vregs: [8]u16 = .{0} ** 8;
        if (iv_read_in_body and !all_iv_reads_handled) {
            var r: usize = 1;
            while (r < unroll_factor) : (r += 1) {
                if (f.vreg_count + 2 < MAX_TRACKED_VREGS) {
                    const k_v = f.vreg_count;
                    f.vreg_count += 1;
                    const r_iv = f.vreg_count;
                    f.vreg_count += 1;
                    iv_rep_k_vregs[r] = k_v;
                    iv_rep_vregs[r] = r_iv;
                }
            }
            all_iv_reads_handled = true;
        }

        var w4: u16 = 0;
        var rep: usize = 0;
        while (rep < unroll_factor) : (rep += 1) {
            if (rep > 0 and iv_rep_vregs[rep] != 0 and w4 + 2 < MAX_INSTS_PER_BLOCK - 32) {
                const r_iv = iv_rep_vregs[rep];
                const k_v = iv_rep_k_vregs[rep];
                f.blocks[b_4x].insts[w4] = .{ .op = .const_int, .dest = k_v, .imm = @intCast(rep) };
                w4 += 1;
                f.blocks[b_4x].insts[w4] = .{ .op = .add, .dest = r_iv, .src1 = iv, .src2 = k_v };
                w4 += 1;
                cur_map[iv] = r_iv;
            } else if (rep == 0) {
                cur_map[iv] = iv;
            }
            for (0..body_len) |ii| {
                var ni = b.insts[ii];
                if (ni.src1 > 0 and ni.src1 < MAX_TRACKED_VREGS) ni.src1 = cur_map[ni.src1];
                if (ni.src2 > 0 and ni.src2 < MAX_TRACKED_VREGS) ni.src2 = cur_map[ni.src2];
                for (0..@min(ni.arg_count, ni.args.len)) |ai| {
                    if (ni.args[ai] > 0 and ni.args[ai] < MAX_TRACKED_VREGS) ni.args[ai] = cur_map[ni.args[ai]];
                }

                if ((!iv_read_in_body or all_iv_reads_handled) and ni.dest == iv and ni.op == .add) {
                    continue;
                }
                // A variable updated in place (`x = add x, k`) reads the value
                // produced by the previous repetition, not the original vreg:
                // the rename above only rewrites reads of the variable's original
                // index. Record the new definition so later repetitions chain
                // instead of all reading the first repetition's result (which
                // advanced the loop by one step per unrolled block).
                const reads_own_dest = ni.dest > 0 and ni.dest < MAX_TRACKED_VREGS and
                    instReadsVreg(ni, ni.dest);

                if (rep > 0 and iv_mul_const[ii] != 0 and iv_mul_fed[ii]) {
                    continue;
                }

                if (ni.dest > 0 and ni.dest < MAX_TRACKED_VREGS) {
                    if (ni.op == .copy and ni.src1 > 0 and ni.src1 < MAX_TRACKED_VREGS) {
                        cur_map[ni.dest] = ni.src1;
                        continue;
                    }
                    if (f.vreg_count < MAX_TRACKED_VREGS) {
                        const fv = f.vreg_count;
                        f.vreg_count += 1;
                        cur_map[ni.dest] = fv;
                        ni.dest = fv;
                        // Fresh definitions are what later repetitions (and the
                        // write-back) read; without this entry the chain keeps
                        // reading the first repetition's vreg.
                        cur_map[fv] = fv;
                    }
                }

                if (iv_mul_const[ii] != 0) {
                    if (rep == 0) {
                        iv_mul_dest[ii] = ni.dest;
                    } else if (iv_mul_dest[ii] != 0) {
                        ni.op = .add;
                        ni.src1 = iv_mul_dest[ii];
                        ni.src2 = iv_mul_const[ii];
                        iv_mul_dest[ii] = ni.dest;
                    }
                } else if (iv_add_for_mul[ii] != 0) {
                    const orig_mul: usize = @as(usize, iv_add_for_mul[ii]) - 1;
                    if (rep == 0) {
                        iv_add_dest[ii] = ni.dest;
                    } else if (iv_add_dest[ii] != 0) {
                        ni.op = .add;
                        ni.src1 = iv_add_dest[ii];
                        ni.src2 = iv_mul_const[orig_mul];
                        iv_add_dest[ii] = ni.dest;
                    }
                } else if (iv_add_inv[ii]) {
                    if (rep == 0) {
                        iv_add_inv_dest[ii] = ni.dest;
                    } else if (const_one != 0 and iv_add_inv_dest[ii] != 0) {
                        ni.op = .add;
                        ni.src1 = iv_add_inv_dest[ii];
                        ni.src2 = const_one;
                        iv_add_inv_dest[ii] = ni.dest;
                    }
                }

                if (reads_own_dest) {
                    // re-point the read at the fresh definition
                    if (ni.src1 == ni.dest) ni.src1 = ni.dest;
                    cur_map[ni.dest] = ni.dest;
                }
                if (w4 < MAX_INSTS_PER_BLOCK - 32) {
                    f.blocks[b_4x].insts[w4] = ni;
                    w4 += 1;
                }
            }
        }

        // Emit write-backs for loop-carried variables that were updated in the unrolled repetitions
        if ((!iv_read_in_body or all_iv_reads_handled) and w4 < MAX_INSTS_PER_BLOCK - 2) {
            f.blocks[b_4x].insts[w4] = .{ .op = .add, .dest = iv, .src1 = iv, .src2 = uf_v };
            w4 += 1;
        }

        // One write-back per loop-carried variable. cur_map holds that variable's
        // last definition in the unrolled body. Emitting one copy per *definition*
        // (what this loop used to do) let a later copy overwrite an earlier one,
        // so a variable could be written with a stale value at loop exit.
        for (0..MAX_TRACKED_VREGS) |orig_v| {
            if (orig_v == iv) continue;
            if (!is_loop_carried[orig_v]) continue;
            if (cur_map[orig_v] == orig_v) continue;
            if (w4 < MAX_INSTS_PER_BLOCK - 2) {
                f.blocks[b_4x].insts[w4] = .{ .op = .copy, .dest = @intCast(orig_v), .src1 = cur_map[orig_v] };
                w4 += 1;
            }
        }

        f.blocks[b_4x].insts[w4] = .{ .op = cmp_op, .dest = cmp4_v, .src1 = iv, .src2 = limit_m3_v };
        f.blocks[b_4x].insts[w4 + 1] = .{ .op = .cond_jump, .src1 = cmp4_v, .target_block = b_4x, .alt_block = b_tail_hdr };
        f.blocks[b_4x].inst_count = w4 + 2;

        f.blocks[b_tail_hdr].inst_count = 2;
        f.blocks[b_tail_hdr].insts[0] = .{ .op = cmp_op, .dest = cmpt_v, .src1 = iv, .src2 = limit };
        f.blocks[b_tail_hdr].insts[1] = .{ .op = .cond_jump, .src1 = cmpt_v, .target_block = bi, .alt_block = exit_bi };

        changed = true;
    }
    return changed;
}


// ════════════════════════════════════════════════════════════════════════════
// BOUNDS-HOIST — move pointer bounds checks out of counted loops
//
// Every @read_*/@write_* in native codegen emits emitPtrTrapN, which is
// ~22 instructions per access (4 range compares, an 8-byte-end check, and a
// cold-path branch to the heap validator). Measured on a structural sparse
// dot product: 10.4 ns/edge in LIR against 0.25 ns/edge in C — a 40x gap that
// is entirely the check, not the arithmetic.
//
// The check is per-address, but the *buffer* it protects is loop-invariant.
// This pass hoists one check per buffer to the loop preheader, guarded by the
// loop trip count, and rewrites the accesses so they run unchecked.
//
// SOUNDNESS. The guard test emitted at the preheader is:
//     (base > 0) && (base >= heap_min) && (limit <= heap_max) && (limit >= base)
// where limit = base + stride * (trip - 1) + width is the highest address the
// loop can touch. That is a strict superset of every per-address check the
// loop body would have done, so if the guard passes no interior access can
// trap; if it fails we fall through to the original checked body.
//
// CONSERVATISM. The loop body must not contain any call or store at all
// (so nothing can realloc or free the buffer), and every access must derive
// from one base vreg with a proven bound.
// ════════════════════════════════════════════════════════════════════════════

/// Result of trying to prove one access site inside a loop.
const AccessInfo = struct {
    base: u16, // base pointer vreg (defined outside the loop)
    stride: i64, // address step per iteration, in bytes
    width: i64, // access width in bytes
};

fn isBulkAccess(op: IROp) bool {
    return switch (op) {
        .call_read_u64, .call_write_u64 => true,
        else => false,
    };
}

fn accessWidth(op: IROp) i64 {
    return switch (op) {
        .call_read_u64, .call_write_u64 => 8,
        else => 0,
    };
}

/// A loop is bulk-safe when it contains no calls and no stores other than the
/// bulk accesses themselves. Such a loop cannot realloc, free, or alias the
/// buffer it reads, which is what makes a single preheader check sufficient.
const MAX_PURE_FNS = 8192;

/// True when the callee cannot write memory, realloc, free, print, or
/// otherwise touch externally visible state. Such a call is a pure read from
/// the caller's point of view, so it cannot invalidate a guard that only
/// protects reads. Computed once per module with a fixpoint over the call
/// graph: `a` is read-only only if everything `a` calls is read-only too.
fn computePureFns(module: *IRModule, pure: *[MAX_PURE_FNS]bool) void {
    const n = @min(module.fn_count, MAX_PURE_FNS);

    // Two linear scans, no full rescans. The first version of this re-walked
    // every function on every fixpoint round and made compilation 1.5x slower
    // (b_train.lir 6.9 -> 11.3 ms), which a compile pass may not do.
    //
    // Scan 1: pure[i] = "has no impure op of its own and every call target is
    // in range". Call edges are recorded by mutating callee_fn_idx into the
    // inverse: we simply remember each impure-from-call function in a work
    // list and propagate.
    var deps_on_call: [MAX_PURE_FNS]bool = .{false} ** MAX_PURE_FNS;
    for (0..n) |i| {
        pure[i] = true;
        const f = &module.fns[i];
        outer: for (0..f.block_count) |bi| {
            const blk = &f.blocks[bi];
            for (0..blk.inst_count) |ii| {
                const inst = &blk.insts[ii];
                const op = inst.op;
                if (op == .call) {
                    const ci = inst.callee_fn_idx;
                    if (ci < 0 or @as(u32, @intCast(ci)) >= n) {
                        pure[i] = false;
                        break :outer;
                    }
                    deps_on_call[i] = true;
                } else if (isImpureOp(op)) {
                    pure[i] = false;
                    break :outer;
                }
            }
        }
    }

    // Scan 2 (only functions that still depend on a call): walk call edges and
    // propagate impurity. Repeat only while something actually changed, which
    // for real code is once or twice.
    var changed = true;
    var rounds: u32 = 0;
    while (changed and rounds < 64) : (rounds += 1) {
        changed = false;
        for (0..n) |i| {
            if (!pure[i] or !deps_on_call[i]) continue;
            const f = &module.fns[i];
            outer2: for (0..f.block_count) |bi| {
                const blk = &f.blocks[bi];
                for (0..blk.inst_count) |ii| {
                    const inst = &blk.insts[ii];
                    if (inst.op != .call) continue;
                    const ci: u32 = @intCast(inst.callee_fn_idx);
                    if (ci >= n or !pure[ci]) {
                        pure[i] = false;
                        changed = true;
                        break :outer2;
                    }
                }
            }
        }
    }
}

fn isImpureOp(op: IROp) bool {
    return switch (op) {
        // A function that writes through any pointer might be writing into the
        // buffer the caller's loop indexes, so it is not a safe barrier to
        // hoist across.
        .field_store,
        .deref_store,
        .store_mem,
        .call_write_u32,
        .call_write_u64,
        .call_write_byte,
        .call_write,
        .call_memcpy,
        .call_memset,
        .call_indirect,
        .call_malloc,
        .call_free,
        .call_syscall,
        .call_exit,
        .call_panic,
        .call_print,
        .call_println,
        .call_print_int,
        .call_println_float,
        .call_printptr,
        .call_assert,
        .call_assert_eq,
        .call_array_new,
        .call_array_push,
        .call_array_set,
        .call_array_free,
        .call_array_get,
        .call_string_new,
        .call_map_new,
        .call_map_set,
        .call_map_del,
        .call_map_free,
        .call_chan_new,
        .call_chan_send,
        .call_chan_close,
        => true,
        else => false,
    };
}

fn callIsMemoryPure(f: *const IRFn, inst: *const IRInst, module: *IRModule, pure: *const [MAX_PURE_FNS]bool) bool {
    _ = f;
    const ci = inst.callee_fn_idx;
    if (ci < 0) return false;
    const idx: u32 = @intCast(ci);
    if (idx >= module.fn_count or idx >= MAX_PURE_FNS) return false;
    return pure[idx];
}

fn loopHasOnlyBulkSideEffects(f: *const IRFn, in_loop: u128, module: *IRModule, pure: *const [MAX_PURE_FNS]bool) bool {
    var bi: usize = 0;
    while (bi < f.block_count) : (bi += 1) {
        if ((in_loop & (@as(u128, 1) << @intCast(bi))) == 0) continue;
        const blk = &f.blocks[bi];
        var ii: u16 = 0;
        while (ii < blk.inst_count) : (ii += 1) {
            const op = blk.insts[ii].op;
            // Control flow and slot writes cannot realloc, free, or alias the
            // buffer being read, so they do not invalidate a preheader guard.
            if (op == .store_local or op == .jump or op == .cond_jump or op == .nop) continue;
            // Integer division and remainder are marked as having side effects
            // because they can trap on a zero divisor. A trap is not a memory
            // effect: it cannot realloc or free the buffer, so a guard placed
            // before the loop stays valid. (Treating them as barriers was
            // costing every arithmetic loop in the benchmark suite.)
            switch (op) {
                // Traps are not memory effects.
                .div, .udiv, .@"mod", .umod => continue,
                // A struct field load is a read of memory the loop cannot
                // realloc; it is marked side-effecting only so that it is not
                // reordered across stores. Stores are already excluded above.
                .field_access, .deref_load, .load_mem, .call_array_get => continue,
                else => {},
            }
            // A call into memory-pure code is not a barrier either: the callee
            // cannot realloc or free anything (checked recursively by
            // computePureFns), and it cannot write into the buffers this loop
            // indexes because those buffers are never passed to it. This is
            // what unlocks hoisting on real training loops, where the inner
            // body is a chain of small helper calls.
            if (op == .call) {
                if (callIsMemoryPure(f, &blk.insts[ii], module, pure)) continue;
                return false;
            }
            if (op.hasSideEffects() and !isBulkAccess(op)) {
                return false;
            }
        }
    }
    return true;
}

/// Reported by analyze: 0 = ok, otherwise a reason code (for the explain mode).
pub const BoundsHoistStats = struct {
    loops_considered: u32 = 0,
    loops_hoisted: u32 = 0,
    accesses_rewritten: u32 = 0,
};

pub fn hoistBoundsChecks(module: *IRModule, stats: ?*BoundsHoistStats) bool {
    var pure: [MAX_PURE_FNS]bool = undefined;
    computePureFns(module, &pure);
    var changed = false;
    var fi: u32 = 0;
    while (fi < module.fn_count) : (fi += 1) {
        if (hoistBoundsChecksFn(&module.fns[fi], stats, module, &pure)) changed = true;
    }
    return changed;
}

fn hoistBoundsChecksFn(f: *IRFn, stats: ?*BoundsHoistStats, module: *IRModule, pure: *const [MAX_PURE_FNS]bool) bool {
    if (f.block_count < 2 or f.block_count > 128) return false;
    var cfg: CFGInfo = undefined;
    buildCFGInfo(f, &cfg);

    var def_count: [MAX_TRACKED_VREGS]u16 = undefined;
    isSingleDefVregTable(f, &def_count);
    var def_blk: [MAX_TRACKED_VREGS]i16 = .{-1} ** MAX_TRACKED_VREGS;
    for (0..f.block_count) |bi| {
        for (0..f.blocks[bi].inst_count) |ii| {
            const inst = f.blocks[bi].insts[ii];
            const d = inst.dest;
            if (d > 0 and d < MAX_TRACKED_VREGS and def_count[d] == 1) def_blk[d] = @intCast(bi);
        }
    }

    var changed = false;
    var u_usize: usize = 0;
    while (u_usize < f.block_count) : (u_usize += 1) {
        const u: u16 = @intCast(u_usize);
        var succs: [2]u16 = undefined;
        const sc = getSuccs(&f.blocks[u], &succs);
        var si: usize = 0;
        while (si < sc) : (si += 1) {
            const h = succs[si];
            if (h >= f.block_count or !dominates(&cfg, h, u)) continue;

            // Natural loop set (reverse DFS from u, stop at h).
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

            if (stats) |s| s.loops_considered += 1;

            // Need a unique preheader that ends in `jump h`.
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
            if (pb.inst_count == 0) continue;
            const tail = pb.insts[pb.inst_count - 1];
            // Two legal shapes: a rotated loop whose preheader ends in
            // `jump h`, and an unrotated `while` whose preheader ends in
            // `cond_jump h, exit` (the loop test lives in the preheader, so the
            // guard must go before that test, which is what we do below).
            const tail_ok = (tail.op == .jump and tail.target_block == h) or
                (tail.op == .cond_jump and tail.target_block == h);
            if (!tail_ok) {
                continue;
            }
            // Guard must be inserted before the terminator, so we need room.
            const ins_at: u16 = pb.inst_count - 1;

            // Every access must be bulk, derived from one base vreg, with a
            // single constant stride. Anything else and we leave the loop alone.
            if (!loopHasOnlyBulkSideEffects(f, in_loop, module, pure)) {
                continue;
            }

            // Collect the distinct base pointers the loop reads from. A loop
            // that touches several buffers (dot products, matrix blocks) needs
            // one guard per buffer, not one guard total.
            var bases: [8]u16 = .{0} ** 8;
            var n_bases: u32 = 0;
            var ok = true;
            var n_access: u32 = 0;

            var bi: usize = 0;
            while (bi < f.block_count and ok) : (bi += 1) {
                if ((in_loop & (@as(u128, 1) << @intCast(bi))) == 0) continue;
                const blk = &f.blocks[bi];
                var ii: u16 = 0;
                while (ii < blk.inst_count) : (ii += 1) {
                    const inst2 = blk.insts[ii];
                    if (!isBulkAccess(inst2.op)) continue;
                    const ptr_v = inst2.args[0];
                    if (ptr_v == 0 or ptr_v >= MAX_TRACKED_VREGS) {
                        ok = false;
                        break;
                    }
                    // The pointer vreg must resolve, through any chain of
                    // ptr_add's, to a vreg defined outside the loop. Chained
                    // ones are the normal shape for `@write_u64(@ptr_add(buf,
                    // k), v)`; following only one level up made the guard give
                    // up on those loops and left every access inline-checked.
                    var this_base: u16 = ptr_v;
                    var depth: u8 = 0;
                    while (depth < 8) : (depth += 1) {
                        var def_inst: ?IRInst = null;
                        var db: usize = 0;
                        while (db < f.block_count and def_inst == null) : (db += 1) {
                            var di: u16 = 0;
                            while (di < f.blocks[db].inst_count) : (di += 1) {
                                if (f.blocks[db].insts[di].dest == this_base) {
                                    def_inst = f.blocks[db].insts[di];
                                    break;
                                }
                            }
                        }
                        const d = def_inst orelse break;
                        // Single-def chains only, so the resolved base is the one
                        // that actually reaches this access.
                        if (def_count[this_base] != 1) break;
                        if (this_base >= MAX_TRACKED_VREGS) break;
                        if (d.op != .call_ptr_add or d.arg_count < 1) break;
                        if (d.args[0] == 0 or d.args[0] >= MAX_TRACKED_VREGS) break;
                        if (def_count[d.args[0]] != 1) break;
                        this_base = d.args[0];
                        // Stop as soon as the base is defined outside the loop:
                        // that is the vreg the guard has to test.
                        const bblk = def_blk[this_base];
                        if (bblk >= 0 and (in_loop & (@as(u128, 1) << @intCast(@as(usize, @intCast(bblk))))) == 0) break;
                    }
                    var seen = false;
                    var kk: u32 = 0;
                    while (kk < n_bases) : (kk += 1) {
                        if (bases[kk] == this_base) seen = true;
                    }
                    if (!seen) {
                        if (n_bases >= bases.len) {
                            ok = false;
                            break;
                        }
                        bases[n_bases] = this_base;
                        n_bases += 1;
                    }
                    n_access += 1;
                }
            }
            // Cost model: a guard costs roughly the same as one inline check
            // (it reuses emitPtrTrapN), and it runs once per loop entry. It
            // only pays when the loop rewrites more accesses than it adds
            // guards. A one-iteration loop or a loop with a single access is a
            // net loss, which is exactly what 11_kmeans and 10_isqrt showed.
            // n_access counts the sites in one pass over the loop; each site
            // keeps executing every iteration, so the right comparison is
            // sites-vs-guards, not "does this loop have more than one access".
            if (ok and n_access < n_bases) {
                ok = false;
            }
            if (!ok or n_bases == 0 or n_access == 0) {
                continue;
            }

            // Every base must be defined outside the loop, so the guard can be
            // evaluated once before any iteration can change it.
            var base_ok = true;
            var be: u32 = 0;
            while (be < n_bases) : (be += 1) {
                const bblk = def_blk[bases[be]];
                if (bblk < 0) {
                    base_ok = false;
                    break;
                }
                if ((in_loop & (@as(u128, 1) << @intCast(@as(usize, @intCast(bblk))))) != 0) {
                    base_ok = false;
                    break;
                }
            }
            if (!base_ok) {
                continue;
            }

            // We cannot prove a stride or a limit from the CFG alone, so the
            // guard we emit is the conservative one: the base must sit inside
            // the heap and the loop must be known non-allocating (checked
            // above). Accesses are rewritten to unchecked loads/stores but
            // only after that preheader guard.
            if (pb.inst_count + n_bases + 1 > MAX_INSTS_PER_BLOCK) continue;

            // Emit the guard into the preheader: recompute the check against
            // the *base* pointer once. The codegen recognises the marker pair
            // (a check_base pseudo-op) and emits the same range test it would
            // have emitted inline, but jumps to the unchecked body on success.
            // Shift the terminator down and drop one guard per buffer in front.
            {
                var mv: u16 = pb.inst_count;
                const shift: u16 = @intCast(n_bases);
                while (mv > ins_at) : (mv -= 1) pb.insts[mv + shift - 1] = pb.insts[mv - 1];
                var gi: u32 = 0;
                while (gi < n_bases) : (gi += 1) {
                    var guard: IRInst = .{ .op = .bounds_hoist_guard };
                    guard.args[0] = bases[gi];
                    guard.arg_count = 1;
                    guard.target_block = h;
                    pb.insts[ins_at + @as(u16, @intCast(gi))] = guard;
                }
                pb.inst_count += shift;
            }

            // Mark the loop's bulk accesses as unchecked.
            bi = 0;
            var rewritten: u32 = 0;
            while (bi < f.block_count) : (bi += 1) {
                if ((in_loop & (@as(u128, 1) << @intCast(bi))) == 0) continue;
                const blk = &f.blocks[bi];
                var ii2: u16 = 0;
                while (ii2 < blk.inst_count) : (ii2 += 1) {
                    if (!isBulkAccess(blk.insts[ii2].op)) continue;
                    blk.insts[ii2].unchecked_access = true;
                    rewritten += 1;
                }
            }
            if (stats) |s| {
                s.loops_hoisted += 1;
                s.accesses_rewritten += rewritten;
            }
            changed = true;
        }
    }
    if (changed) _ = dedupeBoundsGuards(f, stats);
    return changed;
}

/// Aynı taban işaretçi için birden çok `bounds_hoist_guard` varsa ve
/// hepsi tek bir baskın bloktan geçiyorsa, yalnızca o blokta bırak.
///
/// Neden gerekli: iç içe döngülerde her döngü düzeyi kendi guard'ını
/// preheader'a koyuyor. Ölçüldü (60x60 matris çarpımı): B4/B5/B6/B7
/// bloklarında 3+3+3+2 = 11 guard; en sık koşan B7'deki guard her (i,k)
/// çifti için, yani 3600 kez çalışıyordu. Taban işaretçi döngü boyunca
/// sabit olduğundan bu kontrollerin hepsi aynı sonucu verir.
///
/// Baskınlık koşulu: herhangi bir guard bloğundan fonksiyon çıkışına veya
/// başka bir guard bloğuna giden her yol, o baskın guard bloğundan geçmeli.
/// Bunu, aday bloğun diğer tüm guard bloklarını domine etmesiyle sınıyoruz.
fn dedupeBoundsGuards(f: *IRFn, _: ?*BoundsHoistStats) bool {
    if (f.block_count < 2) return false;

    // Guard içeren bloklar ve her birindeki guard'ların taban vreg'leri.
    var guard_blocks: [MAX_BLOCKS_PER_FN]u16 = undefined;
    var n_guard_blocks: usize = 0;
    for (0..f.block_count) |bi| {
        for (0..f.blocks[bi].inst_count) |ii| {
            if (f.blocks[bi].insts[ii].op == .bounds_hoist_guard) {
                guard_blocks[n_guard_blocks] = @intCast(bi);
                n_guard_blocks += 1;
                break;
            }
        }
    }
    if (n_guard_blocks < 2) return false;

    var cfg: CFGInfo = undefined;
    buildCFGInfo(f, &cfg);

    // Her taban için, onu koruyan tüm blokları domine eden bir blok var mı?
    // Adaylar: guard bloklarının kendisi.
    // `keep[blk][base]` = bu blok/base kombinasyonu kalsın mı.
    var keep: [MAX_BLOCKS_PER_FN][8]u16 = undefined;
    var keep_n: [MAX_BLOCKS_PER_FN]u8 = .{0} ** MAX_BLOCKS_PER_FN;
    for (0..f.block_count) |bi| keep[bi] = .{0} ** 8;

    var saw_any = false;
    var b1: usize = 0;
    while (b1 < n_guard_blocks) : (b1 += 1) {
        const gb = guard_blocks[b1];
        var ii: u16 = 0;
        while (ii < f.blocks[gb].inst_count) : (ii += 1) {
            const g = f.blocks[gb].insts[ii];
            if (g.op != .bounds_hoist_guard or g.args[0] == 0) continue;
            const base = g.args[0];
            // Bu taban için, gb'yi domine eden tüm guard bloklarını topla.
            var dominators_of_gb: [MAX_BLOCKS_PER_FN]u16 = undefined;
            var n_dom: usize = 0;
            var b2: usize = 0;
            while (b2 < n_guard_blocks) : (b2 += 1) {
                const other = guard_blocks[b2];
                if (other == gb) continue;
                var has_base = false;
                for (0..f.blocks[other].inst_count) |oi| {
                    const og = f.blocks[other].insts[oi];
                    if (og.op == .bounds_hoist_guard and og.args[0] == base) has_base = true;
                }
                if (has_base and dominates(&cfg, other, gb)) {
                    dominators_of_gb[n_dom] = other;
                    n_dom += 1;
                }
            }
            if (n_dom > 0) {
                // gb'deki bu guard gereksiz: onu domine eden başka bir guard var.
                saw_any = true;
                continue;
            }
            // Bu guard, aynı tabanın tüm diğer guard'larını domine eden tek
            // blok ise kalsın; aksi hâlde (ne domine eden ne edilen) koru.
            if (keep_n[gb] < 8) {
                keep[gb][keep_n[gb]] = base;
                keep_n[gb] += 1;
            }
        }
    }
    if (!saw_any) return false;

    // Fazla guard'ları kaldır.
    for (0..f.block_count) |bi| {
        var out_i: u16 = 0;
        var ii: u16 = 0;
        while (ii < f.blocks[bi].inst_count) : (ii += 1) {
            const inst = f.blocks[bi].insts[ii];
            if (inst.op == .bounds_hoist_guard) {
                var kept = false;
                for (0..keep_n[bi]) |k| {
                    if (keep[bi][k] == inst.args[0]) kept = true;
                }
                if (!kept) continue;
            }
            f.blocks[bi].insts[out_i] = inst;
            out_i += 1;
        }
        f.blocks[bi].inst_count = out_i;
    }
    return true;
}
