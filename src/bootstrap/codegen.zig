// ════════════════════════════════════════════════════════════════════════════
// x86-64 CODEGEN + ELF OUTPUT + PEEPHOLE OPTIMIZATIONS
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const lex = @import("lexer.zig");
const parser = @import("parser.zig");

const TokenKind = lex.TokenKind;
const AST = parser.AST;
const ASTNode = parser.ASTNode;
const NodeKind = parser.NodeKind;
const StructDef = parser.StructDef;

const eql = util.eql;
const printErr = util.printErr;
const printUsize = util.printUsize;
const sysExit = util.sysExit;
const write16 = util.write16;
const write32 = util.write32;
const write64 = util.write64;

// ════════════════════════════════════════════════════════════════════════════
// x86-64 CODEGEN + ELF OUTPUT
// ════════════════════════════════════════════════════════════════════════════

const StringPatch = struct {
    patch_pos: u32,
    string_offset: u32,
};

const LocalVar = struct {
    name_start: u32,
    name_len: u32,
    slot: u32, // address = rbp - (slot * 8)
    is_hidden: bool = false, // name lives in Codegen.hidden_names, not in src
};

const FnInfo = struct {
    name_start: u32,
    name_len: u32,
    ast_idx: u32,
    param_count: u32,
    code_offset: u32,
};

const CallPatch = struct {
    name_buf: [64]u8,
    name_len: u8,
    patch_pos: u32,
};

const LoopCtx = struct {
    break_patches: [16]u32,
    break_count: u32,
    continue_target: u32,
    is_for: bool = false,
    continue_patches: [16]u32 = undefined,
    continue_count: u32 = 0,
};

const ThreadFnPatch = struct {
    name_start: u32,
    name_len: u32,
    code_pos: u32, // position of the imm64 in the code buffer (skip REX+opcode = +2)
    source_id: u32,
};

const ARG_REGS = [_]u8{ 7, 6, 2, 1, 8, 9 }; // rdi, rsi, rdx, rcx, r8, r9

pub const Codegen = struct {
    code: [65536]u8,
    code_len: u32,
    rodata: [65536]u8,
    rodata_len: u32,
    string_patches: [512]StringPatch,
    patch_count: u32,
    string_offsets: [256]u32,
    string_lens: [256]u32,
    string_count: u32,
    src: []const u8,
    ast: *const AST,

    locals: [256]LocalVar,
    local_count: u32,
    next_slot: u32,
    hidden_names: [64][8]u8 = undefined,
    hidden_count: u32 = 0,
    total_slots: u32,
    in_main: bool,

    fns: [128]FnInfo,
    fn_count: u32,
    call_patches: [256]CallPatch,
    call_patch_count: u32,
    printint_patches: [64]u32,
    printint_patch_count: u32,

    loops: [8]LoopCtx,
    loop_depth: u32,

    printint_offset: u32,

    // Struct support
    source_id: u32,
    // Thread function pointer patches
    thread_fn_patches: [64]ThreadFnPatch,
    thread_fn_patch_count: u32,
    // @string_split compiled helper
    stringsplit_offset: u32,
    stringsplit_patches: [64]u32,
    stringsplit_patch_count: u32,
    // Tail-call optimization: index of the function being compiled
    current_fn_idx: u32,

    pub fn init(source: []const u8, tree: *const AST) Codegen {
        return .{
            .code = undefined,
            .code_len = 0,
            .rodata = undefined,
            .rodata_len = 0,
            .string_patches = undefined,
            .patch_count = 0,
            .string_offsets = undefined,
            .string_lens = undefined,
            .string_count = 0,
            .src = source,
            .ast = tree,
            .locals = undefined,
            .local_count = 0,
            .next_slot = 0,
            .total_slots = 0,
            .in_main = false,
            .fns = undefined,
            .fn_count = 0,
            .call_patches = undefined,
            .call_patch_count = 0,
            .printint_patches = undefined,
            .printint_patch_count = 0,
            .loops = undefined,
            .loop_depth = 0,
            .printint_offset = 0,
            .source_id = 0,
            .thread_fn_patches = undefined,
            .thread_fn_patch_count = 0,
            .stringsplit_offset = 0,
            .stringsplit_patches = undefined,
            .stringsplit_patch_count = 0,
            .current_fn_idx = 0,
        };
    }

    // Capacity failures must stop compilation before an unchecked write.
    fn capacityError(message: []const u8) noreturn {
        printErr("Compile error: ");
        printErr(message);
        printErr("\n");
        sysExit(1);
    }

    // ── Emit bytes ──────────────────────────────────────────────
    fn emit8(self: *Codegen, b: u8) void {
        if (@as(usize, self.code_len) >= self.code.len) capacityError("generated code exceeds 64 KiB limit");
        self.code[self.code_len] = b;
        self.code_len += 1;
    }

    fn emit32(self: *Codegen, v: u32) void {
        if (@as(usize, self.code_len) > self.code.len - 4) capacityError("generated code exceeds 64 KiB limit");
        self.code[self.code_len..][0..4].* = .{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24) };
        self.code_len += 4;
    }

    fn emit64(self: *Codegen, v: u64) void {
        if (@as(usize, self.code_len) > self.code.len - 8) capacityError("generated code exceeds 64 KiB limit");
        self.code[self.code_len..][0..8].* = .{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24), @truncate(v >> 32), @truncate(v >> 40), @truncate(v >> 48), @truncate(v >> 56) };
        self.code_len += 8;
    }

    // ── x86-64 instructions ────────────────────────────────────
    fn mov64imm(self: *Codegen, dst: u8, imm: u64) void {
        self.emit8(if (dst >= 8) 0x49 else 0x48);
        self.emit8(0xB8 + (dst & 7));
        self.emit64(imm);
    }

    fn pushReg(self: *Codegen, r: u8) void {
        if (r >= 8) self.emit8(0x41);
        self.emit8(0x50 + (r & 7));
    }

    fn popReg(self: *Codegen, r: u8) void {
        if (r >= 8) self.emit8(0x41);
        self.emit8(0x58 + (r & 7));
    }

    fn movRegReg(self: *Codegen, dst: u8, src: u8) void {
        var rex: u8 = 0x48;
        if (src >= 8) rex |= 0x04;
        if (dst >= 8) rex |= 0x01;
        self.emit8(rex);
        self.emit8(0x89);
        self.emit8(0xC0 | ((src & 7) << 3) | (dst & 7));
    }

    fn xorReg(self: *Codegen, a: u8, b: u8) void {
        var rex: u8 = 0x48;
        if (a >= 8) rex |= 0x04;
        if (b >= 8) rex |= 0x01;
        self.emit8(rex);
        self.emit8(0x31);
        self.emit8(0xC0 | ((b & 7) << 3) | (a & 7));
    }

    fn syscallInst(self: *Codegen) void {
        self.emit8(0x0F);
        self.emit8(0x05);
    }

    fn ret(self: *Codegen) void {
        self.emit8(0xC3);
    }

    /// LEA r64, [rip + disp32] with deferred patch for string addresses
    fn leaRipDeferred(self: *Codegen, dst: u8, string_idx: u32) void {
        var rex: u8 = 0x48;
        if (dst >= 8) rex |= 0x04;
        self.emit8(rex);
        self.emit8(0x8D);
        self.emit8(0x05 | ((dst & 7) << 3));
        const patch_pos = self.code_len;
        self.emit32(0);
        if (self.patch_count >= self.string_patches.len) capacityError("too many string references (limit 512)");
        if (string_idx >= self.string_count) capacityError("invalid string reference during code generation");
        self.string_patches[self.patch_count] = .{
            .patch_pos = patch_pos,
            .string_offset = self.string_offsets[string_idx],
        };
        self.patch_count += 1;
    }

    fn emitJe(self: *Codegen) u32 {
        self.emit8(0x0F);
        self.emit8(0x84);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJne(self: *Codegen) u32 {
        self.emit8(0x0F);
        self.emit8(0x85);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJl(self: *Codegen) u32 {
        self.emit8(0x0F);
        self.emit8(0x8C);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJge(self: *Codegen) u32 {
        self.emit8(0x0F);
        self.emit8(0x8D);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJle(self: *Codegen) u32 {
        self.emit8(0x0F);
        self.emit8(0x8E);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJmp(self: *Codegen) u32 {
        self.emit8(0xE9);
        const patch = self.code_len;
        self.emit32(0);
        return patch;
    }

    fn emitJmpTo(self: *Codegen, target: u32) void {
        self.emit8(0xE9);
        const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(self.code_len + 4)));
        self.emit32(@bitCast(disp));
    }

    fn patchJump(self: *Codegen, patch_pos: u32) void {
        const disp: i32 = @intCast(@as(i64, @intCast(self.code_len)) - @as(i64, @intCast(patch_pos + 4)));
        std.mem.writeInt(i32, self.code[patch_pos..][0..4], disp, .little);
    }

    /// call rel32 to an absolute code offset, resolved immediately
    fn callOffset(self: *Codegen, target: u32) void {
        self.emit8(0xE8);
        const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(self.code_len + 4)));
        self.emit32(@bitCast(disp));
    }

    /// call rel32 to a named user function, patched later
    fn callNamed(self: *Codegen, name: []const u8) void {
        if (name.len > 64) capacityError("function name exceeds 64-byte call-patch limit");
        if (self.call_patch_count >= self.call_patches.len) capacityError("too many deferred function calls");
        self.emit8(0xE8);
        const patch_pos = self.code_len;
        self.emit32(0);
        var patch = CallPatch{
            .name_buf = undefined,
            .name_len = @intCast(name.len),
            .patch_pos = patch_pos,
        };
        @memcpy(patch.name_buf[0..patch.name_len], name);
        self.call_patches[self.call_patch_count] = patch;
        self.call_patch_count += 1;
    }

    // ── Stack frame helpers ─────────────────────────────────────
    fn storeRegToSlot(self: *Codegen, reg: u8, slot: u32) void {
        const disp: i32 = -@as(i32, @intCast(slot)) * 8;
        var rex: u8 = 0x48;
        if (reg >= 8) rex |= 0x04;
        self.emit8(rex);
        self.emit8(0x89); // mov [rbp+disp], reg
        if (disp >= -128 and disp <= 127) {
            self.emit8(0x45 | ((reg & 7) << 3)); // mod=01, disp8
            self.emit8(@bitCast(@as(i8, @intCast(disp))));
        } else {
            self.emit8(0x85 | ((reg & 7) << 3)); // mod=10, disp32
            self.emit32(@bitCast(disp));
        }
    }

    fn storeRaxToSlot(self: *Codegen, slot: u32) void {
        self.storeRegToSlot(0, slot);
    }

    fn loadSlotToRax(self: *Codegen, slot: u32) void {
        const disp: i32 = -@as(i32, @intCast(slot)) * 8;
        self.emit8(0x48);
        self.emit8(0x8B); // mov rax, [rbp+disp]
        if (disp >= -128 and disp <= 127) {
            self.emit8(0x45); // mod=01, disp8
            self.emit8(@bitCast(@as(i8, @intCast(disp))));
        } else {
            self.emit8(0x85); // mod=10, disp32
            self.emit32(@bitCast(disp));
        }
    }

    fn emitLeaveRet(self: *Codegen) void {
        // mov rsp, rbp ; pop rbp ; ret
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xEC);
        self.popReg(5);
        self.ret();
    }

    /// Tail-call optimization: replace `return f(args)` with a jmp when
    /// `f` is the same function.  The sequence is:
    ///   1. Evaluate new args while the current frame is still live.
    ///   2. Load them into the argument registers.
    ///   3. Tear down the current frame.
    ///   4. jmp to the function entry — the prologue creates a fresh frame.
    ///
    /// Key insight: after the epilogue `mov rsp, rbp; pop rbp` rsp points
    /// to the original return address.  The prologue's `push rbp` pushes
    /// the restored rbp below it, so the return address ends up at
    /// rbp+8 — exactly where `ret` expects it.
    fn emitTailCall(self: *Codegen, call_node: ASTNode) void {
        const fi = self.current_fn_idx;
        const target = self.fns[fi].code_offset;

        // Count arguments
        var argc: u32 = 0;
        var ai = call_node.child2;
        while (ai != 0) {
            argc += 1;
            ai = self.ast.nodes[ai].child1;
        }
        if (argc > ARG_REGS.len) return; // unsupported — fall through to normal path

        // 1. Evaluate each argument and push onto the stack.
        //    The current frame is still intact, so locals are accessible.
        ai = call_node.child2;
        while (ai != 0) {
            self.compileExpr(self.ast.nodes[ai].child0);
            self.pushReg(0);
            ai = self.ast.nodes[ai].child1;
        }

        // 2. Pop into argument registers (reverse order for SysV ABI).
        var ri: usize = argc;
        while (ri > 0) {
            ri -= 1;
            self.popReg(ARG_REGS[ri]);
        }

        // 3. Tear down the current frame.
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xEC); // mov rsp, rbp
        self.popReg(5); // pop rbp  (rsp → return address)

        // 4. jmp to function entry — the prologue will push rbp,
        //    set up a new frame, and spill the argument registers.
        self.emit8(0xE9);
        const disp: i32 = @intCast(
            @as(i64, @intCast(target)) - @as(i64, @intCast(self.code_len + 4)),
        );
        self.emit32(@bitCast(disp));
    }

    // ── Symbol tables ───────────────────────────────────────────
    fn nodeText(self: *const Codegen, idx: u32) []const u8 {
        const n = self.ast.nodes[idx];
        if (n.source_id > 0 and n.source_id < self.ast.source_count) {
            return self.ast.nodeTextSrcFrom(n.text_start, n.text_len, n.source_id);
        }
        return self.src[n.text_start..][0..n.text_len];
    }

    /// Get text for a specific source_id.
    fn nodeTextSrcFor(self: *const Codegen, start: u32, length: u32, source_id: u32) []const u8 {
        return self.ast.nodeTextSrcFrom(start, length, source_id);
    }

    fn findLocal(self: *Codegen, name: []const u8) ?u32 {
        var i: u32 = self.local_count;
        while (i > 0) {
            i -= 1;
            const l = self.locals[i];
            const lname = if (l.is_hidden)
                self.hidden_names[@intCast(l.name_start)][0..l.name_len]
            else
                self.src[l.name_start..][0..l.name_len];
            if (eql(lname, name)) return l.slot;
        }
        return null;
    }

    fn defineLocal(self: *Codegen, name: []const u8) void {
        if (self.findLocal(name) != null) {
            printErr("Compile error: redefinition of '");
            printErr(name);
            printErr("'\n");
            sysExit(1);
        }
        if (self.local_count >= self.locals.len) {
            printErr("Compile error: too many local variables\n");
            sysExit(1);
        }
        self.next_slot += 1;
        self.locals[self.local_count] = .{
            .name_start = @intCast(@intFromPtr(name.ptr) - @intFromPtr(self.src.ptr)),
            .name_len = @intCast(name.len),
            .slot = self.next_slot,
        };
        self.local_count += 1;
    }

    /// Define a local without the redefinition check (shadowing allowed).
    /// Hidden names are compiler-generated (stored in hidden_names buffer);
    /// normal names must be slices into the source text.
    fn defineShadowed(self: *Codegen, name: []const u8, hidden: bool) u32 {
        if (self.local_count >= self.locals.len) {
            printErr("Compile error: too many local variables\n");
            sysExit(1);
        }
        self.next_slot += 1;
        if (hidden) {
            if (self.hidden_count >= self.hidden_names.len) {
                printErr("Compile error: too many loop iterations variables\n");
                sysExit(1);
            }
            const hi = self.hidden_count;
            self.hidden_count += 1;
            @memcpy(self.hidden_names[hi][0..name.len], name);
            self.locals[self.local_count] = .{
                .name_start = hi,
                .name_len = @intCast(name.len),
                .slot = self.next_slot,
                .is_hidden = true,
            };
        } else {
            self.locals[self.local_count] = .{
                .name_start = @intCast(@intFromPtr(name.ptr) - @intFromPtr(self.src.ptr)),
                .name_len = @intCast(name.len),
                .slot = self.next_slot,
            };
        }
        self.local_count += 1;
        return self.next_slot;
    }

    fn findFn(self: *Codegen, name: []const u8) ?u32 {
        for (0..self.fn_count) |i| {
            const f = self.fns[i];
            if (eql(self.src[f.name_start..][0..f.name_len], name)) return @intCast(i);
        }
        return null;
    }

    fn collectFns(self: *Codegen) void {
        for (0..self.ast.count) |i| {
            const n = self.ast.nodes[i];
            if (n.kind != .fn_decl) continue;
            if (self.fn_count >= self.fns.len) capacityError("too many functions (limit 128)");
            self.fns[self.fn_count] = .{
                .name_start = n.text_start,
                .name_len = n.text_len,
                .ast_idx = @intCast(i),
                .param_count = @intCast(n.int_val),
                .code_offset = 0,
            };
            self.fn_count += 1;
        }
    }

    /// Pre-pass: count let statements in a block so frame size is known
    /// before emitting the prologue.
    fn countLets(self: *const Codegen, block_idx: u32) u32 {
        var count: u32 = 0;
        var idx = self.ast.nodes[block_idx].child0; // first stmt
        while (idx != 0) {
            const n = self.ast.nodes[idx];
            const next = self.ast.stmt_chains[idx]; // save NEXT before recursing
            switch (n.kind) {
                .let_stmt => count += 1,
                .block => count += self.countLets(idx),
                .if_stmt => {
                    count += self.countLets(n.child1); // then block
                    if (n.child2 != 0) {
                        count += self.countLets(n.child2); // else block
                    }
                },
                .while_stmt => {
                    count += self.countLets(n.child1); // while body
                },
                else => {},
            }
            idx = next; // advance to next sibling statement
        }
        return count;
    }

    fn resetFunctionScope(self: *Codegen, param_count: u32, let_count: u32) void {
        self.local_count = 0;
        self.total_slots = param_count + let_count;
        self.next_slot = param_count; // lets are allocated after param slots
    }

    fn emitPrologue(self: *Codegen, params_head: u32) void {
        const frame = (self.total_slots * 8 + 15) & ~@as(u32, 15);
        self.pushReg(5); // push rbp
        // mov rbp, rsp
        self.emit8(0x48);
        self.emit8(0x89);
        self.emit8(0xE5);
        if (frame > 0) {
            if (frame <= 127) {
                self.emit8(0x48);
                self.emit8(0x83);
                self.emit8(0xEC);
                self.emit8(@intCast(frame));
            } else {
                self.emit8(0x48);
                self.emit8(0x81);
                self.emit8(0xEC);
                self.emit32(frame);
            }
        }
        // Spill register args to their slots
        var pi = params_head;
        var ai: usize = 0;
        var slot: u32 = 1;
        while (pi != 0 and ai < ARG_REGS.len) {
            self.storeRegToSlot(ARG_REGS[ai], slot);
            pi = self.ast.nodes[pi].child1;
            ai += 1;
            slot += 1;
        }
    }

    // ── Patch all deferred references ───────────────────────────
    pub fn patchStrings(self: *Codegen) void {
        for (0..self.patch_count) |i| {
            const p = self.string_patches[i];
            // RIP after the instruction = code_vaddr + patch_pos + 4
            // (patch_pos is where the 4-byte displacement sits;
            //  the instruction ends 4 bytes later)
            const disp: i32 = @intCast(@as(i64, @intCast(self.code_len + p.string_offset)) - @as(i64, @intCast(p.patch_pos + 4)));
            std.mem.writeInt(i32, self.code[p.patch_pos..][0..4], disp, .little);
        }
    }

    fn patchCalls(self: *Codegen) void {
        // Patch user-defined function calls
        for (0..self.call_patch_count) |i| {
            const p = self.call_patches[i];
            const name = p.name_buf[0..p.name_len];
            const fi = self.findFn(name) orelse {
                printErr("Compile error: call to undefined function '");
                printErr(name);
                printErr("'\n");
                sysExit(1);
            };
            const target = self.fns[fi].code_offset;
            const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(p.patch_pos + 4)));
            std.mem.writeInt(i32, self.code[p.patch_pos..][0..4], disp, .little);
        }
        // Patch printInt calls
        for (0..self.printint_patch_count) |i| {
            const patch_pos = self.printint_patches[i];
            const target = self.printint_offset;
            const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(patch_pos + 4)));
            std.mem.writeInt(i32, self.code[patch_pos..][0..4], disp, .little);
        }
        // Patch @string_split calls
        for (0..self.stringsplit_patch_count) |i| {
            const patch_pos = self.stringsplit_patches[i];
            const target = self.stringsplit_offset;
            const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(patch_pos + 4)));
            std.mem.writeInt(i32, self.code[patch_pos..][0..4], disp, .little);
        }
    }

    fn patchThreadFns(self: *Codegen) void {
        for (0..self.thread_fn_patch_count) |i| {
            const p = self.thread_fn_patches[i];
            const src = self.ast.nodeTextSrcFrom(p.name_start, p.name_len, p.source_id);
            const fi = self.findFn(src) orelse {
                printErr("Compile error: @thread_create unknown function '");
                printErr(src);
                printErr("'\n");
                sysExit(1);
            };
            const fn_addr: u64 = self.fns[fi].code_offset + 0x400000;
            std.mem.writeInt(u64, self.code[p.code_pos + 2 ..][0..8], fn_addr, .little);
        }
    }

    // ── String table ────────────────────────────────────────────
    fn addString(self: *Codegen, str: []const u8) u32 {
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
        if (self.string_count >= self.string_offsets.len) capacityError("too many distinct string literals (limit 256)");
        if (str.len >= self.rodata.len or @as(usize, self.rodata_len) > self.rodata.len - str.len - 1) capacityError("string data exceeds 64 KiB read-only data limit");
        const idx = self.string_count;
        const off = self.rodata_len;
        for (str) |ch| {
            self.rodata[self.rodata_len] = ch;
            self.rodata_len += 1;
        }
        self.rodata[self.rodata_len] = 0; // null terminator
        self.rodata_len += 1;

        self.string_offsets[self.string_count] = off;
        self.string_lens[self.string_count] = @intCast(str.len);
        self.string_count += 1;
        return idx;
    }

    // ── Compile program ─────────────────────────────────────────
    pub fn compile(self: *Codegen) void {
        self.collectFns();

        // Emit heap + TLS init at entry point (offset 0)
        self.emitHeapInit();
        self.emitTlsInit();

        // Compile all functions (main comes after init)
        var compiled: [128]bool = .{false} ** 128;
        var main_found = false;
        for (0..self.fn_count) |i| {
            const f = self.fns[i];
            if (eql(self.src[f.name_start..][0..f.name_len], "main")) {
                self.compileFn(@intCast(i));
                compiled[i] = true;
                main_found = true;
                break;
            }
        }
        for (0..self.fn_count) |i| {
            if (!compiled[i]) self.compileFn(@intCast(i));
        }
        if (!main_found) {
            self.mov64imm(0, 60);
            self.xorReg(7, 7);
            self.syscallInst();
        }

        self.emitPrintIntRoutine();
        self.patchCalls();
        self.patchThreadFns();
    }

    fn compileFn(self: *Codegen, fi: u32) void {
        const f = self.fns[fi];
        const decl = self.ast.nodes[f.ast_idx];
        const name = self.src[f.name_start..][0..f.name_len];
        const is_main = eql(name, "main");

        self.fns[fi].code_offset = self.code_len;
        self.current_fn_idx = fi;
        self.in_main = is_main;
        self.loop_depth = 0;

        const let_count = self.countLets(decl.child2);
        self.resetFunctionScope(f.param_count, let_count);

        // Register parameter names as locals in slots 1..N
        var pi = decl.child0;
        while (pi != 0) {
            const pname = self.nodeText(pi);
            if (self.local_count >= self.locals.len) break;
            self.locals[self.local_count] = .{
                .name_start = @intCast(@intFromPtr(pname.ptr) - @intFromPtr(self.src.ptr)),
                .name_len = @intCast(pname.len),
                .slot = self.local_count + 1,
            };
            self.local_count += 1;
            pi = self.ast.nodes[pi].child1;
        }

        self.emitPrologue(decl.child0);
        self.compileBlock(decl.child2);

        if (is_main) {
            // Implicit exit(0)
            self.mov64imm(0, 60);
            self.xorReg(7, 7);
            self.syscallInst();
        } else {
            // Implicit return 0
            self.xorReg(0, 0);
            self.emitLeaveRet();
        }
    }

    /// Native itoa + write routine used by the printInt builtin.
    /// Input: rdi = signed 64-bit integer. Prints digits + newline.
    fn emitPrintIntRoutine(self: *Codegen) void {
        self.printint_offset = self.code_len;

        self.subRspImm(40); // digit buffer on stack
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
        // xor r8d, r8d  (sign flag)
        self.emit8(0x45);
        self.emit8(0x31);
        self.emit8(0xC0);
        // test rax, rax
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0);
        // jns +9 (skip neg & mov r8d,1)
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
        // jnz div_loop (backward rel8)
        const after_jnz = self.code_len + 2;
        const back_disp: i8 = @intCast(@as(i64, @intCast(div_loop)) - @as(i64, @intCast(after_jnz)));
        self.emit8(0x75);
        self.emit8(@bitCast(back_disp));

        // test r8, r8
        self.emit8(0x4D);
        self.emit8(0x85);
        self.emit8(0xC0);
        // jz +6 (skip sign write)
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
        // add rsp, 40
        self.subRspImmAdd(40);
        self.ret();
    }

    fn subRspImmAdd(self: *Codegen, imm: u32) void {
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xC4); // add rsp, imm8
        self.emit8(@intCast(imm));
    }

    fn subRspImm(self: *Codegen, imm: u32) void {
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xEC); // sub rsp, imm8
        self.emit8(@intCast(imm));
    }

    // ── Struct field lookup ─────────────────────────────────────
    fn findStructField(self: *Codegen, struct_idx: u32, field_name: []const u8) ?u32 {
        if (struct_idx >= self.ast.struct_count) return null;
        const sd = self.ast.struct_defs[struct_idx];
        for (0..sd.field_count) |i| {
            const f = sd.fields[i];
            if (self.src[f.name_start..][0..f.name_len].len == field_name.len and
                eql(self.src[f.name_start..][0..f.name_len], field_name))
                return f.offset;
        }
        return null;
    }

    /// Compute the address of an lvalue (field_access or deref) into rax.
    fn compileLValue(self: *Codegen, idx: u32) void {
        const node = self.ast.nodes[idx];
        switch (node.kind) {
            .field_access => {
                self.compileLValue(node.child0); // rax = base address
                const field_name = self.nodeText(idx);
                // Try to determine struct type from the base
                const base_node = self.ast.nodes[node.child0];
                var field_offset: u32 = 0;
                if (base_node.kind == .identifier) {
                    const base_name = self.nodeText(node.child0);
                    // Look for struct type in let_stmt declarations
                    _ = base_name;
                }
                // For now, use the field name to look up across all struct defs
                var found = false;
                for (0..self.ast.struct_count) |si| {
                    if (self.findStructField(@intCast(si), field_name)) |off| {
                        field_offset = off;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    printErr("Compile error: unknown field '");
                    printErr(field_name);
                    printErr("'\n");
                    sysExit(1);
                }
                // rax += field_offset
                if (field_offset > 0) {
                    self.emit8(0x48);
                    self.emit8(0x83);
                    self.emit8(0xC0);
                    self.emit8(@intCast(field_offset)); // add rax, offset
                }
            },
            .deref => {
                self.compileExpr(node.child0); // rax = pointer value
            },
            .index_expr => {
                // rax = base data ptr + index * 8
                self.compileExpr(node.child0); // base (array data ptr)
                self.pushReg(0);
                self.compileExpr(node.child1); // index → rax
                self.popReg(1); // rcx = base
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0x04);
                self.emit8(0xC1); // lea rax, [rcx + rax*8]
            },
            .identifier => {
                const name = self.nodeText(idx);
                const slot = self.findLocal(name) orelse {
                    printErr("Compile error: undefined variable '");
                    printErr(name);
                    printErr("'\n");
                    sysExit(1);
                };
                // Return address of the stack slot
                self.emit8(0x48);
                self.emit8(0x8D);
                self.emit8(0x45);
                const disp: i32 = -@as(i32, @intCast(slot)) * 8;
                self.emit8(@intCast(disp & 0xFF)); // lea rax, [rbp - slot*8]
            },
            else => {
                // Fallback: treat as expression (value, not address)
                self.compileExpr(idx);
            },
        }
    }

    // ── Heap init (mmap via syscall) ──────────────────────────────
    fn emitHeapInit(self: *Codegen) void {
        // mmap(NULL, 0x100000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
        // rax=9(mmap), rdi=0, rsi=0x100000, rdx=3, r10=0x22, r8=-1, r9=0
        self.mov64imm(0, 9); // sys_mmap
        self.xorReg(7, 7); // rdi = 0 (NULL)
        self.mov64imm(6, 0x100000); // rsi = 1MB
        self.mov64imm(2, 3); // rdx = PROT_READ|PROT_WRITE
        self.mov64imm(10, 0x22); // r10 = MAP_PRIVATE|MAP_ANONYMOUS
        self.mov64imm(8, 0xFFFFFFFFFFFFFFFF); // r8 = -1
        self.xorReg(9, 9); // r9 = 0
        self.syscallInst(); // rax = heap base address
        // Save heap base pointer
        self.movRegReg(1, 0); // rbx = rax (heap base, callee-saved)
    }

    /// Emit TLS init: map a page at 0x4FFFFF000 for thread-local storage.
    fn emitTlsInit(self: *Codegen) void {
        // mmap(0x4FFFFF000, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED, -1, 0)
        self.mov64imm(0, 9);
        self.mov64imm(7, 0x4FFFFF000); // rdi = fixed addr
        self.mov64imm(6, 0x1000); // rsi = 4KB
        self.mov64imm(2, 3); // rdx = PROT_READ|PROT_WRITE
        self.mov64imm(10, 0x32); // r10 = MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED
        self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
        self.xorReg(9, 9);
        self.syscallInst();
    }

    // ── Byte copy helper: copy ecx bytes from rsi to rdi ──────────
    fn emitByteCopy(self: *Codegen) void {
        // Simple loop: while (ecx > 0) { [rdi++] = [rsi++]; ecx--; }
        const loop_start = self.code_len;
        // test ecx, ecx
        self.emit8(0x85);
        self.emit8(0xC9);
        // jz done
        const done_patch = self.emitJe();
        // mov al, [rsi]
        self.emit8(0x8A);
        self.emit8(0x06);
        // mov [rdi], al
        self.emit8(0x88);
        self.emit8(0x07);
        // inc rsi
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC6);
        // inc rdi
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC7);
        // dec ecx
        self.emit8(0xFF);
        self.emit8(0xC9);
        // jmp loop_start
        self.emitJmpTo(loop_start);
        self.patchJump(done_patch);
    }

    // ── Statement compilation ───────────────────────────────────
    fn compileBlock(self: *Codegen, block_idx: u32) void {
        const block = self.ast.nodes[block_idx];
        if (block.kind != .block) return;
        var stmt_idx = block.child0;
        while (stmt_idx != 0) {
            self.compileStmt(stmt_idx);
            stmt_idx = self.ast.stmt_chains[stmt_idx];
        }
    }

    fn compileStmt(self: *Codegen, idx: u32) void {
        if (idx == 0) return;
        const node = self.ast.nodes[idx];
        switch (node.kind) {
            .return_stmt => {
                // Tail-call optimization: if this is `return f(args)` where f
                // is the same function, replace call+ret with a single jmp.
                if (node.child0 != 0) {
                    const child = self.ast.nodes[node.child0];
                    if (child.kind == .call_expr and child.child0 != 0) {
                        const callee_name = self.nodeText(child.child0);
                        const cur = self.fns[self.current_fn_idx];
                        if (eql(callee_name, self.src[cur.name_start..][0..cur.name_len])) {
                            self.emitTailCall(child);
                            return;
                        }
                    }
                    self.compileExpr(node.child0);
                } else {
                    self.xorReg(0, 0);
                }
                if (self.in_main) {
                    self.movRegReg(7, 0); // rdi = exit code
                    self.mov64imm(0, 60);
                    self.syscallInst();
                } else {
                    self.emitLeaveRet();
                }
            },
            .expr_stmt => {
                self.compileExpr(node.child0);
            },
            .call_expr => {
                // Bare call used as a statement
                self.compileExpr(idx);
            },
            .let_stmt => {
                const name = self.nodeText(idx);
                self.defineLocal(name);
                const slot = self.findLocal(name).?;
                if (node.child0 != 0) {
                    self.compileExpr(node.child0);
                } else {
                    self.xorReg(0, 0);
                }
                self.storeRaxToSlot(slot);
            },
            .assign_stmt => {
                // Check if child0 is an lvalue (field_access, deref)
                const rhs_node = self.ast.nodes[node.child0];
                const is_lvalue = rhs_node.kind == .field_access or rhs_node.kind == .deref or
                    rhs_node.kind == .index_expr;
                if (is_lvalue) {
                    // lvalue assignment: *ptr = val or obj.field = val
                    self.compileLValue(node.child0); // rax = target address
                    self.pushReg(0); // save address
                    const op_kind: TokenKind = @enumFromInt(node.op);
                    if (op_kind != .assign) {
                        self.emit8(0x48);
                        self.emit8(0x8B);
                        self.emit8(0x08); // mov rcx, [rax]
                        self.pushReg(1); // save current value
                        self.compileExpr(node.child1); // rax = rhs
                        self.popReg(1); // rcx = current
                        self.emitArith(op_kind); // rax = current OP rhs
                    } else {
                        self.compileExpr(node.child1); // rax = rhs
                    }
                    self.popReg(1); // rcx = target address
                    // mov [rcx], rax
                    self.emit8(0x48);
                    self.emit8(0x89);
                    self.emit8(0x01);
                } else {
                    const name = self.nodeText(idx);
                    const slot = self.findLocal(name) orelse {
                        printErr("Compile error: assignment to undeclared variable '");
                        printErr(name);
                        printErr("'\n");
                        sysExit(1);
                    };
                    self.compileExpr(node.child0); // rhs → rax
                    const op_kind: TokenKind = @enumFromInt(node.op);
                    if (op_kind != .assign) {
                        self.pushReg(0);
                        self.loadSlotToRax(slot);
                        self.popReg(1);
                        self.emitArith(op_kind);
                    }
                    self.storeRaxToSlot(slot);
                }
            },
            .struct_decl, .module_import => {
                // No runtime action needed
            },
            .block => {
                self.compileBlock(idx);
            },
            .if_stmt => {
                self.compileExpr(node.child0);
                // test rax, rax
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0);
                const patch = self.emitJe();
                self.compileBlock(node.child1);
                if (node.child2 != 0) {
                    const jmp_patch = self.emitJmp();
                    self.patchJump(patch);
                    self.compileBlock(node.child2);
                    self.patchJump(jmp_patch);
                } else {
                    self.patchJump(patch);
                }
            },
            .for_stmt => {
                if (self.loop_depth >= self.loops.len) {
                    printErr("Compile error: loops nested too deeply\n");
                    sysExit(1);
                }
                const var_name = self.nodeText(idx);
                if (node.int_val == 1) {
                    // ── Range loop: for i in start..end ──────────
                    const var_slot = self.defineShadowed(var_name, false);
                    self.compileExpr(node.child0); // start
                    self.storeRaxToSlot(var_slot);
                    const loop_start = self.code_len;
                    self.loops[self.loop_depth] = .{ .break_patches = undefined, .break_count = 0, .continue_target = 0, .is_for = true };
                    self.loop_depth += 1;
                    // condition: i < end
                    self.loadSlotToRax(var_slot);
                    self.pushReg(0);
                    self.compileExpr(node.child2); // end
                    self.popReg(1); // rcx = i
                    self.emit8(0x48);
                    self.emit8(0x39);
                    self.emit8(0xC1); // cmp rcx, rax  (i vs end)
                    self.emit8(0x0F);
                    self.emit8(0x8D); // jge exit (i >= end)
                    const exit_patch = self.code_len;
                    self.emit32(0);
                    self.compileBlock(node.child1);
                    // increment (continue target)
                    self.loadSlotToRax(var_slot);
                    self.emit8(0x48);
                    self.emit8(0x83);
                    self.emit8(0xC0);
                    self.emit8(0x01); // add rax, 1
                    self.storeRaxToSlot(var_slot);
                    self.emitJmpTo(loop_start);
                    self.patchJump(exit_patch);
                    self.finishLoop();
                } else {
                    // ── Array loop: for x in arr ─────────────────
                    const arr_slot = self.defineShadowed(".forarr", true);
                    self.compileExpr(node.child0); // arr → rax
                    self.storeRaxToSlot(arr_slot);
                    const idx_slot = self.defineShadowed(".foridx", true);
                    self.xorReg(0, 0);
                    self.storeRaxToSlot(idx_slot);
                    const elem_slot = self.defineShadowed(var_name, false);
                    const loop_start = self.code_len;
                    self.loops[self.loop_depth] = .{ .break_patches = undefined, .break_count = 0, .continue_target = 0, .is_for = true };
                    self.loop_depth += 1;
                    // condition: idx < len ([arr-16])
                    self.loadSlotToRax(idx_slot);
                    self.pushReg(0); // save idx
                    self.loadSlotToRax(arr_slot); // rax = arr
                    self.popReg(1); // rcx = idx
                    self.emit8(0x8B);
                    self.emit8(0x50);
                    self.emit8(0xF0); // mov edx, [rax-16] = len
                    self.emit8(0x48);
                    self.emit8(0x39);
                    self.emit8(0xD1); // cmp rcx, rdx
                    self.emit8(0x0F);
                    self.emit8(0x8D); // jge exit
                    const exit_patch = self.code_len;
                    self.emit32(0);
                    // element = arr[idx]
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x04);
                    self.emit8(0xC8); // mov rax, [rax+rcx*8]
                    self.storeRaxToSlot(elem_slot);
                    self.compileBlock(node.child1);
                    // increment idx (continue target)
                    self.loadSlotToRax(idx_slot);
                    self.emit8(0x48);
                    self.emit8(0x83);
                    self.emit8(0xC0);
                    self.emit8(0x01); // add rax, 1
                    self.storeRaxToSlot(idx_slot);
                    self.emitJmpTo(loop_start);
                    self.patchJump(exit_patch);
                    self.finishLoop();
                }
            },
            .while_stmt => {
                if (self.loop_depth >= self.loops.len) {
                    printErr("Compile error: loops nested too deeply\n");
                    sysExit(1);
                }
                const loop_start = self.code_len;
                self.loops[self.loop_depth] = .{ .break_patches = undefined, .break_count = 0, .continue_target = loop_start };
                self.loop_depth += 1;

                self.compileExpr(node.child0);
                self.emit8(0x48);
                self.emit8(0x85);
                self.emit8(0xC0); // test rax, rax
                const exit_patch = self.emitJe();
                self.compileBlock(node.child1);
                self.emitJmpTo(loop_start);
                self.patchJump(exit_patch);

                self.loop_depth -= 1;
                const ctx = self.loops[self.loop_depth];
                for (0..ctx.break_count) |b| {
                    self.patchJump(ctx.break_patches[b]);
                }
            },
            .break_stmt => {
                if (self.loop_depth == 0) {
                    printErr("Compile error: 'break' outside of loop\n");
                    sysExit(1);
                }
                self.recordBreak();
            },
            .continue_stmt => {
                if (self.loop_depth == 0) {
                    printErr("Compile error: 'continue' outside of loop\n");
                    sysExit(1);
                }
                const lctx = &self.loops[self.loop_depth - 1];
                if (lctx.is_for) {
                    // For loops: continue jumps to the increment, which is
                    // only known after the body is compiled — record patch.
                    if (lctx.continue_count >= lctx.continue_patches.len) capacityError("too many continue statements in one loop (limit 16)");
                    lctx.continue_patches[lctx.continue_count] = self.emitJmp();
                    lctx.continue_count += 1;
                } else {
                    self.emitJmpTo(lctx.continue_target);
                }
            },
            else => {},
        }
    }

    fn recordBreak(self: *Codegen) void {
        const p = self.emitJmp();
        const ctx = &self.loops[self.loop_depth - 1];
        if (ctx.break_count >= ctx.break_patches.len) capacityError("too many break statements in one loop (limit 16)");
        ctx.break_patches[ctx.break_count] = p;
        ctx.break_count += 1;
    }

    /// Patch break/continue jumps after a for-loop body was compiled.
    /// `continue_target` is the loop increment position.
    fn finishLoop(self: *Codegen) void {
        self.loop_depth -= 1;
        const ctx = self.loops[self.loop_depth];
        for (0..ctx.break_count) |b| {
            self.patchJump(ctx.break_patches[b]);
        }
        for (0..ctx.continue_count) |c| {
            self.patchJump(ctx.continue_patches[c]);
        }
    }

    /// Apply a binary arithmetic/comparison op with left in rax, right in rcx.
    fn emitArith(self: *Codegen, op_kind: TokenKind) void {
        switch (op_kind) {
            .plus, .plus_eq => {
                self.emit8(0x48);
                self.emit8(0x01);
                self.emit8(0xC8); // add rax, rcx
            },
            .minus, .minus_eq => {
                self.emit8(0x48);
                self.emit8(0x29);
                self.emit8(0xC8); // sub rax, rcx
            },
            .star, .star_eq => {
                self.emit8(0x48);
                self.emit8(0x0F);
                self.emit8(0xAF);
                self.emit8(0xC1); // imul rax, rcx
            },
            .slash, .slash_eq => {
                self.emit8(0x48);
                self.emit8(0x99); // cqo
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xF9); // idiv rcx
            },
            .percent => {
                self.emit8(0x48);
                self.emit8(0x99); // cqo
                self.emit8(0x48);
                self.emit8(0xF7);
                self.emit8(0xF9); // idiv rcx
                self.emit8(0x48);
                self.emit8(0x89);
                self.emit8(0xD0); // mov rax, rdx (remainder)
            },
            .eq => {
                self.cmpSetcc(0x94); // sete
            },
            .ne => {
                self.cmpSetcc(0x95); // setne
            },
            .lt => {
                self.cmpSetcc(0x9C); // setl
            },
            .ge => {
                self.cmpSetcc(0x9D); // setge
            },
            .le => {
                self.cmpSetcc(0x9E); // setle
            },
            .gt => {
                self.cmpSetcc(0x9F); // setg
            },
            .lshift => {
                self.emit8(0x48);
                self.emit8(0xD3);
                self.emit8(0xE0); // shl rax, cl
            },
            .rshift => {
                self.emit8(0x48);
                self.emit8(0xD3);
                self.emit8(0xF8); // sar rax, cl
            },
            else => {},
        }
    }

    /// cmp rax, rcx ; setXX al ; movzx rax, al
    fn cmpSetcc(self: *Codegen, cc: u8) void {
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

    fn compileLogicalAnd(self: *Codegen, node: ASTNode) void {
        self.compileExpr(node.child0);
        self.emitTestRax();
        const fail1 = self.emitJe();
        self.compileExpr(node.child1);
        self.emitTestRax();
        const fail2 = self.emitJe();
        self.mov64imm(0, 1);
        const done = self.emitJmp();
        self.patchJump(fail1);
        self.patchJump(fail2);
        self.xorReg(0, 0);
        self.patchJump(done);
    }

    fn compileLogicalOr(self: *Codegen, node: ASTNode) void {
        self.compileExpr(node.child0);
        self.emitTestRax();
        const ok1 = self.emitJne();
        self.compileExpr(node.child1);
        self.emitTestRax();
        const ok2 = self.emitJne();
        self.xorReg(0, 0);
        const done = self.emitJmp();
        self.patchJump(ok1);
        self.patchJump(ok2);
        self.mov64imm(0, 1);
        self.patchJump(done);
    }

    fn emitTestRax(self: *Codegen) void {
        self.emit8(0x48);
        self.emit8(0x85);
        self.emit8(0xC0); // test rax, rax
    }

    /// Heuristic: does this expression produce a heap string
    /// ([ptr-8] = len header)? String literals and string builtins do.
    fn isStringExpr(self: *Codegen, idx: u32) bool {
        if (idx == 0) return false;
        const n = self.ast.nodes[idx];
        if (n.kind == .string_literal) return true;
        if (n.kind == .call_expr and n.child0 != 0) {
            const callee = self.nodeText(n.child0);
            return eql(callee, "@string_new") or eql(callee, "@string_concat") or
                eql(callee, "@string_sub");
        }
        return false;
    }

    /// Compile an expression that yields a heap string in rax
    /// ([rax-8] = length). String literals are heapified on the fly.
    fn compileAsHeapString(self: *Codegen, idx: u32) void {
        const n = self.ast.nodes[idx];
        if (n.kind != .string_literal) {
            self.compileExpr(idx);
            return;
        }
        const str = self.src[n.text_start..][0..n.text_len];
        const str_idx = self.addString(str);
        self.leaRipDeferred(6, str_idx); // rsi = rodata ptr
        self.pushReg(6);
        self.mov64imm(1, str.len); // rcx = len
        self.movRegReg(12, 1); // r12 = len (survives syscall)
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x70);
        self.emit8(0x08); // lea rsi, [rax+8] = size
        self.mov64imm(0, 9); // sys_mmap
        self.xorReg(7, 7);
        self.mov64imm(2, 3);
        self.mov64imm(10, 0x22);
        self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
        self.xorReg(9, 9);
        self.syscallInst(); // rax = base
        self.emit8(0x44);
        self.emit8(0x89);
        self.emit8(0x20); // mov [rax], r12d (len header)
        self.popReg(6); // rsi = rodata
        self.emit8(0x48);
        self.emit8(0x8D);
        self.emit8(0x78);
        self.emit8(0x08); // lea rdi, [rax+8]
        self.movRegReg(1, 12); // rcx = len
        self.emitByteCopy();
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xC0);
        self.emit8(0x08); // add rax, 8 → data ptr
    }

    /// String concatenation for `a + b` where either side is stringy.
    /// Result: new heap string in rax.
    fn compileStringConcat(self: *Codegen, node: ASTNode) void {
        self.compileAsHeapString(node.child0);
        self.pushReg(0);
        self.compileAsHeapString(node.child1);
        self.pushReg(0); // [rsp] = b, [rsp+8] = a
        // r12 = len_a, r13 = len_b
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x44);
        self.emit8(0x24);
        self.emit8(0x08); // mov rax, [rsp+8] = a
        self.emit8(0x44);
        self.emit8(0x8B);
        self.emit8(0x60);
        self.emit8(0xF8); // mov r12d, [rax-8] = len_a
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x04);
        self.emit8(0x24); // mov rax, [rsp] = b
        self.emit8(0x44);
        self.emit8(0x8B);
        self.emit8(0x68);
        self.emit8(0xF8); // mov r13d, [rax-8] = len_b
        // size = len_a + len_b + 8 → rsi
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0xE6); // mov rsi, r12
        self.emit8(0x4C);
        self.emit8(0x01);
        self.emit8(0xEE); // add rsi, r13
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xC6);
        self.emit8(0x08); // add rsi, 8
        self.mov64imm(0, 9); // sys_mmap
        self.xorReg(7, 7);
        self.mov64imm(2, 3);
        self.mov64imm(10, 0x22);
        self.mov64imm(8, 0xFFFFFFFFFFFFFFFF);
        self.xorReg(9, 9);
        self.syscallInst(); // rax = base
        // header: [base] = len_a + len_b
        self.emit8(0x45);
        self.emit8(0x89);
        self.emit8(0xE7); // mov r15d, r12d
        self.emit8(0x45);
        self.emit8(0x01);
        self.emit8(0xDD); // add r15d, r13d
        self.emit8(0x44);
        self.emit8(0x89);
        self.emit8(0x38); // mov [rax], r15d
        self.emit8(0x49);
        self.emit8(0x89);
        self.emit8(0xC6); // mov r14, rax (base)
        // copy a → base+8
        self.emit8(0x49);
        self.emit8(0x8D);
        self.emit8(0x7E);
        self.emit8(0x08); // lea rdi, [r14+8]
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x74);
        self.emit8(0x24);
        self.emit8(0x08); // mov rsi, [rsp+8] = a
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0xE1); // mov rcx, r12 = len_a
        self.emitByteCopy();
        // copy b → base+8+len_a
        self.emit8(0x49);
        self.emit8(0x8D);
        self.emit8(0x7E);
        self.emit8(0x08); // lea rdi, [r14+8]
        self.emit8(0x4C);
        self.emit8(0x01);
        self.emit8(0xE7); // add rdi, r12
        self.emit8(0x48);
        self.emit8(0x8B);
        self.emit8(0x34);
        self.emit8(0x24); // mov rsi, [rsp] = b
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0xE9); // mov rcx, r13 = len_b
        self.emitByteCopy();
        // result = base + 8
        self.emit8(0x4C);
        self.emit8(0x89);
        self.emit8(0xF0); // mov rax, r14
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xC0);
        self.emit8(0x08); // add rax, 8
        self.emit8(0x48);
        self.emit8(0x83);
        self.emit8(0xC4);
        self.emit8(0x10); // add rsp, 16
    }

    /// String equality for `a == b` / `a != b` where either side is stringy.
    /// Result: 0 or 1 in rax.
    fn compileStringEq(self: *Codegen, node: ASTNode, invert: bool) void {
        self.compileAsHeapString(node.child0);
        self.pushReg(0);
        self.compileAsHeapString(node.child1);
        self.popReg(6); // rsi = a
        self.movRegReg(7, 0); // rdi = b
        // Compare lengths
        self.emit8(0x8B);
        self.emit8(0x4E);
        self.emit8(0xF8); // mov ecx, [rsi-8] = len_a
        self.emit8(0x3B);
        self.emit8(0x4F);
        self.emit8(0xF8); // cmp ecx, [rdi-8] = len_b
        const not_eq = self.emitJne();
        // Byte compare loop
        const eq_loop = self.code_len;
        self.emit8(0x85);
        self.emit8(0xC9); // test ecx, ecx
        const eq_done = self.emitJe();
        self.emit8(0x8A);
        self.emit8(0x06); // mov al, [rsi]
        self.emit8(0x3A);
        self.emit8(0x07); // cmp al, [rdi]
        const neq_byte = self.emitJne();
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC6); // inc rsi
        self.emit8(0x48);
        self.emit8(0xFF);
        self.emit8(0xC7); // inc rdi
        self.emit8(0xFF);
        self.emit8(0xC9); // dec ecx
        self.emitJmpTo(eq_loop);
        self.patchJump(eq_done);
        self.mov64imm(0, 1); // equal
        const eq_end = self.emitJmp();
        self.patchJump(not_eq);
        self.patchJump(neq_byte);
        self.xorReg(0, 0); // not equal
        self.patchJump(eq_end);
        if (invert) {
            self.emit8(0x48);
            self.emit8(0x83);
            self.emit8(0xF0);
            self.emit8(0x01); // xor rax, 1
        }
    }

    fn compileExpr(self: *Codegen, idx: u32) void {
        if (idx == 0) return;
        const node = self.ast.nodes[idx];
        switch (node.kind) {
            .int_literal => {
                self.mov64imm(0, @bitCast(node.int_val));
            },
            .string_literal => {
                const str = self.src[node.text_start..][0..node.text_len];
                const str_idx = self.addString(str);
                self.leaRipDeferred(6, str_idx); // rsi = string address
                self.movRegReg(0, 6); // rax = rsi (for variable storage)
                self.mov64imm(2, str.len); // rdx = length
            },
            .identifier => {
                const name = self.nodeText(idx);
                const slot = self.findLocal(name) orelse {
                    printErr("Compile error: undefined variable '");
                    printErr(name);
                    printErr("'\n");
                    sysExit(1);
                };
                self.loadSlotToRax(slot);
            },
            .index_expr => {
                // Load arr[idx]: compute address, then dereference
                self.compileLValue(idx);
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x00); // mov rax, [rax]
            },
            .ternary_expr => {
                self.compileExpr(node.child0);
                self.emitTestRax();
                const else_j = self.emitJe();
                self.compileExpr(node.child1);
                const done_j = self.emitJmp();
                self.patchJump(else_j);
                self.compileExpr(node.child2);
                self.patchJump(done_j);
            },
            .unary_expr => {
                self.compileExpr(node.child0);
                const op_kind: TokenKind = @enumFromInt(node.op);
                if (op_kind == .minus) {
                    self.emit8(0x48);
                    self.emit8(0xF7);
                    self.emit8(0xD8); // neg rax
                } else if (op_kind == .bang) {
                    self.emitTestRax();
                    self.emit8(0x0F);
                    self.emit8(0x94);
                    self.emit8(0xC0); // sete al
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0xB6);
                    self.emit8(0xC0); // movzx rax, al
                }
            },
            .binary_expr => {
                const op_kind: TokenKind = @enumFromInt(node.op);
                if (op_kind == .and_and) {
                    self.compileLogicalAnd(node);
                    return;
                }
                if (op_kind == .pipe_pipe) {
                    self.compileLogicalOr(node);
                    return;
                }
                // String operators: "a" + b, s == "x", s != "x"
                if ((op_kind == .plus or op_kind == .eq or op_kind == .ne) and
                    (self.isStringExpr(node.child0) or self.isStringExpr(node.child1)))
                {
                    if (op_kind == .plus) {
                        self.compileStringConcat(node);
                    } else {
                        self.compileStringEq(node, op_kind == .ne);
                    }
                    return;
                }
                // Evaluate right, push, evaluate left, pop into rcx, operate
                self.compileExpr(node.child1); // right → rax
                self.pushReg(0);
                self.compileExpr(node.child0); // left → rax
                self.popReg(1); // rcx = right
                self.emitArith(op_kind);
            },
            .call_expr => {
                const callee = self.ast.nodes[node.child0];
                if (callee.kind != .identifier) return;
                const name = self.nodeText(node.child0);

                // Count args (wrapped in expr_stmt chain in child2)
                var argc: u32 = 0;
                var ai = node.child2;
                while (ai != 0) {
                    argc += 1;
                    ai = self.ast.nodes[ai].child1;
                }

                if (eql(name, "println") or eql(name, "print")) {
                    if (argc != 1) {
                        printErr("Compile error: ");
                        printErr(name);
                        printErr(" expects exactly 1 argument\n");
                        sysExit(1);
                    }
                    const arg_idx = self.ast.nodes[node.child2].child0;
                    const arg_node = self.ast.nodes[arg_idx];
                    self.compileExpr(arg_idx);
                    if (arg_node.kind != .string_literal) {
                        // Heap string: read len from header [rax-8]
                        self.emit8(0x8B);
                        self.emit8(0x50);
                        self.emit8(0xF8); // mov edx, [rax-8]
                    }
                    self.movRegReg(6, 0); // rsi = rax (ptr for sys_write)
                    self.mov64imm(0, 1); // rax = sys_write
                    self.mov64imm(7, 1); // rdi = stdout
                    self.syscallInst();
                    if (eql(name, "println")) {
                        const nl_idx = self.addString("\n");
                        self.leaRipDeferred(6, nl_idx);
                        self.mov64imm(0, 1);
                        self.mov64imm(7, 1);
                        self.mov64imm(2, 1);
                        self.syscallInst();
                    }
                    return;
                }

                if (eql(name, "printInt")) {
                    if (argc != 1) {
                        printErr("Compile error: printInt expects exactly 1 argument\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    self.movRegReg(7, 0); // rdi = value
                    // Emit a call rel32 and record for later patching.
                    self.emit8(0xE8);
                    const patch = self.code_len;
                    self.emit32(0);
                    if (self.printint_patch_count >= self.printint_patches.len) capacityError("too many printInt calls (limit 64)");
                    self.printint_patches[self.printint_patch_count] = patch;
                    self.printint_patch_count += 1;
                    return;
                }

                if (eql(name, "exit")) {
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    self.movRegReg(7, 0);
                    self.mov64imm(0, 60);
                    self.syscallInst();
                    return;
                }

                // ── @sizeof(type) ─────────────────────────────
                if (eql(name, "@sizeof")) {
                    self.mov64imm(0, 8); // all types are i64-sized
                    return;
                }

                // ── @syscall(num, a1, a2, a3) ─────────────────
                if (eql(name, "@syscall")) {
                    if (argc < 1) {
                        printErr("@syscall needs at least 1 arg\n");
                        sysExit(1);
                    }
                    // Evaluate args, push in order
                    ai = node.child2;
                    var sc_argc: u32 = 0;
                    while (ai != 0) {
                        self.compileExpr(self.ast.nodes[ai].child0);
                        self.pushReg(0);
                        sc_argc += 1;
                        ai = self.ast.nodes[ai].child1;
                    }
                    // Pop into rax, rdi, rsi, rdx, r10, r8
                    const sc_regs = [_]u8{ 0, 7, 6, 2, 10, 8 };
                    var ri: usize = sc_argc;
                    while (ri > 0) {
                        ri -= 1;
                        self.popReg(sc_regs[ri]);
                    }
                    self.syscallInst();
                    return;
                }

                // ── @memcpy(dst, src, len) ─────────────────────
                if (eql(name, "@memcpy")) {
                    if (argc != 3) {
                        printErr("@memcpy needs 3 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // dst
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // src
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // len
                    self.movRegReg(1, 0); // rcx = len
                    self.popReg(6); // rsi = src
                    self.popReg(7); // rdi = dst
                    self.emitByteCopy();
                    return;
                }

                // ── @memset(dst, val, len) ─────────────────────
                if (eql(name, "@memset")) {
                    if (argc != 3) {
                        printErr("@memset needs 3 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // dst
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // val
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // len
                    self.movRegReg(1, 0); // rcx = len
                    self.popReg(2); // rdx = val
                    self.popReg(7); // rdi = dst
                    // loop: [rdi++] = dl; rcx--
                    const mset_loop = self.code_len;
                    self.emit8(0x85);
                    self.emit8(0xC9); // test ecx, ecx
                    const mset_done = self.emitJe();
                    self.emit8(0x88);
                    self.emit8(0x17); // mov [rdi], dl
                    self.emit8(0x48);
                    self.emit8(0xFF);
                    self.emit8(0xC7); // inc rdi
                    self.emit8(0xFF);
                    self.emit8(0xC9); // dec ecx
                    self.emitJmpTo(mset_loop);
                    self.patchJump(mset_done);
                    return;
                }

                // ── @printptr(val) ─────────────────────────────
                if (eql(name, "@printptr")) {
                    if (argc != 1) {
                        printErr("@printptr needs 1 arg\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    // Print as hex: "0x" + 16 hex digits + newline
                    // rax = value to print
                    self.subRspImm(40);
                    // Save value in r8 (callee-saved)
                    self.emit8(0x49);
                    self.emit8(0x89);
                    self.emit8(0xC0); // mov r8, rax
                    // Write hex digits from high to low into rsp+20..rsp+35
                    // rsi = rsp+36 (start, will decrement)
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x74);
                    self.emit8(0x24);
                    self.emit8(0x24); // lea rsi, [rsp+36]
                    // mov byte [rsi], 0xa (newline) — actually newline goes at end
                    var hex_pos: u32 = 0;
                    while (hex_pos < 16) : (hex_pos += 1) {
                        // dec rsi
                        self.emit8(0x48);
                        self.emit8(0xFF);
                        self.emit8(0xCE);
                        // mov rax, r8
                        self.emit8(0x49);
                        self.emit8(0x89);
                        self.emit8(0xC0);
                        // shr rax, (15 - hex_pos) * 4
                        const shift_amt: u8 = @intCast((15 - hex_pos) * 4);
                        if (shift_amt > 0) {
                            self.emit8(0x48);
                            self.emit8(0xC1);
                            self.emit8(0xE8);
                            self.emit8(shift_amt);
                        }
                        // and al, 0xf
                        self.emit8(0x24);
                        self.emit8(0x0f);
                        // cmp al, 10
                        self.emit8(0x3C);
                        self.emit8(0x0a);
                        // jl +2
                        self.emit8(0x7C);
                        self.emit8(0x02);
                        // add al, 0x27 (a'-'0'-10)
                        self.emit8(0x04);
                        self.emit8(0x27);
                        // add al, '0'
                        self.emit8(0x04);
                        self.emit8(0x30);
                        // mov [rsi], al
                        self.emit8(0x88);
                        self.emit8(0x06);
                    }
                    // Now rsi = rsp+20, write "0x" at rsp+18 and rsp+19
                    // dec rsi twice
                    self.emit8(0x48);
                    self.emit8(0xFF);
                    self.emit8(0xCE); // dec rsi
                    self.emit8(0xC6);
                    self.emit8(0x06);
                    self.emit8(0x78); // mov [rsi], 'x'
                    self.emit8(0x48);
                    self.emit8(0xFF);
                    self.emit8(0xCE); // dec rsi
                    self.emit8(0xC6);
                    self.emit8(0x06);
                    self.emit8(0x30); // mov [rsi], '0'
                    // rsi = rsp+18, total = 19 bytes ("0x" + 16 hex + newline at rsp+37)
                    // Add newline at rsp+37
                    self.emit8(0xC6);
                    self.emit8(0x44);
                    self.emit8(0x24);
                    self.emit8(0x25);
                    self.emit8(0x0a); // mov byte [rsp+37], '\n'
                    // sys_write(1, rsp+18, 20) — "0x" + 16 hex + newline = 20 bytes
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x74);
                    self.emit8(0x24);
                    self.emit8(0x12); // lea rsi, [rsp+18]
                    self.emit8(0xBA);
                    self.emit32(20); // mov edx, 20
                    self.emit8(0xBF);
                    self.emit32(1); // mov edi, 1 (stdout)
                    self.emit8(0xB8);
                    self.emit32(1); // mov eax, 1 (sys_write)
                    self.syscallInst();
                    self.subRspImmAdd(40); // restore stack
                    return;
                }

                // ── Heap: @malloc(size) ────────────────────────
                if (eql(name, "@malloc")) {
                    if (argc != 1) {
                        printErr("@malloc needs 1 arg\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    self.movRegReg(7, 0); // rdi = size
                    self.mov64imm(6, 7); // rsi = PROT_READ|PROT_WRITE
                    self.mov64imm(10, 0x22); // r10 = MAP_PRIVATE|MAP_ANONYMOUS
                    self.mov64imm(8, 0xFFFFFFFFFFFFFFFF); // r8 = -1
                    self.xorReg(9, 9); // r9 = 0
                    self.mov64imm(0, 9); // sys_mmap
                    self.syscallInst(); // rax = ptr
                    return;
                }

                // ── @free(ptr) — no-op for mmap ────────────────
                if (eql(name, "@free")) {
                    if (argc != 1) {
                        printErr("@free needs 1 arg\n");
                        sysExit(1);
                    }
                    // mmap can't be freed; return ptr as-is
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    return;
                }

                // ── @array_new(count, elem_size) ──────────────
                if (eql(name, "@array_new")) {
                    if (argc != 2) {
                        printErr("@array_new needs 2 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // count → rax
                    self.pushReg(0); // [rsp] = count
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // elem_size (ignored)
                    self.popReg(1); // rcx = count
                    // Compute size = count*8 + 16 in rsi (for mmap arg 2)
                    self.movRegReg(6, 1); // rsi = count
                    self.emit8(0x48);
                    self.emit8(0xC1);
                    self.emit8(0xE6);
                    self.emit8(0x03); // shl rsi, 3
                    self.emit8(0x48);
                    self.emit8(0x83);
                    self.emit8(0xC6);
                    self.emit8(0x10); // add rsi, 16
                    // Save count on stack
                    self.pushReg(1); // [rsp] = count
                    // mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
                    self.mov64imm(0, 9); // rax = sys_mmap
                    self.xorReg(7, 7); // rdi = 0 (NULL)
                    // rsi = size already set
                    self.mov64imm(2, 3); // rdx = PROT_READ|PROT_WRITE
                    self.mov64imm(10, 0x22); // r10 = MAP_PRIVATE|MAP_ANONYMOUS
                    self.mov64imm(8, 0xFFFFFFFFFFFFFFFF); // r8 = -1
                    self.xorReg(9, 9); // r9 = 0
                    self.syscallInst(); // rax = mmap ptr
                    // Store header: [rax]=0 (len), pop count → cap
                    self.emit8(0xC7);
                    self.emit8(0x00);
                    self.emit32(0); // mov dword [rax], 0 (len=0)
                    self.popReg(1); // rcx = saved count
                    self.emit8(0x89);
                    self.emit8(0x48);
                    self.emit8(0x04); // mov [rax+4], ecx (cap=count)
                    self.emit8(0x48);
                    self.emit8(0x83);
                    self.emit8(0xC0);
                    self.emit8(0x10); // add rax, 16 (data ptr)
                    return;
                }

                // ── @array_push(arr, value) ───────────────────
                if (eql(name, "@array_push")) {
                    if (argc != 2) {
                        printErr("@array_push needs 2 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // arr
                    self.pushReg(0); // save arr
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // value
                    // rax = value, [rsp] = arr
                    // Load arr and len from saved arr
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x3C);
                    self.emit8(0x24); // mov rdi, [rsp] = arr
                    self.emit8(0x8B);
                    self.emit8(0x4F);
                    self.emit8(0xF0); // mov ecx, [rdi-16] = len
                    // Store value at arr[len*8]
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x14);
                    self.emit8(0xCF); // lea rdx, [rdi+rcx*8]
                    self.emit8(0x48);
                    self.emit8(0x89);
                    self.emit8(0x02); // mov [rdx], rax = value
                    // Increment len: [rdi] += 1
                    self.emit8(0xFF);
                    self.emit8(0x47);
                    self.emit8(0xF0); // inc dword [rdi-16] = len
                    // Pop arr back to rax (return value)
                    self.popReg(0); // rax = arr
                    return;
                }

                // ── @array_get(arr, index) ────────────────────
                if (eql(name, "@array_get")) {
                    if (argc != 2) {
                        printErr("@array_get needs 2 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // arr
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // index
                    self.popReg(6); // rsi = arr
                    // rax = [rsi + rax*8]
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x04);
                    self.emit8(0xC6); // lea rax, [rsi+rax*8]
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x00); // mov rax, [rax]
                    return;
                }

                // ── @array_set(arr, index, value) ──────────────
                if (eql(name, "@array_set")) {
                    if (argc != 3) {
                        printErr("@array_set needs 3 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // arr → rax
                    self.pushReg(0); // [rsp] = arr
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // index → rax
                    self.pushReg(0); // [rsp] = index, [rsp+8] = arr
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // value → rax
                    // Now: [rsp]=index, [rsp+8]=arr, rax=value
                    self.movRegReg(1, 0); // rcx = value
                    self.popReg(2); // rdx = index
                    self.popReg(6); // rsi = arr
                    // addr = rsi + rdx*8
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x04);
                    self.emit8(0xD6); // lea rax, [rsi+rdx*8]
                    self.emit8(0x48);
                    self.emit8(0x89);
                    self.emit8(0x08); // mov [rax], rcx
                    self.movRegReg(0, 6); // return arr
                    return;
                }

                // ── @array_len(arr) ───────────────────────────
                if (eql(name, "@array_len")) {
                    if (argc != 1) {
                        printErr("@array_len needs 1 arg\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    // len = [rax - 16]
                    self.emit8(0x8B);
                    self.emit8(0x40);
                    self.emit8(0xF0); // mov eax, [rax-16]
                    self.emit8(0x48);
                    self.emit8(0x0F);
                    self.emit8(0xB6);
                    self.emit8(0xC0); // movzx rax, eax
                    return;
                }

                // ── @array_free(arr) — no-op ──────────────────
                if (eql(name, "@array_free")) {
                    if (argc != 1) {
                        printErr("@array_free needs 1 arg\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    return;
                }

                // ── @string_new(ptr, len) ─────────────────────
                if (eql(name, "@string_new")) {
                    if (argc != 2) {
                        printErr("@string_new needs 2 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // data ptr → rax
                    self.pushReg(0); // [rsp] = ptr
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // len → rax
                    // Stack: [rsp] = ptr, rax = len
                    // Save len in r12 (callee-saved, survives syscalls)
                    self.emit8(0x49);
                    self.emit8(0x89);
                    self.emit8(0xC4); // mov r12, rax
                    // mmap size = len + 8
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x70);
                    self.emit8(0x08); // lea rsi, [rax+8] = size
                    self.mov64imm(0, 9); // rax = sys_mmap
                    self.xorReg(7, 7); // rdi = 0 (NULL)
                    self.mov64imm(2, 3); // rdx = PROT_READ|PROT_WRITE
                    self.mov64imm(10, 0x22); // r10 = MAP_PRIVATE|MAP_ANONYMOUS
                    self.mov64imm(8, 0xFFFFFFFFFFFFFFFF); // r8 = -1
                    self.xorReg(9, 9); // r9 = 0
                    self.syscallInst(); // rax = new string base
                    // Save base in r13 (callee-saved, byte copy will clobber rax)
                    self.emit8(0x49);
                    self.emit8(0x89);
                    self.emit8(0xC5); // mov r13, rax
                    // Store len header: [rax] = r12d
                    self.emit8(0x44);
                    self.emit8(0x89);
                    self.emit8(0x20); // mov [rax], r12d
                    // Copy data: rdi=rax+8, rsi=ptr, rcx=len
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x78);
                    self.emit8(0x08); // lea rdi, [rax+8]
                    self.popReg(6); // rsi = ptr
                    self.movRegReg(1, 12); // rcx = len (from r12)
                    self.emitByteCopy();
                    // Return base+8 from r13
                    self.emit8(0x4C);
                    self.emit8(0x89);
                    self.emit8(0xE8); // mov rax, r13
                    self.emit8(0x48);
                    self.emit8(0x83);
                    self.emit8(0xC0);
                    self.emit8(0x08); // add rax, 8
                    return;
                }

                // ── @string_len(str) ──────────────────────────
                if (eql(name, "@string_len")) {
                    if (argc != 1) {
                        printErr("@string_len needs 1 arg\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    // len = [rax - 8]
                    self.emit8(0x8B);
                    self.emit8(0x40);
                    self.emit8(0xF8); // mov eax, [rax-8] (zero-extends to rax)
                    return;
                }

                // ── @string_concat(a, b) ──────────────────────
                if (eql(name, "@string_concat")) {
                    if (argc != 2) {
                        printErr("@string_concat needs 2 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // a
                    self.pushReg(0); // [rsp] = a
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // b
                    self.pushReg(0); // [rsp] = b, [rsp+8] = a
                    // Load len_a
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x44);
                    self.emit8(0x24);
                    self.emit8(0x08); // mov rax, [rsp+8] = a
                    self.emit8(0x8B);
                    self.emit8(0x48);
                    self.emit8(0xF8); // mov ecx, [rax-8] = len_a
                    self.pushReg(1); // [rsp]=len_a, [rsp+8]=b, [rsp+16]=a
                    // Load len_b
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x44);
                    self.emit8(0x24);
                    self.emit8(0x08); // mov rax, [rsp+8] = b
                    self.emit8(0x8B);
                    self.emit8(0x50);
                    self.emit8(0xF8); // mov edx, [rax-8] = len_b
                    self.pushReg(2); // [rsp]=len_b, [rsp+8]=len_a, [rsp+16]=b, [rsp+24]=a
                    // total = len_a + len_b + 8
                    self.emit8(0x01);
                    self.emit8(0xD1); // add ecx, edx
                    self.emit8(0x83);
                    self.emit8(0xC1);
                    self.emit8(0x08); // add ecx, 8
                    // Push total for mmap arg, then setup mmap
                    self.pushReg(1); // [rsp]=total, [rsp+8]=len_b, [rsp+16]=len_a, [rsp+24]=b, [rsp+32]=a
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x34);
                    self.emit8(0x24); // mov rsi, [rsp] = total
                    self.xorReg(7, 7); // rdi = 0
                    self.mov64imm(2, 3); // rdx = PROT_RW
                    self.mov64imm(10, 0x22); // r10 = MAP
                    self.mov64imm(8, 0xFFFFFFFFFFFFFFFF); // r8 = -1
                    self.xorReg(9, 9); // r9 = 0
                    self.mov64imm(0, 9); // rax = sys_mmap
                    self.syscallInst(); // rax = base
                    // Pop total (discard)
                    self.emit8(0x48);
                    self.emit8(0x83);
                    self.emit8(0xC4);
                    self.emit8(0x08); // add rsp, 8
                    // Stack: [rsp]=len_b, [rsp+8]=len_a, [rsp+16]=b, [rsp+24]=a
                    // Compute total and store header
                    self.emit8(0x8B);
                    self.emit8(0x4C);
                    self.emit8(0x24);
                    self.emit8(0x00); // mov ecx, [rsp] = len_b
                    self.emit8(0x03);
                    self.emit8(0x4C);
                    self.emit8(0x24);
                    self.emit8(0x08); // add ecx, [rsp+8] = +len_a
                    self.emit8(0x89);
                    self.emit8(0x08); // mov [rax], ecx (store string_len = len_a + len_b)
                    // Save base
                    self.pushReg(0); // [rsp]=base, [rsp+8]=len_b, [rsp+16]=len_a, [rsp+24]=b, [rsp+32]=a
                    // Copy a: rdi=base+8, rsi=a, ecx=len_a
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x78);
                    self.emit8(0x08); // lea rdi, [rax+8]
                    self.emit8(0x8B);
                    self.emit8(0x4C);
                    self.emit8(0x24);
                    self.emit8(0x10); // mov ecx, [rsp+16] = len_a
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x74);
                    self.emit8(0x24);
                    self.emit8(0x20); // mov rsi, [rsp+32] = a
                    self.emitByteCopy();
                    // Copy b: rdi already at base+8+len_a, rsi=b, ecx=len_b
                    self.emit8(0x8B);
                    self.emit8(0x4C);
                    self.emit8(0x24);
                    self.emit8(0x08); // mov ecx, [rsp+8] = len_b
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x74);
                    self.emit8(0x24);
                    self.emit8(0x18); // mov rsi, [rsp+24] = b
                    self.emitByteCopy();
                    // Return base+8
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x04);
                    self.emit8(0x24); // mov rax, [rsp] = base
                    self.emit8(0x48);
                    self.emit8(0x83);
                    self.emit8(0xC0);
                    self.emit8(0x08); // add rax, 8
                    // Clean up 5 items = 40 bytes
                    self.emit8(0x48);
                    self.emit8(0x83);
                    self.emit8(0xC4);
                    self.emit8(0x28); // add rsp, 40
                    return;
                }

                // ── @string_eq(a, b) ─────────────────────────
                if (eql(name, "@string_eq")) {
                    if (argc != 2) {
                        printErr("@string_eq needs 2 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // a
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // b
                    self.popReg(6); // rsi = a (data ptr)
                    // rax = b (data ptr)
                    self.movRegReg(7, 0); // rdi = b
                    // Compare lengths: [rsi-8] vs [rdi-8]
                    self.emit8(0x8B);
                    self.emit8(0x4E);
                    self.emit8(0xF8); // mov ecx, [rsi-8] = len_a
                    self.emit8(0x3B);
                    self.emit8(0x4F);
                    self.emit8(0xF8); // cmp ecx, [rdi-8] = len_b
                    const not_eq = self.emitJne();
                    // Byte compare: loop ecx bytes
                    const eq_loop = self.code_len;
                    self.emit8(0x85);
                    self.emit8(0xC9); // test ecx, ecx
                    const eq_done = self.emitJe();
                    self.emit8(0x8A);
                    self.emit8(0x06); // mov al, [rsi]
                    self.emit8(0x3A);
                    self.emit8(0x07); // cmp al, [rdi]
                    const neq_byte = self.emitJne();
                    self.emit8(0x48);
                    self.emit8(0xFF);
                    self.emit8(0xC6); // inc rsi
                    self.emit8(0x48);
                    self.emit8(0xFF);
                    self.emit8(0xC7); // inc rdi
                    self.emit8(0xFF);
                    self.emit8(0xC9); // dec ecx
                    self.emitJmpTo(eq_loop);
                    self.patchJump(eq_done);
                    self.mov64imm(0, 1); // rax = 1 (equal)
                    const eq_end = self.emitJmp();
                    self.patchJump(not_eq);
                    self.patchJump(neq_byte);
                    self.xorReg(0, 0); // rax = 0 (not equal)
                    self.patchJump(eq_end);
                    return;
                }

                // ── @string_sub(str, start, len) ──────────────
                if (eql(name, "@string_sub")) {
                    if (argc != 3) {
                        printErr("@string_sub needs 3 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // str
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // start
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // sub_len
                    // Stack: [rsp]=start, [rsp+8]=str, rax=sub_len
                    // Save sub_len in r12 (callee-saved)
                    self.emit8(0x49);
                    self.emit8(0x89);
                    self.emit8(0xC4); // mov r12, rax
                    // rax = sub_len + 8 = mmap size
                    self.emit8(0x8D);
                    self.emit8(0x41);
                    self.emit8(0x08); // lea eax, [rcx+8]
                    self.movRegReg(6, 0); // rsi = size
                    self.mov64imm(0, 9); // rax = sys_mmap
                    self.xorReg(7, 7); // rdi = 0 (NULL)
                    self.mov64imm(2, 3); // rdx = PROT_READ|PROT_WRITE
                    self.mov64imm(10, 0x22); // r10 = MAP_PRIVATE|MAP_ANONYMOUS
                    self.mov64imm(8, 0xFFFFFFFFFFFFFFFF); // r8 = -1
                    self.xorReg(9, 9); // r9 = 0
                    self.syscallInst(); // rax = new base
                    // Save base in r13 (callee-saved, byte copy clobbers rax)
                    self.emit8(0x49);
                    self.emit8(0x89);
                    self.emit8(0xC5); // mov r13, rax
                    // Store sub_len header: [rax] = r12d
                    self.emit8(0x44);
                    self.emit8(0x89);
                    self.emit8(0x20); // mov [rax], r12d
                    // Copy: dst=rax+8, src=str+start, ecx=sub_len
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x78);
                    self.emit8(0x08); // lea rdi, [rax+8]
                    self.popReg(2); // rdx = start
                    self.popReg(6); // rsi = str
                    self.emit8(0x48);
                    self.emit8(0x01);
                    self.emit8(0xD6); // add rsi, rdx (src = str + start)
                    self.movRegReg(1, 12); // rcx = sub_len
                    self.emitByteCopy();
                    // Return base+8 from r13
                    self.emit8(0x4C);
                    self.emit8(0x89);
                    self.emit8(0xE8); // mov rax, r13
                    self.emit8(0x48);
                    self.emit8(0x83);
                    self.emit8(0xC0);
                    self.emit8(0x08); // add rax, 8
                    return;
                }

                // ── @string_at(str, idx) ─────────────────────
                if (eql(name, "@string_at")) {
                    if (argc != 2) {
                        printErr("@string_at needs 2 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // str
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // idx
                    self.popReg(6); // rsi = str (data ptr)
                    // rax = [rsi + rax] zero-extended
                    self.emit8(0x0F);
                    self.emit8(0xB6);
                    self.emit8(0x04);
                    self.emit8(0x06); // movzx eax, byte [rsi+rax]
                    return;
                }

                // ── @open(path, flags, mode) ──────────────────
                if (eql(name, "@open")) {
                    if (argc < 2 or argc > 3) {
                        printErr("@open needs 2-3 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0); // path (ptr, len pair from string_literal)
                    // For string literal, rax=ptr, rdx=len. We need ptr.
                    self.pushReg(0); // save ptr (rax)
                    self.pushReg(2); // save len (rdx)
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // flags
                    self.popReg(2);
                    self.popReg(7); // rdi = path ptr
                    self.movRegReg(6, 0); // rsi = flags
                    if (argc == 3) {
                        ai = self.ast.nodes[ai].child1;
                        self.compileExpr(self.ast.nodes[ai].child0); // mode
                        self.movRegReg(2, 0); // rdx = mode
                    } else {
                        self.mov64imm(2, 0o644); // default mode
                    }
                    self.mov64imm(0, 2); // sys_open
                    self.syscallInst();
                    return;
                }

                // ── @read(fd, buf, count) ────────────────────
                if (eql(name, "@read")) {
                    if (argc != 3) {
                        printErr("@read needs 3 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0);
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0);
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0);
                    self.movRegReg(2, 0); // rdx = count
                    self.popReg(6); // rsi = buf
                    self.popReg(7); // rdi = fd
                    self.mov64imm(0, 0); // sys_read
                    self.syscallInst();
                    return;
                }

                // ── @write(fd, buf, count) ───────────────────
                if (eql(name, "@write")) {
                    if (argc != 3) {
                        printErr("@write needs 3 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    self.compileExpr(self.ast.nodes[ai].child0);
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0);
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0);
                    self.movRegReg(2, 0); // rdx = count
                    self.popReg(6); // rsi = buf
                    self.popReg(7); // rdi = fd
                    self.mov64imm(0, 1); // sys_write
                    self.syscallInst();
                    return;
                }

                // ── @close(fd) ───────────────────────────────
                if (eql(name, "@close")) {
                    if (argc != 1) {
                        printErr("@close needs 1 arg\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    self.movRegReg(7, 0);
                    self.mov64imm(0, 3); // sys_close
                    self.syscallInst();
                    return;
                }

                // ── @stat(path) ──────────────────────────────
                if (eql(name, "@stat")) {
                    if (argc != 1) {
                        printErr("@stat needs 1 arg\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    // Allocate 144-byte stat buffer on stack
                    self.subRspImm(144);
                    self.movRegReg(7, 0); // rdi = path
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x14);
                    self.emit8(0x24); // lea rdx, [rsp]
                    self.mov64imm(0, 4); // sys_stat
                    self.syscallInst();
                    // Return file size: stat_buf.st_size at offset 48
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x44);
                    self.emit8(0x24);
                    self.emit8(48); // mov rax, [rsp+48]
                    self.subRspImmAdd(144);
                    return;
                }

                // ── @thread_create(func_name, arg) ───────────
                if (eql(name, "@thread_create")) {
                    if (argc != 2) {
                        printErr("@thread_create needs 2 args\n");
                        sysExit(1);
                    }
                    ai = node.child2;
                    // First arg: string literal function name
                    const name_node = self.ast.nodes[self.ast.nodes[ai].child0];
                    if (name_node.kind != .string_literal) {
                        printErr("@thread_create first arg must be a string literal\n");
                        sysExit(1);
                    }
                    ai = self.ast.nodes[ai].child1;
                    self.compileExpr(self.ast.nodes[ai].child0); // arg → rax
                    // Save arg in r11 (callee-saved, safe across syscalls)
                    self.movRegReg(11, 0); // r11 = arg
                    // mmap 64KB stack for new thread
                    self.mov64imm(0, 9); // sys_mmap
                    self.xorReg(7, 7); // rdi = NULL
                    self.mov64imm(6, 0x10000); // rsi = 64KB
                    self.mov64imm(2, 7); // rdx = PROT_READ|PROT_WRITE
                    self.mov64imm(10, 0x22); // r10 = MAP_PRIVATE|MAP_ANONYMOUS
                    self.mov64imm(8, 0xFFFFFFFFFFFFFFFF); // r8 = -1
                    self.xorReg(9, 9); // r9 = 0
                    self.syscallInst(); // rax = stack base
                    // stack_top = rax + 0x10000
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x80);
                    self.emit64(0x10000); // lea rax, [rax+0x10000]
                    // Save stack_top in r10 (caller-saved, but we don't call anything before clone)
                    self.movRegReg(10, 0); // r10 = stack_top
                    // Store function pointer in TLS slot 0 (0x4FFFFF000)
                    self.mov64imm(7, 0x4FFFFF000); // rdi = TLS slot 0 addr
                    self.emit8(0x48);
                    self.emit8(0xB8); // mov rax, imm64
                    const fn_patch_pos = self.code_len;
                    self.emit64(0); // placeholder for fn_addr
                    // Record patch
                    if (self.thread_fn_patch_count >= self.thread_fn_patches.len) capacityError("too many @thread_create references (limit 64)");
                    self.thread_fn_patches[self.thread_fn_patch_count] = .{
                        .name_start = name_node.text_start,
                        .name_len = name_node.text_len,
                        .code_pos = fn_patch_pos,
                        .source_id = name_node.source_id,
                    };
                    self.thread_fn_patch_count += 1;
                    self.emit8(0x48);
                    self.emit8(0x89);
                    self.emit8(0x07); // mov [rdi], rax
                    // Store arg in TLS slot 1 (0x4FFFFF008)
                    self.mov64imm(7, 0x4FFFFF008);
                    self.movRegReg(0, 11); // rax = arg
                    self.emit8(0x48);
                    self.emit8(0x89);
                    self.emit8(0x07); // mov [rdi], rax
                    // clone(CLONE_VM|CLONE_FS|CLONE_FILES|SIGCHLD, stack_top)
                    // CLONE_VM=0x100, CLONE_FS=0x200, CLONE_FILES=0x400, SIGCHLD=17
                    // Total = 0x100 | 0x200 | 0x400 | 17 = 0x711
                    self.mov64imm(0, 56); // sys_clone
                    self.mov64imm(7, 0x711); // rdi = CLONE flags
                    self.movRegReg(6, 10); // rsi = stack_top
                    self.xorReg(2, 2); // rdx = 0 (parent_tid)
                    self.syscallInst();
                    // if (rax == 0) { child path }
                    self.emitTestRax();
                    const parent_skip = self.emitJne();
                    // Child: call the function pointer stored at TLS slot 0, with arg from TLS slot 1
                    // Load function pointer from 0x4FFFFF000
                    self.mov64imm(0, 0x4FFFFF000);
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x00); // mov rax, [rax] = fn_ptr
                    // Load arg from 0x4FFFFF008
                    self.mov64imm(7, 0x4FFFFF008);
                    self.emit8(0x48);
                    self.emit8(0x8B);
                    self.emit8(0x3F); // mov rdi, [rdi] = arg
                    // Call the function
                    self.emit8(0xFF);
                    self.emit8(0xD0); // call rax
                    // Exit child thread
                    self.mov64imm(0, 231); // sys_exit
                    self.xorReg(7, 7); // rdi = 0
                    self.syscallInst();
                    self.patchJump(parent_skip);
                    // Parent continues: rax = child tid
                    return;
                }

                // ── @thread_join(tid) ─────────────────────────
                if (eql(name, "@thread_join")) {
                    if (argc != 1) {
                        printErr("@thread_join needs 1 arg\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    self.movRegReg(7, 0); // rdi = tid
                    self.xorReg(6, 6); // rsi = NULL
                    self.mov64imm(0, 61); // sys_wait4
                    self.syscallInst();
                    return;
                }

                // ── @mutex_create() → returns 0 ──────────────
                if (eql(name, "@mutex_create")) {
                    self.xorReg(0, 0);
                    return;
                }

                // ── @mutex_lock(addr) ────────────────────────
                if (eql(name, "@mutex_lock")) {
                    if (argc != 1) {
                        printErr("@mutex_lock needs 1 arg\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    self.movRegReg(7, 0); // rdi = addr
                    self.mov64imm(6, 1); // rsi = FUTEX_WAIT
                    self.xorReg(2, 2); // rdx = 0
                    self.mov64imm(0, 202); // sys_futex
                    self.syscallInst();
                    return;
                }

                // ── @mutex_unlock(addr) ──────────────────────
                if (eql(name, "@mutex_unlock")) {
                    if (argc != 1) {
                        printErr("@mutex_unlock needs 1 arg\n");
                        sysExit(1);
                    }
                    self.compileExpr(self.ast.nodes[node.child2].child0);
                    self.movRegReg(7, 0); // rdi = addr
                    self.mov64imm(6, 1); // rsi = FUTEX_WAKE
                    self.mov64imm(2, 1); // rdx = wake 1
                    self.mov64imm(0, 202); // sys_futex
                    self.syscallInst();
                    return;
                }

                // User-defined function call (System V AMD64 convention)
                const fi = self.findFn(name) orelse {
                    printErr("Compile error: call to undefined function '");
                    printErr(name);
                    printErr("'\n");
                    sysExit(1);
                };
                if (argc != self.fns[fi].param_count) {
                    printErr("Compile error: function '");
                    printErr(name);
                    printErr("' expects ");
                    printUsize(self.fns[fi].param_count);
                    printErr(" argument(s), got ");
                    printUsize(argc);
                    printErr("\n");
                    sysExit(1);
                }
                if (argc > ARG_REGS.len) {
                    printErr("Compile error: more than 6 arguments not supported yet\n");
                    sysExit(1);
                }
                // Evaluate args left-to-right, pushing each
                ai = node.child2;
                while (ai != 0) {
                    self.compileExpr(self.ast.nodes[ai].child0);
                    self.pushReg(0);
                    ai = self.ast.nodes[ai].child1;
                }
                // Pop into arg registers in reverse order
                var ri: usize = argc;
                while (ri > 0) {
                    ri -= 1;
                    self.popReg(ARG_REGS[ri]);
                }
                self.callNamed(name);
            },
            .addr_of => {
                // &expr — compile the address of a stack variable or field
                const inner = self.ast.nodes[node.child0];
                if (inner.kind == .identifier) {
                    const name = self.nodeText(node.child0);
                    const slot = self.findLocal(name) orelse {
                        printErr("Compile error: cannot take address of unknown variable '");
                        printErr(name);
                        printErr("'\n");
                        sysExit(1);
                    };
                    // lea rax, [rbp - slot*8]
                    self.emit8(0x48);
                    self.emit8(0x8D);
                    self.emit8(0x45);
                    const disp: i32 = -@as(i32, @intCast(slot)) * 8;
                    self.emit8(@intCast(disp & 0xFF));
                } else if (inner.kind == .field_access) {
                    self.compileLValue(node.child0);
                } else {
                    printErr("Compile error: &operator only supports variables and field access\n");
                    sysExit(1);
                }
            },
            .deref => {
                // *expr — load the value at the pointer in rax
                self.compileExpr(node.child0); // rax = pointer
                // mov rax, [rax]
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x00);
            },
            .field_access => {
                // obj.field — compute address then load
                self.compileLValue(idx);
                // mov rax, [rax]
                self.emit8(0x48);
                self.emit8(0x8B);
                self.emit8(0x00);
            },
            .struct_decl, .module_import => {
                // No runtime value
            },
            else => {},
        }
    }

    // ── ELF Generation ─────────────────────────────────────────
    pub fn generateELF(self: *Codegen, output: []u8) usize {
        var pos: usize = 0;
        const header_size: u64 = 64;
        const phdr_size: u64 = 56;
        const num_phdrs: u64 = 2;
        const total_size: u64 = self.code_len + self.rodata_len;
        // Page-align the code offset so (p_offset % p_align) == (p_vaddr % p_align)
        const raw_offset = header_size + phdr_size * num_phdrs;
        const code_file_offset = (raw_offset + 0xFFF) & ~@as(u64, 0xFFF); // round up to 4096
        if (code_file_offset > @as(u64, @intCast(output.len)) or total_size > @as(u64, @intCast(output.len)) - code_file_offset) capacityError("ELF output buffer is too small");
        const code_vaddr: u64 = 0x400000;
        const entry = code_vaddr + code_file_offset;

        // ELF Header (64 bytes)
        output[0..16].* = .{ 0x7F, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        write16(output[16..], 2); // ET_EXEC
        write16(output[18..], 62); // EM_X86_64
        write32(output[20..], 1); // version
        write64(output[24..], entry); // entry
        write64(output[32..], header_size); // phoff
        write64(output[40..], 0); // shoff
        write32(output[48..], 0); // flags
        write16(output[52..], 64); // ehsize
        write16(output[54..], 56); // phentsize
        write16(output[56..], @intCast(num_phdrs)); // phnum
        write16(output[58..], 64); // shentsize
        write16(output[60..], 0); // shnum
        write16(output[62..], 0); // shstrndx
        pos = 64;

        // PT_LOAD (code + rodata)
        write32(output[pos..][0..4], 1);
        pos += 4;
        write32(output[pos..][0..4], 5);
        pos += 4;
        write64(output[pos..][0..8], 0);
        pos += 8;
        write64(output[pos..][0..8], code_vaddr);
        pos += 8;
        write64(output[pos..][0..8], code_vaddr);
        pos += 8;
        write64(output[pos..][0..8], code_file_offset + total_size);
        pos += 8;
        write64(output[pos..][0..8], code_file_offset + total_size + 0x10000);
        pos += 8;
        write64(output[pos..][0..8], 0x1000);
        pos += 8;

        // PT_GNU_STACK
        write32(output[pos..][0..4], 0x6474e551);
        pos += 4;
        write32(output[pos..][0..4], 7);
        pos += 4;
        write64(output[pos..][0..8], 0);
        pos += 8;
        write64(output[pos..][0..8], 0);
        pos += 8;
        write64(output[pos..][0..8], 0);
        pos += 8;
        write64(output[pos..][0..8], 0);
        pos += 8;
        write64(output[pos..][0..8], 0);
        pos += 8;
        write64(output[pos..][0..8], 0x10);
        pos += 8;

        // Pad to code_file_offset (page-aligned)
        while (pos < code_file_offset) {
            output[pos] = 0;
            pos += 1;
        }

        // Code
        @memcpy(output[pos..][0..self.code_len], self.code[0..self.code_len]);
        pos += self.code_len;

        // Rodata
        @memcpy(output[pos..][0..self.rodata_len], self.rodata[0..self.rodata_len]);
        pos += self.rodata_len;

        return pos;
    }

    // ── Peephole optimizations ─────────────────────────────────────

    /// Run all peephole optimizations on the generated code buffer.
    /// Must be called after patchStrings/patchCalls (when all displacements are resolved).
    pub fn peepholeOptimize(self: *Codegen) void {
        _ = util.writeFile("/tmp/code_before_peep.bin", self.code[0..self.code_len]);
        //self.nopRedundantMovs();
        self.convertShortJumps();
        _ = util.writeFile("/tmp/code_after_peep.bin", self.code[0..self.code_len]);
    }

    /// Replace `mov reg, reg` (REX 89 ModRM) with a 3-byte NOP (0F 1F 00).
    fn nopRedundantMovs(self: *Codegen) void {
        var i: u32 = 0;
        while (i + 2 < self.code_len) {
            if ((self.code[i] == 0x48 or self.code[i] == 0x49) and self.code[i + 1] == 0x89) {
                const modrm = self.code[i + 2];
                // mod=11, reg field == r/m field → mov reg, reg
                if ((modrm >> 6) == 0x03 and ((modrm >> 3) & 0x07) == (modrm & 0x07)) {
                    self.code[i] = 0x0F;
                    self.code[i + 1] = 0x1F;
                    self.code[i + 2] = 0x00; // 3-byte NOP
                    i += 3;
                    continue;
                }
            }
            i += 1;
        }
    }

    /// Convert rel32 conditional/unconditional jumps to rel8 when displacement
    /// fits. Uses a three-phase approach:
    ///   1. Mark which jumps can be converted (conservative, no shift_at lookup)
    ///   2. Compute correct shift_at from the marks
    ///   3. Rebuild the code buffer using corrected shift_at
    fn convertShortJumps(self: *Codegen) void {
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
            // MOV [rbp+disp32]: 48 89/8B 85 xx xx xx xx — skip 7 bytes
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
                    shift -= 4;
                } else {
                    shift -= 3;
                }
            }
            i += 1;
        }
        const final_shift = shift_at[self.code_len];

        // Phase 3: rebuild code buffer with correct displacements
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
                    @memcpy(new_code[new_pos + 1 ..][0..4], self.code[i + 1 ..][0..4]);
                }
                i += 5;
                continue;
            }

            new_code[new_pos] = self.code[i];
            i += 1;
        }

        const new_len: u32 = @intCast(@as(i32, @intCast(self.code_len)) + final_shift);
        @memcpy(self.code[0..new_len], new_code[0..new_len]);
        self.code_len = new_len;
    }
};
