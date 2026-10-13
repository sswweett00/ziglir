// ════════════════════════════════════════════════════════════════════════════
// IR CODEGEN — Translates IR to x86-64 machine code
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const lex = @import("lexer.zig");
const parser = @import("parser.zig");
const ir_mod = @import("ir.zig");

const TokenKind = lex.TokenKind;
const AST = parser.AST;
const ASTNode = parser.ASTNode;
const IRModule = ir_mod.IRModule;
const IRFn = ir_mod.IRFn;
const IRBlock = ir_mod.IRBlock;
const IRInst = ir_mod.IRInst;
const IROp = ir_mod.IROp;

const eql = util.eql;
const printErr = util.printErr;
const printUsize = util.printUsize;
const write16 = util.write16;
const write32 = util.write32;
const write64 = util.write64;

const StringPatch = struct {
    patch_pos: u32,
    string_offset: u32,
};

const FnInfo = struct {
    name_start: u32,
    name_len: u32,
    ir_fn_idx: u32, // index into IRModule.fns
    param_count: u32,
    code_offset: u32,
};

const CallPatch = struct {
    name_buf: [64]u8,
    name_len: u8,
    patch_pos: u32,
};

const IRLoopCtx = struct {
    break_patches: [16]u32,
    break_count: u32,
    continue_target: u32,
};

/// Virtual register → stack slot mapping
const VRegSlot = struct {
    slot: u32, // rbp - slot*8
};

const ARG_REGS = [_]u8{ 7, 6, 2, 1, 8, 9 }; // rdi, rsi, rdx, rcx, r8, r9

pub const IRCodegen = struct {
    code: [65536]u8,
    code_len: u32,
    overflowed: bool,
    invalid_reference: bool,
    rodata: [65536]u8,
    rodata_len: u32,
    string_patches: [512]StringPatch,
    patch_count: u32,
    string_offsets: [256]u32,
    string_lens: [256]u32,
    string_count: u32,

    src: []const u8,
    ir: *const IRModule,

    // Function metadata
    fns: [128]FnInfo,
    fn_count: u32,
    call_patches: [256]CallPatch,
    call_patch_count: u32,
    printint_patches: [64]u32,
    printint_patch_count: u32,
    printint_offset: u32,

    // Current function state
    current_fn_idx: u32,
    in_main: bool,
    total_locals: u32,

    // Virtual register → stack slot mapping (per function)
    vreg_slots: [4096]u32,
    vreg_count: u32,

    // Block → code offset mapping (per function)
    block_offsets: [256]u32,
    block_count: u32,

    // Per-function jump patch list
    jump_patches_fn: [256]JumpPatch = undefined,
    patch_count_fn: u32 = 0,

    pub fn init(self: *IRCodegen, source: []const u8, module: *const IRModule) void {
        self.code_len = 0;
        self.overflowed = false;
        self.invalid_reference = false;
        self.rodata_len = 0;
        self.patch_count = 0;
        self.string_count = 0;
        self.src = source;
        self.ir = module;
        self.fn_count = 0;
        self.call_patch_count = 0;
        self.printint_patch_count = 0;
        self.printint_offset = 0;
        self.current_fn_idx = 0;
        self.in_main = false;
        self.total_locals = 0;
        self.vreg_count = 0;
        self.block_count = 0;
        self.patch_count_fn = 0;
    }

    // ═══════════════════════════════════════════════════════════
    // x86-64 emission helpers (same as codegen.zig)
    // ═══════════════════════════════════════════════════════════

    fn emit8(self: *IRCodegen, b: u8) void {
        if (self.overflowed) return;
        if (@as(usize, self.code_len) >= self.code.len) { self.overflowed = true; return; }
        self.code[self.code_len] = b;
        self.code_len += 1;
    }

    fn emit32(self: *IRCodegen, v: u32) void {
        if (self.overflowed) return;
        if (self.code.len - @as(usize, self.code_len) < 4) { self.overflowed = true; return; }
        self.code[self.code_len..][0..4].* = .{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24) };
        self.code_len += 4;
    }

    fn emit64(self: *IRCodegen, v: u64) void {
        if (self.overflowed) return;
        if (self.code.len - @as(usize, self.code_len) < 8) { self.overflowed = true; return; }
        self.code[self.code_len..][0..8].* = .{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24), @truncate(v >> 32), @truncate(v >> 40), @truncate(v >> 48), @truncate(v >> 56) };
        self.code_len += 8;
    }

    fn mov64imm(self: *IRCodegen, dst: u8, imm: u64) void {
        // Prefer the shortest correct x86-64 encoding. Zeroing a register with
        // XOR is 3 bytes instead of a 10-byte movabs, and C7 /0 sign-extends
        // an imm32 to 64 bits when the value fits in signed 32-bit range.
        if (imm == 0) {
            self.xorReg(dst, dst);
            return;
        }
        const signed_imm: i64 = @bitCast(imm);
        if (signed_imm >= std.math.minInt(i32) and signed_imm <= std.math.maxInt(i32)) {
            self.emit8(if (dst >= 8) 0x49 else 0x48);
            self.emit8(0xC7);
            self.emit8(0xC0 | (dst & 7)); // mov r/m64, imm32; mod=11, /0
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
        var rex: u8 = 0x48;
        if (src >= 8) rex |= 0x04;
        if (dst >= 8) rex |= 0x01;
        self.emit8(rex);
        self.emit8(0x89);
        self.emit8(0xC0 | ((src & 7) << 3) | (dst & 7));
    }

    fn xorReg(self: *IRCodegen, a: u8, b: u8) void {
        var rex: u8 = 0x48;
        if (a >= 8) rex |= 0x04;
        if (b >= 8) rex |= 0x01;
        self.emit8(rex);
        self.emit8(0x31);
        self.emit8(0xC0 | ((b & 7) << 3) | (a & 7));
    }

    fn syscallInst(self: *IRCodegen) void {
        self.emit8(0x0F);
        self.emit8(0x05);
    }

    fn ret(self: *IRCodegen) void {
        self.emit8(0xC3);
    }

    fn emitLeaveRet(self: *IRCodegen) void {
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xEC); // mov rsp, rbp
        self.emit8(0x5D); // pop rbp
        self.ret();
    }

    fn emitTestRax(self: *IRCodegen) void {
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0); // test rax, rax
    }

    fn emitJe(self: *IRCodegen) u32 {
        self.emit8(0x0F);
        self.emit8(0x84);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJne(self: *IRCodegen) u32 {
        self.emit8(0x0F);
        self.emit8(0x85);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJmp(self: *IRCodegen) u32 {
        self.emit8(0xE9);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJmpTo(self: *IRCodegen, target: u32) void {
        self.emit8(0xE9);
        const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(self.code_len + 4)));
        self.emit32(@bitCast(disp));
    }

    fn patchJump(self: *IRCodegen, patch_pos: u32) void {
        const disp: i32 = @intCast(@as(i64, @intCast(self.code_len)) - @as(i64, @intCast(patch_pos + 4)));
        std.mem.writeInt(i32, self.code[patch_pos..][0..4], disp, .little);
    }

    fn callOffset(self: *IRCodegen, target: u32) void {
        self.emit8(0xE8);
        const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(self.code_len + 4)));
        self.emit32(@bitCast(disp));
    }

    fn callNamed(self: *IRCodegen, name: []const u8) void {
        self.emit8(0xE8);
        if (self.call_patch_count < self.call_patches.len) {
            var patch = CallPatch{
                .name_buf = undefined,
                .name_len = @intCast(@min(name.len, 64)),
                .patch_pos = self.code_len,
            };
            @memcpy(patch.name_buf[0..patch.name_len], name[0..patch.name_len]);
            self.call_patches[self.call_patch_count] = patch;
            self.call_patch_count += 1;
        } else {
            self.overflowed = true;
        }
        self.emit32(0); // placeholder
    }

    fn leaRipDeferred(self: *IRCodegen, dst: u8, string_idx: u32) void {
        var rex: u8 = 0x48;
        if (dst >= 8) rex |= 0x04;
        self.emit8(rex);
        self.emit8(0x8D);
        self.emit8(0x05 | ((dst & 7) << 3));
        const patch_pos = self.code_len;
        self.emit32(0);
        if (self.patch_count < self.string_patches.len) {
            self.string_patches[self.patch_count] = .{
                .patch_pos = patch_pos,
                .string_offset = self.string_offsets[string_idx],
            };
            self.patch_count += 1;
        } else {
            self.overflowed = true;
        }
    }

    fn subRspImm(self: *IRCodegen, imm: u32) void {
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

    fn subRspImmAdd(self: *IRCodegen, imm: u32) void {
        self.addRspImm(imm); // just restore stack
    }

    fn loadSlotToRax(self: *IRCodegen, slot: u32) void {
        const disp: i32 = -@as(i32, @intCast(slot)) * 8;
        if (disp >= -128 and disp <= 127) {
            self.emit8(0x48);
            self.emit8(0x8B);
            self.emit8(0x45);
            self.emit8(@intCast(disp & 0xFF));
        } else {
            self.emit8(0x48);
            self.emit8(0x8B);
            self.emit8(0x85);
            self.emit32(@bitCast(disp));
        }
    }

    fn storeRaxToSlot(self: *IRCodegen, slot: u32) void {
        const disp: i32 = -@as(i32, @intCast(slot)) * 8;
        if (disp >= -128 and disp <= 127) {
            self.emit8(0x48);
            self.emit8(0x89);
            self.emit8(0x45);
            self.emit8(@intCast(disp & 0xFF));
        } else {
            self.emit8(0x48);
            self.emit8(0x89);
            self.emit8(0x85);
            self.emit32(@bitCast(disp));
        }
    }

    // Load a stack slot directly into any x86-64 general-purpose register.
    // This avoids temporary push/pop and register-swap instructions in the IR
    // arithmetic path. The encoding uses rbp-relative addressing just like
    // loadSlotToRax, including the compact disp8 form for nearby slots.
    fn loadSlotToReg(self: *IRCodegen, reg: u8, slot: u32) void {
        const disp: i32 = -@as(i32, @intCast(slot)) * 8;
        var rex: u8 = 0x48;
        if (reg >= 8) rex |= 0x04;
        self.emit8(rex);
        self.emit8(0x8B);
        if (disp >= -128 and disp <= 127) {
            self.emit8(0x45 | ((reg & 7) << 3));
            self.emit8(@intCast(disp & 0xFF));
        } else {
            self.emit8(0x85 | ((reg & 7) << 3));
            self.emit32(@bitCast(disp));
        }
    }

    fn loadVregToReg(self: *IRCodegen, vreg: u32, reg: u8) void {
        if (vreg == 0) return;
        self.loadSlotToReg(reg, self.getVregSlot(vreg));
    }

    fn storeRegToSlot(self: *IRCodegen, reg: u8, slot: u32) void {
        const disp: i32 = -@as(i32, @intCast(slot)) * 8;
        var rex: u8 = 0x48;
        if (reg >= 8) rex |= 0x04;
        self.emit8(rex);
        self.emit8(0x89);
        if (disp >= -128 and disp <= 127) {
            self.emit8(0x45 | ((reg & 7) << 3));
            self.emit8(@intCast(disp & 0xFF));
        } else {
            self.emit8(0x85 | ((reg & 7) << 3));
            self.emit32(@bitCast(disp));
        }
    }

    fn emitArith(self: *IRCodegen, op: IROp) void {
        switch (op) {
            .add => {
                self.emit8(0x48);
                self.emit8(0x01);
                self.emit8(0xC8); // add rax, rcx
            },
            .sub => {
                self.emit8(0x48);
                self.emit8(0x29);
                self.emit8(0xC8); // sub rax, rcx
            },
            .mul => {
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xAF);
                self.emit8(0xC1); // imul rax, rcx
            },
            .div => {
                self.emit8(0x48);
                self.emit8(0x99); // cqo
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xF9); // idiv rcx
            },
            .@"mod" => {
                self.emit8(0x48);
                self.emit8(0x99); // cqo
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xF9); // idiv rcx
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0xD0); // mov rax, rdx (remainder)
            },
            .shl => {
                self.emit8(0x48);
                self.emit8(0xD3);
                self.emit8(0xE0); // shl rax, cl
            },
            .shr => {
                self.emit8(0x48);
                self.emit8(0xD3);
                self.emit8(0xF8); // sar rax, cl
            },
            .cmp_eq => self.cmpSetcc(0x94),
            .cmp_ne => self.cmpSetcc(0x95),
            .cmp_lt => self.cmpSetcc(0x9C),
            .cmp_le => self.cmpSetcc(0x9E),
            .cmp_gt => self.cmpSetcc(0x9F),
            .cmp_ge => self.cmpSetcc(0x9D),
            else => {},
        }
    }

    fn cmpSetcc(self: *IRCodegen, cc: u8) void {
        self.emit8(0x48);
        self.emit8(0x39);
        self.emit8(0xC8); // cmp rax, rcx
        self.emit8(0x0F);
        self.emit8(cc);
        self.emit8(0xC0); // setXX al
        self.emit8(0x48);
        self.emit8(0x0F);
        self.emit8(0xB6);
        self.emit8(0xC0); // movzx rax, al
    }

    fn emitByteCopy(self: *IRCodegen) void {
        const loop_start = self.code_len;
        self.emit8(0x85);
        self.emit8(0xC9); // test ecx, ecx
        const done_patch = self.emitJe();
        self.emit8(0x8A);
        self.emit8(0x06); // mov al, [rsi]
        self.emit8(0x88);
        self.emit8(0x07); // mov [rdi], al
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC6); // inc rsi
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC7); // inc rdi
        self.emit8(0xFF);
        self.emit8(0xC9); // dec ecx
        self.emitJmpTo(loop_start);
        self.patchJump(done_patch);
    }

    fn emitHeapInit(self: *IRCodegen) void {
        self.mov64imm(0, 9);
        self.xorReg(7, 7);
        self.mov64imm(6, 0x100000);
        self.mov64imm(2, 3);
        self.mov64imm(10, 0x22);
        self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
        self.xorReg(9, 9);
        self.syscallInst();
        self.movRegReg(1, 0); // rbx = heap base
    }

    fn emitTlsInit(self: *IRCodegen) void {
        self.mov64imm(0, 9);
        self.mov64imm(7, 0x4FFFFF000);
        self.mov64imm(6, 0x1000);
        self.mov64imm(2, 3);
        self.mov64imm(10, 0x32);
        self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
        self.xorReg(9, 9);
        self.syscallInst();
    }

    // ═══════════════════════════════════════════════════════════
    // String table
    // ═══════════════════════════════════════════════════════════

    fn addString(self: *IRCodegen, str: []const u8) u32 {
        var i: u32 = 0;
        while (i < self.string_count) : (i += 1) {
            if (self.string_lens[i] == str.len) {
                var found = true;
                for (0..str.len) |j| {
                    if (self.rodata[self.string_offsets[i] + j] != str[j]) {
                        found = false;
                        break;
                    }
                }
                if (found) return i;
            }
        }
        if (@as(usize, self.string_count) >= self.string_offsets.len or str.len + 1 > self.rodata.len - @as(usize, self.rodata_len)) { self.overflowed = true; return 0; }
        const idx = self.string_count;
        const off = self.rodata_len;
        for (str) |ch| { self.rodata[self.rodata_len] = ch; self.rodata_len += 1; }
        self.rodata[self.rodata_len] = 0;
        self.rodata_len += 1;
        self.string_offsets[self.string_count] = off;
        self.string_lens[self.string_count] = @intCast(str.len);
        self.string_count += 1;
        return idx;
    }

    // ═══════════════════════════════════════════════════════════
    // PrintInt native routine
    // ═══════════════════════════════════════════════════════════

    fn emitPrintIntRoutine(self: *IRCodegen) void {
        self.printint_offset = self.code_len;
        self.subRspImm(40);
        // lea rsi, [rsp+39]
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x74);
        self.emit8(0x24);
        self.emit8(39);
        // mov byte [rsi], '\n'
        self.emit8(0xC6);
        self.emit8(0x06);
        self.emit8('\n');
        // mov rax, rdi
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xF8);
        // xor r8d, r8d
        self.emit8(0x45);
        self.emit8(0x31);
        self.emit8(0xC0);
        // test rax, rax
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        // jns +9
        self.emit8(0x79);
        self.emit8(9);
        // neg rax
        self.emit8(0x48);
        self.emit8(0xF7);
        self.emit8(0xD8);
        // mov r8d, 1
        self.emit8(0x41);
        self.emit8(0xB8);
        self.emit32(1);

        const div_loop = self.code_len;
        // mov r9d, 10
        self.emit8(0x41);
        self.emit8(0xB9);
        self.emit32(10);
        // xor edx, edx
        self.emit8(0x31);
        self.emit8(0xD2);
        // div r9
        self.emit8(0x49);
        self.emit8(0xF7);
        self.emit8(0xF1);
        // add dl, '0'
        self.emit8(0x80);
        self.emit8(0xC2);
        self.emit8('0');
        // dec rsi
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xCE);
        // mov [rsi], dl
        self.emit8(0x88);
        self.emit8(0x16);
        // test rax, rax
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        // jnz div_loop
        const after_jnz = self.code_len + 2;
        const back_disp: i8 = @intCast(@as(i64, @intCast(div_loop)) - @as(i64, @intCast(after_jnz)));
        self.emit8(0x75);
        self.emit8(@bitCast(back_disp));

        // test r8, r8
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xC0);
        // jz +6
        self.emit8(0x74);
        self.emit8(6);
        // dec rsi
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xCE);
        // mov byte [rsi], '-'
        self.emit8(0xC6);
        self.emit8(0x06);
        self.emit8('-');

        // mov rdx, rsp
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xE2);
        // add rdx, 40
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xC2);
        self.emit8(40);
        // sub rdx, rsi
        self.emit8(0x48);
        self.emit8(0x29);
        self.emit8(0xF2);
        // mov eax, 1 (sys_write)
        self.emit8(0xB8);
        self.emit32(1);
        // mov edi, 1 (stdout)
        self.emit8(0xBF);
        self.emit32(1);
        self.syscallInst();
        self.addRspImm(40);
        self.ret();
    }

    // ═══════════════════════════════════════════════════════════
    // Main compilation entry point
    // ═══════════════════════════════════════════════════════════

    pub fn compile(self: *IRCodegen) void {
        // Fixed-capacity metadata must fail explicitly rather than indexing past its end.
        if (@as(usize, self.ir.fn_count) > self.fns.len) {
            self.overflowed = true;
            return;
        }
        // Collect function info
        for (0..self.ir.fn_count) |i| {
            const f = &self.ir.fns[i];
            self.fns[i] = .{
                .name_start = f.name_start,
                .name_len = f.name_len,
                .ir_fn_idx = @intCast(i),
                .param_count = f.param_count,
                .code_offset = 0,
            };
        }
        self.fn_count = self.ir.fn_count;

        // Emit init code
        self.emitHeapInit();
        self.emitTlsInit();

        // Compile main first (so it gets the lowest address)
        var compiled: [128]bool = .{false} ** 128;
        var main_found = false;
        for (0..self.fn_count) |i| {
            if (eql(self.irFnName(@intCast(i)), "main")) {
                self.compileFn(@intCast(i));
                compiled[i] = true;
                main_found = true;
                break;
            }
        }
        // Compile rest
        for (0..self.fn_count) |i| {
            if (!compiled[i]) self.compileFn(@intCast(i));
        }
        if (!main_found) {
            self.mov64imm(0, 60);
            self.xorReg(7, 7);
            self.syscallInst();
        }

        if (self.overflowed) return;
        self.emitPrintIntRoutine();
        if (self.overflowed) return;
        self.patchCalls();
    }

    fn irFnName(self: *const IRCodegen, idx: u32) []const u8 {
        const f = self.ir.fns[idx];
        return self.src[f.name_start..][0..f.name_len];
    }

    const JumpPatch = struct {
        patch_pos: u32,
        target_block: u16,
    };

    fn compileFn(self: *IRCodegen, fi: u32) void {
        const f = &self.fns[fi];
        const ir_fn = &self.ir.fns[f.ir_fn_idx];
        const name = self.irFnName(fi);
        const is_main = eql(name, "main");

        f.code_offset = self.code_len;
        self.current_fn_idx = fi;
        self.in_main = is_main;
        self.total_locals = ir_fn.total_locals;

        // Reset vreg mapping
        self.vreg_count = 0;

        // Emit prologue
        self.emit8(0x55); // push rbp
        self.movRegReg(5, 4); // mov rbp, rsp
        // Reserve stack space for every local AND every virtual register
        // used by this function. A fixed +64 silently under-allocates when
        // codegen emits more than 64 vregs, corrupting the caller's stack.
        const max_vreg = maxVRegInFn(ir_fn);
        const stack_slots = ir_fn.total_locals + max_vreg;
        const stack_size = stack_slots * 8;
        const aligned = (stack_size + 15) & ~@as(u32, 15);
        if (aligned > 0) {
            self.subRspImm(@intCast(aligned));
        }

        // Store register args to their stack slots
        for (0..ir_fn.param_count) |pi| {
            self.storeRegToSlot(ARG_REGS[pi], ir_fn.param_slots[pi]);
        }        // Reset patch list and block offsets
        self.patch_count_fn = 0;
        if (@as(usize, ir_fn.block_count) > self.block_offsets.len) {
            self.overflowed = true;
            return;
        }
        self.block_count = ir_fn.block_count;
        for (0..self.block_offsets.len) |bi| self.block_offsets[bi] = 0;
        for (0..ir_fn.block_count) |bi| {
            self.block_offsets[bi] = self.code_len;
            const blk = &ir_fn.blocks[bi];
            for (0..blk.inst_count) |ii| {
                self.compileIRInst(blk.insts[ii]);
                if (self.overflowed) return;
            }
        }

        // Epilogue
        if (is_main) {
            self.mov64imm(0, 60);
            self.xorReg(7, 7);
            self.syscallInst();
        } else {
            self.xorReg(0, 0);
            self.emitLeaveRet();
        }

        // Patch forward jumps
        for (0..self.patch_count_fn) |pi| {
            const jp = self.jump_patches_fn[pi];
            const target = self.block_offsets[jp.target_block];
            const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(jp.patch_pos + 4)));
            std.mem.writeInt(i32, self.code[jp.patch_pos..][0..4], disp, .little);
        }
    }

    /// Return the largest virtual-register ID referenced by this function.
    /// Vregs are spilled to stack slots, so the prologue must reserve space for
    /// the highest slot before any instruction executes.
    fn maxVRegInFn(ir_fn: *const IRFn) u32 {
        var max_vreg: u32 = 0;
        for (0..ir_fn.block_count) |bi| {
            const block = &ir_fn.blocks[bi];
            for (0..block.inst_count) |ii| {
                const inst = block.insts[ii];
                max_vreg = @max(max_vreg, inst.dest);
                max_vreg = @max(max_vreg, inst.src1);
                max_vreg = @max(max_vreg, inst.src2);
                for (0..inst.arg_count) |ai| {
                    max_vreg = @max(max_vreg, inst.args[ai]);
                }
            }
        }
        return max_vreg;
    }

    fn getVregSlot(self: *IRCodegen, vreg: u32) u32 {
        // Map virtual register to a stack slot (above total_locals)
        const idx = vreg - 1; // vregs start at 1
        if (idx >= self.vreg_count) {
            // Extend the mapping
            self.vreg_count = idx + 1;
        }
        return self.total_locals + idx + 1; // slots after locals
    }

    fn loadVreg(self: *IRCodegen, vreg: u32) void {
        if (vreg == 0) return;
        const slot = self.getVregSlot(vreg);
        self.loadSlotToRax(slot);
    }

    fn storeVreg(self: *IRCodegen, vreg: u32) void {
        if (vreg == 0) return;
        const slot = self.getVregSlot(vreg);
        self.storeRaxToSlot(slot);
    }

    // ═══════════════════════════════════════════════════════════
    // IR instruction compilation
    // ═══════════════════════════════════════════════════════════

    fn compileIRInst(self: *IRCodegen, inst: IRInst) void {
        switch (inst.op) {
            // ── Constants ──
            .const_int => {
                self.mov64imm(0, @bitCast(inst.imm));
                self.storeVreg(inst.dest);
            },
            .const_str => {
                const str = self.ir.strings[self.ir.string_offsets[inst.str_idx]..][0..self.ir.string_lens[inst.str_idx]];
                const str_idx = self.addString(str);
                self.leaRipDeferred(6, str_idx);
                self.movRegReg(0, 6);
                self.storeVreg(inst.dest);
                // Also store length
                self.mov64imm(2, str.len);
            },

            // ── Memory ──
            .load_local => {
                self.loadSlotToRax(inst.slot);
                self.storeVreg(inst.dest);
            },
            .store_local => {
                self.loadVreg(inst.src1);
                self.storeRaxToSlot(inst.slot);
            },

            // ── Arithmetic ──
            .add, .sub, .mul, .div, .@"mod", .shl, .shr, .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => {
                // Keep lhs in rax and load rhs directly into rcx. The previous
                // sequence used push/pop plus xchg for every operation; this
                // removes three instructions and avoids touching the stack.
                self.loadVreg(inst.src1);
                self.loadVregToReg(inst.src2, 1); // rcx = rhs
                self.emitArith(inst.op);
                self.storeVreg(inst.dest);
            },

            // ── Unary ──
            .neg => {
                self.loadVreg(inst.src1);
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xD8); // neg rax
                self.storeVreg(inst.dest);
            },
            .logic_not => {
                self.loadVreg(inst.src1);
                self.emitTestRax();
                self.emit8(0x0F);
                self.emit8(0x94);
                self.emit8(0xC0); // sete al
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xB6);
                self.emit8(0xC0); // movzx rax, al
                self.storeVreg(inst.dest);
            },

            // ── Control flow ──
            .jump => {
                const target = self.block_offsets[inst.target_block];
                if (target > 0) {
                    self.emitJmpTo(target);
                } else {
                    // Forward jump: emit placeholder
                    self.emit8(0xE9);
                    if (self.patch_count_fn < self.jump_patches_fn.len) {
                        self.jump_patches_fn[self.patch_count_fn] = .{ .patch_pos = self.code_len, .target_block = inst.target_block };
                        self.patch_count_fn += 1;
                    }
                    self.emit32(0);
                }
            },
            .cond_jump => {
                self.loadVreg(inst.src1);
                self.emitTestRax();
                const patch = self.emitJe();
                // true branch
                const true_target = self.block_offsets[inst.target_block];
                if (true_target > 0) {
                    self.emitJmpTo(true_target);
                } else {
                    self.emit8(0xE9);
                    if (self.patch_count_fn < self.jump_patches_fn.len) {
                        self.jump_patches_fn[self.patch_count_fn] = .{ .patch_pos = self.code_len, .target_block = inst.target_block };
                        self.patch_count_fn += 1;
                    }
                    self.emit32(0);
                }
                // false branch
                self.patchJump(patch);
                const false_target = self.block_offsets[inst.alt_block];
                if (false_target > 0) {
                    self.emitJmpTo(false_target);
                } else {
                    self.emit8(0xE9);
                    if (self.patch_count_fn < self.jump_patches_fn.len) {
                        self.jump_patches_fn[self.patch_count_fn] = .{ .patch_pos = self.code_len, .target_block = inst.alt_block };
                        self.patch_count_fn += 1;
                    }
                    self.emit32(0);
                }
            },
            .ret => {
                if (inst.src1 != 0) {
                    self.loadVreg(inst.src1);
                } else {
                    self.xorReg(0, 0);
                }
                if (self.in_main) {
                    self.movRegReg(7, 0);
                    self.mov64imm(0, 60);
                    self.syscallInst();
                } else {
                    self.emitLeaveRet();
                }
            },

            // ── Calls ──
            .call => {
                const callee_name = self.irFnNameByStr(inst.fn_name_start, inst.fn_name_len);
                // Push args in reverse order
                var ai: i32 = @intCast(inst.arg_count);
                while (ai > 0) {
                    ai -= 1;
                    self.loadVreg(inst.args[@intCast(ai)]);
                    self.pushReg(0);
                }
                // Pop into arg registers
                var ri: usize = inst.arg_count;
                while (ri > 0) {
                    ri -= 1;
                    self.popReg(ARG_REGS[ri]);
                }
                self.callNamed(callee_name);
                if (inst.dest != 0) {
                    self.storeVreg(inst.dest);
                }
            },

            // ── Builtins ──
            .call_print, .call_println => {
                self.loadVreg(inst.args[0]);
                self.movRegReg(6, 0); // rsi = ptr
                self.mov64imm(0, 1); // sys_write
                self.mov64imm(7, 1); // stdout
                self.syscallInst();
                if (inst.op == .call_println) {
                    const nl_idx = self.addString("\n");
                    self.leaRipDeferred(6, nl_idx);
                    self.mov64imm(0, 1);
                    self.mov64imm(7, 1);
                    self.mov64imm(2, 1);
                    self.syscallInst();
                }
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeVreg(inst.dest);
                }
            },
            .call_print_int => {
                self.loadVreg(inst.args[0]);
                self.movRegReg(7, 0); // rdi = value
                self.emit8(0xE8);
                const patch = self.code_len;
                self.emit32(0);
                if (self.printint_patch_count < self.printint_patches.len) {
                    self.printint_patches[self.printint_patch_count] = patch;
                    self.printint_patch_count += 1;
                } else {
                    self.overflowed = true;
                }
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeVreg(inst.dest);
                }
            },
            .call_exit => {
                self.loadVreg(inst.args[0]);
                self.movRegReg(7, 0);
                self.mov64imm(0, 60);
                self.syscallInst();
            },
            .call_sizeof => {
                if (inst.dest != 0) {
                    self.mov64imm(0, 8);
                    self.storeVreg(inst.dest);
                }
            },
            .call_syscall => {
                // Push args in reverse order
                var ai: i32 = @intCast(inst.arg_count);
                while (ai > 0) {
                    ai -= 1;
                    self.loadVreg(inst.args[@intCast(ai)]);
                    self.pushReg(0);
                }
                const sc_regs = [_]u8{ 0, 7, 6, 2, 10, 8 };
                var ri: usize = inst.arg_count;
                while (ri > 0) {
                    ri -= 1;
                    self.popReg(sc_regs[ri]);
                }
                self.syscallInst();
                if (inst.dest != 0) {
                    self.storeVreg(inst.dest);
                }
            },
            .call_malloc => {
                self.loadVreg(inst.args[0]);
                self.movRegReg(7, 0);
                self.mov64imm(6, 7);
                self.mov64imm(10, 0x22);
                self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
                self.xorReg(9, 9);
                self.mov64imm(0, 9);
                self.syscallInst();
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_free => {
                // no-op
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeVreg(inst.dest);
                }
            },
            .call_array_new => {
                // args: count, elem_size
                self.loadVreg(inst.args[0]); // count
                self.movRegReg(6, 0); // rsi = count
                self.emit8(0x48); self.emit8(0xC1); self.emit8(0xE6); self.emit8(0x03); // shl rsi, 3
                self.emit8(0x48); self.emit8(0x83); self.emit8(0xC6); self.emit8(0x10); // add rsi, 16
                self.pushReg(1); // save count
                self.mov64imm(0, 9);
                self.xorReg(7, 7);
                self.mov64imm(2, 3);
                self.mov64imm(10, 0x22);
                self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
                self.xorReg(9, 9);
                self.syscallInst();
                // Init header
                self.emit8(0xC7); self.emit8(0x00); self.emit32(0); // mov [rax], 0 (len)
                self.popReg(1); // rcx = count
                self.emit8(0x89); self.emit8(0x48); self.emit8(0x04); // mov [rax+4], ecx
                self.emit8(0x48); self.emit8(0x83); self.emit8(0xC0); self.emit8(0x10); // add rax, 16
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_array_push => {
                self.loadVreg(inst.args[0]); // arr
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // value
                self.emit8(0x48); self.emit8(0x8B); self.emit8(0x3C); self.emit8(0x24); // mov rdi, [rsp]
                self.emit8(0x8B); self.emit8(0x4F); self.emit8(0xF0); // mov ecx, [rdi-16]
                self.emit8(0x48); self.emit8(0x8D); self.emit8(0x14); self.emit8(0xCF); // lea rdx, [rdi+rcx*8]
                self.emit8(0x48); self.emit8(0x89); self.emit8(0x02); // mov [rdx], rax
                self.emit8(0xFF); self.emit8(0x47); self.emit8(0xF0); // inc dword [rdi-16]
                self.popReg(0);
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_array_get => {
                self.loadVreg(inst.args[0]); // arr
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // index
                self.popReg(6); // rsi = arr
                self.emit8(0x48); self.emit8(0x8D); self.emit8(0x04); self.emit8(0xC6); // lea rax, [rsi+rax*8]
                self.emit8(0x48); self.emit8(0x8B); self.emit8(0x00); // mov rax, [rax]
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_array_set => {
                self.loadVreg(inst.args[0]); // arr
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // index
                self.pushReg(0);
                self.loadVreg(inst.args[2]); // value
                self.movRegReg(1, 0); // rcx = value
                self.popReg(2); // rdx = index
                self.popReg(6); // rsi = arr
                self.emit8(0x48); self.emit8(0x8D); self.emit8(0x04); self.emit8(0xD6); // lea rax, [rsi+rdx*8]
                self.emit8(0x48); self.emit8(0x89); self.emit8(0x08); // mov [rax], rcx
                self.movRegReg(0, 6); // return arr
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_array_len => {
                self.loadVreg(inst.args[0]);
                self.emit8(0x8B); self.emit8(0x40); self.emit8(0xF0); // mov eax, [rax-16]
                self.emit8(0x48); self.emit8(0x0F); self.emit8(0xB6); self.emit8(0xC0); // movzx rax, eax
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_array_free => {
                // no-op
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeVreg(inst.dest);
                }
            },
            .call_memcpy => {
                self.loadVreg(inst.args[0]); // dst
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // src
                self.pushReg(0);
                self.loadVreg(inst.args[2]); // len
                self.movRegReg(1, 0); // rcx = len
                self.popReg(6); // rsi = src
                self.popReg(7); // rdi = dst
                self.emitByteCopy();
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeVreg(inst.dest);
                }
            },
            .call_memset => {
                self.loadVreg(inst.args[0]); // dst
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // val
                self.pushReg(0);
                self.loadVreg(inst.args[2]); // len
                self.movRegReg(1, 0); // rcx = len
                self.popReg(2); // rdx = val
                self.popReg(7); // rdi = dst
                const mset_loop = self.code_len;
                self.emit8(0x85); self.emit8(0xC9); // test ecx, ecx
                const mset_done = self.emitJe();
                self.emit8(0x88); self.emit8(0x17); // mov [rdi], dl
                self.emit8(0x48); self.emit8(0xFF); self.emit8(0xC7); // inc rdi
                self.emit8(0xFF); self.emit8(0xC9); // dec ecx
                self.emitJmpTo(mset_loop);
                self.patchJump(mset_done);
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeVreg(inst.dest);
                }
            },
            .call_string_new => {
                self.pushReg(12);
                self.pushReg(13);
                self.loadVreg(inst.args[0]); // ptr
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // len
                self.emit8(0x49); self.emit8(0x89); self.emit8(0xC4); // mov r12, rax
                self.emit8(0x48); self.emit8(0x8D); self.emit8(0x70); self.emit8(0x08); // lea rsi, [rax+8]
                self.mov64imm(0, 9); // sys_mmap
                self.xorReg(7, 7);
                self.mov64imm(2, 3);
                self.mov64imm(10, 0x22);
                self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
                self.xorReg(9, 9);
                self.syscallInst();
                self.emit8(0x49); self.emit8(0x89); self.emit8(0xC5); // mov r13, rax
                self.emit8(0x44); self.emit8(0x89); self.emit8(0x20); // mov [rax], r12d
                self.emit8(0x48); self.emit8(0x8D); self.emit8(0x78); self.emit8(0x08); // lea rdi, [rax+8]
                self.popReg(6); // rsi = ptr
                self.movRegReg(1, 12); // rcx = len
                self.emitByteCopy();
                self.emit8(0x4C); self.emit8(0x89); self.emit8(0xE8); // mov rax, r13
                self.emit8(0x48); self.emit8(0x83); self.emit8(0xC0); self.emit8(0x08); // add rax, 8
                self.popReg(13);
                self.popReg(12);
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_string_len => {
                self.loadVreg(inst.args[0]);
                self.emit8(0x8B); self.emit8(0x40); self.emit8(0xF8); // mov eax, [rax-8]
                self.emit8(0x48); self.emit8(0x0F); self.emit8(0xB6); self.emit8(0xC0); // movzx rax, eax
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_string_sub => {
                self.pushReg(12);
                self.pushReg(13);
                self.loadVreg(inst.args[0]); // str
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // start
                self.pushReg(0);
                self.loadVreg(inst.args[2]); // sub_len
                self.emit8(0x49); self.emit8(0x89); self.emit8(0xC4); // mov r12, rax
                self.emit8(0x48); self.emit8(0x8D); self.emit8(0x70); self.emit8(0x08); // lea rsi, [rax+8]
                self.mov64imm(0, 9); // sys_mmap
                self.xorReg(7, 7);
                self.mov64imm(2, 3);
                self.mov64imm(10, 0x22);
                self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
                self.xorReg(9, 9);
                self.syscallInst();
                self.emit8(0x49); self.emit8(0x89); self.emit8(0xC5); // mov r13, rax
                self.emit8(0x44); self.emit8(0x89); self.emit8(0x20); // mov [rax], r12d
                self.emit8(0x48); self.emit8(0x8D); self.emit8(0x78); self.emit8(0x08); // lea rdi, [rax+8]
                self.popReg(2); // rdx = start
                self.popReg(6); // rsi = str
                self.emit8(0x48); self.emit8(0x01); self.emit8(0xD6); // add rsi, rdx
                self.movRegReg(1, 12); // rcx = sub_len
                self.emitByteCopy();
                self.emit8(0x4C); self.emit8(0x89); self.emit8(0xE8); // mov rax, r13
                self.emit8(0x48); self.emit8(0x83); self.emit8(0xC0); self.emit8(0x08); // add rax, 8
                self.popReg(13);
                self.popReg(12);
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_string_concat => {
                self.pushReg(12);
                self.pushReg(13);
                self.pushReg(14);
                self.pushReg(15);
                self.loadVreg(inst.args[0]); // a
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // b
                self.pushReg(0); // [rsp]=b, [rsp+8]=a
                self.emit8(0x48); self.emit8(0x8B); self.emit8(0x44); self.emit8(0x24); self.emit8(0x08); // mov rax, [rsp+8] = a
                self.emit8(0x8B); self.emit8(0x48); self.emit8(0xF8); // mov ecx, [rax-8] = len_a
                self.pushReg(1); // [rsp]=len_a, [rsp+8]=b, [rsp+16]=a
                self.emit8(0x48); self.emit8(0x8B); self.emit8(0x44); self.emit8(0x24); self.emit8(0x08); // mov rax, [rsp+8] = b
                self.emit8(0x8B); self.emit8(0x50); self.emit8(0xF8); // mov edx, [rax-8] = len_b
                self.pushReg(2); // [rsp]=len_b, [rsp+8]=len_a, [rsp+16]=b, [rsp+24]=a
                self.emit8(0x01); self.emit8(0xD1); // add ecx, edx
                self.emit8(0x83); self.emit8(0xC1); self.emit8(0x08); // add ecx, 8
                self.pushReg(1); // [rsp]=total...
                self.emit8(0x48); self.emit8(0x8B); self.emit8(0x34); self.emit8(0x24); // mov rsi, [rsp] = total
                self.xorReg(7, 7);
                self.mov64imm(2, 3);
                self.mov64imm(10, 0x22);
                self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
                self.xorReg(9, 9);
                self.mov64imm(0, 9); // sys_mmap
                self.syscallInst();
                self.emit8(0x48); self.emit8(0x83); self.emit8(0xC4); self.emit8(0x08); // add rsp, 8
                self.emit8(0x8B); self.emit8(0x4C); self.emit8(0x24); self.emit8(0x00); // mov ecx, [rsp] = len_b
                self.emit8(0x03); self.emit8(0x4C); self.emit8(0x24); self.emit8(0x08); // add ecx, [rsp+8] = len_a
                self.emit8(0x89); self.emit8(0x08); // mov [rax], ecx
                self.pushReg(0); // [rsp]=base
                self.emit8(0x48); self.emit8(0x8D); self.emit8(0x78); self.emit8(0x08); // lea rdi, [rax+8]
                self.emit8(0x8B); self.emit8(0x4C); self.emit8(0x24); self.emit8(0x10); // mov ecx, [rsp+16] = len_a
                self.emit8(0x48); self.emit8(0x8B); self.emit8(0x74); self.emit8(0x24); self.emit8(0x20); // mov rsi, [rsp+32] = a
                self.emitByteCopy();
                self.emit8(0x8B); self.emit8(0x4C); self.emit8(0x24); self.emit8(0x08); // mov ecx, [rsp+8] = len_b
                self.emit8(0x48); self.emit8(0x8B); self.emit8(0x74); self.emit8(0x24); self.emit8(0x18); // mov rsi, [rsp+24] = b
                self.emitByteCopy();
                self.emit8(0x48); self.emit8(0x8B); self.emit8(0x04); self.emit8(0x24); // mov rax, [rsp] = base
                self.emit8(0x48); self.emit8(0x83); self.emit8(0xC0); self.emit8(0x08); // add rax, 8
                self.emit8(0x48); self.emit8(0x83); self.emit8(0xC4); self.emit8(0x28); // add rsp, 40
                self.popReg(15);
                self.popReg(14);
                self.popReg(13);
                self.popReg(12);
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_string_eq => {
                self.loadVreg(inst.args[0]); // a
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // b
                self.popReg(6); // rsi = a
                self.movRegReg(7, 0); // rdi = b
                self.emit8(0x8B); self.emit8(0x4E); self.emit8(0xF8); // mov ecx, [rsi-8] = len_a
                self.emit8(0x3B); self.emit8(0x4F); self.emit8(0xF8); // cmp ecx, [rdi-8] = len_b
                const not_eq = self.emitJne();
                const eq_loop = self.code_len;
                self.emit8(0x85); self.emit8(0xC9); // test ecx, ecx
                const eq_done = self.emitJe();
                self.emit8(0x8A); self.emit8(0x06); // mov al, [rsi]
                self.emit8(0x3A); self.emit8(0x07); // cmp al, [rdi]
                const neq_byte = self.emitJne();
                self.emit8(0x48); self.emit8(0xFF); self.emit8(0xC6); // inc rsi
                self.emit8(0x48); self.emit8(0xFF); self.emit8(0xC7); // inc rdi
                self.emit8(0xFF); self.emit8(0xC9); // dec ecx
                self.emitJmpTo(eq_loop);
                self.patchJump(eq_done);
                self.mov64imm(0, 1);
                const eq_end = self.emitJmp();
                self.patchJump(not_eq);
                self.patchJump(neq_byte);
                self.xorReg(0, 0);
                self.patchJump(eq_end);
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_string_split => {
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeVreg(inst.dest);
                }
            },
            .call_printptr => {
                self.loadVreg(inst.args[0]);
                // Simplified: just use printInt for now
                self.movRegReg(7, 0);
                self.emit8(0xE8);
                const patch = self.code_len;
                self.emit32(0);
                if (self.printint_patch_count < self.printint_patches.len) {
                    self.printint_patches[self.printint_patch_count] = patch;
                    self.printint_patch_count += 1;
                } else {
                    self.overflowed = true;
                }
                if (inst.dest != 0) {
                    self.xorReg(0, 0);
                    self.storeVreg(inst.dest);
                }
            },
            .call_open => {
                self.loadVreg(inst.args[0]); // path
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // flags
                self.pushReg(0);
                if (inst.arg_count >= 3) {
                    self.loadVreg(inst.args[2]); // mode
                    self.movRegReg(2, 0); // rdx = mode
                } else {
                    self.mov64imm(2, 0o644);
                }
                self.popReg(6); // rsi = flags
                self.popReg(7); // rdi = path
                self.mov64imm(0, 2); // sys_open
                self.syscallInst();
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_read => {
                self.loadVreg(inst.args[0]); // fd
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // buf
                self.pushReg(0);
                self.loadVreg(inst.args[2]); // count
                self.movRegReg(2, 0); // rdx = count
                self.popReg(6); // rsi = buf
                self.popReg(7); // rdi = fd
                self.mov64imm(0, 0); // sys_read
                self.syscallInst();
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_write => {
                self.loadVreg(inst.args[0]); // fd
                self.pushReg(0);
                self.loadVreg(inst.args[1]); // buf
                self.pushReg(0);
                self.loadVreg(inst.args[2]); // count
                self.movRegReg(2, 0); // rdx = count
                self.popReg(6); // rsi = buf
                self.popReg(7); // rdi = fd
                self.mov64imm(0, 1); // sys_write
                self.syscallInst();
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },
            .call_close => {
                self.loadVreg(inst.args[0]); // fd
                self.movRegReg(7, 0); // rdi = fd
                self.mov64imm(0, 3); // sys_close
                self.syscallInst();
                if (inst.dest != 0) self.storeVreg(inst.dest);
            },

            .nop, .struct_decl, .module_import => {},
            else => {},
        }
    }

    fn irFnNameByStr(self: *const IRCodegen, start: u32, len: u32) []const u8 {
        return self.src[start..][0..len];
    }

    // ═══════════════════════════════════════════════════════════
    // Patching & ELF
    // ═══════════════════════════════════════════════════════════

    fn patchCalls(self: *IRCodegen) void {
        for (0..self.call_patch_count) |i| {
            const p = self.call_patches[i];
            const name = p.name_buf[0..p.name_len];
            const fi = self.findFn(name) orelse {
                // A malformed program must return a compiler error, not terminate
                // the host process (especially important for library/test use).
                printErr("IRCodegen error: call to undefined function '");
                printErr(name);
                printErr("'\n");
                self.invalid_reference = true;
                return;
            };
            const target = self.fns[fi].code_offset;
            const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(p.patch_pos + 4)));
            std.mem.writeInt(i32, self.code[p.patch_pos..][0..4], disp, .little);
        }
        for (0..self.printint_patch_count) |i| {
            const patch_pos = self.printint_patches[i];
            const target = self.printint_offset;
            const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(patch_pos + 4)));
            std.mem.writeInt(i32, self.code[patch_pos..][0..4], disp, .little);
        }
    }

    pub fn patchStrings(self: *IRCodegen) void {
        for (0..self.patch_count) |i| {
            const p = self.string_patches[i];
            const disp: i32 = @intCast(@as(i64, @intCast(self.code_len + p.string_offset)) - @as(i64, @intCast(p.patch_pos + 4)));
            std.mem.writeInt(i32, self.code[p.patch_pos..][0..4], disp, .little);
        }
    }

    fn findFn(self: *const IRCodegen, name: []const u8) ?u32 {
        for (0..self.fn_count) |i| {
            if (eql(self.irFnName(@intCast(i)), name)) return @intCast(i);
        }
        return null;
    }

    pub fn requiredOutputSize(self: *const IRCodegen) usize {
        const header_size: usize = 64;
        const phdr_size: usize = 56;
        const num_phdrs: usize = 2;
        const raw_offset = header_size + phdr_size * num_phdrs;
        const code_file_offset = (raw_offset + 0xFFF) & ~@as(usize, 0xFFF);
        return code_file_offset + @as(usize, self.code_len) + @as(usize, self.rodata_len);
    }

    pub fn generateELF(self: *IRCodegen, output: []u8) usize {
        // This API is public and must not assume its caller allocated the exact
        // size returned by requiredOutputSize(). Fail safely on undersized buffers.
        if (output.len < self.requiredOutputSize()) return 0;

        var pos: usize = 0;
        const header_size: u64 = 64;
        const phdr_size: u64 = 56;
        const num_phdrs: u64 = 2;
        const total_size: u64 = self.code_len + self.rodata_len;
        const raw_offset = header_size + phdr_size * num_phdrs;
        const code_file_offset = (raw_offset + 0xFFF) & ~@as(u64, 0xFFF);
        const code_vaddr: u64 = 0x400000;
        const entry = code_vaddr + code_file_offset;

        // ELF Header
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

        // PT_LOAD
        write32(output[pos..][0..4], 1); pos += 4;
        write32(output[pos..][0..4], 5); pos += 4;
        write64(output[pos..][0..8], 0); pos += 8;
        write64(output[pos..][0..8], code_vaddr); pos += 8;
        write64(output[pos..][0..8], code_vaddr); pos += 8;
        write64(output[pos..][0..8], code_file_offset + total_size); pos += 8;
        write64(output[pos..][0..8], code_file_offset + total_size + 0x10000); pos += 8;
        write64(output[pos..][0..8], 0x1000); pos += 8;

        // PT_GNU_STACK
        write32(output[pos..][0..4], 0x6474e551); pos += 4;
        write32(output[pos..][0..4], 7); pos += 4;
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
        @memcpy(output[pos..][0..self.rodata_len], self.rodata[0..self.rodata_len]);
        pos += self.rodata_len;
        return pos;
    }

    // ── Peephole ──
    pub fn peepholeOptimize(self: *IRCodegen) void {
        self.nopRedundantMovs();
        self.convertShortJumps();
    }

    fn nopRedundantMovs(self: *IRCodegen) void {
        var i: u32 = 0;
        while (i + 2 < self.code_len) {
            if ((self.code[i] == 0x48 or self.code[i] == 0x49) and self.code[i + 1] == 0x89) {
                const modrm = self.code[i + 2];
                if ((modrm >> 6) == 0x03 and ((modrm >> 3) & 0x07) == (modrm & 0x07)) {
                    self.code[i] = 0x0F;
                    self.code[i + 1] = 0x1F;
                    self.code[i + 2] = 0x00;
                    i += 3;
                    continue;
                }
            }
            i += 1;
        }
    }

    fn convertShortJumps(self: *IRCodegen) void {
        if (self.code_len == 0) return;

        // Phase 1: mark jumps that can be shortened to rel8 ───────────
        var convert: [65536]bool = .{false} ** 65536;
        var shift: i32 = 0;
        var i: u32 = 0;
        while (i < self.code_len) {
            // Jcc rel32: 0F 8x xx xx xx xx (6 bytes → 2 bytes)
            if (i + 5 < self.code_len and self.code[i] == 0x0F and
                self.code[i + 1] >= 0x84 and self.code[i + 1] <= 0x8F)
            {
                const d32: i32 = @bitCast(std.mem.readInt(u32, self.code[i + 2 ..][0..4], .little));
                const target: i64 = @as(i64, @intCast(i)) + 6 + @as(i64, @intCast(d32));
                if (target >= 0 and target < self.code_len) {
                    const new_d: i32 = d32 + 4;
                    if (new_d >= -128 and new_d <= 127) {
                        convert[i] = true;
                        shift -= 4;
                    }
                }
                i += 6;
                continue;
            }
            // JMP rel32: E9 xx xx xx xx (5 bytes → 2 bytes)
            if (i + 4 < self.code_len and self.code[i] == 0xE9) {
                const d32: i32 = @bitCast(std.mem.readInt(u32, self.code[i + 1 ..][0..4], .little));
                const target: i64 = @as(i64, @intCast(i)) + 5 + @as(i64, @intCast(d32));
                if (target >= 0 and target < self.code_len) {
                    const new_d: i32 = d32 + 3;
                    if (new_d >= -128 and new_d <= 127) {
                        convert[i] = true;
                        shift -= 3;
                    }
                }
                i += 5;
                continue;
            }
            // CALL rel32: E8 xx xx xx xx — skip to avoid false positive on displacement bytes
            if (i + 4 < self.code_len and self.code[i] == 0xE8) {
                i += 5;
                continue;
            }
            // MOV [rbp+disp32]: 48 89/8B 85 xx xx xx xx — skip 7 bytes to avoid false 0xE9 in disp32
            if (i + 6 < self.code_len and self.code[i] == 0x48 and
                (self.code[i + 1] == 0x89 or self.code[i + 1] == 0x8B) and
                self.code[i + 2] == 0x85)
            {
                i += 7;
                continue;
            }
            // SUB rsp, imm32: 48 81 EC xx xx xx xx — skip 7 bytes
            if (i + 6 < self.code_len and self.code[i] == 0x48 and
                self.code[i + 1] == 0x81 and self.code[i + 2] == 0xEC)
            {
                i += 7;
                continue;
            }
            // MOV rax, imm64: 48 B8 xx... — skip 10 bytes
            if (i + 9 < self.code_len and self.code[i] == 0x48 and
                self.code[i + 1] >= 0xB8 and self.code[i + 1] <= 0xBF)
            {
                i += 10;
                continue;
            }
            i += 1;
        }
        if (shift == 0) return;

        // Phase 2: compute shift_at[i] = cumulative bytes removed before position i
        var shift_at: [65537]i32 = .{@as(i32, 0)} ** 65537;
        shift = 0;
        i = 0;
        while (i <= self.code_len) {
            shift_at[i] = shift;
            if (i < self.code_len and convert[i]) {
                if (self.code[i] == 0x0F) {
                    shift -= 4; // Jcc: 6 → 2, saves 4 bytes
                } else {
                    shift -= 3; // JMP: 5 → 2, saves 3 bytes
                }
            }
            i += 1;
        }
        const final_shift = shift_at[self.code_len];

        // Phase 3: rebuild code buffer with correct displacements ──────
        var new_code: [65536]u8 = undefined;
        i = 0;
        while (i < self.code_len) {
            const new_pos: u32 = @intCast(@as(i32, @intCast(i)) + shift_at[i]);

            // Jcc rel32
            if (i + 5 < self.code_len and self.code[i] == 0x0F and
                self.code[i + 1] >= 0x84 and self.code[i + 1] <= 0x8F)
            {
                const d32: i32 = @bitCast(std.mem.readInt(u32, self.code[i + 2 ..][0..4], .little));
                const target: i64 = @as(i64, @intCast(i)) + 6 + @as(i64, @intCast(d32));
                if (convert[i]) {
                    const t: u32 = @intCast(target);
                    const adj: i32 = if (target >= 0 and target < self.code_len) shift_at[t] - shift_at[i] else 0;
                    const new_d: i32 = d32 + 4 + adj;
                    new_code[new_pos] = 0x70 | (self.code[i + 1] & 0x0F);
                    new_code[new_pos + 1] = @truncate(@as(u32, @bitCast(new_d)));
                } else {
                    const t: u32 = @intCast(target);
                    const adj: i32 = if (target >= 0 and target < self.code_len) shift_at[t] - shift_at[i] else 0;
                    const new_d: i32 = d32 + adj;
                    new_code[new_pos] = self.code[i];
                    new_code[new_pos + 1] = self.code[i + 1];
                    std.mem.writeInt(i32, new_code[new_pos + 2 ..][0..4], new_d, .little);
                }
                i += 6;
                continue;
            }

            // JMP rel32
            if (i + 4 < self.code_len and self.code[i] == 0xE9) {
                const d32: i32 = @bitCast(std.mem.readInt(u32, self.code[i + 1 ..][0..4], .little));
                const target: i64 = @as(i64, @intCast(i)) + 5 + @as(i64, @intCast(d32));
                if (convert[i]) {
                    const t: u32 = @intCast(target);
                    const adj: i32 = if (target >= 0 and target < self.code_len) shift_at[t] - shift_at[i] else 0;
                    const new_d: i32 = d32 + 3 + adj;
                    new_code[new_pos] = 0xEB;
                    new_code[new_pos + 1] = @truncate(@as(u32, @bitCast(new_d)));
                } else {
                    const t: u32 = @intCast(target);
                    const adj: i32 = if (target >= 0 and target < self.code_len) shift_at[t] - shift_at[i] else 0;
                    const new_d: i32 = d32 + adj;
                    new_code[new_pos] = 0xE9;
                    std.mem.writeInt(i32, new_code[new_pos + 1 ..][0..4], new_d, .little);
                }
                i += 5;
                continue;
            }

            // CALL rel32: E8 xx xx xx xx
            if (i + 4 < self.code_len and self.code[i] == 0xE8) {
                const d32: i32 = @bitCast(std.mem.readInt(u32, self.code[i + 1 ..][0..4], .little));
                const target: i64 = @as(i64, @intCast(i)) + 5 + @as(i64, @intCast(d32));
                new_code[new_pos] = 0xE8;
                if (target >= 0 and target < self.code_len) {
                    const t: u32 = @intCast(target);
                    const new_d: i32 = d32 + (shift_at[t] - shift_at[i]);
                    std.mem.writeInt(i32, new_code[new_pos + 1 ..][0..4], new_d, .little);
                } else {
                    // Target outside code buffer (e.g. printInt helper) — copy as-is
                    @memcpy(new_code[new_pos + 1 ..][0..4], self.code[i + 1 ..][0..4]);
                }
                i += 5;
                continue;
            }

            // Default: copy single byte
            new_code[new_pos] = self.code[i];
            i += 1;
        }

        const new_len: u32 = @intCast(@as(i32, @intCast(self.code_len)) + final_shift);
        @memcpy(self.code[0..new_len], new_code[0..new_len]);
        self.code_len = new_len;
    }
};
