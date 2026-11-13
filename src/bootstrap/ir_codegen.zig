// ════════════════════════════════════════════════════════════════════════════
// IR CODEGEN — Linear-scan regalloc + coalescing + immediate folding +
//              x86-64 machine code + slab allocator + ELF64 emitter
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const ir_mod = @import("ir.zig");

const IRModule = ir_mod.IRModule;
const IRFn = ir_mod.IRFn;
const IRBlock = ir_mod.IRBlock;
const IRInst = ir_mod.IRInst;
const IROp = ir_mod.IROp;

const eql = util.eql;
const write16 = util.write16;
const write32 = util.write32;
const write64 = util.write64;

fn stringHash(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| hash = (hash ^ byte) *% 1099511628211;
    return hash;
}

// x86-64 GPR indices:
// 0=rax, 1=rcx, 2=rdx, 3=rbx, 4=rsp, 5=rbp, 6=rsi, 7=rdi, 8..15=r8..r15
// Reserved scratch: rax(0), rcx(1), rdx(2), rsp(4), rbp(5), r11(11)
const ARG_REGS = [_]u8{ 7, 6, 2, 1, 8, 9 }; // rdi, rsi, rdx, rcx, r8, r9
const CALLER_SAVED_POOL = [_]u8{ 8, 9, 10, 6, 7 }; // r8, r9, r10, rsi, rdi (r11 reserved scratch!)
const CALLEE_SAVED_POOL = [_]u8{ 3, 12, 13, 14, 15 }; // rbx, r12, r13, r14, r15
const ALL_ALLOC_REGS = [_]u8{ 8, 9, 10, 6, 7, 3, 12, 13, 14, 15 };
const NO_REG: u8 = 0xFF;

const MAX_CODE_BYTES = 524288;
const MAX_RODATA_BYTES = 65536;
const MAX_VREGS = 4096;
const DATA_VADDR: u64 = 0x600000; // 64 KiB RW zero-init page: [0x00]=argc, [0x08]=argv, [0x10..0x67]=slab, [0x68]=envp, [0x70]=heap_secret, [0x78]=stack_canary, [0x80]=slab_cur_base, [0x88]=heap_min, [0x90]=heap_max, [0x98]=region_count, [0xA0]=is_multithreaded, [0xB0]=free_ring_cursor, [0x100..]=region_dir
const REGION_DIR_CAP: u32 = 4080;

const FnInfo = struct {
    name_start: u32,
    name_len: u32,
    source_id: u16,
    ir_fn_idx: u32,
    param_count: u32,
    code_offset: u32,
    param_store_offset: u32,
};

const RelocKind = enum(u8) {
    jmp32, // E9 disp32 (5B -> 2B EB disp8)
    jcc32, // 0F 8x disp32 (6B -> 2B 7x disp8)
    call32, // E8 disp32 (5B)
    rip_code, // 48/4C 8D reg, [rip + disp32] (7B)
    rip_rodata, // 48/4C 8D reg, [rip + disp32] (7B)
};

const TargetKind = enum(u8) {
    code_offset,
    block,
    fn_call,
    fn_tail,
    printint,
    malloc_fn,
    free_fn,
    chk_heap1_fn,
    chk_heap4_fn,
    chk_heap8_fn,
    chk_ptr_n_fn,
    chk_cfi_fn,
    add_region_fn,
    split_fn,
    array_new_fn,
    array_push_fn,
    array_get_fn,
    array_set_fn,
    float_to_str_fn,
    str_to_float_fn,
    sin_fn,
    cos_fn,
    map_new_fn,
    map_set_fn,
    map_get_fn,
    map_has_fn,
    map_del_fn,
    chan_new_fn,
    chan_send_fn,
    chan_recv_fn,
    assert_fail_fn,
    text_start,
    text_end,
    rodata,
};

const SignedDivMagic = struct { multiplier: i64, shift: u8 };

// Hacker's Delight signed division by an invariant positive divisor. The
// generated quotient is corrected toward zero, matching LIR's idiv semantics.
fn signedDivMagic(divisor: i64) SignedDivMagic {
    const d: u128 = @intCast(divisor);
    const two63: u128 = @as(u128, 1) << 63;
    const anc = two63 - 1 - (two63 % d);
    var p: u32 = 63;
    var q1 = two63 / anc;
    var r1 = two63 - q1 * anc;
    var q2 = two63 / d;
    var r2 = two63 - q2 * d;
    while (true) {
        p += 1;
        q1 *= 2;
        r1 *= 2;
        if (r1 >= anc) {
            q1 += 1;
            r1 -= anc;
        }
        q2 *= 2;
        r2 *= 2;
        if (r2 >= d) {
            q2 += 1;
            r2 -= d;
        }
        const delta = d - r2;
        if (!(q1 < delta or (q1 == delta and r1 == 0))) break;
    }
    const multiplier: i64 = @bitCast(@as(u64, @truncate(q2 + 1)));
    return .{ .multiplier = multiplier, .shift = @intCast(p - 64) };
}

const Reloc = struct {
    kind: RelocKind,
    opcode_pos: u32,
    instr_len: u8,
    cc: u8 = 0,
    target_kind: TargetKind,
    target_id: u32,
    fn_idx: u32 = 0,
    relaxed: bool = false,
};

pub const IRCodegen = struct {
    code: [MAX_CODE_BYTES]u8 = undefined,
    code_len: u32 = 0,
    overflowed: bool = false,
    invalid_reference: bool = false,

    rodata: [MAX_RODATA_BYTES]u8 = undefined,
    rodata_len: u32 = 0,
    string_offsets: [512]u32 = undefined,
    string_lens: [512]u32 = undefined,
    string_hashes: [512]u64 = undefined,
    string_hash_slots: [1024]u16 = .{0} ** 1024,
    string_count: u32 = 0,

    src: []const u8 = "",
    ir: *const IRModule = undefined,

    // Functions & blocks
    fns: [ir_mod.MAX_FNS]FnInfo = undefined,
    fn_count: u32 = 0,
    block_offsets: [ir_mod.MAX_FNS][ir_mod.MAX_BLOCKS_PER_FN]u32 = undefined,
    printint_offset: u32 = 0,
    malloc_offset: u32 = 0,
    free_offset: u32 = 0,
    chk_heap1_offset: u32 = 0,
    chk_heap4_offset: u32 = 0,
    chk_heap8_offset: u32 = 0,
    chk_ptr_n_offset: u32 = 0,
    chk_cfi_offset: u32 = 0,
    cfi_table_rodata_off: u32 = 0,
    cfi_targets: [ir_mod.MAX_FNS]u32 = .{0} ** ir_mod.MAX_FNS,
    cfi_target_count: u32 = 0,
    add_region_offset: u32 = 0,
    split_offset: u32 = 0,
    array_new_offset: u32 = 0,
    array_push_offset: u32 = 0,
    array_get_offset: u32 = 0,
    array_set_offset: u32 = 0,
    float_to_str_offset: u32 = 0,
    str_to_float_offset: u32 = 0,
    sin_offset: u32 = 0,
    cos_offset: u32 = 0,
    map_new_offset: u32 = 0,
    map_set_offset: u32 = 0,
    map_get_offset: u32 = 0,
    map_has_offset: u32 = 0,
    map_del_offset: u32 = 0,
    chan_new_offset: u32 = 0,
    chan_send_offset: u32 = 0,
    chan_recv_offset: u32 = 0,
    assert_fail_offset: u32 = 0,
    text_user_start: u32 = 0,
    text_user_end: u32 = 0,

    // Relocations
    relocs: [32768]Reloc = undefined,
    reloc_count: u32 = 0,

    // Current function allocation & frame state
    cur_fn_idx: u32 = 0,
    cur_total_locals: u32 = 0,
    cur_num_spills: u32 = 0,
    cur_callee_regs: [5]u8 = undefined,
    cur_callee_count: u32 = 0,
    cur_frame_active: bool = true,
    cur_canary_active: bool = false,
    cur_stack_adj: u32 = 0,
    cur_next_emit_bi: u16 = 0xFFFF,

    // Per-vreg allocation state (for current function)
    vreg_reg: [MAX_VREGS]u8 = undefined,
    vreg_spill_slot: [MAX_VREGS]u32 = undefined,
    vreg_def_cnt: [MAX_VREGS]u16 = undefined,
    vreg_last_use: [MAX_VREGS]u32 = undefined,
    vreg_start: [MAX_VREGS]u32 = undefined,
    vreg_end: [MAX_VREGS]u32 = undefined,
    vreg_crosses_call: [MAX_VREGS]bool = undefined,
    vreg_const_known: [MAX_VREGS]bool = undefined,
    vreg_const_imm: [MAX_VREGS]i64 = undefined,
    vreg_elided_const: [MAX_VREGS]bool = undefined,
    vreg_copy_hint: [MAX_VREGS]u16 = undefined,

    // Entry register-only parameter tracking for current function
    param_reg_only: [8]bool = .{false} ** 8,
    param_target_vreg: [8]u16 = .{0} ** 8,
    param_load_skip: [8]bool = .{false} ** 8,

    pub fn init(self: *IRCodegen, source: []const u8, module: *const IRModule) void {
        self.code_len = 0;
        self.overflowed = false;
        self.invalid_reference = false;
        self.rodata_len = 0;
        self.string_count = 0;
        @memset(&self.string_hash_slots, 0);
        self.src = source;
        self.ir = module;
        self.fn_count = 0;
        self.printint_offset = 0;
        self.malloc_offset = 0;
        self.free_offset = 0;
        self.split_offset = 0;
        self.array_new_offset = 0;
        self.array_push_offset = 0;
        self.array_get_offset = 0;
        self.array_set_offset = 0;
        self.float_to_str_offset = 0;
        self.str_to_float_offset = 0;
        self.sin_offset = 0;
        self.cos_offset = 0;
        self.map_new_offset = 0;
        self.map_set_offset = 0;
        self.map_get_offset = 0;
        self.map_has_offset = 0;
        self.map_del_offset = 0;
        self.chan_new_offset = 0;
        self.chan_send_offset = 0;
        self.chan_recv_offset = 0;
        self.assert_fail_offset = 0;
        self.chk_ptr_n_offset = 0;
        self.chk_cfi_offset = 0;
        self.cfi_table_rodata_off = 0;
        self.cfi_target_count = 0;
        self.text_user_start = 0;
        self.text_user_end = 0;
        self.cur_canary_active = false;
        self.reloc_count = 0;
    }

    // ═══════════════════════════════════════════════════════════
    // Low-level x86-64 byte emitters
    // ═══════════════════════════════════════════════════════════

    fn emit8(self: *IRCodegen, b: u8) void {
        if (self.overflowed) return;
        if (@as(usize, self.code_len) >= self.code.len) {
            self.overflowed = true;
            return;
        }
        self.code[self.code_len] = b;
        self.code_len += 1;
    }

    fn emit32(self: *IRCodegen, v: u32) void {
        if (self.overflowed) return;
        if (self.code.len - @as(usize, self.code_len) < 4) {
            self.overflowed = true;
            return;
        }
        self.code[self.code_len..][0..4].* = .{
            @truncate(v),
            @truncate(v >> 8),
            @truncate(v >> 16),
            @truncate(v >> 24),
        };
        self.code_len += 4;
    }

    fn emit64(self: *IRCodegen, v: u64) void {
        if (self.overflowed) return;
        if (self.code.len - @as(usize, self.code_len) < 8) {
            self.overflowed = true;
            return;
        }
        self.code[self.code_len..][0..8].* = .{
            @truncate(v),
            @truncate(v >> 8),
            @truncate(v >> 16),
            @truncate(v >> 24),
            @truncate(v >> 32),
            @truncate(v >> 40),
            @truncate(v >> 48),
            @truncate(v >> 56),
        };
        self.code_len += 8;
    }

    fn emitRex(self: *IRCodegen, reg: u8, rm: u8) void {
        var rex: u8 = 0x48;
        if (reg >= 8) rex |= 0x04;
        if (rm >= 8) rex |= 0x01;
        self.emit8(rex);
    }

    fn emitModRM(self: *IRCodegen, mod: u8, reg: u8, rm: u8) void {
        self.emit8((mod << 6) | ((reg & 7) << 3) | (rm & 7));
    }

    fn mov64imm(self: *IRCodegen, dst: u8, imm: u64) void {
        if (imm == 0) {
            self.xorReg(dst, dst);
            return;
        }
        const signed_imm: i64 = @bitCast(imm);
        if (signed_imm >= 0 and signed_imm <= std.math.maxInt(i32)) {
            // 32-bit mov zero-extends to 64-bit in 5-6 bytes (no REX.W)
            if (dst >= 8) self.emit8(0x41);
            self.emit8(0xB8 + (dst & 7));
            self.emit32(@intCast(@as(u64, imm)));
            return;
        }
        if (signed_imm >= std.math.minInt(i32) and signed_imm <= std.math.maxInt(i32)) {
            self.emit8(if (dst >= 8) 0x49 else 0x48);
            self.emit8(0xC7);
            self.emit8(0xC0 | (dst & 7));
            self.emit32(@bitCast(@as(i32, @intCast(signed_imm))));
            return;
        }
        self.emit8(if (dst >= 8) 0x49 else 0x48);
        self.emit8(0xB8 + (dst & 7));
        self.emit64(imm);
    }

    fn pushReg(self: *IRCodegen, r: u8) void {
        if (r >= 8) self.emit8(0x41);
        self.emit8(0x50 + (r & 7));
    }

    fn popReg(self: *IRCodegen, r: u8) void {
        if (r >= 8) self.emit8(0x41);
        self.emit8(0x58 + (r & 7));
    }

    fn movRegReg(self: *IRCodegen, dst: u8, src: u8) void {
        if (dst == src) return;
        self.emitRex(src, dst);
        self.emit8(0x89);
        self.emitModRM(3, src, dst);
    }

    fn xorReg(self: *IRCodegen, dst: u8, src: u8) void {
        if (dst == src and dst < 8) {
            self.emit8(0x31);
            self.emitModRM(3, src, dst);
            return;
        }
        var rex: u8 = 0x40;
        if (src >= 8) rex |= 0x04;
        if (dst >= 8) rex |= 0x01;
        if (rex != 0x40) self.emit8(rex);
        self.emit8(0x31);
        self.emitModRM(3, src, dst);
    }

    fn syscallInst(self: *IRCodegen) void {
        self.emit8(0x0F);
        self.emit8(0x05);
    }

    fn subRspImm(self: *IRCodegen, imm: u32) void {
        if (imm == 0) return;
        if (imm <= 127) {
            self.emit8(0x48);
            self.emit8(0x83);
            self.emit8(0xEC);
            self.emit8(@intCast(imm));
        } else {
            self.emit8(0x48);
            self.emit8(0x81);
            self.emit8(0xEC);
            self.emit32(imm);
        }
    }

    fn addRspImm(self: *IRCodegen, imm: u32) void {
        if (imm == 0) return;
        if (imm <= 127) {
            self.emit8(0x48);
            self.emit8(0x83);
            self.emit8(0xC4);
            self.emit8(@intCast(imm));
        } else {
            self.emit8(0x48);
            self.emit8(0x81);
            self.emit8(0xC4);
            self.emit32(imm);
        }
    }

    fn emitLeaRegDisp(self: *IRCodegen, dst: u8, base: u8, disp: i32) void {
        self.emitRex(dst, base);
        self.emit8(0x8D);
        if (disp == 0 and (base & 7) != 5 and (base & 7) != 4) {
            self.emitModRM(0, dst, base);
        } else if (disp >= -128 and disp <= 127) {
            self.emitModRM(1, dst, base);
            if ((base & 7) == 4) self.emit8(0x24);
            self.emit8(@intCast(disp & 0xFF));
        } else {
            self.emitModRM(2, dst, base);
            if ((base & 7) == 4) self.emit8(0x24);
            self.emit32(@bitCast(disp));
        }
    }

    fn emitAluRegImm32(self: *IRCodegen, subop: u8, reg: u8, imm: i32) void {
        self.emit8(if (reg >= 8) 0x49 else 0x48);
        if (imm >= -128 and imm <= 127) {
            self.emit8(0x83);
            self.emit8(0xC0 | ((subop & 7) << 3) | (reg & 7));
            self.emit8(@bitCast(@as(i8, @intCast(imm))));
        } else {
            self.emit8(0x81);
            self.emit8(0xC0 | ((subop & 7) << 3) | (reg & 7));
            self.emit32(@bitCast(imm));
        }
    }

    fn emitCmpRegImm32(self: *IRCodegen, reg: u8, imm: i32) void {
        self.emitAluRegImm32(7, reg, imm);
    }

    fn loadSlotToReg(self: *IRCodegen, reg: u8, slot: u32) void {
        const eff_slot: u32 = slot + @as(u32, if (self.cur_canary_active) 1 else 0);
        const disp: i32 = -@as(i32, @intCast(eff_slot)) * 8;
        self.emitRex(reg, 5);
        self.emit8(0x8B);
        if (disp >= -128 and disp <= 127) {
            self.emit8(0x45 | ((reg & 7) << 3));
            self.emit8(@intCast(disp & 0xFF));
        } else {
            self.emit8(0x85 | ((reg & 7) << 3));
            self.emit32(@bitCast(disp));
        }
    }

    fn storeRegToSlot(self: *IRCodegen, reg: u8, slot: u32) void {
        const eff_slot: u32 = slot + @as(u32, if (self.cur_canary_active) 1 else 0);
        const disp: i32 = -@as(i32, @intCast(eff_slot)) * 8;
        self.emitRex(reg, 5);
        self.emit8(0x89);
        if (disp >= -128 and disp <= 127) {
            self.emit8(0x45 | ((reg & 7) << 3));
            self.emit8(@intCast(disp & 0xFF));
        } else {
            self.emit8(0x85 | ((reg & 7) << 3));
            self.emit32(@bitCast(disp));
        }
    }

    fn leaSlotToReg(self: *IRCodegen, reg: u8, slot: u32) void {
        const eff_slot: u32 = slot + @as(u32, if (self.cur_canary_active) 1 else 0);
        const disp: i32 = -@as(i32, @intCast(eff_slot)) * 8;
        self.emitRex(reg, 5);
        self.emit8(0x8D);
        if (disp >= -128 and disp <= 127) {
            self.emit8(0x45 | ((reg & 7) << 3));
            self.emit8(@intCast(disp & 0xFF));
        } else {
            self.emit8(0x85 | ((reg & 7) << 3));
            self.emit32(@bitCast(disp));
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Relocation recording helpers
    // ═══════════════════════════════════════════════════════════

    fn addReloc(self: *IRCodegen, r: Reloc) u32 {
        if (self.reloc_count >= self.relocs.len) {
            self.overflowed = true;
            return 0;
        }
        const idx = self.reloc_count;
        self.relocs[idx] = r;
        self.reloc_count += 1;
        return idx;
    }

    fn emitJmpReloc(self: *IRCodegen, target_kind: TargetKind, target_id: u32, fn_idx: u32) u32 {
        const op_pos = self.code_len;
        self.emit8(0xE9);
        self.emit32(0);
        return self.addReloc(.{
            .kind = .jmp32,
            .opcode_pos = op_pos,
            .instr_len = 5,
            .target_kind = target_kind,
            .target_id = target_id,
            .fn_idx = fn_idx,
        });
    }

    fn emitJccReloc(self: *IRCodegen, cc: u8, target_kind: TargetKind, target_id: u32, fn_idx: u32) u32 {
        const op_pos = self.code_len;
        self.emit8(0x0F);
        self.emit8(0x80 | (cc & 0x0F));
        self.emit32(0);
        return self.addReloc(.{
            .kind = .jcc32,
            .opcode_pos = op_pos,
            .instr_len = 6,
            .cc = cc & 0x0F,
            .target_kind = target_kind,
            .target_id = target_id,
            .fn_idx = fn_idx,
        });
    }

    fn emitCallReloc(self: *IRCodegen, target_kind: TargetKind, target_id: u32) void {
        const op_pos = self.code_len;
        self.emit8(0xE8);
        self.emit32(0);
        _ = self.addReloc(.{
            .kind = .call32,
            .opcode_pos = op_pos,
            .instr_len = 5,
            .target_kind = target_kind,
            .target_id = target_id,
        });
    }

    fn leaRipRodata(self: *IRCodegen, dst: u8, string_idx: u32) void {
        const op_pos = self.code_len;
        self.emit8(if (dst >= 8) 0x4C else 0x48);
        self.emit8(0x8D);
        self.emit8(0x05 | ((dst & 7) << 3));
        self.emit32(0);
        _ = self.addReloc(.{
            .kind = .rip_rodata,
            .opcode_pos = op_pos,
            .instr_len = 7,
            .target_kind = .rodata,
            .target_id = self.string_offsets[string_idx],
        });
    }

    fn leaRipRodataOffset(self: *IRCodegen, dst: u8, rodata_off: u32) void {
        const op_pos = self.code_len;
        self.emit8(if (dst >= 8) 0x4C else 0x48);
        self.emit8(0x8D);
        self.emit8(0x05 | ((dst & 7) << 3));
        self.emit32(0);
        _ = self.addReloc(.{
            .kind = .rip_rodata,
            .opcode_pos = op_pos,
            .instr_len = 7,
            .target_kind = .rodata,
            .target_id = rodata_off,
        });
    }

    fn leaRipCodeBase(self: *IRCodegen, dst: u8) void {
        const op_pos = self.code_len;
        self.emit8(if (dst >= 8) 0x4C else 0x48);
        self.emit8(0x8D);
        self.emit8(0x05 | ((dst & 7) << 3));
        self.emit32(0);
        _ = self.addReloc(.{
            .kind = .rip_code,
            .opcode_pos = op_pos,
            .instr_len = 7,
            .target_kind = .code_offset,
            .target_id = 0,
        });
    }

    fn leaRipFn(self: *IRCodegen, dst: u8, fn_idx: u32) void {
        const op_pos = self.code_len;
        self.emit8(if (dst >= 8) 0x4C else 0x48);
        self.emit8(0x8D);
        self.emit8(0x05 | ((dst & 7) << 3));
        self.emit32(0);
        _ = self.addReloc(.{
            .kind = .rip_code,
            .opcode_pos = op_pos,
            .instr_len = 7,
            .target_kind = .fn_call,
            .target_id = fn_idx,
        });
    }

    fn leaRipSpecial(self: *IRCodegen, dst: u8, target_kind: TargetKind) void {
        const op_pos = self.code_len;
        self.emit8(if (dst >= 8) 0x4C else 0x48);
        self.emit8(0x8D);
        self.emit8(0x05 | ((dst & 7) << 3));
        self.emit32(0);
        _ = self.addReloc(.{
            .kind = .rip_code,
            .opcode_pos = op_pos,
            .instr_len = 7,
            .target_kind = target_kind,
            .target_id = 0,
        });
    }

    // ═══════════════════════════════════════════════════════════
    // Unified 8-byte-aligned .rodata string table: [u64 len][bytes][0x00]
    // ═══════════════════════════════════════════════════════════

    fn addString(self: *IRCodegen, str: []const u8) u32 {
        if (self.overflowed) return 0;
        const hash = stringHash(str);
        const mask: usize = self.string_hash_slots.len - 1;
        var bucket: usize = @intCast(hash & mask);
        while (true) {
            const entry = self.string_hash_slots[bucket];
            if (entry == 0) break;
            const idx: usize = @as(usize, entry) - 1;
            if (idx >= self.string_count) {
                self.overflowed = true;
                return 0;
            }
            const off: usize = self.string_offsets[idx];
            const len: usize = self.string_lens[idx];
            if (self.string_hashes[idx] == hash and len == str.len and
                off <= self.rodata_len and len <= self.rodata_len - off and
                std.mem.eql(u8, self.rodata[off..][0..len], str))
            {
                return @intCast(idx);
            }
            bucket = (bucket + 1) & mask;
        }

        const aligned_hdr: usize = (@as(usize, self.rodata_len) + 7) & ~@as(usize, 7);
        const needed: usize = (aligned_hdr - @as(usize, self.rodata_len)) + 8 + str.len + 1;
        if (@as(usize, self.string_count) >= self.string_offsets.len or
            needed > self.rodata.len - @as(usize, self.rodata_len))
        {
            self.overflowed = true;
            return 0;
        }
        while (self.rodata_len < aligned_hdr) {
            self.rodata[self.rodata_len] = 0;
            self.rodata_len += 1;
        }
        std.mem.writeInt(u64, self.rodata[self.rodata_len..][0..8], @intCast(str.len), .little);
        self.rodata_len += 8;

        const idx = self.string_count;
        const bytes_off = self.rodata_len;
        @memcpy(self.rodata[@as(usize, bytes_off)..][0..str.len], str);
        self.rodata[@as(usize, bytes_off) + str.len] = 0;
        self.rodata_len += @intCast(str.len + 1);

        self.string_offsets[idx] = bytes_off;
        self.string_lens[idx] = @intCast(str.len);
        self.string_hashes[idx] = hash;

        bucket = @intCast(hash & mask);
        while (self.string_hash_slots[bucket] != 0) : (bucket = (bucket + 1) & mask) {}
        self.string_hash_slots[bucket] = @intCast(idx + 1);
        self.string_count += 1;
        return idx;
    }

    // ═══════════════════════════════════════════════════════════
    // Constant Immediate Analysis + Linear-scan regalloc
    // ═══════════════════════════════════════════════════════════

    fn isCallClobberingOp(op: IROp) bool {
        return switch (op) {
            .call,
            .call_indirect,
            .call_print,
            .call_println,
            .call_print_int,
            .call_print_float,
            .call_println_float,
            .call_float_to_string,
            .call_string_to_float,
            .call_floor,
            .call_ceil,
            .call_round,
            .call_sin,
            .call_cos,
            .call_atomic_add,
            .call_atomic_cas,
            .call_map_new,
            .call_map_set,
            .call_map_get,
            .call_map_has,
            .call_map_del,
            .call_map_free,
            .call_chan_new,
            .call_chan_send,
            .call_chan_recv,
            .call_chan_close,
            .call_assert,
            .call_assert_eq,
            .call_random_u64,
            .call_random_bytes,
            .call_secure_zero,
            .call_const_time_eq,
            .call_getenv,
            .call_sleep_ms,
            .call_printptr,
            .call_exit,
            .call_panic,
            .call_syscall,
            .call_memcpy,
            .call_memset,
            .call_malloc,
            .call_free,
            .call_array_new,
            .call_array_push,
            .call_array_get,
            .call_array_set,
            .call_array_free,
            .call_string_new,
            .call_string_sub,
            .call_string_slice,
            .call_string_char_at,
            .call_string_eq,
            .call_string_concat,
            .call_string_split,
            .call_int_to_string,
            .call_string_to_int,
            .call_open,
            .call_read,
            .call_write,
            .call_close,
            .call_unlink,
            .call_mkdir,
            .call_stat,
            .call_getpid,
            .call_getppid,
            .call_getuid,
            .call_tcp_socket,
            .call_tcp_listen,
            .call_tcp_accept,
            .call_tcp_connect,
            .call_sock_send,
            .call_sock_recv,
            .call_thread_create,
            .call_thread_join,
            .call_mutex_create,
            .call_mutex_lock,
            .call_mutex_unlock,
            .call_argv,
            .call_time_ns,
            .call_map_len,
            => true,
            else => false,
        };
    }

    fn emitCmpRegAbs(self: *IRCodegen, reg: u8, abs_addr: u32) void {
        self.emit8(if (reg >= 8) 0x4C else 0x48);
        self.emit8(0x3B);
        self.emit8(@as(u8, ((reg & 7) << 3)) | 0x04);
        self.emit8(0x25);
        self.emit32(abs_addr);
    }

    fn emitLeaRegIdxScale(self: *IRCodegen, dst: u8, base: u8, idx: u8, scale_log2: u2) void {
        std.debug.assert(idx != 4);
        var rex: u8 = 0x48;
        if (dst >= 8) rex |= 0x04;
        if (idx >= 8) rex |= 0x02;
        if (base >= 8) rex |= 0x01;
        self.emit8(rex);
        self.emit8(0x8D);
        const needs_disp0 = (base & 7) == 5;
        self.emit8((if (needs_disp0) @as(u8, 0x44) else @as(u8, 0x04)) | ((dst & 7) << 3));
        self.emit8((@as(u8, scale_log2) << 6) | ((idx & 7) << 3) | (base & 7));
        if (needs_disp0) self.emit8(0);
    }

    fn emitMemLoadByte(self: *IRCodegen, dst: u8, base: u8) void {
        self.emitRex(dst, base);
        self.emit8(0x0F);
        self.emit8(0xB6);
        if ((base & 7) == 5) {
            self.emitModRM(1, dst, base);
            self.emit8(0);
        } else {
            self.emitModRM(0, dst, base);
            if ((base & 7) == 4) self.emit8(0x24);
        }
    }

    fn emitMemStoreByte(self: *IRCodegen, base: u8, src: u8) void {
        var rex: u8 = 0x40;
        if (src >= 8) rex |= 0x04;
        if (base >= 8) rex |= 0x01;
        if (rex != 0x40 or (src >= 4 and src <= 7)) self.emit8(rex);
        self.emit8(0x88);
        if ((base & 7) == 5) {
            self.emitModRM(1, src, base);
            self.emit8(0);
        } else {
            self.emitModRM(0, src, base);
            if ((base & 7) == 4) self.emit8(0x24);
        }
    }

    fn emitMemStoreByteImm(self: *IRCodegen, base: u8, imm8: u8) void {
        if (base >= 8) self.emit8(0x41);
        self.emit8(0xC6);
        if ((base & 7) == 5) {
            self.emitModRM(1, 0, base);
            self.emit8(0);
        } else {
            self.emitModRM(0, 0, base);
            if ((base & 7) == 4) self.emit8(0x24);
        }
        self.emit8(imm8);
    }

    fn emitMemLoadU32(self: *IRCodegen, dst: u8, base: u8) void {
        var rex: u8 = 0x40;
        if (dst >= 8) rex |= 0x04;
        if (base >= 8) rex |= 0x01;
        if (rex != 0x40) self.emit8(rex);
        self.emit8(0x8B);
        if ((base & 7) == 5) {
            self.emitModRM(1, dst, base);
            self.emit8(0);
        } else {
            self.emitModRM(0, dst, base);
            if ((base & 7) == 4) self.emit8(0x24);
        }
    }

    fn emitMemStoreU32(self: *IRCodegen, base: u8, src: u8) void {
        var rex: u8 = 0x40;
        if (src >= 8) rex |= 0x04;
        if (base >= 8) rex |= 0x01;
        if (rex != 0x40) self.emit8(rex);
        self.emit8(0x89);
        if ((base & 7) == 5) {
            self.emitModRM(1, src, base);
            self.emit8(0);
        } else {
            self.emitModRM(0, src, base);
            if ((base & 7) == 4) self.emit8(0x24);
        }
    }

    fn fitsI32NonMin(imm: i64) bool {
        return imm > std.math.minInt(i32) and imm <= std.math.maxInt(i32);
    }

    fn isFoldableRhsBinOp(op: IROp) bool {
        return switch (op) {
            .add,
            .sub,
            .mul,
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
            => true,
            else => false,
        };
    }

    fn isShiftOp(op: IROp) bool {
        return op == .shl or op == .shr or op == .ushr;
    }

    fn analyzeElidedConsts(self: *IRCodegen, ir_fn: *const IRFn) void {
        @memset(&self.vreg_const_known, false);
        @memset(&self.vreg_const_imm, 0);
        @memset(&self.vreg_elided_const, false);
        @memset(&self.vreg_def_cnt, 0);

        for (0..ir_fn.block_count) |bi| {
            const blk = &ir_fn.blocks[bi];
            for (0..blk.inst_count) |ii| {
                const inst = blk.insts[ii];
                if (inst.dest > 0 and inst.dest < MAX_VREGS) {
                    self.vreg_def_cnt[inst.dest] = self.vreg_def_cnt[inst.dest] +| 1;
                    if (inst.op == .const_int) {
                        self.vreg_const_known[inst.dest] = true;
                        self.vreg_const_imm[inst.dest] = inst.imm;
                    }
                }
            }
        }

        var use_cnt: [MAX_VREGS]u16 = .{0} ** MAX_VREGS;
        var non_foldable: [MAX_VREGS]bool = .{false} ** MAX_VREGS;

        for (0..MAX_VREGS) |v| {
            if (self.vreg_def_cnt[v] != 1) self.vreg_const_known[v] = false;
        }

        for (0..ir_fn.block_count) |bi| {
            const blk = &ir_fn.blocks[bi];
            for (0..blk.inst_count) |ii| {
                const inst = blk.insts[ii];
                if (inst.src1 > 0 and inst.src1 < MAX_VREGS) {
                    use_cnt[inst.src1] = use_cnt[inst.src1] +| 1;
                    if (inst.op != .ret and !(isCommutative(inst.op) and self.vreg_const_known[inst.src1] and fitsI32NonMin(self.vreg_const_imm[inst.src1]))) {
                        non_foldable[inst.src1] = true;
                    }
                }
                if (inst.src2 > 0 and inst.src2 < MAX_VREGS) {
                    use_cnt[inst.src2] = use_cnt[inst.src2] +| 1;
                    if (self.vreg_const_known[inst.src2]) {
                        const imm = self.vreg_const_imm[inst.src2];
                        const ok = (isFoldableRhsBinOp(inst.op) and fitsI32NonMin(imm)) or
                            (isShiftOp(inst.op) and imm >= 0 and imm < 64);
                        if (!ok) non_foldable[inst.src2] = true;
                    }
                }
                for (0..@min(inst.arg_count, inst.args.len)) |ai| {
                    const a = inst.args[ai];
                    if (a > 0 and a < MAX_VREGS) {
                        use_cnt[a] = use_cnt[a] +| 1;
                        if (inst.op != .call) non_foldable[a] = true;
                    }
                }
            }
        }

        for (1..MAX_VREGS) |v| {
            if (self.vreg_const_known[v] and (!non_foldable[v] or use_cnt[v] <= 1 or fitsI32NonMin(self.vreg_const_imm[v]))) {
                self.vreg_elided_const[v] = true;
            }
        }
    }

    fn isCommutative(op: IROp) bool {
        return switch (op) {
            .add, .mul, .bit_and, .bit_or, .bit_xor, .cmp_eq, .cmp_ne => true,
            else => false,
        };
    }

    fn allocRegsForFn(self: *IRCodegen, ir_fn: *const IRFn) void {
        @memset(&self.vreg_reg, NO_REG);
        @memset(&self.vreg_spill_slot, 0);
        @memset(&self.vreg_last_use, 0);
        @memset(&self.vreg_start, 0xFFFF_FFFF);
        @memset(&self.vreg_end, 0);
        @memset(&self.vreg_crosses_call, false);
        @memset(&self.vreg_copy_hint, 0);

        self.analyzeElidedConsts(ir_fn);

        var block_start_pos: [ir_mod.MAX_BLOCKS_PER_FN]u32 = .{0} ** ir_mod.MAX_BLOCKS_PER_FN;
        var block_end_pos: [ir_mod.MAX_BLOCKS_PER_FN]u32 = .{0} ** ir_mod.MAX_BLOCKS_PER_FN;
        var call_positions: [1024]u32 = undefined;
        var call_pos_count: usize = 0;
        var overflow_call_min_pos: u32 = std.math.maxInt(u32);

        var max_vreg: u32 = 0;
        var pos: u32 = 0;
        var vreg_weight: [MAX_VREGS]u32 = .{0} ** MAX_VREGS;
        var vreg_fused_skip: [MAX_VREGS]bool = .{false} ** MAX_VREGS;

        for (0..ir_fn.block_count) |bi| {
            block_start_pos[bi] = pos;
            const blk = &ir_fn.blocks[bi];
            for (0..blk.inst_count) |ii| {
                const inst = blk.insts[ii];
                if (inst.op == .copy and inst.dest > 0 and inst.dest < MAX_VREGS and
                    inst.src1 > 0 and inst.src1 < MAX_VREGS and !self.vreg_elided_const[inst.src1])
                {
                    if (self.vreg_copy_hint[inst.dest] == 0) self.vreg_copy_hint[inst.dest] = inst.src1;
                    if (self.vreg_copy_hint[inst.src1] == 0) self.vreg_copy_hint[inst.src1] = inst.dest;
                } else if (inst.dest > 0 and inst.dest < MAX_VREGS) {
                    const two_addr_s1: u16 = switch (inst.op) {
                        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => inst.src1,
                        .call_ptr_add => if (inst.arg_count >= 1) inst.args[0] else 0,
                        else => 0,
                    };
                    if (two_addr_s1 > 0 and two_addr_s1 < MAX_VREGS and !self.vreg_elided_const[two_addr_s1]) {
                        if (self.vreg_copy_hint[inst.dest] == 0) self.vreg_copy_hint[inst.dest] = two_addr_s1;
                    }
                }
                if (ii + 1 < blk.inst_count and isCmpOp(inst.op) and blk.insts[ii + 1].op == .cond_jump and
                    inst.dest > 0 and inst.dest < MAX_VREGS and blk.insts[ii + 1].src1 == inst.dest and
                    self.vreg_def_cnt[inst.dest] == 1)
                {
                    // Verify no other instruction uses inst.dest (only the immediately following cond_jump)
                    var single_next_use = true;
                    for (0..ir_fn.block_count) |obi| {
                        const ob = &ir_fn.blocks[obi];
                        for (0..ob.inst_count) |oii| {
                            if (obi == bi and oii == ii + 1) continue;
                            const oi = ob.insts[oii];
                            if (oi.src1 == inst.dest or oi.src2 == inst.dest) {
                                single_next_use = false;
                                break;
                            }
                            for (0..@min(oi.arg_count, oi.args.len)) |ai| {
                                if (oi.args[ai] == inst.dest) {
                                    single_next_use = false;
                                    break;
                                }
                            }
                            if (!single_next_use) break;
                        }
                        if (!single_next_use) break;
                    }
                    if (single_next_use) vreg_fused_skip[inst.dest] = true;
                }
                if (inst.src1 > 0 and inst.src1 < MAX_VREGS and !self.vreg_elided_const[inst.src1]) {
                    const v = inst.src1;
                    max_vreg = @max(max_vreg, v);
                    self.vreg_last_use[v] = pos;
                    if (!vreg_fused_skip[v]) {
                        self.vreg_start[v] = @min(self.vreg_start[v], pos);
                        self.vreg_end[v] = @max(self.vreg_end[v], pos);
                        vreg_weight[v] +|= 1;
                    }
                }
                if (inst.src2 > 0 and inst.src2 < MAX_VREGS and !self.vreg_elided_const[inst.src2]) {
                    const v = inst.src2;
                    max_vreg = @max(max_vreg, v);
                    self.vreg_last_use[v] = pos;
                    if (!vreg_fused_skip[v]) {
                        self.vreg_start[v] = @min(self.vreg_start[v], pos);
                        self.vreg_end[v] = @max(self.vreg_end[v], pos);
                        vreg_weight[v] +|= 1;
                    }
                }
                for (0..@min(inst.arg_count, inst.args.len)) |ai| {
                    const v = inst.args[ai];
                    if (v > 0 and v < MAX_VREGS and !self.vreg_elided_const[v]) {
                        max_vreg = @max(max_vreg, v);
                        self.vreg_last_use[v] = pos;
                        if (!vreg_fused_skip[v]) {
                            self.vreg_start[v] = @min(self.vreg_start[v], pos);
                            self.vreg_end[v] = @max(self.vreg_end[v], pos);
                            vreg_weight[v] +|= 1;
                        }
                    }
                }
                if (inst.dest > 0 and inst.dest < MAX_VREGS and !self.vreg_elided_const[inst.dest]) {
                    const v = inst.dest;
                    max_vreg = @max(max_vreg, v);
                    if (!vreg_fused_skip[v]) {
                        self.vreg_start[v] = @min(self.vreg_start[v], pos);
                        self.vreg_end[v] = @max(self.vreg_end[v], pos);
                        vreg_weight[v] +|= 1;
                    }
                }
                if (isCallClobberingOp(inst.op)) {
                    if (call_pos_count < call_positions.len) {
                        call_positions[call_pos_count] = pos;
                        call_pos_count += 1;
                    } else if (pos < overflow_call_min_pos) {
                        overflow_call_min_pos = pos;
                    }
                }
                pos += 1;
            }
            block_end_pos[bi] = if (pos > block_start_pos[bi]) pos - 1 else pos;
        }

        // Extend live ranges across loop back-edges and weight loop-hot variables
        for (0..ir_fn.block_count) |bi| {
            const blk = &ir_fn.blocks[bi];
            if (blk.inst_count == 0) continue;
            const term = blk.insts[blk.inst_count - 1];
            var back_targets: [2]u16 = .{ 0xFFFF, 0xFFFF };
            if (term.op == .jump and term.target_block <= bi) back_targets[0] = term.target_block;
            if (term.op == .cond_jump) {
                if (term.target_block <= bi) back_targets[0] = term.target_block;
                if (term.alt_block <= bi) back_targets[1] = term.alt_block;
            }
            for (back_targets) |bt| {
                if (bt == 0xFFFF) continue;
                const loop_start = block_start_pos[bt];
                const loop_end = block_end_pos[bi];
                for (bt..bi + 1) |lbi| {
                    const lb = &ir_fn.blocks[lbi];
                    for (0..lb.inst_count) |lii| {
                        const linst = lb.insts[lii];
                        if (linst.src1 > 0 and linst.src1 < MAX_VREGS) vreg_weight[linst.src1] +|= 8;
                        if (linst.src2 > 0 and linst.src2 < MAX_VREGS) vreg_weight[linst.src2] +|= 8;
                        for (0..@min(linst.arg_count, linst.args.len)) |lai| {
                            const la = linst.args[lai];
                            if (la > 0 and la < MAX_VREGS) vreg_weight[la] +|= 8;
                        }
                        if (linst.dest > 0 and linst.dest < MAX_VREGS) vreg_weight[linst.dest] +|= 8;
                    }
                }
                var v: u32 = 1;
                while (v <= max_vreg) : (v += 1) {
                    if (self.vreg_start[v] <= loop_end and self.vreg_end[v] >= loop_start) {
                        self.vreg_end[v] = @max(self.vreg_end[v], loop_end);
                        if (self.vreg_def_cnt[v] > 1 and self.vreg_start[v] > loop_start) {
                            self.vreg_start[v] = loop_start;
                        }
                    }
                }
            }
        }

        var order: [MAX_VREGS]u16 = undefined;
        var order_count: usize = 0;
        var v: u32 = 1;
        while (v <= max_vreg) : (v += 1) {
            if (self.vreg_elided_const[v] or vreg_fused_skip[v] or self.vreg_start[v] > self.vreg_end[v]) continue;
            for (call_positions[0..call_pos_count]) |cp| {
                if (self.vreg_start[v] < cp and cp < self.vreg_end[v]) {
                    self.vreg_crosses_call[v] = true;
                    break;
                }
            }
            if (!self.vreg_crosses_call[v] and self.vreg_end[v] > overflow_call_min_pos) {
                self.vreg_crosses_call[v] = true;
            }
            order[order_count] = @intCast(v);
            order_count += 1;
        }

        var i: usize = 1;
        while (i < order_count) : (i += 1) {
            const key = order[i];
            const key_start = self.vreg_start[key];
            var j: usize = i;
            while (j > 0 and self.vreg_start[order[j - 1]] > key_start) : (j -= 1) {
                order[j] = order[j - 1];
            }
            order[j] = key;
        }

        var reg_owner: [16]u16 = .{0} ** 16;
        var used_callee_mask: u16 = 0;
        var next_spill: u32 = 1;

        for (order[0..order_count]) |cur_v| {
            const cur_s = self.vreg_start[cur_v];

            for (ALL_ALLOC_REGS) |r| {
                const own = reg_owner[r];
                if (own != 0 and self.vreg_end[own] < cur_s) {
                    reg_owner[r] = 0;
                }
            }

            var chosen: u8 = NO_REG;

            // Check copy coalescing / dying two-address reuse hint first
            const hint_v = self.vreg_copy_hint[cur_v];
            if (hint_v > 0 and hint_v < MAX_VREGS) {
                const hr = self.vreg_reg[hint_v];
                if (hr != NO_REG) {
                    const can_take = (reg_owner[hr] == 0) or
                        (reg_owner[hr] == hint_v and self.vreg_end[hint_v] == cur_s and
                        self.vreg_start[cur_v] == cur_s and self.vreg_def_cnt[cur_v] == 1);
                    const is_callee = (hr == 3 or hr >= 12);
                    if (can_take and (!self.vreg_crosses_call[cur_v] or is_callee)) {
                        chosen = hr;
                    }
                }
            }

            if (chosen == NO_REG and !self.vreg_crosses_call[cur_v]) {
                for (CALLER_SAVED_POOL) |r| {
                    if (reg_owner[r] == 0) {
                        chosen = r;
                        break;
                    }
                }
            }
            if (chosen == NO_REG) {
                for (CALLEE_SAVED_POOL) |r| {
                    if (reg_owner[r] == 0) {
                        chosen = r;
                        break;
                    }
                }
            }

            if (chosen != NO_REG) {
                reg_owner[chosen] = cur_v;
                self.vreg_reg[cur_v] = chosen;
                if (chosen == 3 or chosen >= 12) {
                    used_callee_mask |= @as(u16, 1) << @intCast(chosen);
                }
            } else {
                const pool = if (self.vreg_crosses_call[cur_v]) &CALLEE_SAVED_POOL else &ALL_ALLOC_REGS;
                var best_r: u8 = NO_REG;
                var best_weight: u32 = vreg_weight[cur_v];
                var best_end: u32 = self.vreg_end[cur_v];
                for (pool) |r| {
                    const own = reg_owner[r];
                    if (own == 0) continue;
                    const ow = vreg_weight[own];
                    const oe = self.vreg_end[own];
                    if (ow < best_weight or (ow == best_weight and oe > best_end)) {
                        best_weight = ow;
                        best_end = oe;
                        best_r = r;
                    }
                }
                if (best_r != NO_REG) {
                    const evicted = reg_owner[best_r];
                    self.vreg_reg[evicted] = NO_REG;
                    self.vreg_spill_slot[evicted] = ir_fn.total_locals + next_spill;
                    next_spill += 1;
                    reg_owner[best_r] = cur_v;
                    self.vreg_reg[cur_v] = best_r;
                    if (best_r == 3 or best_r >= 12) {
                        used_callee_mask |= @as(u16, 1) << @intCast(best_r);
                    }
                } else {
                    self.vreg_reg[cur_v] = NO_REG;
                    self.vreg_spill_slot[cur_v] = ir_fn.total_locals + next_spill;
                    next_spill += 1;
                }
            }
        }

        self.cur_num_spills = next_spill - 1;
        self.cur_callee_count = 0;
        for (CALLEE_SAVED_POOL) |r| {
            if ((used_callee_mask & (@as(u16, 1) << @intCast(r))) != 0) {
                self.cur_callee_regs[self.cur_callee_count] = r;
                self.cur_callee_count += 1;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Vreg accessors
    // ═══════════════════════════════════════════════════════════

    fn vregPhys(self: *const IRCodegen, vreg: u16) ?u8 {
        if (vreg == 0 or vreg >= MAX_VREGS) return null;
        if (self.vreg_elided_const[vreg]) return null;
        const r = self.vreg_reg[vreg];
        return if (r == NO_REG) null else r;
    }

    fn loadVregToReg(self: *IRCodegen, vreg: u16, hw_reg: u8) void {
        if (vreg == 0 or vreg >= MAX_VREGS) {
            self.xorReg(hw_reg, hw_reg);
            return;
        }
        if (self.vreg_elided_const[vreg]) {
            self.mov64imm(hw_reg, @bitCast(self.vreg_const_imm[vreg]));
            return;
        }
        if (self.vregPhys(vreg)) |phys| {
            self.movRegReg(hw_reg, phys);
        } else {
            const slot = self.vreg_spill_slot[vreg];
            if (slot > 0) self.loadSlotToReg(hw_reg, slot) else self.xorReg(hw_reg, hw_reg);
        }
    }

    fn storeRegToVreg(self: *IRCodegen, hw_reg: u8, vreg: u16) void {
        if (vreg == 0 or vreg >= MAX_VREGS) return;
        if (self.vregPhys(vreg)) |phys| {
            self.movRegReg(phys, hw_reg);
        } else {
            const slot = self.vreg_spill_slot[vreg];
            if (slot > 0) self.storeRegToSlot(hw_reg, slot);
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Compilation entry point & _start + ABI epilogues
    // ═══════════════════════════════════════════════════════════

    pub fn compile(self: *IRCodegen) void {
        if (@as(usize, self.ir.fn_count) > self.fns.len) {
            self.overflowed = true;
            return;
        }
        for (0..self.ir.fn_count) |i| {
            const f = &self.ir.fns[i];
            self.fns[i] = .{
                .name_start = f.name_start,
                .name_len = f.name_len,
                .source_id = f.source_id,
                .ir_fn_idx = @intCast(i),
                .param_count = f.param_count,
                .code_offset = 0,
                .param_store_offset = 0,
            };
        }
        self.fn_count = self.ir.fn_count;

        self.emitStartStub();
        self.text_user_start = self.code_len;

        var compiled: [ir_mod.MAX_FNS]bool = .{false} ** ir_mod.MAX_FNS;
        for (0..self.fn_count) |i| {
            if (eql(self.irFnName(@intCast(i)), "main")) {
                self.compileFn(@intCast(i));
                compiled[i] = true;
                break;
            }
        }
        for (0..self.fn_count) |i| {
            if (!compiled[i]) self.compileFn(@intCast(i));
        }
        self.text_user_end = self.code_len;

        if (self.overflowed) return;
        self.emitPrintIntRoutine();
        self.emitAllocRoutines();
        self.emitArrayRoutines();
        self.emitSplitRoutine();
        self.emitFloatRoutines();
        self.emitMapRoutines();
        self.emitChanRoutines();
        self.emitAssertFailRoutine();
        self.reserveCfiTable();
        self.emitCfiRoutine();
        if (self.overflowed) return;

        self.relaxAndPatch();
    }

    fn emitStartStub(self: *IRCodegen) void {
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x04);
        self.emit8(0x24); // mov rax, [rsp] (argc)
        self.mov64imm(1, DATA_VADDR);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x01); // mov [rcx], rax
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x54);
        self.emit8(0xC4);
        self.emit8(0x10); // lea rdx, [rsp + rax*8 + 16] (envp)
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x51);
        self.emit8(0x68); // mov [rcx + 0x68], rdx
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(0x08); // lea rax, [rsp+8]
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x41);
        self.emit8(0x08); // mov [rcx+8], rax
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xE4);
        self.emit8(0xF0); // and rsp, -16

        // Seed per-process cryptographic secrets ([DATA_VADDR+0x70]=heap_secret, [DATA_VADDR+0x78]=stack_canary)
        self.subRspImm(16);
        self.movRegReg(3, 4); // rbx = cursor
        self.mov64imm(12, 16); // r12 = remaining
        const seed_loop = self.code_len;
        self.movRegReg(7, 3);
        self.movRegReg(6, 12);
        self.xorReg(2, 2);
        self.mov64imm(0, 318); // SYS_getrandom
        self.syscallInst();
        self.emitCmpRegImm32(0, -4); // EINTR
        _ = self.emitJccReloc(0x4, .code_offset, seed_loop, 0);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0); // test rax, rax
        const seed_ok = self.emitJccReloc(0xF, .code_offset, 0, 0); // jg
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
        self.relocs[seed_ok].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x01);
        self.emit8(0xC3); // add rbx, rax
        self.emit8(0x49);
        self.emit8(0x29);
        self.emit8(0xC4); // sub r12, rax
        _ = self.emitJccReloc(0x5, .code_offset, seed_loop, 0); // jnz

        self.mov64imm(1, DATA_VADDR);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x04);
        self.emit8(0x24); // mov rax, [rsp]
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xE0);
        self.emit8(0xF8); // and rax, -8
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x41);
        self.emit8(0x70); // mov [rcx + 0x70], rax
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(0x08); // mov rax, [rsp + 8]
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE0);
        self.emit8(0x08); // shl rax, 8 (low byte = 0x00)
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        const can_nz = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.mov64imm(0, @bitCast(@as(i64, 0x0102030405060700)));
        self.relocs[can_nz].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x41);
        self.emit8(0x78); // mov [rcx + 0x78], rax
        // Initialize heap_min ([DATA_VADDR + 0x88]) = -1 and last_user_start ([DATA_VADDR + 0xC0]) = -1
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x81);
        self.emit32(0x88);
        self.emit32(0xFFFFFFFF);
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x81);
        self.emit32(0xC0);
        self.emit32(0xFFFFFFFF);
        // Scrub entropy stack buffer and clear registers before main
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x04);
        self.emit8(0x24);
        self.emit32(0);
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(0x08);
        self.emit32(0);
        self.addRspImm(16);
        self.xorReg(0, 0);
        self.xorReg(1, 1);
        self.xorReg(2, 2);
        self.xorReg(3, 3);
        self.xorReg(6, 6);
        self.xorReg(7, 7);
        self.xorReg(12, 12);

        if (self.findFn("main")) |main_fi| {
            self.emitCallReloc(.fn_call, main_fi);
            self.movRegReg(7, 0);
        } else {
            self.xorReg(7, 7);
        }
        self.mov64imm(0, 60);
        self.syscallInst();
    }

    fn irFnName(self: *const IRCodegen, idx: u32) []const u8 {
        const f = &self.ir.fns[idx];
        const s = self.ir.sourceFor(f.source_id, self.src);
        if (@as(usize, f.name_start) + @as(usize, f.name_len) <= s.len) {
            return s[f.name_start..][0..f.name_len];
        }
        return "";
    }

    fn irFnNameByStr(self: *const IRCodegen, start: u32, len: u32, sid: u16) []const u8 {
        const s = self.ir.sourceFor(sid, self.src);
        if (@as(usize, start) + @as(usize, len) <= s.len) {
            return s[start..][0..len];
        }
        return "";
    }

    fn emitEpilogueReturn(self: *IRCodegen) void {
        if (self.cur_frame_active) {
            if (self.cur_canary_active) {
                self.mov64imm(11, DATA_VADDR + 0x78);
                self.emit8(0x4D);
                self.emit8(0x8B);
                self.emit8(0x1B); // mov r11, [r11]
                self.emit8(0x4C);
                self.emit8(0x3B);
                self.emit8(0x5D);
                self.emit8(0xF8); // cmp r11, [rbp - 8]
                self.emit8(0x74);
                self.emit8(0x02); // je +2
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2 (stack buffer overflow detected)
                self.emit8(0x45);
                self.emit8(0x31);
                self.emit8(0xDB); // xor r11d, r11d
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x45);
                self.emit8(0xF8);
                self.emit32(0); // mov qword [rbp - 8], 0
            }
            const data_slots = self.cur_total_locals + self.cur_num_spills;
            var k: u32 = 0;
            while (k < self.cur_callee_count) : (k += 1) {
                const slot = data_slots + 1 + k;
                self.loadSlotToReg(self.cur_callee_regs[k], slot);
            }
            self.emit8(0x48);
            self.emit8(0x89);
            self.emit8(0xEC); // mov rsp, rbp
            self.emit8(0x5D); // pop rbp
            self.emit8(0xC3); // ret
        } else {
            self.addRspImm(self.cur_stack_adj);
            var k: u32 = self.cur_callee_count;
            while (k > 0) {
                k -= 1;
                self.popReg(self.cur_callee_regs[k]);
            }
            self.emit8(0xC3); // ret
        }
    }

    fn detectEntryRegOnlyParams(self: *IRCodegen, ir_fn: *const IRFn) bool {
        @memset(&self.param_reg_only, false);
        @memset(&self.param_target_vreg, 0);
        @memset(&self.param_load_skip, false);

        // Track slot accesses across the whole function
        var non_entry_load_cnt: [8]u32 = .{0} ** 8;
        var entry_load_cnt: [8]u32 = .{0} ** 8;
        var slot_written_or_addr: [8]bool = .{false} ** 8;
        var other_slot_used = false;
        var has_calls = false;

        var b0_entry_limit: usize = 0;
        if (ir_fn.block_count > 0) {
            const b0 = &ir_fn.blocks[0];
            while (b0_entry_limit < b0.inst_count and b0.insts[b0_entry_limit].op == .load_local) : (b0_entry_limit += 1) {}
        }

        for (0..ir_fn.block_count) |bi| {
            const blk = &ir_fn.blocks[bi];
            for (0..blk.inst_count) |ii| {
                const inst = blk.insts[ii];
                if (isCallClobberingOp(inst.op)) has_calls = true;
                switch (inst.op) {
                    .load_local, .store_local, .addr_of, .alloca => {
                        var match_pi: ?usize = null;
                        for (0..@min(ir_fn.param_count, 6)) |pi| {
                            if (inst.slot == ir_fn.param_slots[pi]) {
                                match_pi = pi;
                                break;
                            }
                        }
                        if (match_pi) |pi| {
                            if (inst.op == .load_local and bi == 0 and ii < b0_entry_limit) {
                                entry_load_cnt[pi] += 1;
                                self.param_target_vreg[pi] = inst.dest;
                            } else if (inst.op == .load_local) {
                                non_entry_load_cnt[pi] += 1;
                            } else {
                                slot_written_or_addr[pi] = true;
                            }
                        } else {
                            other_slot_used = true;
                        }
                    },
                    else => {},
                }
            }
        }

        if (ir_fn.param_count <= 6) {
            for (0..@min(ir_fn.param_count, 6)) |pi| {
                const ps = ir_fn.param_slots[pi];
                const tv = self.param_target_vreg[pi];
                if (ps < ir_fn.local_addr_taken.len and !ir_fn.local_addr_taken[ps] and
                    !slot_written_or_addr[pi] and non_entry_load_cnt[pi] == 0 and
                    entry_load_cnt[pi] == 1 and tv > 0 and tv < MAX_VREGS and
                    self.vreg_def_cnt[tv] == 1)
                {
                    self.param_reg_only[pi] = true;
                    self.param_load_skip[pi] = true;
                } else {
                    other_slot_used = true;
                }
            }
        } else {
            other_slot_used = true;
        }

        // Keep frame pointer when spills exist, non-param stack slots exist, or >6 params
        self.cur_frame_active = other_slot_used or (self.cur_num_spills > 0) or (ir_fn.param_count > 6);
        return has_calls;
    }

    fn emitParallelRegParamMoves(self: *IRCodegen, ir_fn: *const IRFn) void {
        const Item = struct { dst_vreg: u16, dst_phys: u8, src_phys: u8, active: bool };
        var items: [6]Item = undefined;
        var count: usize = 0;

        for (0..@min(ir_fn.param_count, 6)) |pi| {
            if (!self.param_reg_only[pi]) continue;
            const tv = self.param_target_vreg[pi];
            if (self.vregPhys(tv)) |dp| {
                if (dp != ARG_REGS[pi]) {
                    items[count] = .{ .dst_vreg = tv, .dst_phys = dp, .src_phys = ARG_REGS[pi], .active = true };
                    count += 1;
                }
            } else {
                // Target vreg spilled -> store directly into spill slot
                self.storeRegToVreg(ARG_REGS[pi], tv);
            }
        }

        var rem = true;
        while (rem) {
            rem = false;
            var prog = false;
            for (0..count) |i| {
                if (!items[i].active) continue;
                rem = true;
                var conflict = false;
                for (0..count) |j| {
                    if (j != i and items[j].active and items[j].src_phys == items[i].dst_phys) {
                        conflict = true;
                        break;
                    }
                }
                if (!conflict) {
                    self.movRegReg(items[i].dst_phys, items[i].src_phys);
                    items[i].active = false;
                    prog = true;
                    break;
                }
            }
            if (rem and !prog) {
                for (0..count) |i| {
                    if (!items[i].active) continue;
                    const victim = items[i].dst_phys;
                    self.movRegReg(11, victim); // r11 scratch
                    for (0..count) |j| {
                        if (items[j].active and items[j].src_phys == victim) items[j].src_phys = 11;
                    }
                    break;
                }
            }
        }
    }

    fn compileFn(self: *IRCodegen, fi: u32) void {
        const f = &self.fns[fi];
        const ir_fn = &self.ir.fns[f.ir_fn_idx];

        self.cur_fn_idx = fi;
        self.cur_total_locals = ir_fn.total_locals;
        self.allocRegsForFn(ir_fn);
        const has_calls = self.detectEntryRegOnlyParams(ir_fn);
        self.cur_canary_active = self.cur_frame_active;

        // Check whether function qualifies for shrink-wrapping:
        // B0 only inspects register-only params/constants, compares, and branches to an immediate-return leaf block.
        var shrink_ret_bi: u16 = 0xFFFF;
        var shrink_cont_bi: u16 = 0xFFFF;
        var can_shrink = !self.cur_frame_active and self.cur_callee_count > 0 and
            ir_fn.param_count > 0 and ir_fn.param_count <= 6 and ir_fn.block_count >= 3;
        if (can_shrink) {
            for (0..ir_fn.param_count) |pi| {
                const tv = self.param_target_vreg[pi];
                if (!self.param_reg_only[pi] or tv == 0 or tv >= MAX_VREGS or self.vreg_elided_const[tv]) {
                    can_shrink = false;
                    break;
                }
            }
        }
        if (can_shrink) {
            var in_deg: [ir_mod.MAX_BLOCKS_PER_FN]u16 = .{0} ** ir_mod.MAX_BLOCKS_PER_FN;
            for (0..ir_fn.block_count) |bi| {
                const blk = &ir_fn.blocks[bi];
                if (blk.inst_count == 0) continue;
                const term = blk.insts[blk.inst_count - 1];
                if (term.op == .jump) {
                    if (term.target_block < ir_fn.block_count) in_deg[term.target_block] += 1;
                } else if (term.op == .cond_jump) {
                    if (term.target_block < ir_fn.block_count) in_deg[term.target_block] += 1;
                    if (term.alt_block < ir_fn.block_count) in_deg[term.alt_block] += 1;
                }
            }
            const b0 = &ir_fn.blocks[0];
            if (in_deg[0] != 0 or b0.inst_count < 2) {
                can_shrink = false;
            } else {
                const term = b0.insts[b0.inst_count - 1];
                if (term.op != .cond_jump or term.target_block == term.alt_block or
                    term.target_block == 0 or term.alt_block == 0 or
                    term.target_block >= ir_fn.block_count or term.alt_block >= ir_fn.block_count)
                {
                    can_shrink = false;
                } else {
                    // Verify B0 only reads params/elided constants and feeds cond_jump with a fused cmp
                    var cmp_v: u16 = 0;
                    if (b0.inst_count >= 2 and isCmpOp(b0.insts[b0.inst_count - 2].op)) {
                        const ci = b0.insts[b0.inst_count - 2];
                        if (ci.dest != 0 and ci.dest == term.src1 and ci.dest < MAX_VREGS and
                            self.vreg_def_cnt[ci.dest] == 1 and self.vreg_last_use[ci.dest] == b0.inst_count - 1)
                        {
                            cmp_v = ci.dest;
                        }
                    }
                    for (0..b0.inst_count - 1) |ii| {
                        const inst = b0.insts[ii];
                        if (inst.op == .load_local) {
                            var is_pskip = false;
                            for (0..@min(ir_fn.param_count, 6)) |pi| {
                                if (self.param_load_skip[pi] and inst.dest == self.param_target_vreg[pi] and inst.slot == ir_fn.param_slots[pi]) {
                                    is_pskip = true;
                                    break;
                                }
                            }
                            if (!is_pskip) {
                                can_shrink = false;
                                break;
                            }
                        } else if (inst.op == .const_int) {
                            if (inst.dest == 0 or inst.dest >= MAX_VREGS or !self.vreg_elided_const[inst.dest]) {
                                can_shrink = false;
                                break;
                            }
                        } else if (isCmpOp(inst.op) and inst.dest != 0 and inst.dest == cmp_v) {
                            // fused compare leaves no register writes
                        } else {
                            can_shrink = false;
                            break;
                        }
                    }
                    if (can_shrink) {
                        const cands = [2]u16{ term.target_block, term.alt_block };
                        for (cands, 0..) |cand, ci_idx| {
                            if (in_deg[cand] != 1) continue;
                            const rb = &ir_fn.blocks[cand];
                            if (rb.inst_count == 0) continue;
                            var rb_ok = true;
                            for (0..rb.inst_count) |ri| {
                                const rinst = rb.insts[ri];
                                if (ri + 1 < rb.inst_count) {
                                    if (rinst.op == .const_int and
                                        rinst.dest > 0 and rinst.dest < MAX_VREGS and self.vreg_elided_const[rinst.dest])
                                    {
                                        continue;
                                    }
                                    rb_ok = false;
                                    break;
                                } else {
                                    if (rinst.op != .ret) {
                                        rb_ok = false;
                                        break;
                                    }
                                    if (rinst.src1 != 0 and !(rinst.src1 < MAX_VREGS and self.vreg_elided_const[rinst.src1])) {
                                        var is_param_v = false;
                                        for (0..ir_fn.param_count) |pi| {
                                            if (rinst.src1 == self.param_target_vreg[pi]) {
                                                is_param_v = true;
                                                break;
                                            }
                                        }
                                        if (!is_param_v) rb_ok = false;
                                    }
                                }
                            }
                            if (rb_ok) {
                                shrink_ret_bi = cand;
                                shrink_cont_bi = cands[1 - ci_idx];
                                break;
                            }
                        }
                        if (shrink_ret_bi == 0xFFFF) can_shrink = false;
                    }
                }
            }
        }

        f.code_offset = self.code_len;

        var saved_param_regs: [6]u8 = .{NO_REG} ** 6;
        const saved_callee_count: u32 = self.cur_callee_count;
        const saved_stack_adj: u32 = if (has_calls and (saved_callee_count % 2 == 0)) 8 else 0;
        var b0_reloc_start: u32 = self.reloc_count;

        if (can_shrink) {
            for (0..ir_fn.param_count) |pi| {
                const tv = self.param_target_vreg[pi];
                saved_param_regs[pi] = self.vreg_reg[tv];
                self.vreg_reg[tv] = ARG_REGS[pi];
            }
            self.cur_callee_count = 0;
            self.cur_stack_adj = 0;
            b0_reloc_start = self.reloc_count;
            f.param_store_offset = self.code_len;
        } else if (self.cur_frame_active) {
            self.emit8(0x55); // push rbp
            self.movRegReg(5, 4); // mov rbp, rsp
            const total_slots = ir_fn.total_locals + self.cur_num_spills + self.cur_callee_count + @as(u32, if (self.cur_canary_active) 1 else 0);
            const aligned_frame = ((total_slots * 8) + 15) & ~@as(u32, 15);
            if (aligned_frame > 0) self.subRspImm(aligned_frame);

            if (self.cur_canary_active) {
                self.mov64imm(11, DATA_VADDR + 0x78);
                self.emit8(0x4D);
                self.emit8(0x8B);
                self.emit8(0x1B); // mov r11, [r11]
                self.emit8(0x4C);
                self.emit8(0x89);
                self.emit8(0x5D);
                self.emit8(0xF8); // mov [rbp - 8], r11
                self.emit8(0x45);
                self.emit8(0x31);
                self.emit8(0xDB); // xor r11d, r11d
            }

            const data_slots = ir_fn.total_locals + self.cur_num_spills;
            for (0..self.cur_callee_count) |k| {
                self.storeRegToSlot(self.cur_callee_regs[k], data_slots + 1 + @as(u32, @intCast(k)));
            }
            self.cur_stack_adj = 0;
        } else {
            for (0..self.cur_callee_count) |k| {
                self.pushReg(self.cur_callee_regs[k]);
            }
            // Entry rsp is 16k + 8. Align rsp to 16 bytes before making nested calls.
            self.cur_stack_adj = if (has_calls and (self.cur_callee_count % 2 == 0)) 8 else 0;
            self.subRspImm(self.cur_stack_adj);
        }

        if (!can_shrink) {
            // Tail calls jump here with updated args in ABI regs
            f.param_store_offset = self.code_len;
            for (0..@min(ir_fn.param_count, ARG_REGS.len)) |pi| {
                if (!self.param_reg_only[pi]) {
                    self.storeRegToSlot(ARG_REGS[pi], ir_fn.param_slots[pi]);
                }
            }
            // Handle 7th and 8th stack parameters ([rbp + 16], [rbp + 24])
            if (ir_fn.param_count > 6 and self.cur_frame_active) {
                for (6..@min(ir_fn.param_count, 8)) |pi| {
                    const caller_off: i32 = 16 + @as(i32, @intCast(pi - 6)) * 8;
                    self.emitMemLoadDisp(0, 5, caller_off);
                    self.storeRegToSlot(0, ir_fn.param_slots[pi]);
                }
            }
            self.emitParallelRegParamMoves(ir_fn);
        }

        var emit_order: [ir_mod.MAX_BLOCKS_PER_FN]u16 = undefined;
        if (can_shrink) {
            emit_order[0] = 0;
            emit_order[1] = shrink_ret_bi;
            emit_order[2] = shrink_cont_bi;
            var oi: usize = 3;
            for (1..ir_fn.block_count) |bi_u| {
                const bu: u16 = @intCast(bi_u);
                if (bu == shrink_ret_bi or bu == shrink_cont_bi) continue;
                emit_order[oi] = bu;
                oi += 1;
            }
        } else {
            for (0..ir_fn.block_count) |bi_u| {
                emit_order[bi_u] = @intCast(bi_u);
            }
        }

        var block_base_pos: [ir_mod.MAX_BLOCKS_PER_FN]u32 = .{0} ** ir_mod.MAX_BLOCKS_PER_FN;
        {
            var p: u32 = 0;
            for (0..ir_fn.block_count) |bi| {
                block_base_pos[bi] = p;
                p += ir_fn.blocks[bi].inst_count;
            }
        }

        const fn_name = self.irFnName(fi);

        for (0..ir_fn.block_count) |ord_i| {
            if (can_shrink and ord_i == 2) {
                const prologue_pos = self.code_len;
                for (b0_reloc_start..self.reloc_count) |ri| {
                    if (self.relocs[ri].target_kind == .block and self.relocs[ri].target_id == shrink_cont_bi) {
                        self.relocs[ri].target_kind = .code_offset;
                        self.relocs[ri].target_id = prologue_pos;
                    }
                }
                self.cur_callee_count = saved_callee_count;
                self.cur_stack_adj = saved_stack_adj;
                for (0..ir_fn.param_count) |pi| {
                    self.vreg_reg[self.param_target_vreg[pi]] = saved_param_regs[pi];
                }
                for (0..self.cur_callee_count) |k| {
                    self.pushReg(self.cur_callee_regs[k]);
                }
                self.subRspImm(self.cur_stack_adj);
                f.param_store_offset = self.code_len;
                self.emitParallelRegParamMoves(ir_fn);
            }
            const bi = emit_order[ord_i];
            self.cur_next_emit_bi = if (ord_i + 1 < ir_fn.block_count and !(can_shrink and ord_i == 1))
                emit_order[ord_i + 1]
            else
                0xFFFF;
            self.block_offsets[fi][bi] = self.code_len;
            const blk = &ir_fn.blocks[bi];
            var ii: u16 = 0;
            while (ii < blk.inst_count) {
                const cur_pos = block_base_pos[bi] + ii;
                const inst = blk.insts[ii];

                // Skip entry load_local already materialized directly by emitParallelRegParamMoves
                if (bi == 0 and inst.op == .load_local) {
                    var skipped = false;
                    for (0..@min(ir_fn.param_count, 6)) |pi| {
                        if (self.param_load_skip[pi] and inst.dest == self.param_target_vreg[pi] and inst.slot == ir_fn.param_slots[pi]) {
                            skipped = true;
                            break;
                        }
                    }
                    if (skipped) {
                        ii += 1;
                        continue;
                    }
                }

                // Fused compare + cond_jump optimization
                if (ii + 1 < blk.inst_count) {
                    const next_inst = blk.insts[ii + 1];
                    if (isCmpOp(inst.op) and next_inst.op == .cond_jump and
                        inst.dest != 0 and next_inst.src1 == inst.dest and
                        inst.dest < MAX_VREGS and self.vreg_def_cnt[inst.dest] == 1 and
                        self.vreg_last_use[inst.dest] == cur_pos + 1)
                    {
                        self.compileFusedCmpBranch(inst, next_inst, @intCast(bi), fi);
                        ii += 2;
                        continue;
                    }

                    // Fused ptr arithmetic (add / call_ptr_add) + inline memory access (read/write byte/u32/u64)
                    if ((inst.op == .add or inst.op == .call_ptr_add) and inst.dest != 0 and
                        inst.dest < MAX_VREGS and self.vreg_def_cnt[inst.dest] == 1 and
                        self.vreg_last_use[inst.dest] == cur_pos + 1)
                    {
                        const mem_sz: u8 = switch (next_inst.op) {
                            .call_read_byte, .call_write_byte => 1,
                            .call_read_u32, .call_write_u32 => 4,
                            .call_read_u64, .call_write_u64 => 8,
                            else => 0,
                        };
                        const is_mem_write = switch (next_inst.op) {
                            .call_write_byte, .call_write_u32, .call_write_u64 => true,
                            else => false,
                        };
                        if (mem_sz != 0 and next_inst.arg_count >= 1 and next_inst.args[0] == inst.dest and
                            (!is_mem_write or (next_inst.arg_count >= 2 and next_inst.args[1] != inst.dest)))
                        {
                            const p1 = if (inst.op == .add) inst.src1 else inst.args[0];
                            const p2 = if (inst.op == .add) inst.src2 else inst.args[1];
                            const r1 = self.vregPhys(p1);
                            const r2 = self.vregPhys(p2);
                            var computed_r11 = false;
                            if (r1 != null and r2 != null) {
                                self.emitLeaRegIdxScale(11, r1.?, r2.?, 0);
                                computed_r11 = true;
                            } else if (r1 != null and p2 > 0 and p2 < MAX_VREGS and self.vreg_const_known[p2] and fitsI32NonMin(self.vreg_const_imm[p2])) {
                                self.emitLeaRegDisp(11, r1.?, @intCast(self.vreg_const_imm[p2]));
                                computed_r11 = true;
                            } else if (r2 != null and p1 > 0 and p1 < MAX_VREGS and self.vreg_const_known[p1] and fitsI32NonMin(self.vreg_const_imm[p1])) {
                                self.emitLeaRegDisp(11, r2.?, @intCast(self.vreg_const_imm[p1]));
                                computed_r11 = true;
                            }
                            if (computed_r11) {
                                self.emitPtrTrapN(11, mem_sz);
                                if (!is_mem_write) {
                                    const dst_reg: u8 = self.vregPhys(next_inst.dest) orelse 0;
                                    switch (mem_sz) {
                                        1 => self.emitMemLoadByte(dst_reg, 11),
                                        4 => self.emitMemLoadU32(dst_reg, 11),
                                        8 => self.emitMemLoadDisp(dst_reg, 11, 0),
                                        else => unreachable,
                                    }
                                    if (next_inst.dest != 0 and self.vregPhys(next_inst.dest) == null) {
                                        self.storeRegToVreg(dst_reg, next_inst.dest);
                                    }
                                } else {
                                    const val_v = next_inst.args[1];
                                    if (mem_sz == 1 and val_v > 0 and val_v < MAX_VREGS and self.vreg_const_known[val_v]) {
                                        const imm8: u8 = @truncate(@as(u64, @bitCast(self.vreg_const_imm[val_v])));
                                        self.emitMemStoreByteImm(11, imm8);
                                    } else {
                                        const val_reg: u8 = self.vregPhys(val_v) orelse blk_val: {
                                            self.loadVregToReg(val_v, 1);
                                            break :blk_val 1;
                                        };
                                        switch (mem_sz) {
                                            1 => self.emitMemStoreByte(11, val_reg),
                                            4 => self.emitMemStoreU32(11, val_reg),
                                            8 => self.emitMemStoreDisp(11, val_reg, 0),
                                            else => unreachable,
                                        }
                                    }
                                    if (next_inst.dest != 0) {
                                        if (self.vregPhys(next_inst.dest)) |dr| {
                                            self.xorReg(dr, dr);
                                        } else {
                                            self.xorReg(0, 0);
                                            self.storeRegToVreg(0, next_inst.dest);
                                        }
                                    }
                                }
                                ii += 2;
                                continue;
                            }
                        }
                    }

                    // Fused (x +/- imm) + 1-arg call -> lea rdi, [x +/- imm]; call
                    if ((inst.op == .add or inst.op == .sub) and next_inst.op == .call and
                        next_inst.arg_count == 1 and inst.dest != 0 and next_inst.args[0] == inst.dest and
                        inst.dest < MAX_VREGS and self.vreg_def_cnt[inst.dest] == 1 and
                        self.vreg_last_use[inst.dest] == cur_pos + 1 and
                        self.vregPhys(inst.src1) != null and
                        inst.src2 > 0 and inst.src2 < MAX_VREGS and self.vreg_const_known[inst.src2])
                    {
                        const imm = self.vreg_const_imm[inst.src2];
                        if (imm > std.math.minInt(i32) and imm <= std.math.maxInt(i32)) {
                            const callee_fi = self.resolveCallTarget(next_inst) orelse {
                                self.invalid_reference = true;
                                return;
                            };
                            const disp: i32 = if (inst.op == .add) @intCast(imm) else -@as(i32, @intCast(imm));
                            self.emitLeaRegDisp(ARG_REGS[0], self.vregPhys(inst.src1).?, disp);
                            self.emitCallReloc(.fn_call, callee_fi);
                            if (next_inst.dest != 0) self.storeRegToVreg(0, next_inst.dest);
                            ii += 2;
                            continue;
                        }
                    }

                    // Self tail-call optimization: call self(...) followed immediately by ret dest
                    const is_self_call = (inst.callee_fn_idx == @as(i32, @intCast(f.ir_fn_idx))) or
                        eql(self.irFnNameByStr(inst.fn_name_start, inst.fn_name_len, inst.fn_source_id), fn_name);
                    if (inst.op == .call and next_inst.op == .ret and
                        (next_inst.src1 == inst.dest or next_inst.src1 == 0) and
                        is_self_call and inst.arg_count <= ARG_REGS.len)
                    {
                        self.compileSelfTailCall(inst, fi);
                        ii += 2;
                        continue;
                    }
                }

                self.compileIRInst(inst, @intCast(bi), fi);
                if (self.overflowed) return;
                ii += 1;
            }
        }

        var needs_fallback = true;
        if (ir_fn.block_count > 0) {
            const lb = &ir_fn.blocks[emit_order[ir_fn.block_count - 1]];
            if (lb.inst_count > 0) {
                const last_op = lb.insts[lb.inst_count - 1].op;
                if (last_op == .ret or last_op == .jump or last_op == .cond_jump or last_op == .unreachable_trap) {
                    needs_fallback = false;
                }
            }
        }
        if (needs_fallback) {
            self.xorReg(0, 0);
            self.emitEpilogueReturn();
        }
        self.cur_canary_active = false;
    }

    fn isCmpOp(op: IROp) bool {
        return switch (op) {
            .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge, .ucmp_lt, .ucmp_le, .ucmp_gt, .ucmp_ge => true,
            else => false,
        };
    }

    fn cmpCc(op: IROp) u8 {
        return switch (op) {
            .cmp_eq => 0x4, // e / z
            .cmp_ne => 0x5, // ne / nz
            .cmp_lt => 0xC, // l
            .cmp_ge => 0xD, // ge
            .cmp_le => 0xE, // le
            .cmp_gt => 0xF, // g
            .ucmp_lt => 0x2, // b
            .ucmp_ge => 0x3, // ae
            .ucmp_le => 0x6, // be
            .ucmp_gt => 0x7, // a
            else => 0x4,
        };
    }

    fn swapCmpOp(op: IROp) IROp {
        return switch (op) {
            .cmp_lt => .cmp_gt,
            .cmp_gt => .cmp_lt,
            .cmp_le => .cmp_ge,
            .cmp_ge => .cmp_le,
            .ucmp_lt => .ucmp_gt,
            .ucmp_gt => .ucmp_lt,
            .ucmp_le => .ucmp_ge,
            .ucmp_ge => .ucmp_le,
            else => op,
        };
    }

    fn emitCmpOperands(self: *IRCodegen, op_in: IROp, v_lhs_in: u16, v_rhs_in: u16) IROp {
        var op = op_in;
        var v_lhs = v_lhs_in;
        var v_rhs = v_rhs_in;

        // Put immediate on RHS if LHS is an i32 constant and RHS is not
        if (v_lhs > 0 and v_lhs < MAX_VREGS and self.vreg_const_known[v_lhs] and fitsI32NonMin(self.vreg_const_imm[v_lhs]) and
            !(v_rhs > 0 and v_rhs < MAX_VREGS and self.vreg_const_known[v_rhs]))
        {
            const tmp = v_lhs;
            v_lhs = v_rhs;
            v_rhs = tmp;
            op = swapCmpOp(op);
        }

        if (v_rhs > 0 and v_rhs < MAX_VREGS and self.vreg_const_known[v_rhs] and fitsI32NonMin(self.vreg_const_imm[v_rhs])) {
            const imm: i32 = @intCast(self.vreg_const_imm[v_rhs]);
            if (self.vregPhys(v_lhs)) |rl| {
                if (imm == 0 and (op == .cmp_eq or op == .cmp_ne)) {
                    self.emitRex(rl, rl);
                    self.emit8(0x85);
                    self.emitModRM(3, rl, rl);
                } else {
                    self.emitCmpRegImm32(rl, imm);
                }
                return op;
            }
            self.loadVregToReg(v_lhs, 0);
            self.emitCmpRegImm32(0, imm);
            return op;
        }

        if (self.vregPhys(v_lhs)) |rl| {
            if (self.vregPhys(v_rhs)) |rr| {
                self.emitRex(rr, rl);
                self.emit8(0x39);
                self.emitModRM(3, rr, rl);
                return op;
            }
        }
        self.loadVregToReg(v_lhs, 0);
        self.loadVregToReg(v_rhs, 1);
        self.emit8(0x48);
        self.emit8(0x39);
        self.emit8(0xC8);
        return op;
    }

    fn compileFusedCmpBranch(self: *IRCodegen, cmp_inst: IRInst, br_inst: IRInst, cur_bi: u16, fi: u32) void {
        _ = cur_bi;
        const eff_op = self.emitCmpOperands(cmp_inst.op, cmp_inst.src1, cmp_inst.src2);
        const cc = cmpCc(eff_op);
        if (br_inst.target_block == self.cur_next_emit_bi) {
            _ = self.emitJccReloc(cc ^ 1, .block, br_inst.alt_block, fi);
        } else if (br_inst.alt_block == self.cur_next_emit_bi) {
            _ = self.emitJccReloc(cc, .block, br_inst.target_block, fi);
        } else {
            _ = self.emitJccReloc(cc, .block, br_inst.target_block, fi);
            _ = self.emitJmpReloc(.block, br_inst.alt_block, fi);
        }
    }

    fn emitRegArgsLoad(self: *IRCodegen, args: []const u16, count: usize) void {
        if (count == 0) return;
        const n = @min(count, ARG_REGS.len);
        if (n == 1) {
            self.loadVregToReg(args[0], ARG_REGS[0]);
            return;
        }
        // Check whether direct sequential loads clobber any later argument's source register
        var has_conflict = false;
        for (0..n) |i| {
            for (i + 1..n) |j| {
                if (self.vregPhys(args[j])) |pj| {
                    if (pj == ARG_REGS[i]) {
                        has_conflict = true;
                        break;
                    }
                }
            }
            if (has_conflict) break;
        }
        if (!has_conflict) {
            for (0..n) |i| {
                self.loadVregToReg(args[i], ARG_REGS[i]);
            }
            return;
        }
        var ai: i32 = @intCast(n);
        while (ai > 0) {
            ai -= 1;
            self.loadVregToReg(args[@intCast(ai)], 0);
            self.pushReg(0);
        }
        for (0..n) |ri| {
            self.popReg(ARG_REGS[ri]);
        }
    }

    fn compileSelfTailCall(self: *IRCodegen, inst: IRInst, fi: u32) void {
        self.emitRegArgsLoad(&inst.args, inst.arg_count);
        _ = self.emitJmpReloc(.fn_tail, fi, fi);
    }

    fn resolveCallTarget(self: *const IRCodegen, inst: IRInst) ?u32 {
        if (inst.callee_fn_idx >= 0) {
            const target_ir_idx: u32 = @intCast(inst.callee_fn_idx);
            for (0..self.fn_count) |i| {
                if (self.fns[i].ir_fn_idx == target_ir_idx) return @intCast(i);
            }
        }
        const callee_name = self.irFnNameByStr(inst.fn_name_start, inst.fn_name_len, inst.fn_source_id);
        return self.findFn(callee_name);
    }

    // ═══════════════════════════════════════════════════════════
    // IR instruction selection
    // ═══════════════════════════════════════════════════════════

    fn compileIRInst(self: *IRCodegen, inst: IRInst, cur_bi: u16, fi: u32) void {
        switch (inst.op) {
            .const_int => {
                if (inst.dest > 0 and inst.dest < MAX_VREGS and self.vreg_elided_const[inst.dest]) return;
                if (self.vregPhys(inst.dest)) |rd| {
                    self.mov64imm(rd, @bitCast(inst.imm));
                } else {
                    self.mov64imm(0, @bitCast(inst.imm));
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .fn_addr => {
                const target_fi = self.resolveCallTarget(inst) orelse {
                    self.invalid_reference = true;
                    return;
                };
                self.recordCfiTarget(target_fi);
                if (self.vregPhys(inst.dest)) |rd| {
                    self.leaRipFn(rd, target_fi);
                } else {
                    self.leaRipFn(0, target_fi);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .const_str => {
                const str = self.ir.strings[self.ir.string_offsets[inst.str_idx]..][0..self.ir.string_lens[inst.str_idx]];
                const str_idx = self.addString(str);
                if (self.vregPhys(inst.dest)) |rd| {
                    self.leaRipRodata(rd, str_idx);
                } else {
                    self.leaRipRodata(0, str_idx);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .copy => {
                if (inst.dest == 0) return;
                if (self.vregPhys(inst.dest)) |rd| {
                    self.loadVregToReg(inst.src1, rd);
                } else {
                    self.loadVregToReg(inst.src1, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .load_local => {
                self.loadSlotToReg(0, inst.slot);
                self.storeRegToVreg(0, inst.dest);
            },
            .store_local => {
                self.loadVregToReg(inst.src1, 0);
                self.storeRegToSlot(0, inst.slot);
            },
            .addr_of, .alloca => {
                if (self.vregPhys(inst.dest)) |rd| {
                    self.leaSlotToReg(rd, inst.slot);
                } else {
                    self.leaSlotToReg(0, inst.slot);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .deref_load => {
                const ptr_reg: u8 = self.vregPhys(inst.src1) orelse blk: {
                    self.loadVregToReg(inst.src1, 0);
                    break :blk 0;
                };
                self.emitPtrTrapN(ptr_reg, 8);
                const dst_reg: u8 = self.vregPhys(inst.dest) orelse 0;
                self.emitMemLoadDisp(dst_reg, ptr_reg, 0);
                if (self.vregPhys(inst.dest) == null) self.storeRegToVreg(dst_reg, inst.dest);
            },
            .deref_store => {
                self.loadVregToReg(inst.src1, 0);
                self.emitPtrTrapN(0, 8);
                self.loadVregToReg(inst.src2, 1);
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x08); // mov [rax], rcx
            },
            .field_access => {
                const ptr_reg: u8 = self.vregPhys(inst.src1) orelse blk: {
                    self.loadVregToReg(inst.src1, 0);
                    break :blk 0;
                };
                if (inst.field_offset == 0) {
                    self.emitPtrTrapN(ptr_reg, 8);
                } else {
                    self.emitLeaRegDisp(11, ptr_reg, @intCast(inst.field_offset));
                    self.emitPtrTrapN(11, 8);
                }
                const dst_reg: u8 = self.vregPhys(inst.dest) orelse 0;
                self.emitMemLoadDisp(dst_reg, ptr_reg, @intCast(inst.field_offset));
                if (self.vregPhys(inst.dest) == null) self.storeRegToVreg(dst_reg, inst.dest);
            },
            .field_store => {
                self.loadVregToReg(inst.src1, 0);
                if (inst.field_offset == 0) {
                    self.emitPtrTrapN(0, 8);
                } else {
                    self.emitLeaRegDisp(11, 0, @intCast(inst.field_offset));
                    self.emitPtrTrapN(11, 8);
                }
                self.loadVregToReg(inst.src2, 1);
                self.emitMemStoreDisp(0, 1, @intCast(inst.field_offset));
            },

            // ── Arithmetic & Bitwise ──
            .add, .sub, .mul, .bit_and, .bit_or, .bit_xor => {
                self.compileRegBinOp(inst);
            },
            .div, .@"mod" => {
                const known_c = inst.src2 > 0 and inst.src2 < MAX_VREGS and self.vreg_const_known[inst.src2];
                const known_imm: i64 = if (known_c) self.vreg_const_imm[inst.src2] else 0;
                const known_u: u64 = if (known_imm > 0) @intCast(known_imm) else 0;
                if (known_c and known_imm > 1 and (known_u & (known_u - 1)) == 0) {
                    const sh: u6 = @intCast(@ctz(known_u));
                    const dst_reg: u8 = self.vregPhys(inst.dest) orelse 0;
                    self.loadVregToReg(inst.src1, 0);
                    if (inst.op == .@"mod") self.movRegReg(11, 0);
                    self.emit8(0x48);
                    self.emit8(0x99); // cqo (rdx = sign mask)
                    if (sh <= 63) {
                        const rshift: u8 = @intCast(64 - @as(u8, sh));
                        self.emit8(0x48);
                        self.emit8(0xC1);
                        self.emit8(0xEA);
                        self.emit8(rshift); // shr rdx, 64-sh
                    }
                    self.emit8(0x48);
                    self.emit8(0x01);
                    self.emit8(0xD0); // add rax, rdx
                    self.emit8(0x48);
                    self.emit8(0xC1);
                    self.emit8(0xF8);
                    self.emit8(sh); // sar rax, sh
                    if (inst.op == .@"mod") {
                        self.emit8(0x48);
                        self.emit8(0xC1);
                        self.emit8(0xE0);
                        self.emit8(sh); // shl rax, sh
                        self.emit8(0x49);
                        self.emit8(0x29);
                        self.emit8(0xC3); // sub r11, rax
                        self.movRegReg(dst_reg, 11);
                    } else {
                        self.movRegReg(dst_reg, 0);
                    }
                    if (self.vregPhys(inst.dest) == null) self.storeRegToVreg(dst_reg, inst.dest);
                    return;
                }
                if (known_c and known_imm > 1) {
                    const magic = signedDivMagic(known_imm);
                    self.loadVregToReg(inst.src1, 0);
                    self.movRegReg(11, 0); // preserve dividend for remainder / correction
                    self.mov64imm(1, @bitCast(magic.multiplier));
                    self.emit8(0x48);
                    self.emit8(0xF7);
                    self.emit8(0xE9); // imul rcx -> rdx:rax
                    if (magic.multiplier < 0) {
                        self.emit8(0x4C);
                        self.emit8(0x01);
                        self.emit8(0xDA); // add rdx, r11
                    }
                    if (magic.shift > 0) {
                        self.emit8(0x48);
                        self.emit8(0xC1);
                        self.emit8(0xFA);
                        self.emit8(magic.shift); // sar rdx, shift
                    }
                    self.movRegReg(0, 2);
                    self.emit8(0x48);
                    self.emit8(0xC1);
                    self.emit8(0xE8);
                    self.emit8(63); // shr rax, 63: adjust arithmetic shift toward zero
                    self.emit8(0x48);
                    self.emit8(0x01);
                    self.emit8(0xC2); // add rdx, rax
                    if (inst.op == .@"mod") {
                        self.movRegReg(0, 2);
                        self.mov64imm(1, @bitCast(known_imm));
                        self.emit8(0x48);
                        self.emit8(0x0F);
                        self.emit8(0xAF);
                        self.emit8(0xC1); // imul rax, rcx
                        self.emit8(0x49);
                        self.emit8(0x29);
                        self.emit8(0xC3); // sub r11, rax
                        self.storeRegToVreg(11, inst.dest);
                    } else {
                        self.storeRegToVreg(2, inst.dest);
                    }
                    return;
                }
                self.loadVregToReg(inst.src1, 0);
                self.loadVregToReg(inst.src2, 1);
                if (!(known_c and known_imm != 0)) {
                    self.emitTestRegZeroTrap(1);
                }
                if (!(known_c and known_imm != -1)) {
                    // Guard hardware #DE on MIN_INT / -1: cmp rcx, -1; jne ok; mov r11, MIN_INT; cmp rax, r11; jne ok; ud2
                    self.emitCmpRegImm32(1, -1);
                    const j_ok1 = self.emitJccReloc(0x5, .code_offset, 0, fi);
                    self.mov64imm(11, @bitCast(@as(i64, std.math.minInt(i64))));
                    self.emit8(0x4C);
                    self.emit8(0x39);
                    self.emit8(0xD8); // cmp rax, r11
                    const j_ok2 = self.emitJccReloc(0x5, .code_offset, 0, fi);
                    self.emit8(0x0F);
                    self.emit8(0x0B); // ud2
                    const ok_pos = self.code_len;
                    self.relocs[j_ok1].target_id = ok_pos;
                    self.relocs[j_ok2].target_id = ok_pos;
                }
                self.emit8(0x48);
                self.emit8(0x99); // cqo
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xF9); // idiv rcx
                if (inst.op == .@"mod") self.movRegReg(0, 2);
                self.storeRegToVreg(0, inst.dest);
            },
            .udiv, .umod => {
                const known_c = inst.src2 > 0 and inst.src2 < MAX_VREGS and self.vreg_const_known[inst.src2];
                const known_imm: i64 = if (known_c) self.vreg_const_imm[inst.src2] else 0;
                const known_u: u64 = @bitCast(known_imm);
                if (known_c and known_u > 1 and (known_u & (known_u - 1)) == 0) {
                    const dst_reg: u8 = self.vregPhys(inst.dest) orelse 0;
                    self.loadVregToReg(inst.src1, dst_reg);
                    if (inst.op == .udiv) {
                        const sh: u6 = @intCast(@ctz(known_u));
                        self.emit8(if (dst_reg >= 8) 0x49 else 0x48);
                        self.emit8(0xC1);
                        self.emit8(0xE8 | (dst_reg & 7)); // shr dst_reg, imm8
                        self.emit8(sh);
                    } else {
                        const mask = known_u - 1;
                        if (mask <= 0x7FFF_FFFF) {
                            self.emitAluRegImm32(4, dst_reg, @intCast(mask)); // and dst_reg, imm32
                        } else {
                            self.mov64imm(11, mask);
                            self.emitRex(11, dst_reg);
                            self.emit8(0x21);
                            self.emitModRM(3, 11, dst_reg); // and dst_reg, r11
                        }
                    }
                    if (self.vregPhys(inst.dest) == null) self.storeRegToVreg(dst_reg, inst.dest);
                    return;
                }
                self.loadVregToReg(inst.src1, 0);
                self.loadVregToReg(inst.src2, 1);
                if (!(known_c and known_u != 0)) {
                    self.emitTestRegZeroTrap(1);
                }
                self.xorReg(2, 2); // xor edx, edx
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xF1); // div rcx
                if (inst.op == .umod) self.movRegReg(0, 2);
                self.storeRegToVreg(0, inst.dest);
            },
            .shl, .shr, .ushr => {
                if (inst.src2 > 0 and inst.src2 < MAX_VREGS and self.vreg_const_known[inst.src2]) {
                    const sh = self.vreg_const_imm[inst.src2];
                    if (sh < 0 or sh >= 64) {
                        self.emit8(0x0F);
                        self.emit8(0x0B); // ud2 on invalid constant shift amount
                        if (inst.dest != 0) {
                            self.xorReg(0, 0);
                            self.storeRegToVreg(0, inst.dest);
                        }
                        return;
                    }
                    const dst_reg: u8 = self.vregPhys(inst.dest) orelse 0;
                    self.loadVregToReg(inst.src1, dst_reg);
                    const subop: u8 = switch (inst.op) {
                        .shl => 4,
                        .shr => 7,
                        .ushr => 5,
                        else => 4,
                    };
                    self.emit8(if (dst_reg >= 8) 0x49 else 0x48);
                    self.emit8(0xC1);
                    self.emit8(0xC0 | (subop << 3) | (dst_reg & 7));
                    self.emit8(@intCast(@as(u6, @intCast(sh))));
                    if (self.vregPhys(inst.dest) == null) self.storeRegToVreg(dst_reg, inst.dest);
                    return;
                }
                self.loadVregToReg(inst.src1, 0);
                self.loadVregToReg(inst.src2, 1);
                self.emitCmpRegImm32(1, 64);
                self.emit8(0x72);
                self.emit8(0x02); // jb +2 (unsigned < 64)
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2 (trap on < 0 or >= 64 shift)
                self.emit8(0x48);
                self.emit8(0xD3);
                self.emit8(switch (inst.op) {
                    .shl => 0xE0,
                    .shr => 0xF8,
                    .ushr => 0xE8,
                    else => 0xE0,
                });
                self.storeRegToVreg(0, inst.dest);
            },
            .sext8 => {
                self.loadVregToReg(inst.src1, 0);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xBE);
                self.emit8(0xC0); // movsx rax, al
                self.storeRegToVreg(0, inst.dest);
            },
            .sext16 => {
                self.loadVregToReg(inst.src1, 0);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xBF);
                self.emit8(0xC0); // movsx rax, ax
                self.storeRegToVreg(0, inst.dest);
            },
            .sext32 => {
                self.loadVregToReg(inst.src1, 0);
                self.emit8(0x48);
                self.emit8(0x63);
                self.emit8(0xC0); // movsxd rax, eax
                self.storeRegToVreg(0, inst.dest);
            },
            .zext8 => {
                self.loadVregToReg(inst.src1, 0);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xB6);
                self.emit8(0xC0); // movzx rax, al
                self.storeRegToVreg(0, inst.dest);
            },
            .zext16 => {
                self.loadVregToReg(inst.src1, 0);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xB7);
                self.emit8(0xC0); // movzx rax, ax
                self.storeRegToVreg(0, inst.dest);
            },
            .zext32 => {
                self.loadVregToReg(inst.src1, 0);
                self.emit8(0x89);
                self.emit8(0xC0); // mov eax, eax
                self.storeRegToVreg(0, inst.dest);
            },

            // ── IEEE-754 Floating-Point (SSE2, f64 bits in 64-bit GPR vregs) ──
            .fadd, .fsub, .fmul, .fdiv => {
                self.loadVregToReg(inst.src1, 0);
                self.loadVregToReg(inst.src2, 1);
                // movq xmm0, rax; movq xmm1, rcx
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xC0);
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xC9);
                // F2 0F <op> C1
                self.emit8(0xF2);
                self.emit8(0x0F);
                self.emit8(switch (inst.op) {
                    .fadd => 0x58,
                    .fsub => 0x5C,
                    .fmul => 0x59,
                    .fdiv => 0x5E,
                    else => 0x58,
                });
                self.emit8(0xC1);
                // movq rax, xmm0
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x7E);
                self.emit8(0xC0);
                self.storeRegToVreg(0, inst.dest);
            },
            .fneg => {
                self.loadVregToReg(inst.src1, 0);
                self.mov64imm(1, 0x8000_0000_0000_0000);
                self.emit8(0x48);
                self.emit8(0x31);
                self.emit8(0xC8); // xor rax, rcx
                self.storeRegToVreg(0, inst.dest);
            },
            .fcmp_eq, .fcmp_ne, .fcmp_lt, .fcmp_le, .fcmp_gt, .fcmp_ge => {
                self.loadVregToReg(inst.src1, 0);
                self.loadVregToReg(inst.src2, 1);
                // movq xmm0, rax; movq xmm1, rcx
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xC0);
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xC9);
                if (inst.op == .fcmp_lt or inst.op == .fcmp_le) {
                    // ucomisd xmm1, xmm0 (swap operands so seta/setae yields false on NaN)
                    self.emit8(0x66);
                    self.emit8(0x0F);
                    self.emit8(0x2E);
                    self.emit8(0xC8);
                } else {
                    // ucomisd xmm0, xmm1
                    self.emit8(0x66);
                    self.emit8(0x0F);
                    self.emit8(0x2E);
                    self.emit8(0xC1);
                }
                switch (inst.op) {
                    .fcmp_eq => {
                        self.emit8(0x0F);
                        self.emit8(0x94);
                        self.emit8(0xC0); // sete al
                        self.emit8(0x0F);
                        self.emit8(0x9B);
                        self.emit8(0xC1); // setnp cl
                        self.emit8(0x20);
                        self.emit8(0xC8); // and al, cl
                    },
                    .fcmp_ne => {
                        self.emit8(0x0F);
                        self.emit8(0x95);
                        self.emit8(0xC0); // setne al
                        self.emit8(0x0F);
                        self.emit8(0x9A);
                        self.emit8(0xC1); // setp cl
                        self.emit8(0x08);
                        self.emit8(0xC8); // or al, cl
                    },
                    .fcmp_gt, .fcmp_lt => {
                        self.emit8(0x0F);
                        self.emit8(0x97);
                        self.emit8(0xC0); // seta al
                    },
                    .fcmp_ge, .fcmp_le => {
                        self.emit8(0x0F);
                        self.emit8(0x93);
                        self.emit8(0xC0); // setae al
                    },
                    else => {},
                }
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xB6);
                self.emit8(0xC0); // movzx rax, al
                self.storeRegToVreg(0, inst.dest);
            },
            .itof => {
                self.loadVregToReg(inst.src1, 0);
                // cvtsi2sd xmm0, rax
                self.emit8(0xF2);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x2A);
                self.emit8(0xC0);
                // movq rax, xmm0
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x7E);
                self.emit8(0xC0);
                self.storeRegToVreg(0, inst.dest);
            },
            .uitof => {
                self.loadVregToReg(inst.src1, 0);
                // For values below 2^63 the signed conversion is already exact.
                // For the upper half, convert ((x >> 1) | (x & 1)) and double;
                // this preserves round-to-nearest-even for the full u64 range.
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0); // test rax, rax
                const low_path = self.emitJccReloc(0x9, .code_offset, 0, fi); // jns
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0xC1); // mov rcx, rax
                self.emit8(0x48);
                self.emit8(0xD1);
                self.emit8(0xE9); // shr rcx, 1
                self.emit8(0x48);
                self.emit8(0x83);
                self.emit8(0xE0);
                self.emit8(0x01); // and rax, 1
                self.emit8(0x48);
                self.emit8(0x09);
                self.emit8(0xC1); // or rcx, rax
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xC1); // movq xmm0, rcx
                self.emit8(0xF2);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x2A);
                self.emit8(0xC1); // cvtsi2sd xmm0, rcx
                self.emit8(0xF2);
                self.emit8(0x0F);
                self.emit8(0x58);
                self.emit8(0xC0); // addsd xmm0, xmm0
                const done = self.emitJmpReloc(.code_offset, 0, fi);
                const low_offset = self.code_len;
                self.relocs[low_path].target_id = low_offset;
                self.loadVregToReg(inst.src1, 0);
                self.emit8(0xF2);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x2A);
                self.emit8(0xC0); // cvtsi2sd xmm0, rax
                self.relocs[done].target_id = self.code_len;
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x7E);
                self.emit8(0xC0); // movq rax, xmm0
                self.storeRegToVreg(0, inst.dest);
            },
            .ftoi => {
                self.loadVregToReg(inst.src1, 1); // rcx = raw f64 bits
                // movq xmm0, rcx
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xC1);
                // cvttsd2si rax, xmm0
                self.emit8(0xF2);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x2C);
                self.emit8(0xC0);
                // Trap if cvttsd2si returned INT64_MIN (NaN/Inf/OOB) unless input == -2^63
                self.mov64imm(11, 0x8000_0000_0000_0000);
                self.emit8(0x4C);
                self.emit8(0x39);
                self.emit8(0xD8); // cmp rax, r11
                const ftoi_ok1 = self.emitJccReloc(0x5, .code_offset, 0, fi); // jne .ok
                self.mov64imm(11, 0xC3E0_0000_0000_0000);
                self.emit8(0x4C);
                self.emit8(0x39);
                self.emit8(0xD9); // cmp rcx, r11
                const ftoi_ok2 = self.emitJccReloc(0x4, .code_offset, 0, fi); // je .ok
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2
                const ftoi_done = self.code_len;
                self.relocs[ftoi_ok1].target_id = ftoi_done;
                self.relocs[ftoi_ok2].target_id = ftoi_done;
                self.storeRegToVreg(0, inst.dest);
            },
            .ftou => {
                self.loadVregToReg(inst.src1, 1); // rcx = raw f64 bits
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xC1); // movq xmm0, rcx
                self.emit8(0x0F);
                self.emit8(0x57);
                self.emit8(0xC9); // xorps xmm1, xmm1
                self.emit8(0x66);
                self.emit8(0x0F);
                self.emit8(0x2E);
                self.emit8(0xC1); // ucomisd xmm0, xmm1
                const bad_negative = self.emitJccReloc(0x2, .code_offset, 0, fi); // jb also catches unordered NaN

                self.mov64imm(11, 0x43F0_0000_0000_0000); // 2^64
                self.emit8(0x66);
                self.emit8(0x49);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xCB); // movq xmm1, r11
                self.emit8(0x66);
                self.emit8(0x0F);
                self.emit8(0x2E);
                self.emit8(0xC1); // ucomisd xmm0, xmm1
                const bad_too_large = self.emitJccReloc(0x3, .code_offset, 0, fi); // jae

                self.mov64imm(11, 0x43E0_0000_0000_0000); // 2^63
                self.emit8(0x66);
                self.emit8(0x49);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xCB); // movq xmm1, r11
                self.emit8(0x66);
                self.emit8(0x0F);
                self.emit8(0x2E);
                self.emit8(0xC1); // ucomisd xmm0, xmm1
                const high_path = self.emitJccReloc(0x3, .code_offset, 0, fi); // jae

                self.emit8(0xF2);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x2C);
                self.emit8(0xC0); // cvttsd2si rax, xmm0
                const low_done = self.emitJmpReloc(.code_offset, 0, fi);

                const high_offset = self.code_len;
                self.relocs[high_path].target_id = high_offset;
                self.mov64imm(11, 0x3FE0_0000_0000_0000); // 0.5
                self.emit8(0x66);
                self.emit8(0x49);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xCB); // movq xmm1, r11
                self.emit8(0xF2);
                self.emit8(0x0F);
                self.emit8(0x59);
                self.emit8(0xC1); // mulsd xmm0, xmm1
                self.emit8(0xF2);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x2C);
                self.emit8(0xC0); // cvttsd2si rax, xmm0 (now below 2^63)
                self.emit8(0x48);
                self.emit8(0xD1);
                self.emit8(0xE0); // shl rax, 1
                const high_done = self.emitJmpReloc(.code_offset, 0, fi);

                const trap_offset = self.code_len;
                self.relocs[bad_negative].target_id = trap_offset;
                self.relocs[bad_too_large].target_id = trap_offset;
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2
                const done_offset = self.code_len;
                self.relocs[low_done].target_id = done_offset;
                self.relocs[high_done].target_id = done_offset;
                self.storeRegToVreg(0, inst.dest);
            },
            .f32_to_f64 => {
                // Canonical slots already store IEEE-754 f64 bits
                self.loadVregToReg(inst.src1, 0);
                self.storeRegToVreg(0, inst.dest);
            },
            .f64_to_f32 => {
                // Round via single precision and widen back so slot stays canonical f64
                self.loadVregToReg(inst.src1, 0);
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xC0); // movq xmm0, rax
                self.emit8(0xF2);
                self.emit8(0x0F);
                self.emit8(0x5A);
                self.emit8(0xC0); // cvtsd2ss xmm0, xmm0
                self.emit8(0xF3);
                self.emit8(0x0F);
                self.emit8(0x5A);
                self.emit8(0xC0); // cvtss2sd xmm0, xmm0
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x7E);
                self.emit8(0xC0); // movq rax, xmm0
                self.storeRegToVreg(0, inst.dest);
            },
            .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge, .ucmp_lt, .ucmp_le, .ucmp_gt, .ucmp_ge => {
                const eff_op = self.emitCmpOperands(inst.op, inst.src1, inst.src2);
                self.emit8(0x0F);
                self.emit8(0x90 | cmpCc(eff_op));
                self.emit8(0xC0);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xB6);
                self.emit8(0xC0);
                self.storeRegToVreg(0, inst.dest);
            },

            // ── Unary ──
            .neg => {
                if (self.vregPhys(inst.dest)) |rd| {
                    self.loadVregToReg(inst.src1, rd);
                    self.emit8(if (rd >= 8) 0x49 else 0x48);
                    self.emit8(0xF7);
                    self.emit8(0xD8 | (rd & 7));
                } else {
                    self.loadVregToReg(inst.src1, 0);
                    self.emit8(0x48);
                    self.emit8(0xF7);
                    self.emit8(0xD8);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .bit_not => {
                if (self.vregPhys(inst.dest)) |rd| {
                    self.loadVregToReg(inst.src1, rd);
                    self.emit8(if (rd >= 8) 0x49 else 0x48);
                    self.emit8(0xF7);
                    self.emit8(0xD0 | (rd & 7));
                } else {
                    self.loadVregToReg(inst.src1, 0);
                    self.emit8(0x48);
                    self.emit8(0xF7);
                    self.emit8(0xD0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .logic_not => {
                self.loadVregToReg(inst.src1, 0);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                self.emit8(0x0F);
                self.emit8(0x94);
                self.emit8(0xC0);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xB6);
                self.emit8(0xC0);
                self.storeRegToVreg(0, inst.dest);
            },

            // ── Control flow ──
            .unreachable_trap => {
                self.emit8(0x0F);
                self.emit8(0x0B);
            },
            .jump => {
                _ = cur_bi;
                if (inst.target_block != self.cur_next_emit_bi) {
                    _ = self.emitJmpReloc(.block, inst.target_block, fi);
                }
            },
            .cond_jump => {
                if (self.vregPhys(inst.src1)) |rs| {
                    self.emitRex(rs, rs);
                    self.emit8(0x85);
                    self.emitModRM(3, rs, rs);
                } else {
                    self.loadVregToReg(inst.src1, 0);
                    self.emit8(0x48);
                    self.emit8(0x85);
                    self.emit8(0xC0);
                }
                if (inst.target_block == self.cur_next_emit_bi) {
                    _ = self.emitJccReloc(0x4, .block, inst.alt_block, fi);
                } else if (inst.alt_block == self.cur_next_emit_bi) {
                    _ = self.emitJccReloc(0x5, .block, inst.target_block, fi);
                } else {
                    _ = self.emitJccReloc(0x5, .block, inst.target_block, fi);
                    _ = self.emitJmpReloc(.block, inst.alt_block, fi);
                }
            },
            .ret => {
                if (inst.src1 != 0) {
                    self.loadVregToReg(inst.src1, 0);
                } else {
                    self.xorReg(0, 0);
                }
                self.emitEpilogueReturn();
            },

            // ── Calls (supporting up to 8 System V ABI params) ──
            .call => {
                const callee_fi = self.resolveCallTarget(inst) orelse {
                    self.invalid_reference = true;
                    return;
                };
                const stack_args: usize = if (inst.arg_count > 6) inst.arg_count - 6 else 0;
                const stack_pad: u32 = if (stack_args % 2 == 1) 8 else 0;
                self.subRspImm(stack_pad);
                if (stack_args > 0) {
                    var si: usize = inst.arg_count;
                    while (si > 6) {
                        si -= 1;
                        self.loadVregToReg(inst.args[si], 0);
                        self.pushReg(0);
                    }
                }
                self.emitRegArgsLoad(&inst.args, @min(inst.arg_count, 6));
                self.emitCallReloc(.fn_call, callee_fi);
                self.addRspImm(@as(u32, @intCast(stack_args)) * 8 + stack_pad);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_indirect => {
                // Target fn pointer in inst.src1; save in r11 and verify exact .fn_addr CFI entry before arg loads
                self.loadVregToReg(inst.src1, 11);
                self.emitCallReloc(.chk_cfi_fn, 0);
                const stack_args: usize = if (inst.arg_count > 6) inst.arg_count - 6 else 0;
                const stack_pad: u32 = if (stack_args % 2 == 1) 8 else 0;
                self.subRspImm(stack_pad);
                if (stack_args > 0) {
                    var si: usize = inst.arg_count;
                    while (si > 6) {
                        si -= 1;
                        self.loadVregToReg(inst.args[si], 0);
                        self.pushReg(0);
                    }
                }
                self.emitRegArgsLoad(&inst.args, @min(inst.arg_count, 6));
                self.emit8(0x41);
                self.emit8(0xFF);
                self.emit8(0xD3); // call r11
                self.addRspImm(@as(u32, @intCast(stack_args)) * 8 + stack_pad);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },

            // ── Builtins ──
            .call_print, .call_println => {
                self.loadVregToReg(inst.args[0], 6);
                self.emitPtrTrap(6);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x56);
                self.emit8(0xF8);
                self.mov64imm(0, 1);
                self.mov64imm(7, 1);
                self.syscallInst();
                if (inst.op == .call_println) {
                    const nl_idx = self.addString("\n");
                    self.leaRipRodata(6, nl_idx);
                    self.mov64imm(0, 1);
                    self.mov64imm(7, 1);
                    self.mov64imm(2, 1);
                    self.syscallInst();
                }
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .call_panic => {
                self.loadVregToReg(inst.args[0], 6);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xF6); // test rsi, rsi
                const skip_msg = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x56);
                self.emit8(0xF8); // mov rdx, [rsi - 8]
                self.mov64imm(0, 1);
                self.mov64imm(7, 2); // stderr
                self.syscallInst();
                self.relocs[skip_msg].target_id = self.code_len;
                const nl_idx = self.addString("\n");
                self.leaRipRodata(6, nl_idx);
                self.mov64imm(0, 1);
                self.mov64imm(7, 2);
                self.mov64imm(2, 1);
                self.syscallInst();
                self.mov64imm(7, 1);
                self.mov64imm(0, 60);
                self.syscallInst();
            },
            .call_print_int, .call_printptr => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitCallReloc(.printint, 0);
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .call_exit => {
                self.loadVregToReg(inst.args[0], 7);
                self.mov64imm(0, 60);
                self.syscallInst();
            },
            .call_sizeof => {
                if (inst.dest != 0) {
                    self.mov64imm(0, 8);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .call_syscall => {
                const sc_regs = [_]u8{ 0, 7, 6, 2, 10, 8, 9 };
                var ai: i32 = @intCast(@min(inst.arg_count, sc_regs.len));
                while (ai > 0) {
                    ai -= 1;
                    self.loadVregToReg(inst.args[@intCast(ai)], 0);
                    self.pushReg(0);
                }
                for (0..@min(inst.arg_count, sc_regs.len)) |ri| {
                    self.popReg(sc_regs[ri]);
                }
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_malloc => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitCallReloc(.malloc_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_free => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitCallReloc(.free_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_array_free => {
                self.loadVregToReg(inst.args[0], 7);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xFF); // test rdi, rdi
                const sk = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emitPtrTrap(7);
                self.pushReg(7);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x7F);
                self.emit8(0x10); // mov rdi, [rdi + 16] (data_ptr)
                self.emitCallReloc(.free_fn, 0);
                self.popReg(7);
                self.emitCallReloc(.free_fn, 0);
                self.relocs[sk].target_id = self.code_len;
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .call_ptr_add => {
                var add_inst = inst;
                add_inst.op = .add;
                add_inst.src1 = inst.args[0];
                add_inst.src2 = inst.args[1];
                self.compileRegBinOp(add_inst);
            },
            .call_read_byte => {
                const ptr_reg: u8 = self.vregPhys(inst.args[0]) orelse blk: {
                    self.loadVregToReg(inst.args[0], 0);
                    break :blk 0;
                };
                self.emitPtrTrapN(ptr_reg, 1);
                const dst_reg: u8 = self.vregPhys(inst.dest) orelse 0;
                self.emitMemLoadByte(dst_reg, ptr_reg);
                if (inst.dest != 0 and self.vregPhys(inst.dest) == null) self.storeRegToVreg(dst_reg, inst.dest);
            },
            .call_write_byte => {
                const ptr_reg: u8 = self.vregPhys(inst.args[0]) orelse blk: {
                    self.loadVregToReg(inst.args[0], 0);
                    break :blk 0;
                };
                self.emitPtrTrapN(ptr_reg, 1);
                const val_v = inst.args[1];
                if (val_v > 0 and val_v < MAX_VREGS and self.vreg_const_known[val_v]) {
                    const imm8: u8 = @truncate(@as(u64, @bitCast(self.vreg_const_imm[val_v])));
                    self.emitMemStoreByteImm(ptr_reg, imm8);
                } else {
                    const val_reg: u8 = self.vregPhys(val_v) orelse blk_v: {
                        self.loadVregToReg(val_v, 1);
                        break :blk_v 1;
                    };
                    self.emitMemStoreByte(ptr_reg, val_reg);
                }
                if (inst.dest != 0) {
                    if (self.vregPhys(inst.dest)) |dr| {
                        self.xorReg(dr, dr);
                    } else {
                        self.xorReg(0, 0);
                        self.storeRegToVreg(0, inst.dest);
                    }
                }
            },
            .call_array_new => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitCallReloc(.array_new_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_array_push => {
                self.emitRegArgsLoad(&inst.args, 2);
                self.emitCallReloc(.array_push_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_array_get => {
                self.emitRegArgsLoad(&inst.args, 2);
                self.emitCallReloc(.array_get_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_array_set => {
                self.emitRegArgsLoad(&inst.args, 3);
                self.emitCallReloc(.array_set_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_array_len => {
                const ptr_reg: u8 = self.vregPhys(inst.args[0]) orelse blk: {
                    self.loadVregToReg(inst.args[0], 0);
                    break :blk 0;
                };
                self.emitPtrTrap(ptr_reg);
                const dst_reg: u8 = self.vregPhys(inst.dest) orelse 0;
                self.emitMemLoadDisp(dst_reg, ptr_reg, 0);
                if (inst.dest != 0 and self.vregPhys(inst.dest) == null) self.storeRegToVreg(dst_reg, inst.dest);
            },
            .call_memcpy => {
                self.emitRegArgsLoad(&inst.args, 3); // rdi=dst, rsi=src, rdx=len
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xD2); // test rdx, rdx
                const len_nonneg = self.emitJccReloc(0x9, .code_offset, 0, fi); // jns
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2 on negative len
                self.relocs[len_nonneg].target_id = self.code_len;
                const len_zero = self.emitJccReloc(0x4, .code_offset, 0, fi); // jz skip
                self.emitCheckPtrLenRegs(7, 2);
                self.emitCheckPtrLenRegs(6, 2);
                self.relocs[len_zero].target_id = self.code_len;
                self.movRegReg(1, 2); // rcx = len
                self.pushReg(7);
                self.emitByteCopy();
                self.popReg(0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_memset => {
                self.emitRegArgsLoad(&inst.args, 3); // rdi=dst, rsi=val, rdx=len
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xD2); // test rdx, rdx
                const ms_nonneg = self.emitJccReloc(0x9, .code_offset, 0, fi);
                self.emit8(0x0F);
                self.emit8(0x0B);
                self.relocs[ms_nonneg].target_id = self.code_len;
                const ms_zero = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emitCheckPtrLenRegs(7, 2);
                self.relocs[ms_zero].target_id = self.code_len;
                self.movRegReg(0, 6); // rax = val
                self.movRegReg(1, 2); // rcx = len
                self.pushReg(7);
                self.emit8(0xFC);
                self.emit8(0xF3);
                self.emit8(0xAA);
                self.popReg(0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },

            // ── Strings ──
            .call_string_new => {
                if (inst.arg_count >= 2) {
                    self.emitRegArgsLoad(&inst.args, 2); // rdi = ptr, rsi = len
                    self.mov64imm(11, 0x7FFF_FFFF);
                    self.emit8(0x4C);
                    self.emit8(0x39);
                    self.emit8(0xDE); // cmp rsi, r11
                    const sn_ok = self.emitJccReloc(0x6, .code_offset, 0, fi); // jbe (unsigned: rejects < 0 and > 2GB)
                    self.emit8(0x0F);
                    self.emit8(0x0B);
                    self.relocs[sn_ok].target_id = self.code_len;
                    self.emit8(0x48);
                    self.emit8(0x85);
                    self.emit8(0xF6); // test rsi, rsi
                    const sn_zero = self.emitJccReloc(0x4, .code_offset, 0, fi);
                    self.emitCheckPtrLenRegs(7, 6);
                    self.relocs[sn_zero].target_id = self.code_len;
                    self.pushReg(7); // ptr
                    self.pushReg(6); // len
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x7E);
                    self.emit8(0x09); // lea rdi, [rsi + 9]
                } else {
                    self.loadVregToReg(inst.args[0], 6);
                    self.emitPtrTrap(6);
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x46);
                    self.emit8(0xF8); // rax = [rsi - 8]
                    self.pushReg(6); // ptr
                    self.pushReg(0); // len
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x78);
                    self.emit8(0x09); // lea rdi, [rax + 9]
                }
                self.emitCallReloc(.malloc_fn, 0);
                self.emitTestRegZeroTrap(0);
                self.popReg(1); // rcx = len
                self.popReg(6); // rsi = src
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x08); // [rax] = len
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0x78);
                self.emit8(0x08);
                self.pushReg(7);
                self.emitByteCopy();
                self.emit8(0xC6);
                self.emit8(0x07);
                self.emit8(0x00);
                self.popReg(0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_string_len => {
                const ptr_reg: u8 = self.vregPhys(inst.args[0]) orelse blk: {
                    self.loadVregToReg(inst.args[0], 0);
                    break :blk 0;
                };
                self.emitPtrTrap(ptr_reg);
                const dst_reg: u8 = self.vregPhys(inst.dest) orelse 0;
                self.emitMemLoadDisp(dst_reg, ptr_reg, -8);
                if (inst.dest != 0 and self.vregPhys(inst.dest) == null) self.storeRegToVreg(dst_reg, inst.dest);
            },
            .call_string_sub, .call_string_slice => {
                self.emitRegArgsLoad(&inst.args, 3); // rdi = str, rsi = start, rdx = len_or_end
                self.emitPtrTrap(7);
                self.emit8(0x4C);
                self.emit8(0x8B);
                self.emit8(0x47);
                self.emit8(0xF8); // mov r8, [rdi - 8] (hay_len)
                // Clamp start >= 0 and start <= hay_len
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xF6);
                self.emit8(0x79);
                self.emit8(0x02);
                self.xorReg(6, 6);
                self.emit8(0x4C);
                self.emit8(0x39);
                self.emit8(0xC6); // cmp rsi, r8
                self.emit8(0x76);
                self.emit8(0x03);
                self.movRegReg(6, 8);
                // r9 = hay_len - start (available bytes)
                self.movRegReg(9, 8);
                self.emit8(0x49);
                self.emit8(0x29);
                self.emit8(0xF1); // sub r9, rsi
                if (inst.op == .call_string_slice) {
                    self.emit8(0x48);
                    self.emit8(0x29);
                    self.emit8(0xF2); // sub rdx, rsi
                }
                // Clamp len >= 0 and len <= r9
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xD2);
                self.emit8(0x79);
                self.emit8(0x02);
                self.xorReg(2, 2);
                self.emit8(0x4C);
                self.emit8(0x39);
                self.emit8(0xCA); // cmp rdx, r9
                self.emit8(0x76);
                self.emit8(0x03);
                self.movRegReg(2, 9);
                // src_ptr = rdi + rsi
                self.emit8(0x48);
                self.emit8(0x01);
                self.emit8(0xF7);
                self.pushReg(7);
                self.pushReg(2);
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0x7A);
                self.emit8(0x09); // lea rdi, [rdx + 9]
                self.emitCallReloc(.malloc_fn, 0);
                self.emitTestRegZeroTrap(0);
                self.popReg(1); // rcx = len
                self.popReg(6); // rsi = src_ptr
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x08); // [rax] = len
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0x78);
                self.emit8(0x08);
                self.pushReg(7);
                self.emitByteCopy();
                self.emit8(0xC6);
                self.emit8(0x07);
                self.emit8(0x00);
                self.popReg(0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_string_char_at => {
                self.emitRegArgsLoad(&inst.args, 2); // rdi = str, rsi = idx
                self.emitPtrTrap(7);
                self.emit8(0x48);
                self.emit8(0x3B);
                self.emit8(0x77);
                self.emit8(0xF8); // cmp rsi, [rdi - 8]
                const ca_ok = self.emitJccReloc(0x2, .code_offset, 0, fi); // jb
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2
                self.relocs[ca_ok].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xB6);
                self.emit8(0x04);
                self.emit8(0x37); // movzx rax, byte [rdi + rsi]
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_string_concat => {
                self.emitRegArgsLoad(&inst.args, 2); // rdi = a, rsi = b
                self.emitPtrTrap(7);
                self.emitPtrTrap(6);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x4F);
                self.emit8(0xF8); // rcx = len_a
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x56);
                self.emit8(0xF8); // rdx = len_b
                self.mov64imm(11, 0x7FFF_FFFF);
                self.emit8(0x4C);
                self.emit8(0x39);
                self.emit8(0xD9); // cmp rcx, r11
                const sc_ok1 = self.emitJccReloc(0x6, .code_offset, 0, fi);
                self.emit8(0x0F);
                self.emit8(0x0B);
                self.relocs[sc_ok1].target_id = self.code_len;
                self.emit8(0x4C);
                self.emit8(0x39);
                self.emit8(0xDA); // cmp rdx, r11
                const sc_ok2 = self.emitJccReloc(0x6, .code_offset, 0, fi);
                self.emit8(0x0F);
                self.emit8(0x0B);
                self.relocs[sc_ok2].target_id = self.code_len;
                self.pushReg(7); // a
                self.pushReg(6); // b
                self.pushReg(1); // len_a
                self.pushReg(2); // len_b
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0x7C);
                self.emit8(0x0A);
                self.emit8(0x09); // lea rdi, [rdx + rcx + 9]
                self.emitCallReloc(.malloc_fn, 0);
                self.emitTestRegZeroTrap(0);
                self.popReg(2); // rdx = len_b
                self.popReg(1); // rcx = len_a
                self.emit8(0x4C);
                self.emit8(0x8D);
                self.emit8(0x14);
                self.emit8(0x11); // r10 = len_a + len_b
                self.emit8(0x4C);
                self.emit8(0x89);
                self.emit8(0x10); // [rax] = r10
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0x78);
                self.emit8(0x08); // rdi = dst
                self.popReg(8); // b
                self.popReg(6); // a
                self.pushReg(7); // ret_str
                self.pushReg(2); // len_b
                self.pushReg(8); // b
                self.emitByteCopy();
                self.popReg(6); // b
                self.popReg(1); // len_b
                self.emitByteCopy();
                self.emit8(0xC6);
                self.emit8(0x07);
                self.emit8(0x00);
                self.popReg(0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_string_eq => {
                self.emitRegArgsLoad(&inst.args, 2); // rdi = a, rsi = b
                self.emitPtrTrap(7);
                self.emitPtrTrap(6);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x4E);
                self.emit8(0xF8);
                self.emit8(0x48);
                self.emit8(0x3B);
                self.emit8(0x4F);
                self.emit8(0xF8);
                const not_eq_reloc = self.emitJccReloc(0x5, .code_offset, 0, fi);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC9);
                const empty_eq_reloc = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emit8(0xFC);
                self.emit8(0xF3);
                self.emit8(0xA6);
                const cmps_neq_reloc = self.emitJccReloc(0x5, .code_offset, 0, fi);
                self.relocs[empty_eq_reloc].target_id = self.code_len;
                self.mov64imm(0, 1);
                const end_reloc = self.emitJmpReloc(.code_offset, 0, fi);
                const neq_pos = self.code_len;
                self.relocs[not_eq_reloc].target_id = neq_pos;
                self.relocs[cmps_neq_reloc].target_id = neq_pos;
                self.xorReg(0, 0);
                self.relocs[end_reloc].target_id = self.code_len;
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_string_split => {
                self.emitRegArgsLoad(&inst.args, 2);
                self.emitCallReloc(.split_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_string_to_int => {
                self.loadVregToReg(inst.args[0], 6);
                self.emitPtrTrap(6);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x4E);
                self.emit8(0xF8);
                self.xorReg(0, 0);
                self.xorReg(2, 2);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC9);
                const done0 = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emit8(0x80);
                self.emit8(0x3E);
                self.emit8('-');
                const not_neg = self.emitJccReloc(0x5, .code_offset, 0, fi);
                self.mov64imm(2, 1);
                self.emit8(0x48);
                self.emit8(0xFF);
                self.emit8(0xC6);
                self.emit8(0x48);
                self.emit8(0xFF);
                self.emit8(0xC9);
                self.relocs[not_neg].target_id = self.code_len;
                const loop_top = self.code_len;
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC9);
                const done1 = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emit8(0x4C);
                self.emit8(0x0F);
                self.emit8(0xB6);
                self.emit8(0x06);
                self.emit8(0x49);
                self.emit8(0x83);
                self.emit8(0xE8);
                self.emit8('0');
                self.emit8(0x49);
                self.emit8(0x83);
                self.emit8(0xF8);
                self.emit8(9);
                const bad_digit = self.emitJccReloc(0x7, .code_offset, 0, fi);
                self.emit8(0x48);
                self.emit8(0x6B);
                self.emit8(0xC0);
                self.emit8(10);
                self.emit8(0x4C);
                self.emit8(0x01);
                self.emit8(0xC0);
                self.emit8(0x48);
                self.emit8(0xFF);
                self.emit8(0xC6);
                self.emit8(0x48);
                self.emit8(0xFF);
                self.emit8(0xC9);
                _ = self.emitJmpReloc(.code_offset, loop_top, fi);
                const done_pos = self.code_len;
                self.relocs[done0].target_id = done_pos;
                self.relocs[done1].target_id = done_pos;
                self.relocs[bad_digit].target_id = done_pos;
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xD2);
                self.emit8(0x74);
                self.emit8(0x03);
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xD8);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_int_to_string => {
                self.loadVregToReg(inst.args[0], 0);
                self.pushReg(0);
                self.mov64imm(7, 40);
                self.emitCallReloc(.malloc_fn, 0);
                self.emitTestRegZeroTrap(0);
                self.movRegReg(7, 0);
                self.popReg(0);
                self.subRspImm(32);
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0x74);
                self.emit8(0x24);
                self.emit8(31);
                self.emit8(0xC6);
                self.emit8(0x06);
                self.emit8(0x00);
                self.xorReg(8, 8);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                self.emit8(0x79);
                self.emit8(0x09);
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xD8);
                self.mov64imm(8, 1);
                const div_l = self.code_len;
                self.mov64imm(9, 10);
                self.xorReg(2, 2);
                self.emit8(0x49);
                self.emit8(0xF7);
                self.emit8(0xF1);
                self.emit8(0x80);
                self.emit8(0xC2);
                self.emit8('0');
                self.emit8(0x48);
                self.emit8(0xFF);
                self.emit8(0xCE);
                self.emit8(0x88);
                self.emit8(0x16);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                _ = self.emitJccReloc(0x5, .code_offset, div_l, fi);
                self.emit8(0x4D);
                self.emit8(0x85);
                self.emit8(0xC0);
                const skip_m = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emit8(0x48);
                self.emit8(0xFF);
                self.emit8(0xCE);
                self.emit8(0xC6);
                self.emit8(0x06);
                self.emit8('-');
                self.relocs[skip_m].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0x4C);
                self.emit8(0x24);
                self.emit8(31);
                self.emit8(0x48);
                self.emit8(0x29);
                self.emit8(0xF1);
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x0F);
                self.emit8(0x48);
                self.emit8(0x83);
                self.emit8(0xC7);
                self.emit8(0x08);
                self.pushReg(7);
                self.emit8(0x48);
                self.emit8(0xFF);
                self.emit8(0xC1);
                self.emitByteCopy();
                self.popReg(0);
                self.addRspImm(32);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },

            // ── Filesystem & Clock I/O ──
            .call_open => {
                self.loadVregToReg(inst.args[0], 0);
                self.pushReg(0);
                self.loadVregToReg(inst.args[1], 0);
                self.pushReg(0);
                if (inst.arg_count >= 3) {
                    self.loadVregToReg(inst.args[2], 2);
                } else {
                    self.mov64imm(2, 0o644);
                }
                self.popReg(6);
                self.popReg(7);
                self.emitPtrTrap(7);
                self.mov64imm(0, 2);
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_read, .call_sock_recv => {
                self.loadVregToReg(inst.args[0], 0);
                self.pushReg(0);
                self.loadVregToReg(inst.args[1], 0);
                self.pushReg(0);
                self.loadVregToReg(inst.args[2], 2);
                self.popReg(6);
                self.popReg(7);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xD2); // test rdx, rdx
                const rd_nonneg = self.emitJccReloc(0x9, .code_offset, 0, fi); // jns
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2
                self.relocs[rd_nonneg].target_id = self.code_len;
                const rd_zero = self.emitJccReloc(0x4, .code_offset, 0, fi); // jz
                self.emitCheckPtrLenRegs(6, 2);
                self.relocs[rd_zero].target_id = self.code_len;
                self.xorReg(0, 0);
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_write, .call_sock_send => {
                self.loadVregToReg(inst.args[0], 0);
                self.pushReg(0);
                self.loadVregToReg(inst.args[1], 0);
                self.pushReg(0);
                self.loadVregToReg(inst.args[2], 2);
                self.popReg(6);
                self.popReg(7);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xD2); // test rdx, rdx
                const wr_nonneg = self.emitJccReloc(0x9, .code_offset, 0, fi); // jns
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2
                self.relocs[wr_nonneg].target_id = self.code_len;
                const wr_zero = self.emitJccReloc(0x4, .code_offset, 0, fi); // jz
                self.emitCheckPtrLenRegs(6, 2);
                self.relocs[wr_zero].target_id = self.code_len;
                self.mov64imm(0, 1);
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_close => {
                self.loadVregToReg(inst.args[0], 7);
                self.mov64imm(0, 3);
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_unlink => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitPtrTrap(7);
                self.mov64imm(0, 87); // sys_unlink
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_mkdir => {
                self.loadVregToReg(inst.args[0], 7);
                self.pushReg(7);
                self.loadVregToReg(inst.args[1], 6);
                self.popReg(7);
                self.emitPtrTrap(7);
                self.mov64imm(0, 83); // sys_mkdir
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_getpid => {
                self.mov64imm(0, 39);
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_getppid => {
                self.mov64imm(0, 110);
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_getuid => {
                self.mov64imm(0, 102);
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_tcp_socket => {
                self.mov64imm(7, 2);
                self.mov64imm(6, 1);
                self.xorReg(2, 2);
                self.mov64imm(0, 41);
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_tcp_accept => {
                self.loadVregToReg(inst.args[0], 7);
                self.xorReg(6, 6);
                self.xorReg(2, 2);
                self.mov64imm(0, 43);
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_tcp_listen => {
                // args: [0]=fd, [1]=port, [2]=backlog
                self.subRspImm(32);
                // zero sockaddr_in [rsp..rsp+16], set AF_INET(2)
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x04);
                self.emit8(0x24);
                self.emit32(0);
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x44);
                self.emit8(0x24);
                self.emit8(8);
                self.emit32(0);
                self.emit8(0x66);
                self.emit8(0xC7);
                self.emit8(0x04);
                self.emit8(0x24);
                self.emit8(2);
                self.emit8(0);
                // [rsp+24] = fd
                self.loadVregToReg(inst.args[0], 0);
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x44);
                self.emit8(0x24);
                self.emit8(24);
                // [rsp+2] = htons(port)
                self.loadVregToReg(inst.args[1], 0);
                self.emit8(0x86);
                self.emit8(0xC4); // xchg al, ah
                self.emit8(0x66);
                self.emit8(0x89);
                self.emit8(0x44);
                self.emit8(0x24);
                self.emit8(2);
                // [rsp+16] = backlog > 0 ? backlog : 128
                self.loadVregToReg(inst.args[2], 0);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0); // test rax, rax
                const bl_ok = self.emitJccReloc(0xF, .code_offset, 0, fi); // jg
                self.mov64imm(0, 128);
                self.relocs[bl_ok].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x44);
                self.emit8(0x24);
                self.emit8(16);
                // dword [rsp+20] = 1 (SO_REUSEADDR)
                self.emit8(0xC7);
                self.emit8(0x44);
                self.emit8(0x24);
                self.emit8(20);
                self.emit32(1);
                // setsockopt(fd, 1, 2, rsp+20, 4)
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x7C);
                self.emit8(0x24);
                self.emit8(24); // mov rdi, [rsp+24]
                self.mov64imm(6, 1);
                self.mov64imm(2, 2);
                self.emit8(0x4C);
                self.emit8(0x8D);
                self.emit8(0x54);
                self.emit8(0x24);
                self.emit8(20); // lea r10, [rsp+20]
                self.mov64imm(8, 4);
                self.mov64imm(0, 54);
                self.syscallInst();
                // bind(fd, rsp, 16)
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x7C);
                self.emit8(0x24);
                self.emit8(24);
                self.movRegReg(6, 4);
                self.mov64imm(2, 16);
                self.mov64imm(0, 49);
                self.syscallInst();
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                const bind_fail = self.emitJccReloc(0x8, .code_offset, 0, fi); // js
                // listen(fd, backlog)
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x7C);
                self.emit8(0x24);
                self.emit8(24);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x74);
                self.emit8(0x24);
                self.emit8(16);
                self.mov64imm(0, 50);
                self.syscallInst();
                self.relocs[bind_fail].target_id = self.code_len;
                self.addRspImm(32);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_tcp_connect => {
                // args: [0]=ip, [1]=port
                self.subRspImm(24);
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x04);
                self.emit8(0x24);
                self.emit32(0);
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x44);
                self.emit8(0x24);
                self.emit8(8);
                self.emit32(0);
                self.emit8(0x66);
                self.emit8(0xC7);
                self.emit8(0x04);
                self.emit8(0x24);
                self.emit8(2);
                self.emit8(0);
                // [rsp+4] = ip
                self.loadVregToReg(inst.args[0], 0);
                self.emit8(0x89);
                self.emit8(0x44);
                self.emit8(0x24);
                self.emit8(4);
                // [rsp+2] = htons(port)
                self.loadVregToReg(inst.args[1], 0);
                self.emit8(0x86);
                self.emit8(0xC4);
                self.emit8(0x66);
                self.emit8(0x89);
                self.emit8(0x44);
                self.emit8(0x24);
                self.emit8(2);
                // socket(2, 1, 0)
                self.mov64imm(7, 2);
                self.mov64imm(6, 1);
                self.xorReg(2, 2);
                self.mov64imm(0, 41);
                self.syscallInst();
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                const sock_fail = self.emitJccReloc(0x8, .code_offset, 0, fi); // js
                // [rsp+16] = fd
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x44);
                self.emit8(0x24);
                self.emit8(16);
                self.movRegReg(7, 0);
                self.movRegReg(6, 4);
                self.mov64imm(2, 16);
                self.mov64imm(0, 42);
                self.syscallInst();
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                const conn_ok = self.emitJccReloc(0x9, .code_offset, 0, fi); // jns
                // save err in [rsp], close(fd), restore err
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x04);
                self.emit8(0x24);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x7C);
                self.emit8(0x24);
                self.emit8(16);
                self.mov64imm(0, 3);
                self.syscallInst();
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x04);
                self.emit8(0x24);
                const conn_err_done = self.emitJmpReloc(.code_offset, 0, fi);
                self.relocs[conn_ok].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x44);
                self.emit8(0x24);
                self.emit8(16);
                self.relocs[conn_err_done].target_id = self.code_len;
                self.relocs[sock_fail].target_id = self.code_len;
                self.addRspImm(24);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_stat => {
                if (inst.arg_count >= 2) {
                    self.emitRegArgsLoad(&inst.args, 2);
                    self.emitPtrTrap(7);
                    self.mov64imm(11, 144);
                    self.emitCheckPtrLenRegs(6, 11);
                    self.mov64imm(0, 4);
                    self.syscallInst();
                } else {
                    self.loadVregToReg(inst.args[0], 7);
                    self.emitPtrTrap(7);
                    self.subRspImm(144);
                    self.movRegReg(6, 4);
                    self.mov64imm(0, 4);
                    self.syscallInst();
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x44);
                    self.emit8(0x24);
                    self.emit8(48);
                    self.addRspImm(144);
                }
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_time_ns => {
                // clock_gettime(CLOCK_MONOTONIC=1, &ts)
                self.subRspImm(16);
                self.mov64imm(7, 1);
                self.movRegReg(6, 4);
                self.mov64imm(0, 228);
                self.syscallInst();
                // rax = ts.tv_sec * 1_000_000_000 + ts.tv_nsec
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x04);
                self.emit8(0x24); // mov rax, [rsp]
                self.emit8(0x48);
                self.emit8(0x69);
                self.emit8(0xC0);
                self.emit32(1000000000); // imul rax, rax, 1000000000
                self.emit8(0x48);
                self.emit8(0x03);
                self.emit8(0x44);
                self.emit8(0x24);
                self.emit8(0x08); // add rax, [rsp+8]
                self.addRspImm(16);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },

            // ── Threads & Mutexes ──
            .call_thread_create => {
                const target_fi = self.resolveCallTarget(inst) orelse {
                    self.invalid_reference = true;
                    return;
                };
                // Mark process multi-threaded so slab spinlocks engage & invalidate single-thread heap cache
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x04);
                self.emit8(0x25);
                self.emit32(@intCast(DATA_VADDR + 0xA0));
                self.emit32(1);
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x04);
                self.emit8(0x25);
                self.emit32(@intCast(DATA_VADDR + 0xC0));
                self.emit32(0xFFFFFFFF);
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x04);
                self.emit8(0x25);
                self.emit32(@intCast(DATA_VADDR + 0xC8));
                self.emit32(0);
                self.loadVregToReg(inst.args[1], 0);
                self.pushReg(0);
                self.xorReg(7, 7);
                self.mov64imm(6, 0x11000); // 4 KiB PROT_NONE guard page + 64 KiB thread stack
                self.mov64imm(2, 3);
                self.mov64imm(10, 0x22);
                self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
                self.xorReg(9, 9);
                self.mov64imm(0, 9);
                self.syscallInst();
                // Check sys_mmap error (-4095..-1 unsigned > -4096)
                self.mov64imm(11, @bitCast(@as(i64, -4096)));
                self.emit8(0x4C);
                self.emit8(0x39);
                self.emit8(0xD8); // cmp rax, r11
                const tc_mmap_ok = self.emitJccReloc(0x6, .code_offset, 0, fi); // jbe
                self.popReg(11);
                self.mov64imm(0, @bitCast(@as(i64, -1)));
                const tc_fail_done = self.emitJmpReloc(.code_offset, 0, fi);
                self.relocs[tc_mmap_ok].target_id = self.code_len;
                self.pushReg(0); // preserve stack base across mprotect
                self.movRegReg(7, 0);
                self.mov64imm(6, 0x1000);
                self.xorReg(2, 2); // PROT_NONE = 0
                self.mov64imm(0, 10); // SYS_mprotect
                self.syscallInst();
                self.popReg(0);
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0xB0);
                self.emit32(0x11000 - 16);
                self.leaRipFn(0, target_fi);
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x06);
                self.popReg(0);
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x46);
                self.emit8(0x08);
                self.mov64imm(7, 0x711);
                self.xorReg(2, 2);
                self.mov64imm(0, 56);
                self.syscallInst();
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                const parent_jcc = self.emitJccReloc(0x5, .code_offset, 0, fi);
                self.popReg(0);
                self.popReg(7);
                self.emit8(0xFF);
                self.emit8(0xD0);
                self.mov64imm(0, 60);
                self.xorReg(7, 7);
                self.syscallInst();
                const tc_done_pos = self.code_len;
                self.relocs[parent_jcc].target_id = tc_done_pos;
                self.relocs[tc_fail_done].target_id = tc_done_pos;
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_thread_join => {
                self.loadVregToReg(inst.args[0], 7);
                self.xorReg(6, 6);
                self.xorReg(2, 2);
                self.xorReg(10, 10);
                self.mov64imm(0, 61);
                self.syscallInst();
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_mutex_create => {
                self.mov64imm(7, 16);
                self.emitCallReloc(.malloc_fn, 0);
                self.emitTestRegZeroTrap(0);
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x00);
                self.emit32(0); // mov qword [rax], 0
                self.emit8(0x48);
                self.emit8(0x83);
                self.emit8(0xC0);
                self.emit8(0x08); // add rax, 8
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_mutex_lock => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitPtrTrap(7);
                const retry = self.code_len;
                self.emit8(0xB8);
                self.emit32(1);
                self.emit8(0x87);
                self.emit8(0x47);
                self.emit8(0xF8);
                self.emit8(0x85);
                self.emit8(0xC0);
                const acq = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.pushReg(7);
                self.emit8(0x48);
                self.emit8(0x83);
                self.emit8(0xEF);
                self.emit8(0x08);
                self.xorReg(6, 6);
                self.mov64imm(2, 1);
                self.xorReg(10, 10);
                self.mov64imm(0, 202);
                self.syscallInst();
                self.popReg(7);
                _ = self.emitJmpReloc(.code_offset, retry, fi);
                self.relocs[acq].target_id = self.code_len;
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .call_mutex_unlock => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitPtrTrap(7);
                self.xorReg(0, 0);
                self.emit8(0x87);
                self.emit8(0x47);
                self.emit8(0xF8);
                self.emit8(0x48);
                self.emit8(0x83);
                self.emit8(0xEF);
                self.emit8(0x08);
                self.mov64imm(6, 1);
                self.mov64imm(2, 1);
                self.mov64imm(0, 202);
                self.syscallInst();
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .call_argc => {
                self.mov64imm(0, DATA_VADDR);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x00);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_argv => {
                self.loadVregToReg(inst.args[0], 1);
                self.mov64imm(0, DATA_VADDR);
                self.emit8(0x48);
                self.emit8(0x3B);
                self.emit8(0x08); // cmp rcx, [rax] (unsigned idx < argc)
                const argv_ok = self.emitJccReloc(0x2, .code_offset, 0, fi); // jb
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2
                self.relocs[argv_ok].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x40);
                self.emit8(0x08);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x34);
                self.emit8(0xC8); // rsi = cstr
                self.emitTestRegZeroTrap(6);
                self.xorReg(1, 1);
                const sl_loop = self.code_len;
                self.emit8(0x80);
                self.emit8(0x3C);
                self.emit8(0x0E);
                self.emit8(0x00);
                const sl_done = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emit8(0x48);
                self.emit8(0xFF);
                self.emit8(0xC1);
                _ = self.emitJmpReloc(.code_offset, sl_loop, fi);
                self.relocs[sl_done].target_id = self.code_len;
                self.pushReg(6);
                self.pushReg(1);
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0x79);
                self.emit8(0x09); // lea rdi, [rcx + 9]
                self.emitCallReloc(.malloc_fn, 0);
                self.emitTestRegZeroTrap(0);
                self.popReg(1);
                self.popReg(6);
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x08);
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0x78);
                self.emit8(0x08);
                self.pushReg(7);
                self.emitByteCopy();
                self.emit8(0xC6);
                self.emit8(0x07);
                self.emit8(0x00);
                self.popReg(0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },

            // ── Floating-point print / parse / format / math ──
            .call_float_to_string => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitCallReloc(.float_to_str_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_print_float, .call_println_float => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitCallReloc(.float_to_str_fn, 0);
                self.movRegReg(6, 0);
                self.emitTestRegZeroTrap(6);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x56);
                self.emit8(0xF8); // rdx = len
                self.mov64imm(0, 1);
                self.mov64imm(7, 1);
                self.syscallInst();
                // float_to_str returns allocation + 8 (past the string length).
                // free must receive the original allocation, not its interior.
                self.emitLeaRegDisp(7, 6, -8);
                self.emitCallReloc(.free_fn, 0);
                if (inst.op == .call_println_float) {
                    const nl_idx = self.addString("\n");
                    self.leaRipRodata(6, nl_idx);
                    self.mov64imm(0, 1);
                    self.mov64imm(7, 1);
                    self.mov64imm(2, 1);
                    self.syscallInst();
                }
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .call_string_to_float => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitCallReloc(.str_to_float_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_sqrt => {
                self.loadVregToReg(inst.args[0], 0);
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xC0); // movq xmm0, rax
                self.emit8(0xF2);
                self.emit8(0x0F);
                self.emit8(0x51);
                self.emit8(0xC0); // sqrtsd xmm0, xmm0
                self.emit8(0x66);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0x7E);
                self.emit8(0xC0); // movq rax, xmm0
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_fabs => {
                self.loadVregToReg(inst.args[0], 0);
                self.mov64imm(1, 0x7FFF_FFFF_FFFF_FFFF);
                self.emit8(0x48);
                self.emit8(0x21);
                self.emit8(0xC8); // and rax, rcx
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_floor, .call_ceil, .call_round => {
                // Baseline-SSE2 rounding for |x| < 2^52 using cvttsd2si / cvtsi2sd
                self.loadVregToReg(inst.args[0], 0);
                self.mov64imm(1, 0x7FFF_FFFF_FFFF_FFFF);
                self.emit8(0x48);
                self.emit8(0x21);
                self.emit8(0xC1); // rcx = |x| bits
                const r_done0 = self.emitJccReloc(0x4, .code_offset, 0, fi); // jz (preserve +-0.0)
                self.mov64imm(2, 0x4330_0000_0000_0000); // 2^52
                self.emit8(0x48);
                self.emit8(0x39);
                self.emit8(0xD1); // cmp rcx, rdx
                const r_done1 = self.emitJccReloc(0x3, .code_offset, 0, fi); // jae (|x|>=2^52 or Inf/NaN)

                self.mov64imm(8, 0x3FF0_0000_0000_0000); // 1.0
                self.emit8(0x66);
                self.emit8(0x49);
                self.emit8(0x0F);
                self.emit8(0x6E);
                self.emit8(0xD8); // movq xmm3, r8 (1.0)

                if (inst.op == .call_round) {
                    self.mov64imm(10, 0x8000_0000_0000_0000);
                }

                if (inst.op == .call_floor or inst.op == .call_ceil) {
                    self.emit8(0x66);
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0x6E);
                    self.emit8(0xC0); // movq xmm0, rax
                    self.emit8(0xF2);
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0x2C);
                    self.emit8(0xC8); // cvttsd2si rcx, xmm0
                    self.emit8(0xF2);
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0x2A);
                    self.emit8(0xC9); // cvtsi2sd xmm1, rcx (trunc)
                    if (inst.op == .call_floor) {
                        self.emit8(0x66);
                        self.emit8(0x0F);
                        self.emit8(0x2E);
                        self.emit8(0xC8); // ucomisd xmm1, xmm0
                        const fl_ok = self.emitJccReloc(0x6, .code_offset, 0, fi); // jbe
                        self.emit8(0xF2);
                        self.emit8(0x0F);
                        self.emit8(0x5C);
                        self.emit8(0xCB); // subsd xmm1, xmm3
                        self.relocs[fl_ok].target_id = self.code_len;
                    } else {
                        self.emit8(0x66);
                        self.emit8(0x0F);
                        self.emit8(0x2E);
                        self.emit8(0xC1); // ucomisd xmm0, xmm1
                        const cl_ok = self.emitJccReloc(0x6, .code_offset, 0, fi); // jbe
                        self.emit8(0xF2);
                        self.emit8(0x0F);
                        self.emit8(0x58);
                        self.emit8(0xCB); // addsd xmm1, xmm3
                        self.relocs[cl_ok].target_id = self.code_len;
                    }
                    self.emit8(0x66);
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0x7E);
                    self.emit8(0xC8); // movq rax, xmm1
                } else {
                    // round half away from zero: |x| in rcx, sign bit in r10
                    self.emit8(0x49);
                    self.emit8(0x21);
                    self.emit8(0xC2); // and r10, rax
                    self.emit8(0x66);
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0x6E);
                    self.emit8(0xC1); // movq xmm0, rcx (|x|)
                    self.emit8(0xF2);
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0x2C);
                    self.emit8(0xC0); // cvttsd2si rax, xmm0
                    self.emit8(0xF2);
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0x2A);
                    self.emit8(0xC8); // cvtsi2sd xmm1, rax (trunc(|x|))
                    self.emit8(0xF2);
                    self.emit8(0x0F);
                    self.emit8(0x5C);
                    self.emit8(0xC1); // subsd xmm0, xmm1 (frac)
                    self.mov64imm(9, 0x3FE0_0000_0000_0000); // 0.5
                    self.emit8(0x66);
                    self.emit8(0x49);
                    self.emit8(0x0F);
                    self.emit8(0x6E);
                    self.emit8(0xD1); // movq xmm2, r9 (0.5)
                    self.emit8(0x66);
                    self.emit8(0x0F);
                    self.emit8(0x2E);
                    self.emit8(0xC2); // ucomisd xmm0, xmm2
                    const rnd_ok = self.emitJccReloc(0x2, .code_offset, 0, fi); // jb
                    self.emit8(0xF2);
                    self.emit8(0x0F);
                    self.emit8(0x58);
                    self.emit8(0xCB); // addsd xmm1, xmm3
                    self.relocs[rnd_ok].target_id = self.code_len;
                    self.emit8(0x66);
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0x7E);
                    self.emit8(0xC8); // movq rax, xmm1
                    self.emit8(0x4C);
                    self.emit8(0x09);
                    self.emit8(0xD0); // or rax, r10
                }
                const r_done_pos = self.code_len;
                self.relocs[r_done0].target_id = r_done_pos;
                self.relocs[r_done1].target_id = r_done_pos;
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_sin => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitCallReloc(.sin_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_cos => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitCallReloc(.cos_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },

            // ── Portable Bitwise Operations ──
            .call_popcount => {
                // Baseline x86-64 SWAR popcount (does not require POPCNT CPUID)
                self.loadVregToReg(inst.args[0], 0);
                self.movRegReg(1, 0);
                self.emit8(0x48);
                self.emit8(0xD1);
                self.emit8(0xE9); // shr rcx, 1
                self.mov64imm(2, 0x5555_5555_5555_5555);
                self.emit8(0x48);
                self.emit8(0x21);
                self.emit8(0xD1); // and rcx, rdx
                self.emit8(0x48);
                self.emit8(0x29);
                self.emit8(0xC8); // sub rax, rcx
                self.mov64imm(2, 0x3333_3333_3333_3333);
                self.movRegReg(1, 0);
                self.emit8(0x48);
                self.emit8(0xC1);
                self.emit8(0xE9);
                self.emit8(2); // shr rcx, 2
                self.emit8(0x48);
                self.emit8(0x21);
                self.emit8(0xD0); // and rax, rdx
                self.emit8(0x48);
                self.emit8(0x21);
                self.emit8(0xD1); // and rcx, rdx
                self.emit8(0x48);
                self.emit8(0x01);
                self.emit8(0xC8); // add rax, rcx
                self.movRegReg(1, 0);
                self.emit8(0x48);
                self.emit8(0xC1);
                self.emit8(0xE9);
                self.emit8(4); // shr rcx, 4
                self.emit8(0x48);
                self.emit8(0x01);
                self.emit8(0xC8); // add rax, rcx
                self.mov64imm(2, 0x0F0F_0F0F_0F0F_0F0F);
                self.emit8(0x48);
                self.emit8(0x21);
                self.emit8(0xD0); // and rax, rdx
                self.mov64imm(2, 0x0101_0101_0101_0101);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xAF);
                self.emit8(0xC2); // imul rax, rdx
                self.emit8(0x48);
                self.emit8(0xC1);
                self.emit8(0xE8);
                self.emit8(56); // shr rax, 56
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_clz => {
                self.loadVregToReg(inst.args[0], 1);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC9); // test rcx, rcx
                const clz_nz = self.emitJccReloc(0x5, .code_offset, 0, fi);
                self.mov64imm(0, 64);
                const clz_done = self.emitJmpReloc(.code_offset, 0, fi);
                self.relocs[clz_nz].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xBD);
                self.emit8(0xC1); // bsr rax, rcx
                self.emit8(0x83);
                self.emit8(0xF0);
                self.emit8(63); // xor eax, 63
                self.relocs[clz_done].target_id = self.code_len;
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_ctz => {
                self.loadVregToReg(inst.args[0], 1);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC9); // test rcx, rcx
                const ctz_nz = self.emitJccReloc(0x5, .code_offset, 0, fi);
                self.mov64imm(0, 64);
                const ctz_done = self.emitJmpReloc(.code_offset, 0, fi);
                self.relocs[ctz_nz].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xBC);
                self.emit8(0xC1); // bsf rax, rcx
                self.relocs[ctz_done].target_id = self.code_len;
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_bswap => {
                self.loadVregToReg(inst.args[0], 0);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xC8); // bswap rax
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },

            // ── Atomic Memory Operations ──
            .call_atomic_add => {
                self.emitRegArgsLoad(&inst.args, 2); // rdi = ptr, rsi = delta
                self.emitPtrTrap(7);
                self.movRegReg(0, 6);
                self.emit8(0xF0);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xC1);
                self.emit8(0x07); // lock xadd [rdi], rax
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_atomic_cas => {
                self.emitRegArgsLoad(&inst.args, 3); // rdi = ptr, rsi = expected, rdx = desired
                self.emitPtrTrap(7);
                self.movRegReg(0, 6);
                self.emit8(0xF0);
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xB1);
                self.emit8(0x17); // lock cmpxchg [rdi], rdx
                self.emit8(0x0F);
                self.emit8(0x94);
                self.emit8(0xC0); // sete al
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xB6);
                self.emit8(0xC0); // movzx rax, al
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },

            // ── Hash Maps ──
            .call_map_new => {
                if (inst.arg_count >= 1) {
                    self.loadVregToReg(inst.args[0], 7);
                } else {
                    self.xorReg(7, 7);
                }
                self.emitCallReloc(.map_new_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_map_set => {
                self.emitRegArgsLoad(&inst.args, 3);
                self.emitCallReloc(.map_set_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_map_get => {
                self.emitRegArgsLoad(&inst.args, 2);
                self.emitCallReloc(.map_get_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_map_has => {
                self.emitRegArgsLoad(&inst.args, 2);
                self.emitCallReloc(.map_has_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_map_del => {
                self.emitRegArgsLoad(&inst.args, 2);
                self.emitCallReloc(.map_del_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_map_len => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitPtrTrap(7);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x07); // mov rax, [rdi]
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_map_free => {
                self.loadVregToReg(inst.args[0], 7);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xFF);
                const mf_skip = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emitPtrTrap(7);
                self.pushReg(7);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x7F);
                self.emit8(0x10); // rdi = [rdi+16] (entries_ptr)
                self.emitCallReloc(.free_fn, 0);
                self.popReg(7);
                self.emitCallReloc(.free_fn, 0);
                self.relocs[mf_skip].target_id = self.code_len;
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },

            // ── Channels ──
            .call_chan_new => {
                if (inst.arg_count >= 1) {
                    self.loadVregToReg(inst.args[0], 7);
                } else {
                    self.mov64imm(7, 16);
                }
                self.emitCallReloc(.chan_new_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_chan_send => {
                self.emitRegArgsLoad(&inst.args, 2);
                self.emitCallReloc(.chan_send_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_chan_recv => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitCallReloc(.chan_recv_fn, 0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_chan_close => {
                self.loadVregToReg(inst.args[0], 7);
                self.emitPtrTrap(7);
                // Acquire spinlock at [rdi], set [rdi+40] = 1, unlock
                const cc_spin = self.code_len;
                self.emit8(0xB8);
                self.emit32(1);
                self.emit8(0x87);
                self.emit8(0x07); // xchg [rdi], eax
                self.emit8(0x85);
                self.emit8(0xC0);
                const cc_got = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emit8(0xF3);
                self.emit8(0x90);
                _ = self.emitJmpReloc(.code_offset, cc_spin, fi);
                self.relocs[cc_got].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x47);
                self.emit8(40);
                self.emit32(1);
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x07);
                self.emit32(0);
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },

            // ── Assertions ──
            .call_assert => {
                self.loadVregToReg(inst.args[0], 0);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                const as_ok = self.emitJccReloc(0x5, .code_offset, 0, fi);
                self.emitCallReloc(.assert_fail_fn, 0);
                self.relocs[as_ok].target_id = self.code_len;
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .call_assert_eq => {
                self.loadVregToReg(inst.args[0], 0);
                self.loadVregToReg(inst.args[1], 1);
                self.emit8(0x48);
                self.emit8(0x39);
                self.emit8(0xC8); // cmp rax, rcx
                const ae_ok = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emitCallReloc(.assert_fail_fn, 0);
                self.relocs[ae_ok].target_id = self.code_len;
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },

            // ── High-Security & Zero-Wrapper Systems Builtins ──
            .call_random_u64 => {
                self.subRspImm(16);
                self.movRegReg(7, 4); // rdi = rsp
                self.mov64imm(6, 8); // rsi = 8
                const ru_loop = self.code_len;
                self.xorReg(2, 2); // flags = 0
                self.mov64imm(0, 318); // SYS_getrandom
                self.syscallInst();
                self.emitCmpRegImm32(0, -4); // EINTR
                _ = self.emitJccReloc(0x4, .code_offset, ru_loop, fi);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                const ru_ok = self.emitJccReloc(0xF, .code_offset, 0, fi); // jg
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2 (never return unseeded zero on failure)
                self.relocs[ru_ok].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x01);
                self.emit8(0xC7); // add rdi, rax
                self.emit8(0x48);
                self.emit8(0x29);
                self.emit8(0xC6); // sub rsi, rax
                const ru_done = self.emitJccReloc(0x4, .code_offset, 0, fi); // jz
                _ = self.emitJmpReloc(.code_offset, ru_loop, fi);
                self.relocs[ru_done].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x04);
                self.emit8(0x24); // mov rax, [rsp]
                self.emit8(0x48);
                self.emit8(0xC7);
                self.emit8(0x04);
                self.emit8(0x24);
                self.emit32(0); // mov qword [rsp], 0 (scrub CSPRNG stack slot)
                self.addRspImm(16);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_random_bytes => {
                self.emitRegArgsLoad(&inst.args, 2); // rdi = buf, rsi = len
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xF6);
                const rb_nonneg = self.emitJccReloc(0x9, .code_offset, 0, fi); // jns
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2
                self.relocs[rb_nonneg].target_id = self.code_len;
                self.pushReg(6); // original len
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xF6);
                const rb_done0 = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emitCheckPtrLenRegs(7, 6);
                const rb_loop = self.code_len;
                self.xorReg(2, 2);
                self.mov64imm(0, 318);
                self.syscallInst();
                self.emitCmpRegImm32(0, -4);
                _ = self.emitJccReloc(0x4, .code_offset, rb_loop, fi);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                const rb_ok = self.emitJccReloc(0xF, .code_offset, 0, fi); // jg
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2
                self.relocs[rb_ok].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x01);
                self.emit8(0xC7);
                self.emit8(0x48);
                self.emit8(0x29);
                self.emit8(0xC6);
                const rb_done = self.emitJccReloc(0x4, .code_offset, 0, fi);
                _ = self.emitJmpReloc(.code_offset, rb_loop, fi);
                const rb_end = self.code_len;
                self.relocs[rb_done0].target_id = rb_end;
                self.relocs[rb_done].target_id = rb_end;
                self.popReg(0);
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_secure_zero => {
                self.emitRegArgsLoad(&inst.args, 2); // rdi = ptr, rsi = len
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xF6);
                const sz_nonneg = self.emitJccReloc(0x9, .code_offset, 0, fi);
                self.emit8(0x0F);
                self.emit8(0x0B);
                self.relocs[sz_nonneg].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xF6);
                const sz_done = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emitCheckPtrLenRegs(7, 6);
                self.movRegReg(1, 6);
                self.xorReg(0, 0);
                self.emit8(0xFC); // cld
                self.emit8(0xF3);
                self.emit8(0xAA); // rep stosb
                self.relocs[sz_done].target_id = self.code_len;
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeRegToVreg(0, inst.dest);
                }
            },
            .call_const_time_eq => {
                self.emitRegArgsLoad(&inst.args, 3); // rdi = a, rsi = b, rdx = len
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xD2);
                const ct_nonneg = self.emitJccReloc(0x9, .code_offset, 0, fi);
                self.emit8(0x0F);
                self.emit8(0x0B);
                self.relocs[ct_nonneg].target_id = self.code_len;
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xD2);
                const ct_zero_len = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emitCheckPtrLenRegs(7, 2);
                self.emitCheckPtrLenRegs(6, 2);
                self.xorReg(8, 8);
                self.xorReg(1, 1);
                const ct_loop = self.code_len;
                self.emit8(0x0F);
                self.emit8(0xB6);
                self.emit8(0x04);
                self.emit8(0x0F); // movzx eax, byte ptr [rdi+rcx]
                self.emit8(0x32);
                self.emit8(0x04);
                self.emit8(0x0E); // xor al, byte ptr [rsi+rcx]
                self.emit8(0x41);
                self.emit8(0x08);
                self.emit8(0xC0); // or r8b, al
                self.emit8(0x48);
                self.emit8(0xFF);
                self.emit8(0xC1); // inc rcx
                self.emit8(0x48);
                self.emit8(0x39);
                self.emit8(0xD1); // cmp rcx, rdx
                _ = self.emitJccReloc(0x2, .code_offset, ct_loop, fi); // jb
                self.emit8(0x45);
                self.emit8(0x84);
                self.emit8(0xC0); // test r8b, r8b
                self.emit8(0x0F);
                self.emit8(0x94);
                self.emit8(0xC0); // sete al
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xB6);
                self.emit8(0xC0); // movzx rax, al
                const ct_done = self.emitJmpReloc(.code_offset, 0, fi);
                self.relocs[ct_zero_len].target_id = self.code_len;
                self.mov64imm(0, 1);
                self.relocs[ct_done].target_id = self.code_len;
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_checked_add, .call_checked_sub, .call_checked_mul => {
                self.loadVregToReg(inst.args[0], 0);
                self.loadVregToReg(inst.args[1], 1);
                if (inst.op == .call_checked_add) {
                    self.emit8(0x48);
                    self.emit8(0x01);
                    self.emit8(0xC8); // add rax, rcx
                } else if (inst.op == .call_checked_sub) {
                    self.emit8(0x48);
                    self.emit8(0x29);
                    self.emit8(0xC8); // sub rax, rcx
                } else {
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0xAF);
                    self.emit8(0xC1); // imul rax, rcx
                }
                self.emit8(0x71);
                self.emit8(0x02); // jno +2
                self.emit8(0x0F);
                self.emit8(0x0B); // ud2
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_getenv => {
                self.loadVregToReg(inst.args[0], 7); // rdi = name_str
                self.emitPtrTrap(7);
                self.emit8(0x4C);
                self.emit8(0x8B);
                self.emit8(0x47);
                self.emit8(0xF8); // r8 = [rdi - 8] (name_len)
                self.mov64imm(0, DATA_VADDR);
                self.emit8(0x4C);
                self.emit8(0x8B);
                self.emit8(0x48);
                self.emit8(0x68); // r9 = [DATA_VADDR + 0x68] (envp)
                self.emit8(0x4D);
                self.emit8(0x85);
                self.emit8(0xC9);
                const ge_not_found_null = self.emitJccReloc(0x4, .code_offset, 0, fi);
                const ge_env_loop = self.code_len;
                self.emit8(0x4D);
                self.emit8(0x8B);
                self.emit8(0x11); // r10 = [r9]
                self.emit8(0x4D);
                self.emit8(0x85);
                self.emit8(0xD2);
                const ge_not_found_end = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.xorReg(1, 1);
                const ge_cmp_loop = self.code_len;
                self.emit8(0x4C);
                self.emit8(0x39);
                self.emit8(0xC1); // cmp rcx, r8
                const ge_cmp_eq_sign = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emit8(0x41);
                self.emit8(0x0F);
                self.emit8(0xB6);
                self.emit8(0x04);
                self.emit8(0x0A); // movzx eax, byte ptr [r10+rcx]
                self.emit8(0x84);
                self.emit8(0xC0); // test al, al
                const ge_next1 = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emit8(0x3A);
                self.emit8(0x04);
                self.emit8(0x0F); // cmp al, byte ptr [rdi+rcx]
                const ge_next2 = self.emitJccReloc(0x5, .code_offset, 0, fi);
                self.emit8(0x48);
                self.emit8(0xFF);
                self.emit8(0xC1); // inc rcx
                _ = self.emitJmpReloc(.code_offset, ge_cmp_loop, fi);
                self.relocs[ge_cmp_eq_sign].target_id = self.code_len;
                self.emit8(0x43);
                self.emit8(0x80);
                self.emit8(0x3C);
                self.emit8(0x02);
                self.emit8('='); // cmp byte ptr [r10+r8], '='
                const ge_next3 = self.emitJccReloc(0x5, .code_offset, 0, fi);
                // Found! rsi = r10 + r8 + 1
                self.emit8(0x4B);
                self.emit8(0x8D);
                self.emit8(0x74);
                self.emit8(0x02);
                self.emit8(1); // lea rsi, [r10 + r8 + 1]
                self.xorReg(1, 1);
                const ge_len_loop = self.code_len;
                self.emit8(0x80);
                self.emit8(0x3C);
                self.emit8(0x0E);
                self.emit8(0x00); // cmp byte ptr [rsi+rcx], 0
                const ge_len_done = self.emitJccReloc(0x4, .code_offset, 0, fi);
                self.emit8(0x48);
                self.emit8(0xFF);
                self.emit8(0xC1);
                _ = self.emitJmpReloc(.code_offset, ge_len_loop, fi);
                self.relocs[ge_len_done].target_id = self.code_len;
                self.pushReg(6);
                self.pushReg(1);
                self.emitLeaRegDisp(7, 1, 9);
                self.emitCallReloc(.malloc_fn, 0);
                self.emitTestRegZeroTrap(0);
                self.popReg(1);
                self.popReg(6);
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0x08); // [rax] = val_len
                self.emitLeaRegDisp(7, 0, 8);
                self.pushReg(7);
                self.emitByteCopy();
                self.emit8(0xC6);
                self.emit8(0x07);
                self.emit8(0x00);
                self.popReg(0);
                const ge_done = self.emitJmpReloc(.code_offset, 0, fi);
                const ge_next_pos = self.code_len;
                self.relocs[ge_next1].target_id = ge_next_pos;
                self.relocs[ge_next2].target_id = ge_next_pos;
                self.relocs[ge_next3].target_id = ge_next_pos;
                self.emit8(0x49);
                self.emit8(0x83);
                self.emit8(0xC1);
                self.emit8(0x08); // add r9, 8
                _ = self.emitJmpReloc(.code_offset, ge_env_loop, fi);
                const ge_nf_pos = self.code_len;
                self.relocs[ge_not_found_null].target_id = ge_nf_pos;
                self.relocs[ge_not_found_end].target_id = ge_nf_pos;
                const empty_idx = self.addString("");
                self.leaRipRodata(0, empty_idx);
                self.relocs[ge_done].target_id = self.code_len;
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_sleep_ms => {
                self.loadVregToReg(inst.args[0], 0);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                const sl_zero = self.emitJccReloc(0xE, .code_offset, 0, fi); // jle
                self.emit8(0x48);
                self.emit8(0x99); // cqo
                self.mov64imm(1, 1000);
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xF9); // idiv rcx -> rax=sec, rdx=rem_ms
                self.emit8(0x48);
                self.emit8(0x69);
                self.emit8(0xD2);
                self.emit32(1000000); // imul rdx, rdx, 1_000_000
                self.pushReg(2); // tv_nsec
                self.pushReg(0); // tv_sec
                const sl_retry = self.code_len;
                self.movRegReg(7, 4);
                self.movRegReg(6, 4);
                self.mov64imm(0, 35); // SYS_nanosleep
                self.syscallInst();
                self.emitCmpRegImm32(0, -4); // EINTR
                _ = self.emitJccReloc(0x4, .code_offset, sl_retry, fi);
                self.addRspImm(16);
                const sl_done = self.emitJmpReloc(.code_offset, 0, fi);
                self.relocs[sl_zero].target_id = self.code_len;
                self.xorReg(0, 0);
                self.relocs[sl_done].target_id = self.code_len;
                if (inst.dest != 0) self.storeRegToVreg(0, inst.dest);
            },
            .call_read_u32 => {
                const ptr_reg: u8 = self.vregPhys(inst.args[0]) orelse blk: {
                    self.loadVregToReg(inst.args[0], 0);
                    break :blk 0;
                };
                self.emitPtrTrapN(ptr_reg, 4);
                const dst_reg: u8 = self.vregPhys(inst.dest) orelse 0;
                self.emitMemLoadU32(dst_reg, ptr_reg);
                if (inst.dest != 0 and self.vregPhys(inst.dest) == null) self.storeRegToVreg(dst_reg, inst.dest);
            },
            .call_write_u32 => {
                const ptr_reg: u8 = self.vregPhys(inst.args[0]) orelse blk: {
                    self.loadVregToReg(inst.args[0], 0);
                    break :blk 0;
                };
                self.emitPtrTrapN(ptr_reg, 4);
                const val_reg: u8 = self.vregPhys(inst.args[1]) orelse blk_v: {
                    self.loadVregToReg(inst.args[1], 1);
                    break :blk_v 1;
                };
                self.emitMemStoreU32(ptr_reg, val_reg);
                if (inst.dest != 0) {
                    if (self.vregPhys(inst.dest)) |dr| {
                        self.xorReg(dr, dr);
                    } else {
                        self.xorReg(0, 0);
                        self.storeRegToVreg(0, inst.dest);
                    }
                }
            },
            .call_read_u64 => {
                const ptr_reg: u8 = self.vregPhys(inst.args[0]) orelse blk: {
                    self.loadVregToReg(inst.args[0], 0);
                    break :blk 0;
                };
                self.emitPtrTrapN(ptr_reg, 8);
                const dst_reg: u8 = self.vregPhys(inst.dest) orelse 0;
                self.emitMemLoadDisp(dst_reg, ptr_reg, 0);
                if (inst.dest != 0 and self.vregPhys(inst.dest) == null) self.storeRegToVreg(dst_reg, inst.dest);
            },
            .call_write_u64 => {
                const ptr_reg: u8 = self.vregPhys(inst.args[0]) orelse blk: {
                    self.loadVregToReg(inst.args[0], 0);
                    break :blk 0;
                };
                self.emitPtrTrapN(ptr_reg, 8);
                const val_reg: u8 = self.vregPhys(inst.args[1]) orelse blk_v: {
                    self.loadVregToReg(inst.args[1], 1);
                    break :blk_v 1;
                };
                self.emitMemStoreDisp(ptr_reg, val_reg, 0);
                if (inst.dest != 0) {
                    if (self.vregPhys(inst.dest)) |dr| {
                        self.xorReg(dr, dr);
                    } else {
                        self.xorReg(0, 0);
                        self.storeRegToVreg(0, inst.dest);
                    }
                }
            },

            .nop, .struct_decl, .module_import => {},
            else => {},
        }
    }

    fn compileRegBinOp(self: *IRCodegen, inst: IRInst) void {
        const op = inst.op;
        var s1 = inst.src1;
        var s2 = inst.src2;

        // Put i32 constant on RHS if commutative and LHS is constant
        if (isCommutative(op) and s1 > 0 and s1 < MAX_VREGS and self.vreg_const_known[s1] and
            fitsI32NonMin(self.vreg_const_imm[s1]) and
            !(s2 > 0 and s2 < MAX_VREGS and self.vreg_const_known[s2]))
        {
            const tmp = s1;
            s1 = s2;
            s2 = tmp;
        }

        const rd_opt = self.vregPhys(inst.dest);
        const r1_opt = self.vregPhys(s1);

        // Immediate RHS fast path!
        if (s2 > 0 and s2 < MAX_VREGS and self.vreg_const_known[s2] and fitsI32NonMin(self.vreg_const_imm[s2])) {
            const imm: i32 = @intCast(self.vreg_const_imm[s2]);
            if ((op == .add or op == .sub) and rd_opt != null and r1_opt != null and rd_opt.? != r1_opt.?) {
                const disp: i32 = if (op == .add) imm else -imm;
                self.emitLeaRegDisp(rd_opt.?, r1_opt.?, disp);
                return;
            }
            if (op == .mul and rd_opt != null) {
                const rd = rd_opt.?;
                const rs = r1_opt orelse blk: {
                    self.loadVregToReg(s1, 0);
                    break :blk 0;
                };
                if (imm == 3) {
                    self.emitLeaRegIdxScale(rd, rs, rs, 1);
                    return;
                } else if (imm == 5) {
                    self.emitLeaRegIdxScale(rd, rs, rs, 2);
                    return;
                } else if (imm == 9) {
                    self.emitLeaRegIdxScale(rd, rs, rs, 3);
                    return;
                }
                self.emitRex(rd, rs);
                if (imm >= -128 and imm <= 127) {
                    self.emit8(0x6B);
                    self.emitModRM(3, rd, rs);
                    self.emit8(@bitCast(@as(i8, @intCast(imm))));
                } else {
                    self.emit8(0x69);
                    self.emitModRM(3, rd, rs);
                    self.emit32(@bitCast(imm));
                }
                return;
            }
            const dst_reg: u8 = rd_opt orelse 0;
            self.loadVregToReg(s1, dst_reg);
            if (op == .mul) {
                if (imm == 3) {
                    self.emitLeaRegIdxScale(dst_reg, dst_reg, dst_reg, 1);
                } else if (imm == 5) {
                    self.emitLeaRegIdxScale(dst_reg, dst_reg, dst_reg, 2);
                } else if (imm == 9) {
                    self.emitLeaRegIdxScale(dst_reg, dst_reg, dst_reg, 3);
                } else {
                    self.emitRex(dst_reg, dst_reg);
                    if (imm >= -128 and imm <= 127) {
                        self.emit8(0x6B);
                        self.emitModRM(3, dst_reg, dst_reg);
                        self.emit8(@bitCast(@as(i8, @intCast(imm))));
                    } else {
                        self.emit8(0x69);
                        self.emitModRM(3, dst_reg, dst_reg);
                        self.emit32(@bitCast(imm));
                    }
                }
            } else {
                const subop: u8 = switch (op) {
                    .add => 0,
                    .bit_or => 1,
                    .bit_and => 4,
                    .sub => 5,
                    .bit_xor => 6,
                    else => 0,
                };
                self.emitAluRegImm32(subop, dst_reg, imm);
            }
            if (rd_opt == null) self.storeRegToVreg(dst_reg, inst.dest);
            return;
        }

        const r2_opt = self.vregPhys(s2);
        if (rd_opt != null and r1_opt != null and r2_opt != null) {
            const rd = rd_opt.?;
            const r1 = r1_opt.?;
            const r2 = r2_opt.?;
            if (op == .add and rd != r1 and rd != r2 and r2 != 4) {
                self.emitLeaRegIdxScale(rd, r1, r2, 0);
                return;
            }
            if (rd != r2) {
                self.movRegReg(rd, r1);
                self.emitBinRegReg(op, rd, r2);
                return;
            } else if (isCommutative(op)) {
                // rd == r2 and commutative: op rd, r1
                self.emitBinRegReg(op, rd, r1);
                return;
            }
        }

        self.loadVregToReg(s1, 0);
        self.loadVregToReg(s2, 1);
        self.emitBinRegReg(op, 0, 1);
        self.storeRegToVreg(0, inst.dest);
    }

    fn emitBinRegReg(self: *IRCodegen, op: IROp, dst: u8, src: u8) void {
        if (op == .mul) {
            self.emitRex(dst, src);
            self.emit8(0x0F);
            self.emit8(0xAF);
            self.emitModRM(3, dst, src);
            return;
        }
        const opcode: u8 = switch (op) {
            .add => 0x01,
            .sub => 0x29,
            .bit_and => 0x21,
            .bit_or => 0x09,
            .bit_xor => 0x31,
            else => return,
        };
        self.emitRex(src, dst);
        self.emit8(opcode);
        self.emitModRM(3, src, dst);
    }

    fn emitMemLoadDisp(self: *IRCodegen, dst: u8, base: u8, disp: i32) void {
        self.emitRex(dst, base);
        self.emit8(0x8B);
        if (disp == 0 and (base & 7) != 5 and (base & 7) != 4) {
            self.emitModRM(0, dst, base);
        } else if (disp >= -128 and disp <= 127) {
            self.emitModRM(1, dst, base);
            if ((base & 7) == 4) self.emit8(0x24);
            self.emit8(@intCast(disp & 0xFF));
        } else {
            self.emitModRM(2, dst, base);
            if ((base & 7) == 4) self.emit8(0x24);
            self.emit32(@bitCast(disp));
        }
    }

    fn emitMemStoreDisp(self: *IRCodegen, base: u8, src: u8, disp: i32) void {
        self.emitRex(src, base);
        self.emit8(0x89);
        if (disp == 0 and (base & 7) != 5 and (base & 7) != 4) {
            self.emitModRM(0, src, base);
        } else if (disp >= -128 and disp <= 127) {
            self.emitModRM(1, src, base);
            if ((base & 7) == 4) self.emit8(0x24);
            self.emit8(@intCast(disp & 0xFF));
        } else {
            self.emitModRM(2, src, base);
            if ((base & 7) == 4) self.emit8(0x24);
            self.emit32(@bitCast(disp));
        }
    }

    fn emitTestRegZeroTrap(self: *IRCodegen, reg: u8) void {
        self.emitRex(reg, reg);
        self.emit8(0x85);
        self.emitModRM(3, reg, reg); // test reg, reg
        self.emit8(0x75);
        self.emit8(0x02); // jnz +2
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
    }

    fn emitBasicPtrTrap(self: *IRCodegen, reg: u8) void {
        self.emitCmpRegImm32(reg, 4096);
        self.emit8(0x73);
        self.emit8(0x02); // jae +2 (unsigned >= 4096: reject NULL and 1..4095)
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
        self.emitRex(reg, reg);
        self.emit8(0x85);
        self.emitModRM(3, reg, reg); // test reg, reg
        self.emit8(0x79);
        self.emit8(0x02); // jns +2 (bit 63 == 0: reject negative error ints & kernel addresses)
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
    }

    fn emitPtrTrap(self: *IRCodegen, reg: u8) void {
        self.emitPtrTrapN(reg, 1);
    }

    fn emitPtrTrapN(self: *IRCodegen, reg: u8, access_bytes: u8) void {
        std.debug.assert(reg != 4);
        const trap_kind: TargetKind = switch (access_bytes) {
            4 => .chk_heap4_fn,
            8 => .chk_heap8_fn,
            else => .chk_heap1_fn,
        };

        // Fast path: single-thread last-checked chunk inline cache [DATA_VADDR+0xC0..+0xC8]
        self.emitCmpRegAbs(reg, @intCast(DATA_VADDR + 0xC8));
        const jae_slow1 = self.code_len + 1;
        self.emit8(0x73);
        self.emit8(0); // jae .slow

        var fast_ok_patch: usize = 0;
        var jb_slow2: usize = 0;
        if (access_bytes <= 1) {
            self.emitCmpRegAbs(reg, @intCast(DATA_VADDR + 0xC0));
            fast_ok_patch = self.code_len + 1;
            self.emit8(0x73);
            self.emit8(0); // jae .ok
        } else {
            self.emitCmpRegAbs(reg, @intCast(DATA_VADDR + 0xC0));
            jb_slow2 = self.code_len + 1;
            self.emit8(0x72);
            self.emit8(0); // jb .slow
            if (reg != 11) {
                self.emitLeaRegDisp(11, reg, @intCast(access_bytes));
                self.emitCmpRegAbs(11, @intCast(DATA_VADDR + 0xC8));
            } else {
                self.pushReg(0);
                self.emitLeaRegDisp(0, 11, @intCast(access_bytes));
                self.emitCmpRegAbs(0, @intCast(DATA_VADDR + 0xC8));
                self.popReg(0); // pop preserves flags
            }
            fast_ok_patch = self.code_len + 1;
            self.emit8(0x76);
            self.emit8(0); // jbe .ok
        }

        const slow_pos = self.code_len;
        self.code[jae_slow1] = @intCast(slow_pos - (jae_slow1 + 1));
        if (jb_slow2 != 0) self.code[jb_slow2] = @intCast(slow_pos - (jb_slow2 + 1));

        self.emitCmpRegImm32(reg, 4096);
        const jb_trap = self.code_len + 1;
        self.emit8(0x72);
        self.emit8(0); // jb .trap
        self.emitRex(reg, reg);
        self.emit8(0x85);
        self.emitModRM(3, reg, reg); // test reg, reg
        const js_trap = self.code_len + 1;
        self.emit8(0x78);
        self.emit8(0); // js .trap
        self.emitCmpRegAbs(reg, @intCast(DATA_VADDR + 0x88)); // heap_min
        const jb_ok1 = self.code_len + 1;
        self.emit8(0x72);
        self.emit8(0); // jb .ok
        self.emitCmpRegAbs(reg, @intCast(DATA_VADDR + 0x90)); // heap_max
        const jae_ok2 = self.code_len + 1;
        self.emit8(0x73);
        self.emit8(0); // jae .ok
        self.pushReg(reg);
        self.emitCallReloc(trap_kind, 0);
        self.popReg(reg);
        const jmp_ok = self.code_len + 1;
        self.emit8(0xEB);
        self.emit8(0); // jmp .ok

        const trap_pos = self.code_len;
        self.code[jb_trap] = @intCast(trap_pos - (jb_trap + 1));
        self.code[js_trap] = @intCast(trap_pos - (js_trap + 1));
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2

        const ok_pos = self.code_len;
        self.code[fast_ok_patch] = @intCast(ok_pos - (fast_ok_patch + 1));
        self.code[jb_ok1] = @intCast(ok_pos - (jb_ok1 + 1));
        self.code[jae_ok2] = @intCast(ok_pos - (jae_ok2 + 1));
        self.code[jmp_ok] = @intCast(ok_pos - (jmp_ok + 1));
    }

    fn emitCheckPtrLenRegs(self: *IRCodegen, ptr_reg: u8, len_reg: u8) void {
        self.pushReg(len_reg);
        self.pushReg(ptr_reg);
        self.emitCallReloc(.chk_ptr_n_fn, 0);
        self.addRspImm(16);
    }

    fn emitByteZeroQwords(self: *IRCodegen) void {
        self.xorReg(0, 0);
        self.emit8(0xFC); // cld
        self.emit8(0xF3);
        self.emit8(0x48);
        self.emit8(0xAB); // rep stosq
    }

    fn emitByteCopy(self: *IRCodegen) void {
        self.emit8(0xFC);
        self.emit8(0xF3);
        self.emit8(0xA4);
    }

    // ═══════════════════════════════════════════════════════════
    // Runtime Helper Routines (printInt, slab malloc/free, split)
    // ═══════════════════════════════════════════════════════════

    fn emitPrintIntRoutine(self: *IRCodegen) void {
        self.printint_offset = self.code_len;
        self.subRspImm(40);
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x74);
        self.emit8(0x24);
        self.emit8(39);
        self.emit8(0xC6);
        self.emit8(0x06);
        self.emit8('\n');
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xF8);
        self.emit8(0x45);
        self.emit8(0x31);
        self.emit8(0xC0);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        self.emit8(0x79);
        self.emit8(9);
        self.emit8(0x48);
        self.emit8(0xF7);
        self.emit8(0xD8);
        self.emit8(0x41);
        self.emit8(0xB8);
        self.emit32(1);

        // Unsigned divide by 10 via multiply-high: floor(x / 10) is
        // (x * 0xCCCCCCCCCCCCCCCD) >> 67 for every u64 value.
        self.mov64imm(9, 0xCCCCCCCCCCCCCCCD);
        const div_loop = self.code_len;
        self.movRegReg(10, 0); // preserve the current magnitude for remainder
        self.emit8(0x49);
        self.emit8(0xF7);
        self.emit8(0xE1); // mul r9 -> rdx:rax
        self.movRegReg(0, 2);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE8);
        self.emit8(3); // quotient in rax
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x14);
        self.emit8(0x80); // lea rdx, [rax + rax*4]
        self.emit8(0x48);
        self.emit8(0xD1);
        self.emit8(0xE2); // shl rdx, 1 => quotient * 10
        self.emit8(0x49);
        self.emit8(0x29);
        self.emit8(0xD2); // sub r10, rdx => remainder
        self.movRegReg(2, 10);
        self.emit8(0x80);
        self.emit8(0xC2);
        self.emit8('0');
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xCE);
        self.emit8(0x88);
        self.emit8(0x16);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        const after_jnz = self.code_len + 2;
        const back_disp: i8 = @intCast(@as(i64, @intCast(div_loop)) - @as(i64, @intCast(after_jnz)));
        self.emit8(0x75);
        self.emit8(@bitCast(back_disp));

        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xC0);
        self.emit8(0x74);
        self.emit8(6);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xCE);
        self.emit8(0xC6);
        self.emit8(0x06);
        self.emit8('-');

        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xE2);
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xC2);
        self.emit8(40);
        self.emit8(0x48);
        self.emit8(0x29);
        self.emit8(0xF2);
        self.emit8(0xB8);
        self.emit32(1);
        self.emit8(0xBF);
        self.emit32(1);
        self.syscallInst();
        self.addRspImm(40);
        self.emit8(0xC3);
    }

    fn emitAllocRoutines(self: *IRCodegen) void {
        const FREE_COOKIE: u64 = 0x4C49_5246_5245_4500; // "LIRFREE\0"
        const LIVE_SLAB_BASE: u64 = 0x4C49_524C_0000_0000; // "LIRL..." | class
        const LIVE_MMAP_COOKIE: u64 = 0x4C49_524D_0000_0000; // "LIRM\0\0\0\0"
        const CANARY_SALT: u64 = 0xA5A5_5A5A_1234_5678;
        const SLAB_PAYLOAD_END: u32 = 0xFF000; // 1 MiB slab minus 4 KiB chunk-start bitmap page

        // ── __lir_add_region(rdi=base, rsi=region_size, rdx=word1) ──
        // Clobbers: rax, rcx, rsi, rdx, r8, r10, r11 (preserves r9 & rbx & r12..r15)
        self.add_region_offset = self.code_len;
        self.mov64imm(10, DATA_VADDR);
        // Acquire region_lock [r10 + 0xA8] only when multithreaded ([r10 + 0xA0] != 0)
        self.emit8(0x49);
        self.emit8(0x83);
        self.emit8(0xBA);
        self.emit32(0xA0);
        self.emit8(0); // cmp qword [r10 + 0xA0], 0
        const ar_skip_lock = self.emitJccReloc(0x4, .code_offset, 0, 0);
        const ar_spin = self.code_len;
        self.emit8(0xB8);
        self.emit32(1);
        self.emit8(0x41);
        self.emit8(0x87);
        self.emit8(0x82);
        self.emit32(0xA8); // xchg eax, [r10 + 0xA8]
        self.emit8(0x85);
        self.emit8(0xC0);
        const ar_got_lock = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0xF3);
        self.emit8(0x90);
        _ = self.emitJmpReloc(.code_offset, ar_spin, 0);
        self.relocs[ar_got_lock].target_id = self.code_len;
        self.relocs[ar_skip_lock].target_id = self.code_len;

        // Update heap_min = min(heap_min, rdi) and heap_max = max(heap_max, rdi + rsi)
        self.emit8(0x49);
        self.emit8(0x3B);
        self.emit8(0xBA);
        self.emit32(0x88); // cmp rdi, [r10 + 0x88]
        const ar_min_ok = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0xBA);
        self.emit32(0x88); // mov [r10 + 0x88], rdi
        self.relocs[ar_min_ok].target_id = self.code_len;

        self.emit8(0x48);
        self.emit8(0x01);
        self.emit8(0xFE); // add rsi, rdi (rsi = new_end)
        self.emit8(0x49);
        self.emit8(0x3B);
        self.emit8(0xB2);
        self.emit32(0x90); // cmp rsi, [r10 + 0x90]
        const ar_max_ok = self.emitJccReloc(0x6, .code_offset, 0, 0); // jbe
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0xB2);
        self.emit32(0x90); // mov [r10 + 0x90], rsi
        self.relocs[ar_max_ok].target_id = self.code_len;

        // Scan region_dir to clear overlapping FREED_MMAP entries and capture first free slot in r11
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x8A);
        self.emit32(0x98); // mov rcx, [r10 + 0x98] (region_count)
        self.mov64imm(8, DATA_VADDR + 0x100);
        self.xorReg(11, 11);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC9); // test rcx, rcx
        const ar_scan_done = self.emitJccReloc(0x4, .code_offset, 0, 0);
        const ar_scan_loop = self.code_len;
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x00); // mov rax, [r8]
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0); // test rax, rax
        const ar_nonempty = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xDB); // test r11, r11
        const ar_next_from_empty = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.movRegReg(11, 8);
        const ar_jmp_next = self.emitJmpReloc(.code_offset, 0, 0);

        self.relocs[ar_nonempty].target_id = self.code_len;
        self.emit8(0x4D);
        self.emit8(0x8B);
        self.emit8(0x50);
        self.emit8(0x08); // mov r10, [r8 + 8]
        self.movRegReg(0, 10);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE8);
        self.emit8(62); // shr rax, 62
        self.emitCmpRegImm32(0, 2);
        const ar_not_freed = self.emitJccReloc(0x5, .code_offset, 0, 0); // jne
        self.mov64imm(0, 0x0000_FFFF_FFFF_FFFF);
        self.emit8(0x49);
        self.emit8(0x21);
        self.emit8(0xC2); // and r10, rax (old_end)
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x00); // mov rax, [r8] (old_base)
        self.emit8(0x48);
        self.emit8(0x39);
        self.emit8(0xF0); // cmp rax, rsi (old_base >= new_end?)
        const ar_no_ovr1 = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae
        self.emit8(0x49);
        self.emit8(0x39);
        self.emit8(0xFA); // cmp r10, rdi (old_end <= new_base?)
        const ar_no_ovr2 = self.emitJccReloc(0x6, .code_offset, 0, 0); // jbe
        // Overlapping stale FREED_MMAP entry: clear it
        self.emit8(0x49);
        self.emit8(0xC7);
        self.emit8(0x00);
        self.emit32(0); // mov qword [r8], 0
        self.emit8(0x49);
        self.emit8(0xC7);
        self.emit8(0x40);
        self.emit8(0x08);
        self.emit32(0); // mov qword [r8 + 8], 0
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xDB);
        const ar_no_ovr3 = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.movRegReg(11, 8);

        const ar_next_pos = self.code_len;
        self.relocs[ar_next_from_empty].target_id = ar_next_pos;
        self.relocs[ar_jmp_next].target_id = ar_next_pos;
        self.relocs[ar_not_freed].target_id = ar_next_pos;
        self.relocs[ar_no_ovr1].target_id = ar_next_pos;
        self.relocs[ar_no_ovr2].target_id = ar_next_pos;
        self.relocs[ar_no_ovr3].target_id = ar_next_pos;
        self.emitAluRegImm32(0, 8, 16); // add r8, 16
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC9); // dec rcx
        _ = self.emitJccReloc(0x5, .code_offset, ar_scan_loop, 0); // jnz

        self.relocs[ar_scan_done].target_id = self.code_len;
        self.mov64imm(10, DATA_VADDR);
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xDB); // test r11, r11
        const ar_append = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x3B); // mov [r11], rdi
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x53);
        self.emit8(0x08); // mov [r11 + 8], rdx
        const ar_unlock = self.emitJmpReloc(.code_offset, 0, 0);

        self.relocs[ar_append].target_id = self.code_len;
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x8A);
        self.emit32(0x98); // mov rcx, [r10 + 0x98]
        self.emitCmpRegImm32(1, @intCast(REGION_DIR_CAP));
        const ar_full = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae
        self.movRegReg(8, 1);
        self.emit8(0x49);
        self.emit8(0xC1);
        self.emit8(0xE0);
        self.emit8(4); // shl r8, 4
        self.mov64imm(11, DATA_VADDR + 0x100);
        self.emit8(0x4D);
        self.emit8(0x01);
        self.emit8(0xD8); // add r8, r11
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x38); // mov [r8], rdi
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x50);
        self.emit8(0x08); // mov [r8 + 8], rdx
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1); // inc rcx
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x8A);
        self.emit32(0x98); // mov [r10 + 0x98], rcx
        const ar_unlock2 = self.emitJmpReloc(.code_offset, 0, 0);

        // Full fallback: reuse a FREED_MMAP slot via free_ring_cursor [r10 + 0xB0]
        self.relocs[ar_full].target_id = self.code_len;
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x8A);
        self.emit32(0xB0); // rcx = cursor
        self.mov64imm(11, REGION_DIR_CAP);
        const ar_full_loop = self.code_len;
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xD9); // cmp rcx, r11
        const ar_wrap = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb
        self.xorReg(1, 1);
        self.relocs[ar_wrap].target_id = self.code_len;
        self.movRegReg(8, 1);
        self.emit8(0x49);
        self.emit8(0xC1);
        self.emit8(0xE0);
        self.emit8(4); // shl r8, 4
        self.mov64imm(0, DATA_VADDR + 0x100);
        self.emit8(0x49);
        self.emit8(0x01);
        self.emit8(0xC0); // add r8, rax
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x40);
        self.emit8(0x08); // rax = [r8 + 8]
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE8);
        self.emit8(62);
        self.emitCmpRegImm32(0, 2);
        const ar_found_reclaim = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xCB); // dec r11
        _ = self.emitJccReloc(0x5, .code_offset, ar_full_loop, 0);
        const ar_unlock3 = self.emitJmpReloc(.code_offset, 0, 0);
        self.relocs[ar_found_reclaim].target_id = self.code_len;
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x38); // [r8] = rdi
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x50);
        self.emit8(0x08); // [r8 + 8] = rdx
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x8A);
        self.emit32(0xB0);

        const ar_unlock_pos = self.code_len;
        self.relocs[ar_unlock].target_id = ar_unlock_pos;
        self.relocs[ar_unlock2].target_id = ar_unlock_pos;
        self.relocs[ar_unlock3].target_id = ar_unlock_pos;
        self.emit8(0x49);
        self.emit8(0xC7);
        self.emit8(0x82);
        self.emit32(0xA8);
        self.emit32(0); // mov qword [r10 + 0xA8], 0
        self.emit8(0xC3);

        // ── __lir_chk_heap{1,4,8}: stack arg [rsp+8]=ptr, preserves ALL GPRs ──
        self.chk_heap1_offset = self.code_len;
        self.pushReg(0);
        self.emit8(0xB8);
        self.emit32(1);
        const chk_j1 = self.emitJmpReloc(.code_offset, 0, 0);

        self.chk_heap4_offset = self.code_len;
        self.pushReg(0);
        self.emit8(0xB8);
        self.emit32(4);
        const chk_j4 = self.emitJmpReloc(.code_offset, 0, 0);

        self.chk_heap8_offset = self.code_len;
        self.pushReg(0);
        self.emit8(0xB8);
        self.emit32(8);
        const chk_j8 = self.emitJmpReloc(.code_offset, 0, 0);

        // __lir_chk_ptr_n: stack [rsp+8]=ptr, [rsp+16]=len; preserves ALL GPRs
        self.chk_ptr_n_offset = self.code_len;
        self.pushReg(0); // [rsp+0]=saved_rax, [rsp+8]=ret, [rsp+16]=ptr, [rsp+24]=len
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(24); // mov rax, [rsp + 24] (len)
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0); // test rax, rax
        const cpn_zero = self.emitJccReloc(0x4, .code_offset, 0, 0); // jz .ok_rax
        const cpn_neg = self.emitJccReloc(0x8, .code_offset, 0, 0); // js .trap
        self.pushReg(11); // [rsp+0]=saved_r11, [rsp+8]=saved_rax, [rsp+16]=ret, [rsp+24]=ptr, [rsp+32]=len
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x5C);
        self.emit8(0x24);
        self.emit8(24); // mov r11, [rsp + 24] (ptr)
        self.emitCmpRegImm32(11, 4096);
        const cpn_lo = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb .trap
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xDB); // test r11, r11
        const cpn_hi = self.emitJccReloc(0x8, .code_offset, 0, 0); // js .trap
        self.pushReg(1); // save rcx
        self.mov64imm(1, 0x0000_7FFF_FFFF_FFFF);
        self.emit8(0x4C);
        self.emit8(0x29);
        self.emit8(0xD9); // sub rcx, r11 (avail = 0x7FFFFFFFFFFF - ptr)
        const cpn_ovf1 = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb .trap
        self.emit8(0x48);
        self.emit8(0x39);
        self.emit8(0xC1); // cmp rcx, rax (avail >= len)
        const cpn_ovf2 = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb .trap
        self.popReg(1);
        self.emitCmpRegAbs(11, @intCast(DATA_VADDR + 0x88)); // heap_min
        const cpn_nonheap1 = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb .ok_r11
        self.emitCmpRegAbs(11, @intCast(DATA_VADDR + 0x90)); // heap_max
        const cpn_nonheap2 = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae .ok_r11
        self.popReg(11);
        const cpn_go_common = self.emitJmpReloc(.code_offset, 0, 0);
        const cpn_ok_r11_pos = self.code_len;
        self.relocs[cpn_nonheap1].target_id = cpn_ok_r11_pos;
        self.relocs[cpn_nonheap2].target_id = cpn_ok_r11_pos;
        self.popReg(11);
        const cpn_ok_rax_pos = self.code_len;
        self.relocs[cpn_zero].target_id = cpn_ok_rax_pos;
        self.popReg(0);
        self.emit8(0xC3);
        const cpn_trap_pos = self.code_len;
        self.relocs[cpn_neg].target_id = cpn_trap_pos;
        self.relocs[cpn_lo].target_id = cpn_trap_pos;
        self.relocs[cpn_hi].target_id = cpn_trap_pos;
        self.relocs[cpn_ovf1].target_id = cpn_trap_pos;
        self.relocs[cpn_ovf2].target_id = cpn_trap_pos;
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2

        const chk_common = self.code_len;
        self.relocs[chk_j1].target_id = chk_common;
        self.relocs[chk_j4].target_id = chk_common;
        self.relocs[chk_j8].target_id = chk_common;
        self.relocs[cpn_go_common].target_id = chk_common;
        self.pushReg(0); // [rsp+0]=access_sz, [rsp+8]=saved_rax, [rsp+16]=ret, [rsp+24]=ptr
        self.pushReg(1);
        self.pushReg(2);
        self.pushReg(6);
        self.pushReg(7);
        self.pushReg(8);
        self.pushReg(9);
        self.pushReg(10);
        self.pushReg(11);
        // 8 more pushes = 64B -> [rsp+64]=access_sz, [rsp+72]=saved_rax, [rsp+80]=ret, [rsp+88]=ptr
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x7C);
        self.emit8(0x24);
        self.emit8(88); // mov rdi, [rsp + 88]
        self.mov64imm(1, DATA_VADDR);
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x81);
        self.emit32(0x98); // mov r8, [rcx + 0x98] (region_count)
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xC0); // test r8, r8
        const chk_done_empty = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.mov64imm(6, DATA_VADDR + 0x100);

        const chk_loop = self.code_len;
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x0E); // mov r9, [rsi] (base)
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xC9); // test r9, r9
        const chk_skip0 = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x56);
        self.emit8(0x08); // mov r10, [rsi + 8] (word1)
        self.movRegReg(2, 10);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xEA);
        self.emit8(62); // shr rdx, 62 (kind)
        self.mov64imm(0, 0x0000_FFFF_FFFF_FFFF);
        self.emit8(0x49);
        self.emit8(0x21);
        self.emit8(0xC2); // and r10, rax (end)
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xCF); // cmp rdi, r9
        const chk_skip1 = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xD7); // cmp rdi, r10
        const chk_skip2 = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae

        // Region matched! kind: 0=SLAB, 1=LIVE_MMAP, 2=FREED_MMAP
        self.emitCmpRegImm32(2, 2);
        const chk_trap_freed = self.emitJccReloc(0x4, .code_offset, 0, 0); // je trap (UAF!)
        self.emitCmpRegImm32(2, 1);
        const chk_is_slab = self.emitJccReloc(0x5, .code_offset, 0, 0); // jne is_slab

        // Live large mmap: [r9+8]=req_size, user range [r9+16 .. r9+16+req_size)
        self.emit8(0x49);
        self.emit8(0x8D);
        self.emit8(0x41);
        self.emit8(16); // lea rax, [r9 + 16]
        self.emit8(0x48);
        self.emit8(0x39);
        self.emit8(0xC7); // cmp rdi, rax
        const chk_trap_mmap_hdr = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb trap
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x41);
        self.emit8(0x08); // mov rax, [r9 + 8] (req_size)
        self.emit8(0x49);
        self.emit8(0x8D);
        self.emit8(0x4C);
        self.emit8(0x01);
        self.emit8(16); // lea rcx, [r9 + rax + 16] (user_end)
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(64); // mov rax, [rsp + 64] (access_sz)
        self.movRegReg(2, 1); // rdx = user_end
        self.emit8(0x48);
        self.emit8(0x29);
        self.emit8(0xFA); // sub rdx, rdi (avail = user_end - ptr)
        const chk_trap_mmap_oob1 = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb trap
        self.emit8(0x48);
        self.emit8(0x39);
        self.emit8(0xC2); // cmp rdx, rax (avail >= access_sz)
        const chk_trap_mmap_oob = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb trap (OOB!)
        const chk_done_mmap = self.emitJmpReloc(.code_offset, 0, 0);

        // Live slab: find chunk_start in bitmap [r9 + 0xFF000]
        self.relocs[chk_is_slab].target_id = self.code_len;
        self.movRegReg(0, 7);
        self.emit8(0x4C);
        self.emit8(0x29);
        self.emit8(0xC8); // sub rax, r9 (off)
        self.emitCmpRegImm32(0, @intCast(SLAB_PAYLOAD_END));
        const chk_trap_bmap = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae trap
        self.movRegReg(2, 0);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xEA);
        self.emit8(5); // shr rdx, 5 (slot)
        self.movRegReg(10, 9);
        self.emitAluRegImm32(0, 10, @intCast(SLAB_PAYLOAD_END)); // r10 = bitmap_ptr
        self.movRegReg(0, 2);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE8);
        self.emit8(6); // shr rax, 6 (word_idx)
        self.movRegReg(1, 2);
        self.emitAluRegImm32(4, 1, 63); // and rcx, 63 (bit_idx)
        self.emit8(0x48);
        self.emit8(0xF7);
        self.emit8(0xD9); // neg rcx
        self.emitAluRegImm32(0, 1, 63); // add rcx, 63 (cl = 63 - bit_idx)
        self.mov64imm(11, 0xFFFFFFFFFFFFFFFF);
        self.emit8(0x49);
        self.emit8(0xD3);
        self.emit8(0xEB); // shr r11, cl
        self.emit8(0x4D);
        self.emit8(0x23);
        self.emit8(0x1C);
        self.emit8(0xC2); // and r11, [r10 + rax*8]
        const chk_found_word = self.emitJccReloc(0x5, .code_offset, 0, 0); // jnz

        const chk_bscan = self.code_len;
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0); // test rax, rax
        const chk_trap_uninit = self.emitJccReloc(0x4, .code_offset, 0, 0); // jz trap
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC8); // dec rax
        self.emit8(0x4D);
        self.emit8(0x8B);
        self.emit8(0x1C);
        self.emit8(0xC2); // mov r11, [r10 + rax*8]
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xDB); // test r11, r11
        _ = self.emitJccReloc(0x4, .code_offset, chk_bscan, 0); // jz

        self.relocs[chk_found_word].target_id = self.code_len;
        self.emit8(0x49);
        self.emit8(0x0F);
        self.emit8(0xBD);
        self.emit8(0xD3); // bsr rdx, r11
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE0);
        self.emit8(6); // shl rax, 6
        self.emit8(0x48);
        self.emit8(0x01);
        self.emit8(0xD0); // add rax, rdx (found_slot)
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE0);
        self.emit8(5); // shl rax, 5 (chunk offset)
        self.emit8(0x49);
        self.emit8(0x8D);
        self.emit8(0x14);
        self.emit8(0x01); // lea rdx, [r9 + rax] (chunk_base)

        // Verify live slab cookie ^ heap_secret and exact [chunk+16 .. chunk+16+req_size)
        self.mov64imm(9, DATA_VADDR);
        self.emit8(0x4D);
        self.emit8(0x8B);
        self.emit8(0x49);
        self.emit8(0x70); // mov r9, [r9 + 0x70] (heap_secret)
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x02); // mov rax, [rdx]
        self.emit8(0x4C);
        self.emit8(0x31);
        self.emit8(0xC8); // xor rax, r9
        self.emitAluRegImm32(4, 0, -8); // and rax, -8
        self.mov64imm(11, LIVE_SLAB_BASE);
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xD8); // cmp rax, r11
        const chk_trap_uaf = self.emitJccReloc(0x5, .code_offset, 0, 0); // jne trap (UAF!)

        self.emit8(0x4C);
        self.emit8(0x8D);
        self.emit8(0x4A);
        self.emit8(16); // lea r9, [rdx + 16] (payload_start)
        self.movRegReg(10, 9); // r10 = payload_start (for cache update)
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xCF); // cmp rdi, r9
        const chk_trap_hdr = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb trap
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x42);
        self.emit8(0x08); // mov rax, [rdx + 8] (req_size)
        self.emit8(0x49);
        self.emit8(0x01);
        self.emit8(0xC1); // add r9, rax (payload_end)
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(64); // mov rax, [rsp + 64] (access_sz)
        self.movRegReg(2, 9); // rdx = payload_end
        self.emit8(0x48);
        self.emit8(0x29);
        self.emit8(0xFA); // sub rdx, rdi (avail = payload_end - ptr)
        const chk_trap_oob1 = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb trap
        self.emit8(0x48);
        self.emit8(0x39);
        self.emit8(0xC2); // cmp rdx, rax (avail >= access_sz)
        const chk_trap_oob = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb trap (OOB!)
        const chk_cache_slab = self.emitJmpReloc(.code_offset, 0, 0);

        const chk_next_pos = self.code_len;
        self.relocs[chk_skip0].target_id = chk_next_pos;
        self.relocs[chk_skip1].target_id = chk_next_pos;
        self.relocs[chk_skip2].target_id = chk_next_pos;
        self.emitAluRegImm32(0, 6, 16); // add rsi, 16
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xC8); // dec r8
        _ = self.emitJccReloc(0x5, .code_offset, chk_loop, 0); // jnz

        const chk_done_empty_pos = self.code_len;
        self.relocs[chk_done_empty].target_id = chk_done_empty_pos;
        const chk_done_skip = self.emitJmpReloc(.code_offset, 0, 0);

        // Cache update on live heap check hit (r10=payload_start, r9=payload_end for slab; mmap sets r10,r9 here)
        self.relocs[chk_done_mmap].target_id = self.code_len;
        self.emit8(0x4D);
        self.emit8(0x8D);
        self.emit8(0x51);
        self.emit8(16); // lea r10, [r9 + 16] (payload_start)
        self.movRegReg(9, 1); // r9 = rcx (payload_end)
        self.relocs[chk_cache_slab].target_id = self.code_len;
        self.mov64imm(0, DATA_VADDR);
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xB8);
        self.emit32(0xA0);
        self.emit8(0); // cmp qword [rax + 0xA0], 0 (is_multithreaded)
        const chk_skip_cache = self.emitJccReloc(0x5, .code_offset, 0, 0); // jne
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x90);
        self.emit32(0xC0); // mov [rax + 0xC0], r10
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x88);
        self.emit32(0xC8); // mov [rax + 0xC8], r9

        const chk_done_pos = self.code_len;
        self.relocs[chk_done_skip].target_id = chk_done_pos;
        self.relocs[chk_skip_cache].target_id = chk_done_pos;
        self.popReg(11);
        self.popReg(10);
        self.popReg(9);
        self.popReg(8);
        self.popReg(7);
        self.popReg(6);
        self.popReg(2);
        self.popReg(1);
        self.addRspImm(8); // discard access_sz
        self.popReg(0);
        self.emit8(0xC3);

        const chk_trap_pos = self.code_len;
        self.relocs[chk_trap_freed].target_id = chk_trap_pos;
        self.relocs[chk_trap_mmap_hdr].target_id = chk_trap_pos;
        self.relocs[chk_trap_mmap_oob1].target_id = chk_trap_pos;
        self.relocs[chk_trap_mmap_oob].target_id = chk_trap_pos;
        self.relocs[chk_trap_bmap].target_id = chk_trap_pos;
        self.relocs[chk_trap_uninit].target_id = chk_trap_pos;
        self.relocs[chk_trap_uaf].target_id = chk_trap_pos;
        self.relocs[chk_trap_hdr].target_id = chk_trap_pos;
        self.relocs[chk_trap_oob1].target_id = chk_trap_pos;
        self.relocs[chk_trap_oob].target_id = chk_trap_pos;
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2

        // ── __lir_malloc(rdi = req_size) -> rax = ptr (or 0 on invalid/OOM) ──
        self.malloc_offset = self.code_len;
        // Reject negative or overflow-inducing sizes (> 0x7FFF_FFFF_0000 unsigned)
        self.mov64imm(11, 0x7FFF_FFFF_0000);
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xDF); // cmp rdi, r11
        const m_too_big = self.emitJccReloc(0x7, .code_offset, 0, 0); // ja

        // r9 = exact user req_size (saved for trailing overflow canary placement)
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0xF9); // mov r9, rdi
        // rsi = max(req_size, 1) + 24 (16B header + payload + 8B trailing overflow canary)
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xFE); // mov rsi, rdi
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xF6); // test rsi, rsi
        self.emit8(0x75);
        self.emit8(0x05); // jnz +5
        self.emit8(0xBE);
        self.emit32(1); // mov esi, 1
        self.emitLeaRegDisp(6, 6, 24);
        // cmp rsi, 4096; ja large_mmap
        self.emitCmpRegImm32(6, 4096);
        const large_jcc = self.emitJccReloc(0x7, .code_offset, 0, 0);

        // O(1) size class via bsr: rsi in 25..4096 -> rcx in 0..7, rdx = 32 << rcx
        self.xorReg(1, 1);
        self.mov64imm(2, 32);
        self.emitCmpRegImm32(6, 32);
        const cls_done = self.emitJccReloc(0x6, .code_offset, 0, 0); // jbe
        self.emitLeaRegDisp(0, 6, -1); // rax = rsi - 1
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0xBD);
        self.emit8(0xC8); // bsr rcx, rax
        self.emitAluRegImm32(5, 1, 4); // sub rcx, 4
        self.emit8(0x48);
        self.emit8(0xD3);
        self.emit8(0xE2); // shl rdx, cl
        self.relocs[cls_done].target_id = self.code_len;

        // Acquire spinlock on [DATA_VADDR + 0x10] only when multithreaded ([r10 + 0xA0] != 0)
        self.mov64imm(10, DATA_VADDR);
        self.emit8(0x49);
        self.emit8(0x83);
        self.emit8(0xBA);
        self.emit32(0xA0);
        self.emit8(0); // cmp qword [r10 + 0xA0], 0
        const m_skip_lock = self.emitJccReloc(0x4, .code_offset, 0, 0);
        const lock_spin = self.code_len;
        self.emit8(0xB8);
        self.emit32(1); // mov eax, 1
        self.emit8(0x41);
        self.emit8(0x87);
        self.emit8(0x42);
        self.emit8(0x10); // xchg eax, [r10 + 0x10]
        self.emit8(0x85);
        self.emit8(0xC0); // test eax, eax
        const got_lock = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0xF3);
        self.emit8(0x90); // pause
        _ = self.emitJmpReloc(.code_offset, lock_spin, 0);
        self.relocs[got_lock].target_id = self.code_len;
        self.relocs[m_skip_lock].target_id = self.code_len;

        // Pop free_heads[rcx] = [r10 + rcx*8 + 0x28]
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0xCA);
        self.emit8(0x28);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0); // test rax, rax
        const carve_slab = self.emitJccReloc(0x4, .code_offset, 0, 0);
        // Freelist next link is stored at [rax + 8] so [rax + 0] preserves FREE_COOKIE
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x40);
        self.emit8(0x08); // mov r8, [rax + 8]
        self.emit8(0x4D);
        self.emit8(0x89);
        self.emit8(0x44);
        self.emit8(0xCA);
        self.emit8(0x28);
        const to_unlock = self.emitJmpReloc(.code_offset, 0, 0);

        // Carve from active 1 MiB slab ([r10+0x20] = slab_base + SLAB_PAYLOAD_END)
        self.relocs[carve_slab].target_id = self.code_len;
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x42);
        self.emit8(0x18); // rax = slab_cur
        self.emit8(0x4C);
        self.emit8(0x8D);
        self.emit8(0x04);
        self.emit8(0x10); // r8 = rax + rdx
        self.emit8(0x4D);
        self.emit8(0x3B);
        self.emit8(0x42);
        self.emit8(0x20); // cmp r8, slab_end
        const slab_ok = self.emitJccReloc(0x6, .code_offset, 0, 0); // jbe

        // Refill 1 MiB slab via sys_mmap(0, 0x100000, 3, 0x22, -1, 0)
        self.pushReg(1);
        self.pushReg(2);
        self.pushReg(9);
        self.pushReg(10);
        self.xorReg(7, 7);
        self.mov64imm(6, 0x100000);
        self.mov64imm(2, 3);
        self.mov64imm(10, 0x22);
        self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
        self.xorReg(9, 9);
        self.mov64imm(0, 9);
        self.syscallInst();
        self.popReg(10);
        self.popReg(9);
        self.popReg(2);
        self.popReg(1);
        // Check sys_mmap -errno (> -4096 unsigned): unlock and return 0
        self.mov64imm(11, @bitCast(@as(i64, -4096)));
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xD8); // cmp rax, r11
        const slab_mmap_oom = self.emitJccReloc(0x7, .code_offset, 0, 0); // ja
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x82);
        self.emit32(0x80); // mov [r10 + 0x80], rax (slab_cur_base)
        self.emit8(0x4C);
        self.emit8(0x8D);
        self.emit8(0x98);
        self.emit32(SLAB_PAYLOAD_END); // r11 = rax + SLAB_PAYLOAD_END
        self.emit8(0x4D);
        self.emit8(0x89);
        self.emit8(0x5A);
        self.emit8(0x20); // slab_end = r11
        // Register new slab region in region_dir (preserves rax, rcx, rdx, r9)
        self.pushReg(0);
        self.pushReg(1);
        self.pushReg(2);
        self.movRegReg(7, 0); // rdi = base
        self.mov64imm(6, 0x100000); // rsi = 1 MiB
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x14);
        self.emit8(0x37); // lea rdx, [rdi + rsi] (word1 = end, kind=0)
        self.emitCallReloc(.add_region_fn, 0);
        self.popReg(2);
        self.popReg(1);
        self.popReg(0);
        self.mov64imm(10, DATA_VADDR);
        self.emit8(0x4C);
        self.emit8(0x8D);
        self.emit8(0x04);
        self.emit8(0x10); // r8 = rax + rdx

        self.relocs[slab_ok].target_id = self.code_len;
        self.emit8(0x4D);
        self.emit8(0x89);
        self.emit8(0x42);
        self.emit8(0x18); // slab_cur = r8
        // Mark chunk start in slab's 4 KiB bitmap ([slab_cur_base + SLAB_PAYLOAD_END])
        self.emit8(0x4D);
        self.emit8(0x8B);
        self.emit8(0x82);
        self.emit32(0x80); // mov r8, [r10 + 0x80] (slab_cur_base)
        self.movRegReg(11, 0); // r11 = chunk
        self.emit8(0x4D);
        self.emit8(0x29);
        self.emit8(0xC3); // sub r11, r8 (off)
        self.emit8(0x49);
        self.emit8(0xC1);
        self.emit8(0xEB);
        self.emit8(5); // shr r11, 5 (slot)
        self.emitAluRegImm32(0, 8, @intCast(SLAB_PAYLOAD_END)); // r8 = bitmap_ptr
        self.emit8(0x4D);
        self.emit8(0x0F);
        self.emit8(0xAB);
        self.emit8(0x18); // bts qword ptr [r8], r11

        // Unlock & write CSPRNG-keyed slab header + exact req_size + trailing canary
        self.relocs[to_unlock].target_id = self.code_len;
        self.emit8(0x4D);
        self.emit8(0x8B);
        self.emit8(0x42);
        self.emit8(0x70); // mov r8, [r10 + 0x70] (heap_secret)
        self.mov64imm(11, LIVE_SLAB_BASE);
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xC3); // xor r11, r8
        self.emit8(0x49);
        self.emit8(0x09);
        self.emit8(0xCB); // or r11, rcx
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x18); // mov [rax], r11
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x48);
        self.emit8(0x08); // mov [rax + 8], r9 (req_size)
        self.emit8(0x41);
        self.emit8(0xC7);
        self.emit8(0x42);
        self.emit8(0x10);
        self.emit32(0); // unlock spinlock
        self.mov64imm(11, CANARY_SALT);
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xC3); // xor r11, r8
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xCB); // xor r11, r9
        self.emit8(0x4E);
        self.emit8(0x89);
        self.emit8(0x5C);
        self.emit8(0x08);
        self.emit8(0x10); // mov [rax + r9 + 16], r11
        self.xorReg(8, 8);
        self.xorReg(11, 11);
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xC0);
        self.emit8(0x10); // add rax, 16
        const m_slab_cache = self.emitJmpReloc(.code_offset, 0, 0);

        // Slab OOM: release spinlock and return 0
        self.relocs[slab_mmap_oom].target_id = self.code_len;
        self.emit8(0x41);
        self.emit8(0xC7);
        self.emit8(0x42);
        self.emit8(0x10);
        self.emit32(0);
        self.relocs[m_too_big].target_id = self.code_len;
        const m_oom_ret = self.code_len;
        self.xorReg(0, 0);
        self.emit8(0xC3);

        // Large mmap fallback (>4096): round rsi up to 4 KiB page boundary
        self.relocs[large_jcc].target_id = self.code_len;
        self.emitAluRegImm32(0, 6, 4095);
        self.emitAluRegImm32(4, 6, -4096);
        self.pushReg(6); // save mapped_size
        self.pushReg(9); // save exact req_size across sys_mmap
        self.xorReg(7, 7);
        self.mov64imm(2, 3);
        self.mov64imm(10, 0x22);
        self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
        self.xorReg(9, 9);
        self.mov64imm(0, 9);
        self.syscallInst();
        self.popReg(9); // r9 = exact req_size
        self.popReg(6); // rsi = mapped_size
        self.mov64imm(11, @bitCast(@as(i64, -4096)));
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xD8); // cmp rax, r11
        _ = self.emitJccReloc(0x7, .code_offset, m_oom_ret, 0); // ja m_oom_ret
        // Register live mmap region in region_dir: word1 = (1 << 62) | (rax + mapped_size)
        self.pushReg(0);
        self.movRegReg(7, 0); // rdi = base
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x14);
        self.emit8(0x37); // lea rdx, [rdi + rsi]
        self.mov64imm(11, @as(u64, 1) << 62);
        self.emit8(0x4C);
        self.emit8(0x09);
        self.emit8(0xDA); // or rdx, r11
        self.emitCallReloc(.add_region_fn, 0);
        self.popReg(0);
        self.mov64imm(10, DATA_VADDR);
        self.emit8(0x4D);
        self.emit8(0x8B);
        self.emit8(0x42);
        self.emit8(0x70); // mov r8, [r10 + 0x70]
        self.mov64imm(11, LIVE_MMAP_COOKIE);
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xC3); // xor r11, r8
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x18); // [rax] = heap_secret ^ LIVE_MMAP_COOKIE
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x48);
        self.emit8(0x08); // [rax + 8] = req_size
        self.mov64imm(11, CANARY_SALT);
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xC3); // xor r11, r8
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xCB); // xor r11, r9
        self.emit8(0x4E);
        self.emit8(0x89);
        self.emit8(0x5C);
        self.emit8(0x08);
        self.emit8(0x10); // mov [rax + r9 + 16], r11
        self.xorReg(8, 8);
        self.xorReg(11, 11);
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xC0);
        self.emit8(0x10);
        self.mov64imm(10, DATA_VADDR);
        self.relocs[m_slab_cache].target_id = self.code_len;
        // Single-thread fast path: seed inline heap cache [0xC0..0xC8) for freshly allocated block
        self.emit8(0x49);
        self.emit8(0x83);
        self.emit8(0xBA);
        self.emit32(0xA0);
        self.emit8(0); // cmp qword [r10 + 0xA0], 0
        const m_skip_cache = self.emitJccReloc(0x5, .code_offset, 0, 0); // jne
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x82);
        self.emit32(0xC0); // mov [r10 + 0xC0], rax
        self.emitLeaRegIdxScale(11, 0, 9, 0); // r11 = rax + r9
        self.emit8(0x4D);
        self.emit8(0x89);
        self.emit8(0x9A);
        self.emit32(0xC8); // mov [r10 + 0xC8], r11
        self.xorReg(11, 11);
        self.relocs[m_skip_cache].target_id = self.code_len;
        self.emit8(0xC3);

        // ── __lir_free(rdi = ptr) ───────────────────────────────
        self.free_offset = self.code_len;
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xFF); // test rdi, rdi
        const f_done0 = self.emitJccReloc(0x4, .code_offset, 0, 0);
        // Invalidate single-thread last-checked chunk cache immediately
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x04);
        self.emit8(0x25);
        self.emit32(@intCast(DATA_VADDR + 0xC0));
        self.emit32(0xFFFFFFFF);
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x04);
        self.emit8(0x25);
        self.emit32(@intCast(DATA_VADDR + 0xC8));
        self.emit32(0);
        self.emitBasicPtrTrap(7);
        // Reject pointers outside [heap_min, heap_max) (e.g. stack/rodata pointers) without touching [ptr-16]
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x3C);
        self.emit8(0x25);
        self.emit32(@intCast(DATA_VADDR + 0x88)); // cmp rdi, [heap_min]
        const f_out_lo = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb trap
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x3C);
        self.emit8(0x25);
        self.emit32(@intCast(DATA_VADDR + 0x90)); // cmp rdi, [heap_max]
        const f_out_hi = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae trap
        // Require 16-byte alignment on user pointer (reject interior pointers)
        self.emit8(0xF7);
        self.emit8(0xC7);
        self.emit32(15); // test edi, 15
        const f_unaligned = self.emitJccReloc(0x5, .code_offset, 0, 0); // jnz trap
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xEF);
        self.emit8(0x10); // sub rdi, 16
        self.mov64imm(10, DATA_VADDR);
        self.emit8(0x4D);
        self.emit8(0x8B);
        self.emit8(0x42);
        self.emit8(0x70); // mov r8, [r10 + 0x70] (heap_secret)
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x07); // mov rax, [rdi]
        self.mov64imm(11, LIVE_MMAP_COOKIE);
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xC3); // xor r11, r8
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xD8); // cmp rax, r11
        const f_munmap = self.emitJccReloc(0x4, .code_offset, 0, 0); // je
        self.mov64imm(11, LIVE_SLAB_BASE);
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xC3); // xor r11, r8
        self.emit8(0x4C);
        self.emit8(0x31);
        self.emit8(0xD8); // xor rax, r11
        self.emitCmpRegImm32(0, 7);
        const f_bad = self.emitJccReloc(0x7, .code_offset, 0, 0); // ja trap

        // Acquire spinlock when multithreaded and re-validate tag, size, and canary under lock
        self.emit8(0x49);
        self.emit8(0x83);
        self.emit8(0xBA);
        self.emit32(0xA0);
        self.emit8(0);
        const f_skip_lock = self.emitJccReloc(0x4, .code_offset, 0, 0);
        const flock = self.code_len;
        self.emit8(0xB8);
        self.emit32(1);
        self.emit8(0x41);
        self.emit8(0x87);
        self.emit8(0x42);
        self.emit8(0x10);
        self.emit8(0x85);
        self.emit8(0xC0);
        const fgot = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0xF3);
        self.emit8(0x90);
        _ = self.emitJmpReloc(.code_offset, flock, 0);
        self.relocs[fgot].target_id = self.code_len;

        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x07); // mov rax, [rdi]
        self.emit8(0x4C);
        self.emit8(0x31);
        self.emit8(0xD8); // xor rax, r11
        self.emitCmpRegImm32(0, 7);
        const f_locked_ok = self.emitJccReloc(0x6, .code_offset, 0, 0); // jbe
        const f_unlock_trap = self.code_len;
        self.emit8(0x41);
        self.emit8(0xC7);
        self.emit8(0x42);
        self.emit8(0x10);
        self.emit32(0); // unlock spinlock before trap
        const f_race_trap = self.emitJmpReloc(.code_offset, 0, 0);

        self.relocs[f_skip_lock].target_id = self.code_len;
        self.relocs[f_locked_ok].target_id = self.code_len;
        self.movRegReg(1, 0); // rcx = class (0..7)
        self.mov64imm(2, 32);
        self.emit8(0x48);
        self.emit8(0xD3);
        self.emit8(0xE2); // shl rdx, cl (chunk_size)
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x4F);
        self.emit8(0x08); // mov r9, [rdi + 8] (req_size)
        self.emit8(0x4D);
        self.emit8(0x8D);
        self.emit8(0x59);
        self.emit8(0x18); // lea r11, [r9 + 24]
        self.emit8(0x49);
        self.emit8(0x39);
        self.emit8(0xD3); // cmp r11, rdx
        _ = self.emitJccReloc(0x7, .code_offset, f_unlock_trap, 0); // ja unlock_trap
        self.mov64imm(11, CANARY_SALT);
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xC3); // xor r11, r8
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xCB); // xor r11, r9
        self.emit8(0x4E);
        self.emit8(0x39);
        self.emit8(0x5C);
        self.emit8(0x0F);
        self.emit8(0x10); // cmp [rdi + r9 + 16], r11
        _ = self.emitJccReloc(0x5, .code_offset, f_unlock_trap, 0); // jne unlock_trap (heap buffer overflow detected!)

        // Poison header with secret FREE_COOKIE & fast zero-wipe payload + canary
        self.mov64imm(11, FREE_COOKIE);
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xC3); // xor r11, r8
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x1F); // mov [rdi], r11
        // Fast unrolled zeroing for 32B/64B chunks; rep stosq for >= 128B
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x47);
        self.emit8(16);
        self.emit32(0); // [rdi+16] = 0
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x47);
        self.emit8(24);
        self.emit32(0); // [rdi+24] = 0
        self.emitCmpRegImm32(2, 32);
        const f_wipe_done32 = self.emitJccReloc(0x6, .code_offset, 0, 0); // jbe
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x47);
        self.emit8(32);
        self.emit32(0);
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x47);
        self.emit8(40);
        self.emit32(0);
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x47);
        self.emit8(48);
        self.emit32(0);
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x47);
        self.emit8(56);
        self.emit32(0);
        self.emitCmpRegImm32(2, 64);
        const f_wipe_done64 = self.emitJccReloc(0x6, .code_offset, 0, 0); // jbe
        self.pushReg(1); // save class
        self.pushReg(7); // save chunk ptr
        self.emitLeaRegDisp(7, 7, 64); // rdi = payload + 48
        self.emitAluRegImm32(5, 2, 64); // sub rdx, 64
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xEA);
        self.emit8(3); // shr rdx, 3 (qword count)
        self.movRegReg(1, 2); // rcx = qword count
        self.emitByteZeroQwords(); // rep stosq
        self.popReg(7);
        self.popReg(1);
        self.relocs[f_wipe_done32].target_id = self.code_len;
        self.relocs[f_wipe_done64].target_id = self.code_len;
        self.emit8(0x4D);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0xCA);
        self.emit8(0x28); // r8 = free_heads[rcx]
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x47);
        self.emit8(0x08); // [rdi+8] = r8
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x7C);
        self.emit8(0xCA);
        self.emit8(0x28); // free_heads[rcx] = rdi
        self.emit8(0x41);
        self.emit8(0xC7);
        self.emit8(0x42);
        self.emit8(0x10);
        self.emit32(0); // unlock
        self.xorReg(8, 8);
        self.xorReg(11, 11);
        self.relocs[f_done0].target_id = self.code_len;
        self.xorReg(0, 0);
        self.emit8(0xC3);

        self.relocs[f_munmap].target_id = self.code_len;
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x4F);
        self.emit8(0x08); // mov r9, [rdi + 8] (req_size)
        self.mov64imm(11, 0x7FFF_FFFF_0000);
        self.emit8(0x4D);
        self.emit8(0x39);
        self.emit8(0xD9); // cmp r9, r11
        const f_mmap_big_trap = self.emitJccReloc(0x7, .code_offset, 0, 0); // ja trap
        self.mov64imm(11, CANARY_SALT);
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xC3); // xor r11, r8
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xCB); // xor r11, r9
        self.emit8(0x4E);
        self.emit8(0x39);
        self.emit8(0x5C);
        self.emit8(0x0F);
        self.emit8(0x10); // cmp [rdi + r9 + 16], r11
        const f_mmap_can_trap = self.emitJccReloc(0x5, .code_offset, 0, 0); // jne trap
        self.mov64imm(11, FREE_COOKIE);
        self.emit8(0x4D);
        self.emit8(0x31);
        self.emit8(0xC3); // xor r11, r8
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x1F); // poison before munmap
        self.emit8(0x49);
        self.emit8(0x8D);
        self.emit8(0xB1);
        self.emit32(4119); // lea rsi, [r9 + 24 + 4095]
        self.emitAluRegImm32(4, 6, -4096); // and rsi, -4096 (mapped_size)

        // Mark matching region_dir entry as FREED_MMAP (kind = 2) before munmap
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x8A);
        self.emit32(0x98); // rcx = region_count
        self.mov64imm(8, DATA_VADDR + 0x100);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC9);
        const fm_dir_done = self.emitJccReloc(0x4, .code_offset, 0, 0);
        const fm_dir_loop = self.code_len;
        self.emit8(0x49);
        self.emit8(0x39);
        self.emit8(0x38); // cmp [r8], rdi
        const fm_dir_next = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x04);
        self.emit8(0x37); // lea rax, [rdi + rsi]
        self.mov64imm(11, @as(u64, 2) << 62);
        self.emit8(0x4C);
        self.emit8(0x09);
        self.emit8(0xD8); // or rax, r11
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x40);
        self.emit8(0x08); // mov [r8 + 8], rax
        const fm_dir_found = self.emitJmpReloc(.code_offset, 0, 0);
        self.relocs[fm_dir_next].target_id = self.code_len;
        self.emitAluRegImm32(0, 8, 16);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC9);
        _ = self.emitJccReloc(0x5, .code_offset, fm_dir_loop, 0);
        self.relocs[fm_dir_found].target_id = self.code_len;
        self.relocs[fm_dir_done].target_id = self.code_len;

        self.xorReg(8, 8);
        self.xorReg(11, 11);
        self.mov64imm(0, 11); // SYS_munmap
        self.syscallInst();
        self.xorReg(0, 0);
        self.emit8(0xC3);

        const f_trap_pos = self.code_len;
        self.relocs[f_out_lo].target_id = f_trap_pos;
        self.relocs[f_out_hi].target_id = f_trap_pos;
        self.relocs[f_unaligned].target_id = f_trap_pos;
        self.relocs[f_bad].target_id = f_trap_pos;
        self.relocs[f_race_trap].target_id = f_trap_pos;
        self.relocs[f_mmap_big_trap].target_id = f_trap_pos;
        self.relocs[f_mmap_can_trap].target_id = f_trap_pos;
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
    }

    fn emitArrayRoutines(self: *IRCodegen) void {
        // Handle layout (24 bytes): [0]=len, [8]=cap, [16]=data_ptr

        // ── __lir_array_new(rdi = cap) -> rax = handle ──────────
        self.array_new_offset = self.code_len;
        self.pushReg(3); // rbx
        self.pushReg(12);
        self.subRspImm(8); // 16-byte stack aligned
        self.emitCmpRegImm32(7, 8);
        self.emit8(0x73);
        self.emit8(0x05);
        self.mov64imm(7, 8);
        self.mov64imm(11, @as(u64, 1) << 28);
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xDF); // cmp rdi, r11
        const an_cap_ok = self.emitJccReloc(0x6, .code_offset, 0, 0); // jbe
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
        self.relocs[an_cap_ok].target_id = self.code_len;
        self.movRegReg(3, 7); // rbx = cap
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE7);
        self.emit8(0x03); // shl rdi, 3
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.movRegReg(12, 0); // r12 = data_ptr
        self.movRegReg(7, 12);
        self.movRegReg(1, 3);
        self.emitByteZeroQwords();
        self.mov64imm(7, 24);
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x00);
        self.emit32(0); // [rax+0] = 0
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x58);
        self.emit8(0x08); // [rax+8] = rbx
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x60);
        self.emit8(0x10); // [rax+16] = r12
        self.addRspImm(8);
        self.popReg(12);
        self.popReg(3);
        self.emit8(0xC3);

        // ── __lir_array_push(rdi = arr, rsi = val) -> rax = arr ─
        self.array_push_offset = self.code_len;
        self.emitPtrTrap(7);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x0F); // rcx = [rdi+0] (len)
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x4F);
        self.emit8(0x08); // cmp rcx, [rdi+8] (cap)
        const ap_fast = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb fast
        self.pushReg(3);
        self.pushReg(12);
        self.pushReg(13);
        self.pushReg(14);
        self.pushReg(15);
        self.movRegReg(3, 7); // rbx = arr
        self.movRegReg(12, 6); // r12 = val
        self.movRegReg(13, 1); // r13 = old_len
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x73);
        self.emit8(0x08); // r14 = cap
        self.emitCmpRegImm32(14, 8);
        const ap_min_ok = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae
        self.mov64imm(14, 8);
        self.relocs[ap_min_ok].target_id = self.code_len;
        self.emit8(0x49);
        self.emit8(0xD1);
        self.emit8(0xE6); // shl r14, 1 (new_cap)
        self.mov64imm(11, @as(u64, 1) << 28);
        self.emit8(0x4D);
        self.emit8(0x39);
        self.emit8(0xDE); // cmp r14, r11
        const ap_cap_ok = self.emitJccReloc(0x6, .code_offset, 0, 0); // jbe
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
        self.relocs[ap_cap_ok].target_id = self.code_len;
        self.movRegReg(7, 14);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE7);
        self.emit8(0x03); // rdi = new_cap * 8
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.movRegReg(15, 0); // r15 = new_data
        self.movRegReg(7, 15);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x73);
        self.emit8(0x10); // rsi = [rbx+16] (old_data)
        self.movRegReg(1, 13);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE1);
        self.emit8(0x03); // rcx = old_len * 8
        self.emitByteCopy();
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x7B);
        self.emit8(0x10); // rdi = old_data
        self.emitCallReloc(.free_fn, 0);
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x73);
        self.emit8(0x08); // [rbx+8] = new_cap
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x7B);
        self.emit8(0x10); // [rbx+16] = new_data
        self.movRegReg(7, 3);
        self.movRegReg(6, 12);
        self.movRegReg(1, 13);
        self.popReg(15);
        self.popReg(14);
        self.popReg(13);
        self.popReg(12);
        self.popReg(3);

        self.relocs[ap_fast].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x57);
        self.emit8(0x10); // rdx = [rdi+16]
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x34);
        self.emit8(0xCA); // [rdx + rcx*8] = rsi
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0x07); // inc qword [rdi]
        self.movRegReg(0, 7);
        self.emit8(0xC3);

        // ── __lir_array_get(rdi = arr, rsi = idx) -> rax = val ──
        self.array_get_offset = self.code_len;
        self.emitPtrTrap(7);
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x37); // cmp rsi, [rdi] (unsigned idx < len)
        const ag_ok = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
        self.relocs[ag_ok].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x57);
        self.emit8(0x10); // rdx = [rdi+16]
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x04);
        self.emit8(0xF2); // rax = [rdx + rsi*8]
        self.emit8(0xC3);

        // ── __lir_array_set(rdi = arr, rsi = idx, rdx = val) -> rax = arr ─
        self.array_set_offset = self.code_len;
        self.emitPtrTrap(7);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xF6); // test rsi, rsi
        self.emit8(0x79);
        self.emit8(0x02); // jns +2
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x77);
        self.emit8(0x08); // cmp rsi, [rdi+8]
        const as_fast = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb
        self.mov64imm(11, @as(u64, 1) << 28);
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xDE); // cmp rsi, r11
        const as_idx_ok = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
        self.relocs[as_idx_ok].target_id = self.code_len;
        self.pushReg(3);
        self.pushReg(12);
        self.pushReg(13);
        self.pushReg(14);
        self.pushReg(15);
        self.movRegReg(3, 7); // rbx = arr
        self.movRegReg(12, 6); // r12 = idx
        self.movRegReg(13, 2); // r13 = val
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x73);
        self.emit8(0x08); // r14 = cap
        self.emitCmpRegImm32(14, 8);
        const as_min_ok = self.emitJccReloc(0x3, .code_offset, 0, 0);
        self.mov64imm(14, 8);
        self.relocs[as_min_ok].target_id = self.code_len;
        self.emit8(0x49);
        self.emit8(0xD1);
        self.emit8(0xE6); // shl r14, 1
        self.emitLeaRegDisp(0, 12, 1); // rax = idx + 1
        self.emit8(0x49);
        self.emit8(0x39);
        self.emit8(0xC6); // cmp r14, rax
        self.emit8(0x73);
        self.emit8(0x03); // jae +3
        self.movRegReg(14, 0); // r14 = idx + 1
        self.movRegReg(7, 14);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE7);
        self.emit8(0x03);
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.movRegReg(15, 0);
        self.movRegReg(7, 15);
        self.movRegReg(1, 14);
        self.emitByteZeroQwords();
        self.movRegReg(7, 15);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x73);
        self.emit8(0x10); // rsi = old_data
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x0B); // rcx = old_len
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE1);
        self.emit8(0x03);
        self.emitByteCopy();
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x7B);
        self.emit8(0x10);
        self.emitCallReloc(.free_fn, 0);
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x73);
        self.emit8(0x08);
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x7B);
        self.emit8(0x10);
        self.movRegReg(7, 3);
        self.movRegReg(6, 12);
        self.movRegReg(2, 13);
        self.popReg(15);
        self.popReg(14);
        self.popReg(13);
        self.popReg(12);
        self.popReg(3);

        self.relocs[as_fast].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x4F);
        self.emit8(0x10); // rcx = [rdi+16]
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x14);
        self.emit8(0xF1); // [rcx + rsi*8] = rdx
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x46);
        self.emit8(0x01); // rax = idx + 1
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x07); // cmp rax, [rdi]
        self.emit8(0x76);
        self.emit8(0x03); // jbe +3
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x07); // [rdi] = rax
        self.movRegReg(0, 7);
        self.emit8(0xC3);
    }

    fn emitSplitRoutine(self: *IRCodegen) void {
        // __lir_split(rdi = str, rsi = delim) -> rax = array of substrings
        self.split_offset = self.code_len;
        self.emitPtrTrap(7);
        self.emitPtrTrap(6);
        self.pushReg(3); // rbx
        self.pushReg(12);
        self.pushReg(13);
        self.pushReg(14);
        self.pushReg(15);
        self.subRspImm(16); // [rsp+0]=start, [rsp+8]=cur

        self.movRegReg(3, 7); // rbx = str
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x67);
        self.emit8(0xF8); // r12 = [rdi - 8] (hay_len)
        self.movRegReg(13, 6); // r13 = delim
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x76);
        self.emit8(0xF8); // r14 = [rsi - 8] (delim_len)

        // Allocate growable dynamic array (cap = 16)
        self.mov64imm(7, 16);
        self.emitCallReloc(.array_new_fn, 0);
        self.movRegReg(15, 0); // r15 = arr

        // start = 0, cur = 0
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x04);
        self.emit8(0x24);
        self.emit32(0);
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(0x08);
        self.emit32(0);

        // If delim_len == 0, jump to emit_tail (returns whole string)
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xF6);
        const j_empty_delim = self.emitJccReloc(0x4, .code_offset, 0, 0);

        // Scan loop: while (cur + delim_len <= hay_len)
        const scan_top = self.code_len;
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(0x08); // rax = cur
        self.emit8(0x4A);
        self.emit8(0x8D);
        self.emit8(0x0C);
        self.emit8(0x30); // rcx = cur + delim_len
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xE1);
        const j_tail = self.emitJccReloc(0x7, .code_offset, 0, 0);

        // Compare r14 bytes between [rbx + rax] and [r13]
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x34);
        self.emit8(0x03); // lea rsi, [rbx + rax]
        self.movRegReg(7, 13); // rdi = delim
        self.movRegReg(1, 14); // rcx = delim_len
        self.emit8(0xFC);
        self.emit8(0xF3);
        self.emit8(0xA6); // repe cmpsb
        const j_no_match = self.emitJccReloc(0x5, .code_offset, 0, 0);

        // Match! Create slice [start .. cur)
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(0x08); // rax = cur
        self.emit8(0x48);
        self.emit8(0x2B);
        self.emit8(0x04);
        self.emit8(0x24); // rax = cur - start = seg_len
        self.pushReg(0);
        self.emitLeaRegDisp(7, 0, 9);
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.popReg(1); // rcx = seg_len
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x08); // [buf] = seg_len
        self.emitLeaRegDisp(7, 0, 8);
        self.pushReg(7);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x74);
        self.emit8(0x24);
        self.emit8(0x08); // rsi = start (rsp+8)
        self.emit8(0x48);
        self.emit8(0x01);
        self.emit8(0xDE);
        self.emitByteCopy();
        self.emit8(0xC6);
        self.emit8(0x07);
        self.emit8(0x00);
        self.popReg(6); // rsi = str_ptr
        self.movRegReg(7, 15); // rdi = arr
        self.emitCallReloc(.array_push_fn, 0);

        // cur += delim_len; start = cur
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(0x08);
        self.emit8(0x4C);
        self.emit8(0x01);
        self.emit8(0xF0);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(0x08);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x04);
        self.emit8(0x24);
        _ = self.emitJmpReloc(.code_offset, scan_top, 0);

        self.relocs[j_no_match].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(0x08);
        _ = self.emitJmpReloc(.code_offset, scan_top, 0);

        // Emit trailing tail segment [start .. hay_len)
        const tail_pos = self.code_len;
        self.relocs[j_empty_delim].target_id = tail_pos;
        self.relocs[j_tail].target_id = tail_pos;

        self.movRegReg(0, 12);
        self.emit8(0x48);
        self.emit8(0x2B);
        self.emit8(0x04);
        self.emit8(0x24);
        self.pushReg(0);
        self.emitLeaRegDisp(7, 0, 9);
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.popReg(1);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x08);
        self.emitLeaRegDisp(7, 0, 8);
        self.pushReg(7);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x74);
        self.emit8(0x24);
        self.emit8(0x08);
        self.emit8(0x48);
        self.emit8(0x01);
        self.emit8(0xDE);
        self.emitByteCopy();
        self.emit8(0xC6);
        self.emit8(0x07);
        self.emit8(0x00);
        self.popReg(6);
        self.movRegReg(7, 15);
        self.emitCallReloc(.array_push_fn, 0);

        self.movRegReg(0, 15);
        self.addRspImm(16);
        self.popReg(15);
        self.popReg(14);
        self.popReg(13);
        self.popReg(12);
        self.popReg(3);
        self.emit8(0xC3);
    }

    fn emitFloatRoutines(self: *IRCodegen) void {
        // Helper to emit a 64-bit f64 constant into an xmm register via rax
        const emitXmmConst = struct {
            fn f(cg: *IRCodegen, xmm_reg: u8, val: f64) void {
                cg.mov64imm(0, @bitCast(val));
                cg.emit8(0x66);
                cg.emit8(0x48);
                cg.emit8(0x0F);
                cg.emit8(0x6E);
                cg.emit8(0xC0 | ((xmm_reg & 7) << 3)); // movq xmm, rax
            }
        }.f;

        // ── __lir_float_to_str(rdi = f64_bits) -> rax = LIR heap string ─
        self.float_to_str_offset = self.code_len;
        self.pushReg(3); // rbx
        self.pushReg(12);
        self.pushReg(13);
        self.pushReg(14);
        self.pushReg(15); // 5 pushes -> 16B aligned
        self.subRspImm(48); // [rsp..+32] scratch digits, [rsp+32]=exp
        self.movRegReg(14, 7); // r14 = raw f64 bits

        self.mov64imm(7, 64);
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.movRegReg(12, 0); // r12 = base alloc
        self.emitLeaRegDisp(13, 12, 8); // r13 = write cursor

        // Extract sign bit in r15 (0 or 1), |x| bits in r14
        self.movRegReg(15, 14);
        self.emit8(0x49);
        self.emit8(0xC1);
        self.emit8(0xEF);
        self.emit8(63); // shr r15, 63
        self.mov64imm(0, 0x7FFF_FFFF_FFFF_FFFF);
        self.emit8(0x49);
        self.emit8(0x21);
        self.emit8(0xC6); // and r14, rax

        // Check NaN / Inf: exp == 0x7FF
        self.movRegReg(0, 14);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE8);
        self.emit8(52);
        self.emitCmpRegImm32(0, 0x7FF);
        const fts_finite = self.emitJccReloc(0x5, .code_offset, 0, 0); // jne
        // Non-finite: check mantissa
        self.movRegReg(0, 14);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE0);
        self.emit8(12);
        const fts_inf = self.emitJccReloc(0x4, .code_offset, 0, 0); // jz
        // NaN
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(0);
        self.emit8('n');
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(1);
        self.emit8('a');
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(2);
        self.emit8('n');
        self.emit8(0x49);
        self.emit8(0x83);
        self.emit8(0xC5);
        self.emit8(3);
        const fts_nan_done = self.emitJmpReloc(.code_offset, 0, 0);

        // Inf / -Inf
        self.relocs[fts_inf].target_id = self.code_len;
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xFF);
        const fts_pos_inf = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(0);
        self.emit8('-');
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xC5);
        self.relocs[fts_pos_inf].target_id = self.code_len;
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(0);
        self.emit8('i');
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(1);
        self.emit8('n');
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(2);
        self.emit8('f');
        self.emit8(0x49);
        self.emit8(0x83);
        self.emit8(0xC5);
        self.emit8(3);
        const fts_inf_done = self.emitJmpReloc(.code_offset, 0, 0);

        // Finite
        self.relocs[fts_finite].target_id = self.code_len;
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xFF);
        const fts_no_minus = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(0);
        self.emit8('-');
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xC5);
        self.relocs[fts_no_minus].target_id = self.code_len;

        // Check == 0.0
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xF6);
        const fts_nz = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(0);
        self.emit8('0');
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(1);
        self.emit8('.');
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(2);
        self.emit8('0');
        self.emit8(0x49);
        self.emit8(0x83);
        self.emit8(0xC5);
        self.emit8(3);
        const fts_zero_done = self.emitJmpReloc(.code_offset, 0, 0);

        self.relocs[fts_nz].target_id = self.code_len;
        // Load |x| into xmm0; check scientific normalization threshold (>= 1e15 or < 1e-4)
        self.emit8(0x66);
        self.emit8(0x49);
        self.emit8(0x0F);
        self.emit8(0x6E);
        self.emit8(0xC6); // movq xmm0, r14
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(32);
        self.emit32(0); // exp = 0
        self.xorReg(3, 3); // rbx = use_sci = 0

        emitXmmConst(self, 1, 1.0e15);
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x2E);
        self.emit8(0xC1); // ucomisd xmm0, xmm1
        const fts_check_small = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb
        self.mov64imm(3, 1); // use_sci = 1
        const fts_norm_hi = self.code_len;
        emitXmmConst(self, 1, 10.0);
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x2E);
        self.emit8(0xC1);
        const fts_hi_done = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb
        emitXmmConst(self, 1, 0.1);
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x59);
        self.emit8(0xC1); // mulsd xmm0, 0.1
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(32); // inc exp
        _ = self.emitJmpReloc(.code_offset, fts_norm_hi, 0);

        self.relocs[fts_check_small].target_id = self.code_len;
        emitXmmConst(self, 1, 1.0e-4);
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x2E);
        self.emit8(0xC1);
        const fts_norm_done = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae
        self.mov64imm(3, 1);
        self.mov64imm(1, 350); // iteration cap
        const fts_norm_lo = self.code_len;
        emitXmmConst(self, 1, 1.0);
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x2E);
        self.emit8(0xC1);
        const fts_lo_done = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae
        emitXmmConst(self, 1, 10.0);
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x59);
        self.emit8(0xC1); // mulsd xmm0, 10.0
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0x4C);
        self.emit8(0x24);
        self.emit8(32); // dec exp
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC9);
        _ = self.emitJccReloc(0x5, .code_offset, fts_norm_lo, 0); // jnz

        const norm_join = self.code_len;
        self.relocs[fts_hi_done].target_id = norm_join;
        self.relocs[fts_norm_done].target_id = norm_join;
        self.relocs[fts_lo_done].target_id = norm_join;

        // Split xmm0 into r14 = int_part, rax = round((x - int_part) * 1_000_000)
        self.emit8(0xF2);
        self.emit8(0x4C);
        self.emit8(0x0F);
        self.emit8(0x2C);
        self.emit8(0xF0); // cvttsd2si r14, xmm0
        self.emit8(0xF2);
        self.emit8(0x49);
        self.emit8(0x0F);
        self.emit8(0x2A);
        self.emit8(0xCE); // cvtsi2sd xmm1, r14
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x5C);
        self.emit8(0xC1); // subsd xmm0, xmm1
        emitXmmConst(self, 1, 1_000_000.0);
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x59);
        self.emit8(0xC1);
        emitXmmConst(self, 1, 0.5);
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x58);
        self.emit8(0xC1);
        self.emit8(0xF2);
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0x2C);
        self.emit8(0xC0); // cvttsd2si rax, xmm0
        self.emitCmpRegImm32(0, 1_000_000);
        const fts_no_carry = self.emitJccReloc(0xC, .code_offset, 0, 0); // jl
        self.emit8(0x48);
        self.emit8(0x2D);
        self.emit32(1_000_000); // sub eax, 1_000_000
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xC6); // inc r14
        self.relocs[fts_no_carry].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(40); // save frac at [rsp+40]

        // Format int_part (r14) backwards into [rsp+24..0]
        self.movRegReg(0, 14);
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x74);
        self.emit8(0x24);
        self.emit8(24); // rsi = end
        self.movRegReg(7, 6);
        const fts_idiv = self.code_len;
        self.mov64imm(9, 10);
        self.xorReg(2, 2);
        self.emit8(0x49);
        self.emit8(0xF7);
        self.emit8(0xF1); // div r9
        self.emit8(0x80);
        self.emit8(0xC2);
        self.emit8('0');
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xCE);
        self.emit8(0x88);
        self.emit8(0x16);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        _ = self.emitJccReloc(0x5, .code_offset, fts_idiv, 0);
        // Copy integer digits to r13
        self.movRegReg(1, 7);
        self.emit8(0x48);
        self.emit8(0x29);
        self.emit8(0xF1); // rcx = len
        self.movRegReg(7, 13);
        self.emit8(0x49);
        self.emit8(0x01);
        self.emit8(0xCD); // r13 += len
        self.emitByteCopy();

        // Emit '.'
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(0);
        self.emit8('.');
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xC5);

        // Format 6 fractional digits at [rsp..rsp+6]
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(40); // rax = frac
        self.mov64imm(1, 6);
        const fts_floop = self.code_len;
        self.mov64imm(9, 10);
        self.xorReg(2, 2);
        self.emit8(0x49);
        self.emit8(0xF7);
        self.emit8(0xF1);
        self.emit8(0x80);
        self.emit8(0xC2);
        self.emit8('0');
        self.emit8(0x88);
        self.emit8(0x54);
        self.emit8(0x0C);
        self.emit8(0xFF); // mov [rsp + rcx - 1], dl
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC9);
        _ = self.emitJccReloc(0x5, .code_offset, fts_floop, 0);

        // Trim trailing '0's keeping at least 1 digit
        self.mov64imm(1, 6);
        const fts_trim = self.code_len;
        self.emitCmpRegImm32(1, 1);
        const fts_trim_done = self.emitJccReloc(0x6, .code_offset, 0, 0); // jbe
        self.emit8(0x80);
        self.emit8(0x7C);
        self.emit8(0x0C);
        self.emit8(0xFF);
        self.emit8('0'); // cmp byte [rsp + rcx - 1], '0'
        const fts_trim_stop = self.emitJccReloc(0x5, .code_offset, 0, 0); // jne
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC9);
        _ = self.emitJmpReloc(.code_offset, fts_trim, 0);
        self.relocs[fts_trim_done].target_id = self.code_len;
        self.relocs[fts_trim_stop].target_id = self.code_len;

        self.movRegReg(6, 4); // rsi = rsp
        self.movRegReg(7, 13);
        self.emit8(0x49);
        self.emit8(0x01);
        self.emit8(0xCD);
        self.emitByteCopy();

        // Append exponent if use_sci (rbx != 0)
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xDB);
        const fts_no_sci = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(0);
        self.emit8('e');
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xC5);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(32); // rax = exp
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        const fts_exp_pos = self.emitJccReloc(0x9, .code_offset, 0, 0); // jns
        self.emit8(0x48);
        self.emit8(0xF7);
        self.emit8(0xD8); // neg rax
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(0);
        self.emit8('-');
        const fts_exp_sign = self.emitJmpReloc(.code_offset, 0, 0);
        self.relocs[fts_exp_pos].target_id = self.code_len;
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(0);
        self.emit8('+');
        self.relocs[fts_exp_sign].target_id = self.code_len;
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xC5);
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x74);
        self.emit8(0x24);
        self.emit8(24);
        self.movRegReg(7, 6);
        const fts_ediv = self.code_len;
        self.mov64imm(9, 10);
        self.xorReg(2, 2);
        self.emit8(0x49);
        self.emit8(0xF7);
        self.emit8(0xF1);
        self.emit8(0x80);
        self.emit8(0xC2);
        self.emit8('0');
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xCE);
        self.emit8(0x88);
        self.emit8(0x16);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        _ = self.emitJccReloc(0x5, .code_offset, fts_ediv, 0);
        self.movRegReg(1, 7);
        self.emit8(0x48);
        self.emit8(0x29);
        self.emit8(0xF1);
        self.movRegReg(7, 13);
        self.emit8(0x49);
        self.emit8(0x01);
        self.emit8(0xCD);
        self.emitByteCopy();

        // Finalize header [r12] = len, [r13] = 0, return r12 + 8
        const fts_finish = self.code_len;
        self.relocs[fts_nan_done].target_id = fts_finish;
        self.relocs[fts_inf_done].target_id = fts_finish;
        self.relocs[fts_zero_done].target_id = fts_finish;
        self.relocs[fts_no_sci].target_id = fts_finish;
        self.emit8(0x41);
        self.emit8(0xC6);
        self.emit8(0x45);
        self.emit8(0);
        self.emit8(0); // null terminate
        self.emitLeaRegDisp(0, 12, 8);
        self.movRegReg(1, 13);
        self.emit8(0x48);
        self.emit8(0x29);
        self.emit8(0xC1); // rcx = r13 - (r12 + 8)
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x0C);
        self.emit8(0x24); // [r12] = len
        self.addRspImm(48);
        self.popReg(15);
        self.popReg(14);
        self.popReg(13);
        self.popReg(12);
        self.popReg(3);
        self.emit8(0xC3);

        // ── __lir_str_to_float(rdi = str) -> rax = f64 bits ─────
        self.str_to_float_offset = self.code_len;
        self.emitPtrTrap(7);
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x4F);
        self.emit8(0xF8); // r9 = len
        self.xorReg(1, 1); // rcx = cursor
        self.xorReg(8, 8); // r8 = neg
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0xEF);
        self.emit8(0xC0); // pxor xmm0, xmm0
        emitXmmConst(self, 2, 10.0); // xmm2 = 10.0

        // Skip whitespace
        const stf_ws = self.code_len;
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xC9);
        const stf_ret0 = self.emitJccReloc(0x3, .code_offset, 0, 0);
        self.emit8(0x0F);
        self.emit8(0xB6);
        self.emit8(0x04);
        self.emit8(0x0F); // movzx eax, [rdi+rcx]
        self.emitCmpRegImm32(0, ' ');
        const stf_ws_done = self.emitJccReloc(0x7, .code_offset, 0, 0); // ja
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        _ = self.emitJmpReloc(.code_offset, stf_ws, 0);
        self.relocs[stf_ws_done].target_id = self.code_len;

        // Sign
        self.emitCmpRegImm32(0, '-');
        const stf_not_neg = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.mov64imm(8, 1);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        const stf_sign_done = self.emitJmpReloc(.code_offset, 0, 0);
        self.relocs[stf_not_neg].target_id = self.code_len;
        self.emitCmpRegImm32(0, '+');
        const stf_no_plus = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        self.relocs[stf_sign_done].target_id = self.code_len;
        self.relocs[stf_no_plus].target_id = self.code_len;

        // Integer part
        const stf_int = self.code_len;
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xC9);
        const stf_end1 = self.emitJccReloc(0x3, .code_offset, 0, 0);
        self.emit8(0x0F);
        self.emit8(0xB6);
        self.emit8(0x04);
        self.emit8(0x0F);
        self.emit8(0x83);
        self.emit8(0xE8);
        self.emit8('0'); // sub eax, '0'
        self.emitCmpRegImm32(0, 9);
        const stf_dot_chk = self.emitJccReloc(0x7, .code_offset, 0, 0);
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x59);
        self.emit8(0xC2); // mulsd xmm0, xmm2
        self.emit8(0xF2);
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0x2A);
        self.emit8(0xC8); // cvtsi2sd xmm1, rax
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x58);
        self.emit8(0xC1); // addsd xmm0, xmm1
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        _ = self.emitJmpReloc(.code_offset, stf_int, 0);

        // Dot check
        self.relocs[stf_dot_chk].target_id = self.code_len;
        self.emit8(0x0F);
        self.emit8(0xB6);
        self.emit8(0x04);
        self.emit8(0x0F);
        self.emitCmpRegImm32(0, '.');
        const stf_exp_chk = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        // Frac integer + pow10 in xmm3 (avoid 0.1 drift)
        self.xorReg(2, 2); // rdx = frac_int
        self.pushReg(0); // dummy save? keep xmm3 = 1.0 in xmm3
        emitXmmConst(self, 3, 1.0); // Note: trashes rax, ok
        emitXmmConst(self, 2, 10.0); // restore xmm2=10.0
        self.xorReg(10, 10); // digit count <= 17
        const stf_frac = self.code_len;
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xC9);
        const stf_frac_done1 = self.emitJccReloc(0x3, .code_offset, 0, 0);
        self.emit8(0x0F);
        self.emit8(0xB6);
        self.emit8(0x04);
        self.emit8(0x0F);
        self.emit8(0x83);
        self.emit8(0xE8);
        self.emit8('0');
        self.emitCmpRegImm32(0, 9);
        const stf_frac_done2 = self.emitJccReloc(0x7, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        self.emitCmpRegImm32(10, 17);
        _ = self.emitJccReloc(0x3, .code_offset, stf_frac, 0); // ignore extra >17 digits
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xC2);
        self.emit8(0x48);
        self.emit8(0x6B);
        self.emit8(0xD2);
        self.emit8(10); // imul rdx, rdx, 10
        self.emit8(0x48);
        self.emit8(0x01);
        self.emit8(0xC2); // add rdx, rax
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x59);
        self.emit8(0xDA); // mulsd xmm3, xmm2
        _ = self.emitJmpReloc(.code_offset, stf_frac, 0);
        const stf_frac_add = self.code_len;
        self.relocs[stf_frac_done1].target_id = stf_frac_add;
        self.relocs[stf_frac_done2].target_id = stf_frac_add;
        self.popReg(0); // balance stack push above
        self.emit8(0xF2);
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0x2A);
        self.emit8(0xCA); // cvtsi2sd xmm1, rdx
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x5E);
        self.emit8(0xCB); // divsd xmm1, xmm3
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x58);
        self.emit8(0xC1); // addsd xmm0, xmm1

        // Exponent 'e'/'E'
        self.relocs[stf_exp_chk].target_id = self.code_len;
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xC9);
        const stf_end2 = self.emitJccReloc(0x3, .code_offset, 0, 0);
        self.emit8(0x0F);
        self.emit8(0xB6);
        self.emit8(0x04);
        self.emit8(0x0F);
        self.emit8(0x83);
        self.emit8(0xE0);
        self.emit8(0xDF); // and eax, ~0x20 (upper)
        self.emitCmpRegImm32(0, 'E');
        const stf_end3 = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        self.xorReg(10, 10); // exp_neg
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xC9);
        const stf_end4 = self.emitJccReloc(0x3, .code_offset, 0, 0);
        self.emit8(0x0F);
        self.emit8(0xB6);
        self.emit8(0x04);
        self.emit8(0x0F);
        self.emitCmpRegImm32(0, '-');
        const stf_enotneg = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.mov64imm(10, 1);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        const stf_es_done = self.emitJmpReloc(.code_offset, 0, 0);
        self.relocs[stf_enotneg].target_id = self.code_len;
        self.emitCmpRegImm32(0, '+');
        const stf_enoplus = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        self.relocs[stf_es_done].target_id = self.code_len;
        self.relocs[stf_enoplus].target_id = self.code_len;
        self.xorReg(2, 2); // exp_val
        const stf_eloop = self.code_len;
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xC9);
        const stf_edone = self.emitJccReloc(0x3, .code_offset, 0, 0);
        self.emit8(0x0F);
        self.emit8(0xB6);
        self.emit8(0x04);
        self.emit8(0x0F);
        self.emit8(0x83);
        self.emit8(0xE8);
        self.emit8('0');
        self.emitCmpRegImm32(0, 9);
        const stf_edone2 = self.emitJccReloc(0x7, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC1);
        self.emit8(0x48);
        self.emit8(0x6B);
        self.emit8(0xD2);
        self.emit8(10);
        self.emit8(0x48);
        self.emit8(0x01);
        self.emit8(0xC2);
        self.emitCmpRegImm32(2, 350);
        _ = self.emitJccReloc(0x6, .code_offset, stf_eloop, 0);
        self.mov64imm(2, 350);
        _ = self.emitJmpReloc(.code_offset, stf_eloop, 0);
        const stf_eapply = self.code_len;
        self.relocs[stf_edone].target_id = stf_eapply;
        self.relocs[stf_edone2].target_id = stf_eapply;
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xD2);
        const stf_ezero = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xD2); // test r10, r10
        const stf_ediv_branch = self.emitJccReloc(0x5, .code_offset, 0, 0);
        const stf_emul = self.code_len;
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x59);
        self.emit8(0xC2); // mulsd xmm0, xmm2
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xCA); // dec rdx
        _ = self.emitJccReloc(0x5, .code_offset, stf_emul, 0);
        const stf_eend_j = self.emitJmpReloc(.code_offset, 0, 0);
        self.relocs[stf_ediv_branch].target_id = self.code_len;
        const stf_ediv = self.code_len;
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x5E);
        self.emit8(0xC2); // divsd xmm0, xmm2
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xCA); // dec rdx
        _ = self.emitJccReloc(0x5, .code_offset, stf_ediv, 0);

        const stf_fin = self.code_len;
        self.relocs[stf_ret0].target_id = stf_fin;
        self.relocs[stf_end1].target_id = stf_fin;
        self.relocs[stf_end2].target_id = stf_fin;
        self.relocs[stf_end3].target_id = stf_fin;
        self.relocs[stf_end4].target_id = stf_fin;
        self.relocs[stf_ezero].target_id = stf_fin;
        self.relocs[stf_eend_j].target_id = stf_fin;
        self.emit8(0x66);
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0x7E);
        self.emit8(0xC0); // movq rax, xmm0
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xC0);
        const stf_pos_ret = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.mov64imm(1, 0x8000_0000_0000_0000);
        self.emit8(0x48);
        self.emit8(0x31);
        self.emit8(0xC8);
        self.relocs[stf_pos_ret].target_id = self.code_len;
        self.emit8(0xC3);

        // ── __lir_cos(rdi = f64) & __lir_sin(rdi = f64) ──────────
        self.cos_offset = self.code_len;
        self.emit8(0x66);
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0x6E);
        self.emit8(0xC7); // movq xmm0, rdi
        emitXmmConst(self, 1, std.math.pi * 0.5);
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x58);
        self.emit8(0xC1); // addsd xmm0, pi/2
        const cos_to_sin = self.emitJmpReloc(.code_offset, 0, 0);

        self.sin_offset = self.code_len;
        self.emit8(0x66);
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0x6E);
        self.emit8(0xC7); // movq xmm0, rdi

        self.relocs[cos_to_sin].target_id = self.code_len;
        // NaN guard: if xmm0 != xmm0 -> return xmm0
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x2E);
        self.emit8(0xC0); // ucomisd xmm0, xmm0
        const sin_nan = self.emitJccReloc(0xA, .code_offset, 0, 0); // jp

        // Range reduction: x -= round(x / (2*pi)) * (2*pi)
        emitXmmConst(self, 1, 1.0 / (2.0 * std.math.pi));
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x28);
        self.emit8(0xD0); // movapd xmm2, xmm0
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x59);
        self.emit8(0xD1); // mulsd xmm2, xmm1 (x / 2pi)
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0xEF);
        self.emit8(0xDB); // pxor xmm3, xmm3
        emitXmmConst(self, 1, 0.5);
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x2E);
        self.emit8(0xD3); // ucomisd xmm2, xmm3
        const sin_k_neg = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x58);
        self.emit8(0xD1); // addsd xmm2, 0.5
        const sin_k_done = self.emitJmpReloc(.code_offset, 0, 0);
        self.relocs[sin_k_neg].target_id = self.code_len;
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x5C);
        self.emit8(0xD1); // subsd xmm2, 0.5
        self.relocs[sin_k_done].target_id = self.code_len;
        self.emit8(0xF2);
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0x2C);
        self.emit8(0xC2); // cvttsd2si rax, xmm2
        self.emit8(0xF2);
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0x2A);
        self.emit8(0xC8); // cvtsi2sd xmm1, rax
        emitXmmConst(self, 2, 2.0 * std.math.pi);
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x59);
        self.emit8(0xCA); // mulsd xmm1, xmm2
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x5C);
        self.emit8(0xC1); // subsd xmm0, xmm1

        // Fold [-pi, pi] into [-pi/2, pi/2]
        emitXmmConst(self, 1, std.math.pi * 0.5);
        emitXmmConst(self, 2, std.math.pi);
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x2E);
        self.emit8(0xC1); // ucomisd xmm0, pi/2
        const sin_chk_lo = self.emitJccReloc(0x6, .code_offset, 0, 0); // jbe
        // x = pi - x
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x5C);
        self.emit8(0xD0); // subsd xmm2, xmm0
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x28);
        self.emit8(0xC2); // movapd xmm0, xmm2
        const sin_poly = self.emitJmpReloc(.code_offset, 0, 0);

        self.relocs[sin_chk_lo].target_id = self.code_len;
        emitXmmConst(self, 1, -std.math.pi * 0.5);
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x2E);
        self.emit8(0xC1); // ucomisd xmm0, -pi/2
        const sin_poly2 = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae
        // x = -pi - x
        emitXmmConst(self, 2, -std.math.pi);
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x5C);
        self.emit8(0xD0); // subsd xmm2, xmm0
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x28);
        self.emit8(0xC2); // movapd xmm0, xmm2

        const sin_poly_pos = self.code_len;
        self.relocs[sin_poly].target_id = sin_poly_pos;
        self.relocs[sin_poly2].target_id = sin_poly_pos;
        // Odd Taylor polynomial on [-pi/2, pi/2] (degree 17 -> full f64 accuracy)
        self.emit8(0x66);
        self.emit8(0x0F);
        self.emit8(0x28);
        self.emit8(0xC8); // movapd xmm1, xmm0
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x59);
        self.emit8(0xC8); // mulsd xmm1, xmm0 (x^2)
        const coeffs = [_]f64{
            1.0 / 355687428096000.0,
            -1.0 / 1307674368000.0,
            1.0 / 6227020800.0,
            -1.0 / 39916800.0,
            1.0 / 362880.0,
            -1.0 / 5040.0,
            1.0 / 120.0,
            -1.0 / 6.0,
            1.0,
        };
        emitXmmConst(self, 2, coeffs[0]);
        for (coeffs[1..]) |c| {
            self.emit8(0xF2);
            self.emit8(0x0F);
            self.emit8(0x59);
            self.emit8(0xD1); // mulsd xmm2, xmm1
            emitXmmConst(self, 3, c);
            self.emit8(0xF2);
            self.emit8(0x0F);
            self.emit8(0x58);
            self.emit8(0xD3); // addsd xmm2, xmm3
        }
        self.emit8(0xF2);
        self.emit8(0x0F);
        self.emit8(0x59);
        self.emit8(0xC2); // mulsd xmm0, xmm2
        self.relocs[sin_nan].target_id = self.code_len;
        self.emit8(0x66);
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0x7E);
        self.emit8(0xC0); // movq rax, xmm0
        self.emit8(0xC3);
    }

    fn emitMapRoutines(self: *IRCodegen) void {
        // Map struct (40B): [0]=len, [8]=cap, [16]=entries_ptr, [24]=flags (bit0=str_key), [32]=load_count
        // Entry (24B): [0]=state (0=empty,1=occ,2=tomb), [8]=key, [16]=val

        // Internal hash helper: (rdi=key, rsi=flags) -> rax=hash (clobbers rcx, r8)
        const map_hash_off = self.code_len;
        self.emit8(0x48);
        self.emit8(0xF7);
        self.emit8(0xC6);
        self.emit32(1); // test esi, 1
        const mh_str = self.emitJccReloc(0x5, .code_offset, 0, 0);
        // Int splitmix64 keyed with per-process CSPRNG secret [DATA_VADDR + 0x70]
        self.movRegReg(0, 7);
        self.mov64imm(8, DATA_VADDR);
        self.emit8(0x49);
        self.emit8(0x33);
        self.emit8(0x40);
        self.emit8(0x70); // xor rax, [r8 + 0x70]
        self.movRegReg(1, 0);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE9);
        self.emit8(30);
        self.emit8(0x48);
        self.emit8(0x31);
        self.emit8(0xC8);
        self.mov64imm(8, 0xbf58476d1ce4e5b9);
        self.emit8(0x49);
        self.emit8(0x0F);
        self.emit8(0xAF);
        self.emit8(0xC0);
        self.movRegReg(1, 0);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE9);
        self.emit8(27);
        self.emit8(0x48);
        self.emit8(0x31);
        self.emit8(0xC8);
        self.mov64imm(8, 0x94d049bb133111eb);
        self.emit8(0x49);
        self.emit8(0x0F);
        self.emit8(0xAF);
        self.emit8(0xC0);
        self.movRegReg(1, 0);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE9);
        self.emit8(31);
        self.emit8(0x48);
        self.emit8(0x31);
        self.emit8(0xC8);
        self.emit8(0xC3);
        // String FNV-1a seeded with per-process CSPRNG secret (HashDoS resistant)
        self.relocs[mh_str].target_id = self.code_len;
        self.emitPtrTrap(7);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x4F);
        self.emit8(0xF8); // rcx = len
        self.mov64imm(0, 0xcbf29ce484222325);
        self.mov64imm(8, DATA_VADDR);
        self.emit8(0x49);
        self.emit8(0x33);
        self.emit8(0x40);
        self.emit8(0x70); // xor rax, [r8 + 0x70]
        self.mov64imm(8, 0x100000001b3);
        const mh_sloop = self.code_len;
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC9);
        const mh_sdone = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x32);
        self.emit8(0x07); // xor al, [rdi]
        self.emit8(0x49);
        self.emit8(0x0F);
        self.emit8(0xAF);
        self.emit8(0xC0); // imul rax, r8
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC7);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC9);
        _ = self.emitJmpReloc(.code_offset, mh_sloop, 0);
        self.relocs[mh_sdone].target_id = self.code_len;
        self.emit8(0xC3);

        // Internal key_eq helper: (rdi=k1, rsi=k2, rdx=flags) -> rax=1/0
        const map_eq_off = self.code_len;
        self.emit8(0x48);
        self.emit8(0x39);
        self.emit8(0xF7); // cmp rdi, rsi
        const me_same = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0xF7);
        self.emit8(0xC2);
        self.emit32(1); // test edx, 1
        const me_false_fast = self.emitJccReloc(0x4, .code_offset, 0, 0); // int keys differed
        self.emitPtrTrap(7);
        self.emitPtrTrap(6);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x4F);
        self.emit8(0xF8);
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x4E);
        self.emit8(0xF8);
        const me_false_len = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC9);
        const me_true_empty = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0xFC);
        self.emit8(0xF3);
        self.emit8(0xA6);
        const me_false_cmp = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.relocs[me_same].target_id = self.code_len;
        self.relocs[me_true_empty].target_id = self.code_len;
        self.mov64imm(0, 1);
        self.emit8(0xC3);
        const me_false_pos = self.code_len;
        self.relocs[me_false_fast].target_id = me_false_pos;
        self.relocs[me_false_len].target_id = me_false_pos;
        self.relocs[me_false_cmp].target_id = me_false_pos;
        self.xorReg(0, 0);
        self.emit8(0xC3);

        // ── __lir_map_new(rdi = flags) -> rax = map_ptr ─────────
        self.map_new_offset = self.code_len;
        self.pushReg(3);
        self.pushReg(12);
        self.pushReg(13); // 3 pushes -> 16B aligned
        self.movRegReg(12, 7);
        self.mov64imm(7, 40);
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.movRegReg(3, 0);
        self.mov64imm(7, 16 * 24);
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.movRegReg(13, 0);
        self.movRegReg(7, 13);
        self.mov64imm(1, (16 * 24) / 8);
        self.emitByteZeroQwords();
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x03);
        self.emit32(0); // len = 0
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x43);
        self.emit8(8);
        self.emit32(16); // cap = 16
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x6B);
        self.emit8(16); // entries_ptr = r13
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x63);
        self.emit8(24); // flags = r12
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x43);
        self.emit8(32);
        self.emit32(0); // load_count = 0
        self.movRegReg(0, 3);
        self.popReg(13);
        self.popReg(12);
        self.popReg(3);
        self.emit8(0xC3);

        // Internal find_entry: (rdi=m, rsi=key) -> rax=entry_ptr or 0
        const map_find_off = self.code_len;
        self.emitPtrTrap(7);
        self.pushReg(3);
        self.pushReg(12);
        self.pushReg(13);
        self.pushReg(14);
        self.pushReg(15); // 5 pushes
        self.subRspImm(16); // [rsp]=step, [rsp+8]=entry
        self.movRegReg(3, 7); // rbx = m
        self.movRegReg(12, 6); // r12 = key
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x73);
        self.emit8(8); // r14 = cap
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xF6);
        const mf_ret0 = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xCE); // r14 = cap - 1 (mask)
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x7B);
        self.emit8(16); // r15 = entries_ptr
        self.movRegReg(7, 12);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x73);
        self.emit8(24); // rsi = flags
        _ = self.addReloc(.{ .kind = .call32, .opcode_pos = self.code_len, .instr_len = 5, .target_kind = .code_offset, .target_id = map_hash_off });
        self.emit8(0xE8);
        self.emit32(0);
        self.movRegReg(13, 0); // r13 = hash
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x04);
        self.emit8(0x24);
        self.emit32(0); // step = 0
        const mf_loop = self.code_len;
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x04);
        self.emit8(0x24); // rax = step
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xF0); // cmp rax, mask
        const mf_not_found1 = self.emitJccReloc(0x7, .code_offset, 0, 0); // ja
        self.emit8(0x4C);
        self.emit8(0x01);
        self.emit8(0xE8); // rax += hash
        self.emit8(0x4C);
        self.emit8(0x21);
        self.emit8(0xF0); // rax &= mask
        self.emit8(0x48);
        self.emit8(0x6B);
        self.emit8(0xC0);
        self.emit8(24); // rax *= 24
        self.emit8(0x4C);
        self.emit8(0x01);
        self.emit8(0xF8); // rax += entries
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(8); // [rsp+8] = entry
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x08); // rcx = state
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC9);
        const mf_not_found2 = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emitCmpRegImm32(1, 1);
        const mf_next = self.emitJccReloc(0x5, .code_offset, 0, 0); // tombstone (2)
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x78);
        self.emit8(8); // rdi = entry.key
        self.movRegReg(6, 12); // rsi = key
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x53);
        self.emit8(24); // rdx = flags
        _ = self.addReloc(.{ .kind = .call32, .opcode_pos = self.code_len, .instr_len = 5, .target_kind = .code_offset, .target_id = map_eq_off });
        self.emit8(0xE8);
        self.emit32(0);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        const mf_found = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.relocs[mf_next].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0x04);
        self.emit8(0x24); // inc step
        _ = self.emitJmpReloc(.code_offset, mf_loop, 0);
        self.relocs[mf_found].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(8); // rax = entry
        const mf_done = self.emitJmpReloc(.code_offset, 0, 0);
        const mf_nf_pos = self.code_len;
        self.relocs[mf_ret0].target_id = mf_nf_pos;
        self.relocs[mf_not_found1].target_id = mf_nf_pos;
        self.relocs[mf_not_found2].target_id = mf_nf_pos;
        self.xorReg(0, 0);
        self.relocs[mf_done].target_id = self.code_len;
        self.addRspImm(16);
        self.popReg(15);
        self.popReg(14);
        self.popReg(13);
        self.popReg(12);
        self.popReg(3);
        self.emit8(0xC3);

        // ── __lir_map_get(rdi = m, rsi = key) -> rax = val ──────
        self.map_get_offset = self.code_len;
        _ = self.addReloc(.{ .kind = .call32, .opcode_pos = self.code_len, .instr_len = 5, .target_kind = .code_offset, .target_id = map_find_off });
        self.emit8(0xE8);
        self.emit32(0);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        self.emit8(0x74);
        self.emit8(0x04); // jz +4
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x40);
        self.emit8(16); // mov rax, [rax+16]
        self.emit8(0xC3);

        // ── __lir_map_has(rdi = m, rsi = key) -> rax = 0/1 ──────
        self.map_has_offset = self.code_len;
        _ = self.addReloc(.{ .kind = .call32, .opcode_pos = self.code_len, .instr_len = 5, .target_kind = .code_offset, .target_id = map_find_off });
        self.emit8(0xE8);
        self.emit32(0);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        self.emit8(0x0F);
        self.emit8(0x95);
        self.emit8(0xC0);
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0xB6);
        self.emit8(0xC0);
        self.emit8(0xC3);

        // ── __lir_map_del(rdi = m, rsi = key) -> rax = 0/1 ──────
        self.map_del_offset = self.code_len;
        self.pushReg(7); // save m, keeps 16B aligned
        _ = self.addReloc(.{ .kind = .call32, .opcode_pos = self.code_len, .instr_len = 5, .target_kind = .code_offset, .target_id = map_find_off });
        self.emit8(0xE8);
        self.emit32(0);
        self.popReg(7);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        const md_miss = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x00);
        self.emit32(2); // state = tombstone (2)
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0x0F); // dec qword [rdi] (len)
        self.mov64imm(0, 1);
        self.emit8(0xC3);
        self.relocs[md_miss].target_id = self.code_len;
        self.xorReg(0, 0);
        self.emit8(0xC3);

        // ── __lir_map_set(rdi = m, rsi = key, rdx = val) -> rax = m
        self.map_set_offset = self.code_len;
        self.emitPtrTrap(7);
        self.pushReg(3);
        self.pushReg(12);
        self.pushReg(13);
        self.pushReg(14);
        self.pushReg(15); // 5 pushes -> 16B aligned
        self.subRspImm(32); // [rsp]=hash, [rsp+8]=first_tomb, [rsp+16]=new_cap, [rsp+24]=new_entries
        self.movRegReg(3, 7); // rbx = m
        self.movRegReg(12, 6); // r12 = key
        self.movRegReg(13, 2); // r13 = val

        // Check rehash: (load_count + 1) * 2 >= cap
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x43);
        self.emit8(32);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC0);
        self.emit8(0x48);
        self.emit8(0xD1);
        self.emit8(0xE0); // shl rax, 1
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x43);
        self.emit8(8);
        const ms_no_rehash = self.emitJccReloc(0x2, .code_offset, 0, 0); // jb

        // new_cap = if (len * 2 >= cap) cap * 2 else cap
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x43);
        self.emit8(0);
        self.emit8(0x48);
        self.emit8(0xD1);
        self.emit8(0xE0);
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x73);
        self.emit8(8); // r14 = old_cap
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xF0);
        const ms_keep_cap = self.emitJccReloc(0x2, .code_offset, 0, 0);
        self.emit8(0x49);
        self.emit8(0xD1);
        self.emit8(0xE6); // r14 *= 2
        self.relocs[ms_keep_cap].target_id = self.code_len;
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x74);
        self.emit8(0x24);
        self.emit8(16); // [rsp+16] = new_cap
        self.emit8(0x49);
        self.emit8(0x6B);
        self.emit8(0xFE);
        self.emit8(24); // rdi = new_cap * 24
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(24); // [rsp+24] = new_entries
        self.movRegReg(7, 0);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x4C);
        self.emit8(0x24);
        self.emit8(16);
        self.emit8(0x48);
        self.emit8(0x6B);
        self.emit8(0xC9);
        self.emit8(3); // rcx = new_cap * 3 qwords
        self.emitByteZeroQwords();

        // Re-insert active entries from old_entries into new_entries
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x7B);
        self.emit8(16); // r15 = old_entries
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x73);
        self.emit8(8); // r14 = old_cap
        const ms_re_loop = self.code_len;
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xF6);
        const ms_re_done = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xCE); // dec r14
        self.emit8(0x49);
        self.emit8(0x83);
        self.emit8(0x3F);
        self.emit8(1); // cmp qword [r15], 1
        const ms_re_skip = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x7F);
        self.emit8(8); // rdi = old.key
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x73);
        self.emit8(24); // rsi = flags
        _ = self.addReloc(.{ .kind = .call32, .opcode_pos = self.code_len, .instr_len = 5, .target_kind = .code_offset, .target_id = map_hash_off });
        self.emit8(0xE8);
        self.emit32(0);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x4C);
        self.emit8(0x24);
        self.emit8(16); // rcx = new_cap
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC9); // rcx = new_mask
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x4C);
        self.emit8(0x24);
        self.emit8(24); // r9 = new_entries
        const ms_re_probe = self.code_len;
        self.emit8(0x48);
        self.emit8(0x21);
        self.emit8(0xC8); // rax &= mask
        self.emit8(0x48);
        self.emit8(0x6B);
        self.emit8(0xD0);
        self.emit8(24); // rdx = idx * 24
        self.emit8(0x49);
        self.emit8(0x83);
        self.emit8(0x3C);
        self.emit8(0x11);
        self.emit8(0); // cmp qword [r9+rdx], 0
        const ms_re_slot = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC0);
        _ = self.emitJmpReloc(.code_offset, ms_re_probe, 0);
        self.relocs[ms_re_slot].target_id = self.code_len;
        self.emit8(0x49);
        self.emit8(0xC7);
        self.emit8(0x04);
        self.emit8(0x11);
        self.emit32(1); // state = 1
        self.emit8(0x4D);
        self.emit8(0x8B);
        self.emit8(0x47);
        self.emit8(8);
        self.emit8(0x4D);
        self.emit8(0x89);
        self.emit8(0x44);
        self.emit8(0x11);
        self.emit8(8); // key
        self.emit8(0x4D);
        self.emit8(0x8B);
        self.emit8(0x47);
        self.emit8(16);
        self.emit8(0x4D);
        self.emit8(0x89);
        self.emit8(0x44);
        self.emit8(0x11);
        self.emit8(16); // val
        self.relocs[ms_re_skip].target_id = self.code_len;
        self.emit8(0x49);
        self.emit8(0x83);
        self.emit8(0xC7);
        self.emit8(24);
        _ = self.emitJmpReloc(.code_offset, ms_re_loop, 0);
        self.relocs[ms_re_done].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x7B);
        self.emit8(16); // free(old_entries)
        self.emitCallReloc(.free_fn, 0);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(16);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x43);
        self.emit8(8); // cap = new_cap
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(24);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x43);
        self.emit8(16); // entries_ptr = new_entries
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x03);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x43);
        self.emit8(32); // load_count = len

        self.relocs[ms_no_rehash].target_id = self.code_len;
        self.movRegReg(7, 12);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x73);
        self.emit8(24);
        _ = self.addReloc(.{ .kind = .call32, .opcode_pos = self.code_len, .instr_len = 5, .target_kind = .code_offset, .target_id = map_hash_off });
        self.emit8(0xE8);
        self.emit32(0);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x04);
        self.emit8(0x24); // [rsp] = hash
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(8);
        self.emit32(0); // [rsp+8] = first_tomb = 0
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x73);
        self.emit8(8);
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xCE); // r14 = cap - 1
        self.xorReg(15, 15); // r15 = step
        const ms_ploop = self.code_len;
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x04);
        self.emit8(0x24);
        self.emit8(0x4C);
        self.emit8(0x01);
        self.emit8(0xF8); // hash + step
        self.emit8(0x4C);
        self.emit8(0x21);
        self.emit8(0xF0); // & mask
        self.emit8(0x48);
        self.emit8(0x6B);
        self.emit8(0xC0);
        self.emit8(24);
        self.emit8(0x48);
        self.emit8(0x03);
        self.emit8(0x43);
        self.emit8(16); // rax = entry_ptr
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(24); // save entry_ptr
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x08); // rcx = state
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC9);
        const ms_empty = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emitCmpRegImm32(1, 2);
        const ms_tomb = self.emitJccReloc(0x4, .code_offset, 0, 0);
        // state == 1: compare key
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x78);
        self.emit8(8);
        self.movRegReg(6, 12);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x53);
        self.emit8(24);
        _ = self.addReloc(.{ .kind = .call32, .opcode_pos = self.code_len, .instr_len = 5, .target_kind = .code_offset, .target_id = map_eq_off });
        self.emit8(0xE8);
        self.emit32(0);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        const ms_overwrite = self.emitJccReloc(0x5, .code_offset, 0, 0);
        const ms_next_step = self.code_len;
        self.emit8(0x49);
        self.emit8(0xFF);
        self.emit8(0xC7);
        _ = self.emitJmpReloc(.code_offset, ms_ploop, 0);

        self.relocs[ms_tomb].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0x7C);
        self.emit8(0x24);
        self.emit8(8);
        self.emit8(0); // cmp qword [rsp+8], 0
        _ = self.emitJccReloc(0x5, .code_offset, ms_next_step, 0);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(8); // first_tomb = entry_ptr
        _ = self.emitJmpReloc(.code_offset, ms_next_step, 0);

        // Overwrite existing entry
        self.relocs[ms_overwrite].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(24);
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x68);
        self.emit8(16); // [entry+16] = r13
        const ms_done1 = self.emitJmpReloc(.code_offset, 0, 0);

        // Empty slot reached: insert into first_tomb or empty entry
        self.relocs[ms_empty].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x4C);
        self.emit8(0x24);
        self.emit8(8);
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC9);
        const ms_use_empty = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.movRegReg(0, 1);
        const ms_write_new = self.emitJmpReloc(.code_offset, 0, 0);
        self.relocs[ms_use_empty].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0x43);
        self.emit8(32); // inc load_count
        self.relocs[ms_write_new].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x00);
        self.emit32(1); // state = 1
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x60);
        self.emit8(8); // key = r12
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0x68);
        self.emit8(16); // val = r13
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0x03); // inc len

        self.relocs[ms_done1].target_id = self.code_len;
        self.movRegReg(0, 3);
        self.addRspImm(32);
        self.popReg(15);
        self.popReg(14);
        self.popReg(13);
        self.popReg(12);
        self.popReg(3);
        self.emit8(0xC3);
    }

    fn emitChanRoutines(self: *IRCodegen) void {
        // Channel struct (56B): [0]=lock, [8]=cap, [16]=len, [24]=head, [32]=tail, [40]=closed, [48]=buf_ptr

        // ── __lir_chan_new(rdi = cap) -> rax = chan_ptr ─────────
        self.chan_new_offset = self.code_len;
        self.pushReg(3);
        self.pushReg(12);
        self.pushReg(13); // 3 pushes -> 16B aligned
        self.emitCmpRegImm32(7, 1);
        self.emit8(0x7D);
        self.emit8(0x05); // jge +5
        self.mov64imm(7, 1);
        self.mov64imm(11, @as(u64, 1) << 24);
        self.emit8(0x4C);
        self.emit8(0x39);
        self.emit8(0xDF);
        const cn_ok = self.emitJccReloc(0x6, .code_offset, 0, 0);
        self.emit8(0x0F);
        self.emit8(0x0B);
        self.relocs[cn_ok].target_id = self.code_len;
        self.movRegReg(3, 7); // rbx = cap
        self.mov64imm(7, 56);
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.movRegReg(12, 0);
        self.movRegReg(7, 3);
        self.emit8(0x48);
        self.emit8(0xC1);
        self.emit8(0xE7);
        self.emit8(0x03); // cap * 8
        self.emitCallReloc(.malloc_fn, 0);
        self.emitTestRegZeroTrap(0);
        self.movRegReg(13, 0);
        self.emit8(0x49);
        self.emit8(0xC7);
        self.emit8(0x04);
        self.emit8(0x24);
        self.emit32(0); // lock = 0
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x5C);
        self.emit8(0x24);
        self.emit8(8); // cap = rbx
        self.emit8(0x49);
        self.emit8(0xC7);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(16);
        self.emit32(0); // len = 0
        self.emit8(0x49);
        self.emit8(0xC7);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(24);
        self.emit32(0); // head = 0
        self.emit8(0x49);
        self.emit8(0xC7);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(32);
        self.emit32(0); // tail = 0
        self.emit8(0x49);
        self.emit8(0xC7);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(40);
        self.emit32(0); // closed = 0
        self.emit8(0x4D);
        self.emit8(0x89);
        self.emit8(0x6C);
        self.emit8(0x24);
        self.emit8(48); // buf_ptr = r13
        self.movRegReg(0, 12);
        self.popReg(13);
        self.popReg(12);
        self.popReg(3);
        self.emit8(0xC3);

        // ── __lir_chan_send(rdi = chan, rsi = val) -> rax = 0/-1 ─
        self.chan_send_offset = self.code_len;
        self.emitPtrTrap(7);
        const cs_spin = self.code_len;
        self.emit8(0xB8);
        self.emit32(1);
        self.emit8(0x87);
        self.emit8(0x07); // xchg [rdi], eax
        self.emit8(0x85);
        self.emit8(0xC0);
        const cs_got = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0xF3);
        self.emit8(0x90); // pause
        _ = self.emitJmpReloc(.code_offset, cs_spin, 0);
        self.relocs[cs_got].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0x7F);
        self.emit8(40);
        self.emit8(0); // cmp qword [rdi+40], 0
        const cs_closed = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x47);
        self.emit8(16); // len
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x47);
        self.emit8(8); // cmp len, cap
        const cs_full = self.emitJccReloc(0x3, .code_offset, 0, 0); // jae
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x57);
        self.emit8(32); // rdx = tail
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x47);
        self.emit8(48); // r8 = buf_ptr
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0x34);
        self.emit8(0xD0); // [r8 + rdx*8] = rsi
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC2);
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x57);
        self.emit8(8);
        self.emit8(0x72);
        self.emit8(0x02);
        self.xorReg(2, 2);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x57);
        self.emit8(32);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0x47);
        self.emit8(16); // inc len
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x07);
        self.emit32(0); // unlock
        self.xorReg(0, 0);
        self.emit8(0xC3);
        self.relocs[cs_full].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x07);
        self.emit32(0); // unlock
        self.pushReg(7);
        self.pushReg(6);
        self.mov64imm(0, 24); // SYS_sched_yield
        self.syscallInst();
        self.popReg(6);
        self.popReg(7);
        _ = self.emitJmpReloc(.code_offset, cs_spin, 0);
        self.relocs[cs_closed].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x07);
        self.emit32(0);
        self.mov64imm(0, @bitCast(@as(i64, -1)));
        self.emit8(0xC3);

        // ── __lir_chan_recv(rdi = chan) -> rax = val ────────────
        self.chan_recv_offset = self.code_len;
        self.emitPtrTrap(7);
        const cr_spin = self.code_len;
        self.emit8(0xB8);
        self.emit32(1);
        self.emit8(0x87);
        self.emit8(0x07);
        self.emit8(0x85);
        self.emit8(0xC0);
        const cr_got = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0xF3);
        self.emit8(0x90);
        _ = self.emitJmpReloc(.code_offset, cr_spin, 0);
        self.relocs[cr_got].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0x7F);
        self.emit8(16);
        self.emit8(0); // cmp qword [rdi+16], 0
        const cr_empty = self.emitJccReloc(0x4, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x57);
        self.emit8(24); // rdx = head
        self.emit8(0x4C);
        self.emit8(0x8B);
        self.emit8(0x47);
        self.emit8(48); // r8 = buf_ptr
        self.emit8(0x49);
        self.emit8(0x8B);
        self.emit8(0x04);
        self.emit8(0xD0); // rax = [r8 + rdx*8]
        self.emit8(0x49);
        self.emit8(0xC7);
        self.emit8(0x04);
        self.emit8(0xD0);
        self.emit32(0); // mov qword [r8 + rdx*8], 0 (scrub consumed slot)
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC2);
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x57);
        self.emit8(8);
        self.emit8(0x72);
        self.emit8(0x02);
        self.xorReg(2, 2);
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0x57);
        self.emit8(24);
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0x4F);
        self.emit8(16); // dec len
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x07);
        self.emit32(0); // unlock
        self.emit8(0xC3);
        self.relocs[cr_empty].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0x7F);
        self.emit8(40);
        self.emit8(0); // closed?
        const cr_closed = self.emitJccReloc(0x5, .code_offset, 0, 0);
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x07);
        self.emit32(0); // unlock
        self.pushReg(7);
        self.mov64imm(0, 24);
        self.syscallInst();
        self.popReg(7);
        _ = self.emitJmpReloc(.code_offset, cr_spin, 0);
        self.relocs[cr_closed].target_id = self.code_len;
        self.emit8(0x48);
        self.emit8(0xC7);
        self.emit8(0x07);
        self.emit32(0);
        self.xorReg(0, 0);
        self.emit8(0xC3);
    }

    fn emitAssertFailRoutine(self: *IRCodegen) void {
        self.assert_fail_offset = self.code_len;
        const msg_idx = self.addString("Assertion failed\n");
        self.leaRipRodata(6, msg_idx);
        self.mov64imm(2, 17);
        self.mov64imm(7, 2);
        self.mov64imm(0, 1);
        self.syscallInst();
        self.mov64imm(7, 1);
        self.mov64imm(0, 60);
        self.syscallInst();
    }

    fn recordCfiTarget(self: *IRCodegen, target_fi: u32) void {
        for (0..self.cfi_target_count) |i| {
            if (self.cfi_targets[i] == target_fi) return;
        }
        if (self.cfi_target_count >= self.cfi_targets.len) {
            self.overflowed = true;
            return;
        }
        self.cfi_targets[self.cfi_target_count] = target_fi;
        self.cfi_target_count += 1;
    }

    fn reserveCfiTable(self: *IRCodegen) void {
        if (self.cfi_target_count == 0 or self.overflowed) return;
        const aligned: usize = (@as(usize, self.rodata_len) + 7) & ~@as(usize, 7);
        const bytes: usize = @as(usize, self.cfi_target_count) * 8;
        if (aligned + bytes > self.rodata.len) {
            self.overflowed = true;
            return;
        }
        while (self.rodata_len < aligned) {
            self.rodata[self.rodata_len] = 0;
            self.rodata_len += 1;
        }
        self.cfi_table_rodata_off = self.rodata_len;
        @memset(self.rodata[self.cfi_table_rodata_off..][0..bytes], 0);
        self.rodata_len += @intCast(bytes);
    }

    fn emitCfiRoutine(self: *IRCodegen) void {
        // __lir_chk_cfi(r11 = target_ptr): preserves r11; clobbers rax, rcx, rdx; traps if not an exact .fn_addr target
        self.chk_cfi_offset = self.code_len;
        if (self.cfi_target_count == 0) {
            self.emit8(0x0F);
            self.emit8(0x0B); // ud2
            return;
        }
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xDB); // test r11, r11
        const cfi_nonnull = self.emitJccReloc(0x5, .code_offset, 0, 0); // jnz
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
        self.relocs[cfi_nonnull].target_id = self.code_len;

        self.movRegReg(0, 11); // mov rax, r11
        self.leaRipCodeBase(1); // lea rcx, [rip -> code[0]]
        self.emit8(0x48);
        self.emit8(0x29);
        self.emit8(0xC8); // sub rax, rcx (offset from code[0])
        self.leaRipRodataOffset(1, self.cfi_table_rodata_off); // lea rcx, [rip -> cfi_table]
        self.mov64imm(2, self.cfi_target_count);
        const cfi_loop = self.code_len;
        self.emit8(0x48);
        self.emit8(0x3B);
        self.emit8(0x01); // cmp rax, [rcx]
        const cfi_hit = self.emitJccReloc(0x4, .code_offset, 0, 0); // je .ok
        self.emitAluRegImm32(0, 1, 8); // add rcx, 8
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xCA); // dec rdx
        _ = self.emitJccReloc(0x5, .code_offset, cfi_loop, 0); // jnz .loop
        self.emit8(0x0F);
        self.emit8(0x0B); // ud2
        self.relocs[cfi_hit].target_id = self.code_len;
        self.emit8(0xC3);
    }

    // ═══════════════════════════════════════════════════════════
    // Short-jump relaxation + relocation patching
    // ═══════════════════════════════════════════════════════════

    fn relocTargetCodeOffset(self: *const IRCodegen, r: Reloc) u32 {
        return switch (r.target_kind) {
            .code_offset => r.target_id,
            .block => self.block_offsets[r.fn_idx][r.target_id],
            .fn_call => self.fns[r.target_id].code_offset,
            .fn_tail => self.fns[r.target_id].param_store_offset,
            .printint => self.printint_offset,
            .malloc_fn => self.malloc_offset,
            .free_fn => self.free_offset,
            .chk_heap1_fn => self.chk_heap1_offset,
            .chk_heap4_fn => self.chk_heap4_offset,
            .chk_heap8_fn => self.chk_heap8_offset,
            .chk_ptr_n_fn => self.chk_ptr_n_offset,
            .chk_cfi_fn => self.chk_cfi_offset,
            .add_region_fn => self.add_region_offset,
            .split_fn => self.split_offset,
            .array_new_fn => self.array_new_offset,
            .array_push_fn => self.array_push_offset,
            .array_get_fn => self.array_get_offset,
            .array_set_fn => self.array_set_offset,
            .float_to_str_fn => self.float_to_str_offset,
            .str_to_float_fn => self.str_to_float_offset,
            .sin_fn => self.sin_offset,
            .cos_fn => self.cos_offset,
            .map_new_fn => self.map_new_offset,
            .map_set_fn => self.map_set_offset,
            .map_get_fn => self.map_get_offset,
            .map_has_fn => self.map_has_offset,
            .map_del_fn => self.map_del_offset,
            .chan_new_fn => self.chan_new_offset,
            .chan_send_fn => self.chan_send_offset,
            .chan_recv_fn => self.chan_recv_offset,
            .assert_fail_fn => self.assert_fail_offset,
            .text_start => self.text_user_start,
            .text_end => self.text_user_end,
            .rodata => ((self.code_len + 0xFFF) & ~@as(u32, 0xFFF)) + r.target_id,
        };
    }

    fn relaxAndPatch(self: *IRCodegen) void {
        if (self.invalid_reference or self.overflowed) return;
        const page_alloc = std.heap.page_allocator;
        const shrink_flags = page_alloc.alloc(bool, self.relocs.len) catch {
            self.overflowed = true;
            return;
        };
        defer page_alloc.free(shrink_flags);
        const shift_prefix = page_alloc.alloc(u32, self.relocs.len) catch {
            self.overflowed = true;
            return;
        };
        defer page_alloc.free(shift_prefix);
        const new_code = page_alloc.alloc(u8, MAX_CODE_BYTES) catch {
            self.overflowed = true;
            return;
        };
        defer page_alloc.free(new_code);

        var pass: u32 = 0;
        while (pass < 8) : (pass += 1) {
            var shrink_count: u32 = 0;
            @memset(shrink_flags[0..self.reloc_count], false);

            for (0..self.reloc_count) |ri| {
                const r = self.relocs[ri];
                if (r.relaxed) continue;
                if (r.kind != .jmp32 and r.kind != .jcc32) continue;
                const target = self.relocTargetCodeOffset(r);
                const disp: i64 = @as(i64, @intCast(target)) - @as(i64, @intCast(r.opcode_pos + 2));
                if (disp >= -128 and disp <= 127) {
                    shrink_flags[ri] = true;
                    shrink_count += 1;
                }
            }
            if (shrink_count == 0) break;

            var total_shift: u32 = 0;
            for (0..self.reloc_count) |ri| {
                shift_prefix[ri] = total_shift;
                if (shrink_flags[ri]) {
                    total_shift += @as(u32, self.relocs[ri].instr_len) - 2;
                }
            }

            const remap = struct {
                fn apply(relocs_in: []const Reloc, flags: []const bool, prefix: []const u32, count: u32, old_pos: u32) u32 {
                    var lo: usize = 0;
                    var hi: usize = count;
                    while (lo < hi) {
                        const mid = lo + (hi - lo) / 2;
                        if (relocs_in[mid].opcode_pos < old_pos) lo = mid + 1 else hi = mid;
                    }
                    if (lo == 0) return old_pos;
                    const idx = lo - 1;
                    const extra: u32 = if (flags[idx]) @as(u32, relocs_in[idx].instr_len) - 2 else 0;
                    return old_pos - (prefix[idx] + extra);
                }
            }.apply;

            var new_len: u32 = 0;
            var src_cursor: u32 = 0;
            for (0..self.reloc_count) |ri| {
                if (!shrink_flags[ri]) continue;
                const r = self.relocs[ri];
                const chunk = r.opcode_pos - src_cursor;
                @memcpy(new_code[new_len..][0..chunk], self.code[src_cursor..][0..chunk]);
                new_len += chunk;
                if (r.kind == .jmp32) {
                    new_code[new_len] = 0xEB;
                    new_code[new_len + 1] = 0;
                } else {
                    new_code[new_len] = 0x70 | (r.cc & 0x0F);
                    new_code[new_len + 1] = 0;
                }
                new_len += 2;
                src_cursor = r.opcode_pos + r.instr_len;
            }
            const tail = self.code_len - src_cursor;
            @memcpy(new_code[new_len..][0..tail], self.code[src_cursor..][0..tail]);
            new_len += tail;

            @memcpy(self.code[0..new_len], new_code[0..new_len]);
            self.code_len = new_len;

            for (0..self.fn_count) |fi_idx| {
                self.fns[fi_idx].code_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.fns[fi_idx].code_offset);
                self.fns[fi_idx].param_store_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.fns[fi_idx].param_store_offset);
                const ir_fn = &self.ir.fns[self.fns[fi_idx].ir_fn_idx];
                for (0..ir_fn.block_count) |bi| {
                    self.block_offsets[fi_idx][bi] = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.block_offsets[fi_idx][bi]);
                }
            }
            self.printint_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.printint_offset);
            self.malloc_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.malloc_offset);
            self.free_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.free_offset);
            self.chk_heap1_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.chk_heap1_offset);
            self.chk_heap4_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.chk_heap4_offset);
            self.chk_heap8_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.chk_heap8_offset);
            self.chk_ptr_n_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.chk_ptr_n_offset);
            self.chk_cfi_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.chk_cfi_offset);
            self.add_region_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.add_region_offset);
            self.split_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.split_offset);
            self.array_new_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.array_new_offset);
            self.array_push_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.array_push_offset);
            self.array_get_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.array_get_offset);
            self.array_set_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.array_set_offset);
            self.float_to_str_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.float_to_str_offset);
            self.str_to_float_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.str_to_float_offset);
            self.sin_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.sin_offset);
            self.cos_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.cos_offset);
            self.map_new_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.map_new_offset);
            self.map_set_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.map_set_offset);
            self.map_get_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.map_get_offset);
            self.map_has_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.map_has_offset);
            self.map_del_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.map_del_offset);
            self.chan_new_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.chan_new_offset);
            self.chan_send_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.chan_send_offset);
            self.chan_recv_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.chan_recv_offset);
            self.assert_fail_offset = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.assert_fail_offset);
            self.text_user_start = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.text_user_start);
            self.text_user_end = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.text_user_end);

            for (0..self.reloc_count) |ri| {
                if (self.relocs[ri].target_kind == .code_offset) {
                    self.relocs[ri].target_id = remap(self.relocs[0..self.reloc_count], shrink_flags[0..self.reloc_count], shift_prefix[0..self.reloc_count], self.reloc_count, self.relocs[ri].target_id);
                }
            }
            for (0..self.reloc_count) |ri| {
                self.relocs[ri].opcode_pos -= shift_prefix[ri];
                if (shrink_flags[ri]) {
                    self.relocs[ri].instr_len = 2;
                    self.relocs[ri].relaxed = true;
                }
            }
        }

        // Populate exact relaxed function entry offsets into read-only CFI table
        for (0..self.cfi_target_count) |ci| {
            const tfi = self.cfi_targets[ci];
            const off: u64 = self.fns[tfi].code_offset;
            std.mem.writeInt(u64, self.rodata[self.cfi_table_rodata_off + ci * 8 ..][0..8], off, .little);
        }

        for (0..self.reloc_count) |ri| {
            const r = self.relocs[ri];
            const target = self.relocTargetCodeOffset(r);
            if (r.relaxed) {
                const disp: i8 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(r.opcode_pos + 2)));
                self.code[r.opcode_pos + 1] = @bitCast(disp);
            } else {
                switch (r.kind) {
                    .jmp32, .call32 => {
                        const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(r.opcode_pos + 5)));
                        std.mem.writeInt(i32, self.code[r.opcode_pos + 1 ..][0..4], disp, .little);
                    },
                    .jcc32 => {
                        const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(r.opcode_pos + 6)));
                        std.mem.writeInt(i32, self.code[r.opcode_pos + 2 ..][0..4], disp, .little);
                    },
                    .rip_code, .rip_rodata => {
                        const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(r.opcode_pos + 7)));
                        std.mem.writeInt(i32, self.code[r.opcode_pos + 3 ..][0..4], disp, .little);
                    },
                }
            }
        }
    }

    fn findFn(self: *const IRCodegen, name: []const u8) ?u32 {
        for (0..self.fn_count) |i| {
            if (eql(self.irFnName(@intCast(i)), name)) return @intCast(i);
        }
        return null;
    }

    // ═══════════════════════════════════════════════════════════
    // ELF64 output emission (Strict W^X: RX .text, R-only NX .rodata, RW NX .bss, NX stack)
    // ═══════════════════════════════════════════════════════════

    pub fn requiredOutputSize(self: *const IRCodegen) usize {
        const header_size: usize = 64;
        const phdr_size: usize = 56;
        const num_phdrs: usize = if (self.rodata_len > 0) 4 else 3;
        const raw_offset = header_size + phdr_size * num_phdrs;
        const code_file_offset = (raw_offset + 0xFFF) & ~@as(usize, 0xFFF);
        if (self.rodata_len == 0) {
            return code_file_offset + @as(usize, self.code_len);
        }
        const rodata_file_offset = (code_file_offset + @as(usize, self.code_len) + 0xFFF) & ~@as(usize, 0xFFF);
        return rodata_file_offset + @as(usize, self.rodata_len);
    }

    pub fn generateELF(self: *IRCodegen, output: []u8) usize {
        if (output.len < self.requiredOutputSize()) return 0;

        var pos: usize = 0;
        const header_size: u64 = 64;
        const phdr_size: u64 = 56;
        const has_rodata = self.rodata_len > 0;
        const num_phdrs: u64 = if (has_rodata) 4 else 3;
        const raw_offset = header_size + phdr_size * num_phdrs;
        const code_file_offset = (raw_offset + 0xFFF) & ~@as(u64, 0xFFF);
        const rodata_file_offset = (code_file_offset + @as(u64, self.code_len) + 0xFFF) & ~@as(u64, 0xFFF);
        const code_vaddr: u64 = 0x400000;
        const entry = code_vaddr + code_file_offset;

        output[0..16].* = .{ 0x7F, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        write16(output[16..], 2);
        write16(output[18..], 62);
        write32(output[20..], 1);
        write64(output[24..], entry);
        write64(output[32..], header_size);
        write64(output[40..], 0);
        write32(output[48..], 0);
        write16(output[52..], 64);
        write16(output[54..], 56);
        write16(output[56..], @intCast(num_phdrs));
        write16(output[58..], 64);
        write16(output[60..], 0);
        write16(output[62..], 0);
        pos = 64;

        // PHDR 0: PT_LOAD (PF_R | PF_X) — headers + executable .text only
        write32(output[pos..][0..4], 1); pos += 4;
        write32(output[pos..][0..4], 5); pos += 4;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], code_vaddr); pos += 8;
        write64(output[pos..][0..8], code_vaddr); pos += 8;
        write64(output[pos..][0..8], code_file_offset + @as(u64, self.code_len)); pos += 8;
        write64(output[pos..][0..8], code_file_offset + @as(u64, self.code_len)); pos += 8;
        write64(output[pos..][0..8], 0x1000); pos += 8;

        // PHDR 1 (if rodata present): PT_LOAD (PF_R ONLY) — Non-Executable, Read-Only .rodata
        if (has_rodata) {
            const rodata_vaddr = code_vaddr + rodata_file_offset;
            write32(output[pos..][0..4], 1); pos += 4;
            write32(output[pos..][0..4], 4); pos += 4; // PF_R only (no W, no X)
            write64(output[pos..][0..8], rodata_file_offset); pos += 8;
            write64(output[pos..][0..8], rodata_vaddr); pos += 8;
            write64(output[pos..][0..8], rodata_vaddr); pos += 8;
            write64(output[pos..][0..8], @as(u64, self.rodata_len)); pos += 8;
            write64(output[pos..][0..8], @as(u64, self.rodata_len)); pos += 8;
            write64(output[pos..][0..8], 0x1000); pos += 8;
        }

        // PT_LOAD (PF_R | PF_W) 64 KiB BSS/data page at DATA_VADDR (Non-Executable)
        write32(output[pos..][0..4], 1); pos += 4;
        write32(output[pos..][0..4], 6); pos += 4;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], DATA_VADDR); pos += 8;
        write64(output[pos..][0..8], DATA_VADDR); pos += 8;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], 0x10000); pos += 8;
        write64(output[pos..][0..8], 0x10000); pos += 8;

        // PT_GNU_STACK (PF_R | PF_W) — Non-Executable Stack
        write32(output[pos..][0..4], 0x6474e551); pos += 4;
        write32(output[pos..][0..4], 6); pos += 4;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], 0x10); pos += 8;

        while (pos < code_file_offset) {
            output[pos] = 0;
            pos += 1;
        }

        @memcpy(output[pos..][0..self.code_len], self.code[0..self.code_len]);
        pos += self.code_len;
        if (has_rodata) {
            while (pos < rodata_file_offset) {
                output[pos] = 0;
                pos += 1;
            }
            @memcpy(output[pos..][0..self.rodata_len], self.rodata[0..self.rodata_len]);
            pos += self.rodata_len;
        }

        return pos;
    }
};
