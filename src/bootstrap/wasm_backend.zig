// ════════════════════════════════════════════════════════════════════════════
// DIRECT WEBASSEMBLY (wasm32-wasi) BINARY EMITTER
// Zero-dependency backend: compiles verified IRModule directly to valid Wasm
// MVP + WASI snapshot_preview1 .wasm binary bytes without clang, lld, or zig.
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const ir = @import("ir.zig");
const util = @import("util.zig");

const IRModule = ir.IRModule;
const IRFn = ir.IRFn;
const IRInst = ir.IRInst;
const IROp = ir.IROp;

pub const WasmError = error{
    MissingMain,
    InvalidFunction,
    OutOfMemory,
};

// Wasm type encodings
const T_I32: u8 = 0x7F;
const T_I64: u8 = 0x7E;
const T_F32: u8 = 0x7D;
const T_F64: u8 = 0x7C;
const T_FUNCREF: u8 = 0x70;
const T_VOID: u8 = 0x40;

// Wasm opcodes
const OP_UNREACHABLE: u8 = 0x00;
const OP_NOP: u8 = 0x01;
const OP_BLOCK: u8 = 0x02;
const OP_LOOP: u8 = 0x03;
const OP_IF: u8 = 0x04;
const OP_ELSE: u8 = 0x05;
const OP_END: u8 = 0x0B;
const OP_BR: u8 = 0x0C;
const OP_BR_IF: u8 = 0x0D;
const OP_BR_TABLE: u8 = 0x0E;
const OP_RETURN: u8 = 0x0F;
const OP_CALL: u8 = 0x10;
const OP_DROP: u8 = 0x1A;
const OP_SELECT: u8 = 0x1B;

const OP_LOCAL_GET: u8 = 0x20;
const OP_LOCAL_SET: u8 = 0x21;
const OP_LOCAL_TEE: u8 = 0x22;
const OP_GLOBAL_GET: u8 = 0x23;
const OP_GLOBAL_SET: u8 = 0x24;

const OP_I32_LOAD: u8 = 0x28;
const OP_I64_LOAD: u8 = 0x29;
const OP_I32_LOAD8_U: u8 = 0x2D;
const OP_I64_LOAD8_U: u8 = 0x31;
const OP_I64_LOAD32_U: u8 = 0x35;
const OP_I32_STORE: u8 = 0x36;
const OP_I64_STORE: u8 = 0x37;
const OP_I32_STORE8: u8 = 0x3A;
const OP_I64_STORE8: u8 = 0x3C;
const OP_I64_STORE32: u8 = 0x3E;
const OP_MEM_SIZE: u8 = 0x3F;
const OP_MEM_GROW: u8 = 0x40;

const OP_I32_CONST: u8 = 0x41;
const OP_I64_CONST: u8 = 0x42;
const OP_F64_CONST: u8 = 0x44;

const OP_I32_EQZ: u8 = 0x45;
const OP_I32_EQ: u8 = 0x46;
const OP_I32_NE: u8 = 0x47;
const OP_I32_LT_S: u8 = 0x48;
const OP_I32_LT_U: u8 = 0x49;
const OP_I32_GT_S: u8 = 0x4A;
const OP_I32_GT_U: u8 = 0x4B;
const OP_I32_LE_S: u8 = 0x4C;
const OP_I32_LE_U: u8 = 0x4D;
const OP_I32_GE_S: u8 = 0x4E;
const OP_I32_GE_U: u8 = 0x4F;

const OP_I64_EQZ: u8 = 0x50;
const OP_I64_EQ: u8 = 0x51;
const OP_I64_NE: u8 = 0x52;
const OP_I64_LT_S: u8 = 0x53;
const OP_I64_LT_U: u8 = 0x54;
const OP_I64_GT_S: u8 = 0x55;
const OP_I64_GT_U: u8 = 0x56;
const OP_I64_LE_S: u8 = 0x57;
const OP_I64_LE_U: u8 = 0x58;
const OP_I64_GE_S: u8 = 0x59;
const OP_I64_GE_U: u8 = 0x5A;

const OP_F64_EQ: u8 = 0x61;
const OP_F64_NE: u8 = 0x62;
const OP_F64_LT: u8 = 0x63;
const OP_F64_GT: u8 = 0x64;
const OP_F64_LE: u8 = 0x65;
const OP_F64_GE: u8 = 0x66;

const OP_I32_ADD: u8 = 0x6A;
const OP_I32_SUB: u8 = 0x6B;
const OP_I32_MUL: u8 = 0x6C;
const OP_I32_AND: u8 = 0x71;
const OP_I32_OR: u8 = 0x72;
const OP_I32_XOR: u8 = 0x73;
const OP_I32_SHL: u8 = 0x74;
const OP_I32_SHR_U: u8 = 0x76;

const OP_I64_CLZ: u8 = 0x79;
const OP_I64_CTZ: u8 = 0x7A;
const OP_I64_POPCNT: u8 = 0x7B;
const OP_I64_ADD: u8 = 0x7C;
const OP_I64_SUB: u8 = 0x7D;
const OP_I64_MUL: u8 = 0x7E;
const OP_I64_DIV_S: u8 = 0x7F;
const OP_I64_DIV_U: u8 = 0x80;
const OP_I64_REM_S: u8 = 0x81;
const OP_I64_REM_U: u8 = 0x82;
const OP_I64_AND: u8 = 0x83;
const OP_I64_OR: u8 = 0x84;
const OP_I64_XOR: u8 = 0x85;
const OP_I64_SHL: u8 = 0x86;
const OP_I64_SHR_S: u8 = 0x87;
const OP_I64_SHR_U: u8 = 0x88;

const OP_F64_ABS: u8 = 0x99;
const OP_F64_NEG: u8 = 0x9A;
const OP_F64_CEIL: u8 = 0x9B;
const OP_F64_FLOOR: u8 = 0x9C;
const OP_F64_TRUNC: u8 = 0x9D;
const OP_F64_NEAREST: u8 = 0x9E;
const OP_F64_SQRT: u8 = 0x9F;
const OP_F64_ADD: u8 = 0xA0;
const OP_F64_SUB: u8 = 0xA1;
const OP_F64_MUL: u8 = 0xA2;
const OP_F64_DIV: u8 = 0xA3;

const OP_I32_WRAP_I64: u8 = 0xA7;
const OP_I64_TRUNC_F64_S: u8 = 0xB0;
const OP_I64_TRUNC_F64_U: u8 = 0xB1;
const OP_I64_EXTEND_I32_U: u8 = 0xAD;
const OP_F32_DEMOTE_F64: u8 = 0xB6;
const OP_F64_CONVERT_I64_S: u8 = 0xB9;
const OP_F64_CONVERT_I64_U: u8 = 0xBA;
const OP_F64_PROMOTE_F32: u8 = 0xBB;
const OP_I32_REINTERPRET_F32: u8 = 0xBC;
const OP_I64_REINTERPRET_F64: u8 = 0xBD;
const OP_F32_REINTERPRET_I32: u8 = 0xBE;
const OP_F64_REINTERPRET_I64: u8 = 0xBF;
const OP_I64_EXTEND8_S: u8 = 0xC2;
const OP_I64_EXTEND16_S: u8 = 0xC3;
const OP_I64_EXTEND32_S: u8 = 0xC4;

const SCRATCH_ADDR: i32 = 0x1000; // WASI iovecs / runtime scratch (above 4096 guard page)
const RODATA_BASE: i32 = 0x1200;

const Buf = struct {
    alloc: std.mem.Allocator,
    data: std.ArrayListUnmanaged(u8) = .{},

    fn deinit(self: *Buf) void {
        self.data.deinit(self.alloc);
    }
    fn b(self: *Buf, byte: u8) !void {
        try self.data.append(self.alloc, byte);
    }
    fn bytes(self: *Buf, s: []const u8) !void {
        try self.data.appendSlice(self.alloc, s);
    }
    fn u32Leb(self: *Buf, val: u32) !void {
        var v = val;
        while (true) {
            var byte: u8 = @truncate(v & 0x7F);
            v >>= 7;
            if (v != 0) byte |= 0x80;
            try self.b(byte);
            if (v == 0) break;
        }
    }
    fn i32Leb(self: *Buf, val: i32) !void {
        var v = val;
        while (true) {
            var byte: u8 = @bitCast(@as(i8, @truncate(v & 0x7F)));
            v >>= 7;
            const sign_bit = (byte & 0x40) != 0;
            const done = (v == 0 and !sign_bit) or (v == -1 and sign_bit);
            if (!done) byte |= 0x80;
            try self.b(byte);
            if (done) break;
        }
    }
    fn i64Leb(self: *Buf, val: i64) !void {
        var v = val;
        while (true) {
            var byte: u8 = @bitCast(@as(i8, @truncate(v & 0x7F)));
            v >>= 7;
            const sign_bit = (byte & 0x40) != 0;
            const done = (v == 0 and !sign_bit) or (v == -1 and sign_bit);
            if (!done) byte |= 0x80;
            try self.b(byte);
            if (done) break;
        }
    }
    fn str(self: *Buf, s: []const u8) !void {
        try self.u32Leb(@intCast(s.len));
        try self.bytes(s);
    }
    fn f64Const(self: *Buf, val: f64) !void {
        try self.b(OP_F64_CONST);
        const bits: u64 = @bitCast(val);
        var arr: [8]u8 = undefined;
        std.mem.writeInt(u64, &arr, bits, .little);
        try self.bytes(&arr);
    }

    // Convenience instruction helpers
    fn i32c(self: *Buf, v: i32) !void {
        try self.b(OP_I32_CONST);
        try self.i32Leb(v);
    }
    fn i64c(self: *Buf, v: i64) !void {
        try self.b(OP_I64_CONST);
        try self.i64Leb(v);
    }
    fn lget(self: *Buf, idx: u32) !void {
        try self.b(OP_LOCAL_GET);
        try self.u32Leb(idx);
    }
    fn lset(self: *Buf, idx: u32) !void {
        try self.b(OP_LOCAL_SET);
        try self.u32Leb(idx);
    }
    fn ltee(self: *Buf, idx: u32) !void {
        try self.b(OP_LOCAL_TEE);
        try self.u32Leb(idx);
    }
    fn gget(self: *Buf, idx: u32) !void {
        try self.b(OP_GLOBAL_GET);
        try self.u32Leb(idx);
    }
    fn gset(self: *Buf, idx: u32) !void {
        try self.b(OP_GLOBAL_SET);
        try self.u32Leb(idx);
    }
    fn call(self: *Buf, fn_idx: u32) !void {
        try self.b(OP_CALL);
        try self.u32Leb(fn_idx);
    }
    fn memop(self: *Buf, opcode: u8, align_pow2: u32, offset: u32) !void {
        try self.b(opcode);
        try self.u32Leb(align_pow2);
        try self.u32Leb(offset);
    }
    fn emitSection(self: *Buf, id: u8, body: *const Buf) !void {
        try self.b(id);
        try self.u32Leb(@intCast(body.data.items.len));
        try self.bytes(body.data.items);
    }
};

// Imported WASI function indices
const IMP_FD_WRITE: u32 = 0;
const IMP_FD_READ: u32 = 1;
const IMP_PROC_EXIT: u32 = 2;
const IMP_RANDOM_GET: u32 = 3;
const IMP_CLOCK_TIME_GET: u32 = 4;
const IMP_ARGS_SIZES_GET: u32 = 5;
const IMP_ARGS_GET: u32 = 6;
const NUM_IMPORTS: u32 = 7;

// Builtin helper function indices (immediately after imports)
const RT_CHK_PTR: u32 = NUM_IMPORTS + 0;
const RT_MALLOC: u32 = NUM_IMPORTS + 1;
const RT_FREE: u32 = NUM_IMPORTS + 2;
const RT_MEMCPY: u32 = NUM_IMPORTS + 3;
const RT_MEMSET: u32 = NUM_IMPORTS + 4;
const RT_WRITE_FD: u32 = NUM_IMPORTS + 5;
const RT_PRINT_STR: u32 = NUM_IMPORTS + 6;
const RT_PRINT_INT: u32 = NUM_IMPORTS + 7;
const RT_STR_LEN: u32 = NUM_IMPORTS + 8;
const RT_STR_NEW: u32 = NUM_IMPORTS + 9;
const RT_STR_CONCAT: u32 = NUM_IMPORTS + 10;
const RT_STR_EQ: u32 = NUM_IMPORTS + 11;
const RT_STR_SUB: u32 = NUM_IMPORTS + 12;
const RT_STR_CHAR_AT: u32 = NUM_IMPORTS + 13;
const RT_INT_TO_STR: u32 = NUM_IMPORTS + 14;
const RT_STR_TO_INT: u32 = NUM_IMPORTS + 15;
const RT_ARRAY_NEW: u32 = NUM_IMPORTS + 16;
const RT_ARRAY_PUSH: u32 = NUM_IMPORTS + 17;
const RT_ARRAY_GET: u32 = NUM_IMPORTS + 18;
const RT_ARRAY_SET: u32 = NUM_IMPORTS + 19;
const RT_ARRAY_LEN: u32 = NUM_IMPORTS + 20;
const RT_ARRAY_FREE: u32 = NUM_IMPORTS + 21;
const RT_STR_SPLIT: u32 = NUM_IMPORTS + 22;
const RT_MAP_HASH: u32 = NUM_IMPORTS + 23;
const RT_MAP_NEW: u32 = NUM_IMPORTS + 24;
const RT_MAP_SET: u32 = NUM_IMPORTS + 25;
const RT_MAP_GET: u32 = NUM_IMPORTS + 26;
const RT_MAP_HAS: u32 = NUM_IMPORTS + 27;
const RT_MAP_DEL: u32 = NUM_IMPORTS + 28;
const RT_MAP_LEN: u32 = NUM_IMPORTS + 29;
const RT_MAP_FREE: u32 = NUM_IMPORTS + 30;
const RT_RANDOM_U64: u32 = NUM_IMPORTS + 31;
const RT_RANDOM_BYTES: u32 = NUM_IMPORTS + 32;
const RT_CONST_TIME_EQ: u32 = NUM_IMPORTS + 33;
const RT_SECURE_ZERO: u32 = NUM_IMPORTS + 34;
const RT_CHECKED_ADD: u32 = NUM_IMPORTS + 35;
const RT_CHECKED_SUB: u32 = NUM_IMPORTS + 36;
const RT_CHECKED_MUL: u32 = NUM_IMPORTS + 37;
const RT_DIV_I64: u32 = NUM_IMPORTS + 38;
const RT_MOD_I64: u32 = NUM_IMPORTS + 39;
const RT_SHL_I64: u32 = NUM_IMPORTS + 40;
const RT_SHR_I64: u32 = NUM_IMPORTS + 41;
const RT_USHR_I64: u32 = NUM_IMPORTS + 42;
const RT_TIME_NS: u32 = NUM_IMPORTS + 43;
const RT_FLOAT_TO_STR: u32 = NUM_IMPORTS + 44;
const RT_STR_TO_FLOAT: u32 = NUM_IMPORTS + 45;
const RT_PRINT_FLOAT: u32 = NUM_IMPORTS + 46;
const RT_SIN: u32 = NUM_IMPORTS + 47;
const RT_COS: u32 = NUM_IMPORTS + 48;
const RT_CALL_INDIRECT: u32 = NUM_IMPORTS + 49;
const RT_ARGV: u32 = NUM_IMPORTS + 50;
const RT_CHK_PTR_N: u32 = NUM_IMPORTS + 51;
const NUM_RT_HELPERS: u32 = 52;

const USER_FN_BASE: u32 = NUM_IMPORTS + NUM_RT_HELPERS;

// Globals
const GLB_HEAP_PTR: u32 = 0; // mut i32
const GLB_STACK_PTR: u32 = 1; // mut i32
const GLB_HEAP_SECRET: u32 = 2; // mut i64
const GLB_ARGC: u32 = 3; // mut i32
const GLB_ARGV_PTR: u32 = 4; // mut i32
const GLB_HEAP_BASE: u32 = 5; // const i32
const GLB_PAGE_DIR: u32 = 6; // const i32

// Type indices
const TY_4I32_TO_I32: u32 = 0; // (i32,i32,i32,i32)->i32
const TY_I32_TO_VOID: u32 = 1; // (i32)->()
const TY_2I32_TO_I32: u32 = 2; // (i32,i32)->i32
const TY_I32_I64_I32_TO_I32: u32 = 3; // (i32,i64,i32)->i32
const TY_VOID_TO_VOID: u32 = 4; // ()->()
const TY_I64_TO_VOID: u32 = 5; // (i64)->()
const TY_I64_I32_TO_VOID: u32 = 6; // (i64,i32)->()
const TY_I32_2I64_TO_I64: u32 = 7; // (i32,i64,i64)->i64
const TY_9I64_TO_I64: u32 = 8; // (i64 x 9)->i64 (call_indirect dispatcher)
const TY_2I64_TO_VOID: u32 = 9; // (i64,i64)->()
// User & helper functions: param_count 0..8 -> type idx 10 + param_count
const TY_ARITY_BASE: u32 = 10; // (i64 x N)->i64 for N = 0..8

fn writeFnBody(out_sec: *Buf, locals_i64: u32, locals_i32: u32, locals_f64: u32, body: *const Buf) !void {
    var fn_buf = Buf{ .alloc = out_sec.alloc };
    defer fn_buf.deinit();
    var groups: u32 = 0;
    if (locals_i64 > 0) groups += 1;
    if (locals_i32 > 0) groups += 1;
    if (locals_f64 > 0) groups += 1;
    try fn_buf.u32Leb(groups);
    if (locals_i64 > 0) {
        try fn_buf.u32Leb(locals_i64);
        try fn_buf.b(T_I64);
    }
    if (locals_i32 > 0) {
        try fn_buf.u32Leb(locals_i32);
        try fn_buf.b(T_I32);
    }
    if (locals_f64 > 0) {
        try fn_buf.u32Leb(locals_f64);
        try fn_buf.b(T_F64);
    }
    try fn_buf.bytes(body.data.items);
    try fn_buf.b(OP_END);
    try out_sec.u32Leb(@intCast(fn_buf.data.items.len));
    try out_sec.bytes(fn_buf.data.items);
}

fn emitEdgePhisWasm(b: *Buf, f: *const IRFn, from_blk: u16, to_blk: u16, vreg_base: u32, phi_tmp_base: u32) !void {
    const dest_b = &f.blocks[to_blk];
    var phi_n: u16 = 0;
    while (phi_n < dest_b.inst_count and dest_b.insts[phi_n].op == .phi) : (phi_n += 1) {
        const p = dest_b.insts[phi_n];
        var src_v: u16 = 0;
        for (0..p.arg_count) |ai| {
            if (p.phi_blocks[ai] == from_blk) {
                src_v = p.args[ai];
                break;
            }
        }
        try b.lget(vreg_base + src_v);
        try b.lset(phi_tmp_base + phi_n);
    }
    var k: u16 = 0;
    while (k < phi_n) : (k += 1) {
        const p = dest_b.insts[k];
        if (p.dest != 0) {
            try b.lget(phi_tmp_base + k);
            try b.lset(vreg_base + p.dest);
        }
    }
}

pub fn emitWasm(alloc: std.mem.Allocator, module: *const IRModule, source: []const u8) ![]u8 {
    // 1. Build rodata blob starting at RODATA_BASE (0x1000)
    var rodata = Buf{ .alloc = alloc };
    defer rodata.deinit();
    var str_vaddrs: [512]i64 = .{0} ** 512;
    for (0..module.string_count) |si| {
        const off = module.string_offsets[si];
        const len = module.string_lens[si];
        const s = module.strings[off..][0..len];
        while ((rodata.data.items.len & 7) != 0) try rodata.b(0);
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(u64, &hdr, len, .little);
        try rodata.bytes(&hdr);
        str_vaddrs[si] = @as(i64, RODATA_BASE) + @as(i64, @intCast(rodata.data.items.len));
        try rodata.bytes(s);
        try rodata.b(0);
    }

    const rodata_end: u32 = @as(u32, @intCast(RODATA_BASE)) + @as(u32, @intCast(rodata.data.items.len));
    const page_dir_base: u32 = (rodata_end + 15) & ~@as(u32, 15);
    const page_dir_size: u32 = 65536; // 16,384 x 4KiB page first-chunk pointers (64 MiB)
    const stack_base: u32 = page_dir_base + page_dir_size;
    const stack_size: u32 = 512 * 1024; // 512 KiB shadow stack for alloca/addr_of
    const heap_init: u32 = stack_base + stack_size;
    const init_pages: u32 = @max(((heap_init + 65536 + 65535) / 65536), 32);

    // Find main()
    var main_fi: ?u32 = null;
    for (module.fns[0..module.fn_count], 0..) |*f, fi| {
        const fsrc = module.sourceFor(f.source_id, source);
        const fname = if (@as(usize, f.name_start) + @as(usize, f.name_len) <= fsrc.len)
            fsrc[f.name_start..][0..f.name_len]
        else
            "";
        if (util.eql(fname, "main")) {
            main_fi = @intCast(fi);
            break;
        }
    }
    const mfi = main_fi orelse return error.MissingMain;

    var wasm = Buf{ .alloc = alloc };
    errdefer wasm.deinit();

    // Header: \0asm + version 1
    try wasm.bytes("\x00asm\x01\x00\x00\x00");

    // ── Section 1: Type ──
    {
        var sec = Buf{ .alloc = alloc };
        defer sec.deinit();
        try sec.u32Leb(TY_ARITY_BASE + 9);
        // 0: (i32,i32,i32,i32)->i32
        try sec.bytes(&.{ 0x60, 4, T_I32, T_I32, T_I32, T_I32, 1, T_I32 });
        // 1: (i32)->()
        try sec.bytes(&.{ 0x60, 1, T_I32, 0 });
        // 2: (i32,i32)->i32
        try sec.bytes(&.{ 0x60, 2, T_I32, T_I32, 1, T_I32 });
        // 3: (i32,i64,i32)->i32
        try sec.bytes(&.{ 0x60, 3, T_I32, T_I64, T_I32, 1, T_I32 });
        // 4: ()->()
        try sec.bytes(&.{ 0x60, 0, 0 });
        // 5: (i64)->()
        try sec.bytes(&.{ 0x60, 1, T_I64, 0 });
        // 6: (i64,i32)->()
        try sec.bytes(&.{ 0x60, 2, T_I64, T_I32, 0 });
        // 7: (i32,i64,i64)->i64
        try sec.bytes(&.{ 0x60, 3, T_I32, T_I64, T_I64, 1, T_I64 });
        // 8: (i64 x 9)->i64
        try sec.bytes(&.{ 0x60, 9, T_I64, T_I64, T_I64, T_I64, T_I64, T_I64, T_I64, T_I64, T_I64, 1, T_I64 });
        // 9: (i64,i64)->()
        try sec.bytes(&.{ 0x60, 2, T_I64, T_I64, 0 });
        // 10..18: (i64 x N)->i64 for N=0..8
        for (0..9) |n| {
            try sec.b(0x60);
            try sec.u32Leb(@intCast(n));
            for (0..n) |_| try sec.b(T_I64);
            try sec.bytes(&.{ 1, T_I64 });
        }
        try wasm.emitSection(1, &sec);
    }

    // ── Section 2: Import (wasi_snapshot_preview1) ──
    {
        var sec = Buf{ .alloc = alloc };
        defer sec.deinit();
        try sec.u32Leb(NUM_IMPORTS);
        const imps = [_]struct { name: []const u8, ty: u32 }{
            .{ .name = "fd_write", .ty = TY_4I32_TO_I32 },
            .{ .name = "fd_read", .ty = TY_4I32_TO_I32 },
            .{ .name = "proc_exit", .ty = TY_I32_TO_VOID },
            .{ .name = "random_get", .ty = TY_2I32_TO_I32 },
            .{ .name = "clock_time_get", .ty = TY_I32_I64_I32_TO_I32 },
            .{ .name = "args_sizes_get", .ty = TY_2I32_TO_I32 },
            .{ .name = "args_get", .ty = TY_2I32_TO_I32 },
        };
        for (imps) |imp| {
            try sec.str("wasi_snapshot_preview1");
            try sec.str(imp.name);
            try sec.b(0x00); // func
            try sec.u32Leb(imp.ty);
        }
        try wasm.emitSection(2, &sec);
    }

    // ── Section 3: Function signatures ──
    const start_fn_idx: u32 = USER_FN_BASE + module.fn_count;
    {
        var sec = Buf{ .alloc = alloc };
        defer sec.deinit();
        try sec.u32Leb(NUM_RT_HELPERS + module.fn_count + 1);
        // Runtime helper types
        const rt_tys = [NUM_RT_HELPERS]u32{
            TY_I64_TO_VOID, // 0: chk_ptr
            TY_ARITY_BASE + 1, // 1: malloc(sz) -> ptr
            TY_I64_TO_VOID, // 2: free(ptr)
            TY_ARITY_BASE + 3, // 3: memcpy(d,s,n) -> d
            TY_ARITY_BASE + 3, // 4: memset(d,c,n) -> d
            TY_I32_2I64_TO_I64, // 5: write_fd
            TY_I64_I32_TO_VOID, // 6: print_str(s, nl)
            TY_I64_TO_VOID, // 7: print_int(v)
            TY_ARITY_BASE + 1, // 8: str_len(s)
            TY_ARITY_BASE + 3, // 9: str_new(ptr, len, has_len)
            TY_ARITY_BASE + 2, // 10: str_concat(a,b)
            TY_ARITY_BASE + 2, // 11: str_eq(a,b)
            TY_ARITY_BASE + 4, // 12: str_sub(s,st,arg2,is_slice)
            TY_ARITY_BASE + 2, // 13: str_char_at(s,idx)
            TY_ARITY_BASE + 1, // 14: int_to_str(v)
            TY_ARITY_BASE + 1, // 15: str_to_int(s)
            TY_ARITY_BASE + 1, // 16: array_new(cap)
            TY_ARITY_BASE + 2, // 17: array_push(h,v) -> i64(0)
            TY_ARITY_BASE + 2, // 18: array_get(h,idx)
            TY_ARITY_BASE + 3, // 19: array_set(h,idx,v)
            TY_ARITY_BASE + 1, // 20: array_len(h)
            TY_I64_TO_VOID, // 21: array_free(h)
            TY_ARITY_BASE + 2, // 22: str_split(s,delim)
            TY_ARITY_BASE + 2, // 23: map_hash(k,flags)
            TY_ARITY_BASE + 1, // 24: map_new(flags)
            TY_ARITY_BASE + 3, // 25: map_set(h,k,v) -> 0
            TY_ARITY_BASE + 2, // 26: map_get(h,k)
            TY_ARITY_BASE + 2, // 27: map_has(h,k)
            TY_ARITY_BASE + 2, // 28: map_del(h,k)
            TY_ARITY_BASE + 1, // 29: map_len(h)
            TY_I64_TO_VOID, // 30: map_free(h)
            TY_ARITY_BASE + 0, // 31: random_u64()
            TY_ARITY_BASE + 2, // 32: random_bytes(dst,n)
            TY_ARITY_BASE + 3, // 33: const_time_eq(a,b,n)
            TY_ARITY_BASE + 2, // 34: secure_zero(p,n)->0
            TY_ARITY_BASE + 2, // 35: checked_add
            TY_ARITY_BASE + 2, // 36: checked_sub
            TY_ARITY_BASE + 2, // 37: checked_mul
            TY_ARITY_BASE + 2, // 38: div_i64
            TY_ARITY_BASE + 2, // 39: mod_i64
            TY_ARITY_BASE + 2, // 40: shl_i64
            TY_ARITY_BASE + 2, // 41: shr_i64
            TY_ARITY_BASE + 2, // 42: ushr_i64
            TY_ARITY_BASE + 0, // 43: time_ns
            TY_ARITY_BASE + 1, // 44: float_to_str
            TY_ARITY_BASE + 1, // 45: str_to_float
            TY_I64_I32_TO_VOID, // 46: print_float(bits, nl)
            TY_ARITY_BASE + 1, // 47: sin
            TY_ARITY_BASE + 1, // 48: cos
            TY_9I64_TO_I64, // 49: call_indirect
            TY_ARITY_BASE + 1, // 50: argv(idx)
            TY_2I64_TO_VOID, // 51: chk_ptr_n(p, acc_sz)
        };
        for (rt_tys) |ty| try sec.u32Leb(ty);
        for (module.fns[0..module.fn_count]) |*f| {
            try sec.u32Leb(TY_ARITY_BASE + @min(f.param_count, 8));
        }
        try sec.u32Leb(TY_VOID_TO_VOID); // _start
        try wasm.emitSection(3, &sec);
    }

    // ── Section 5: Memory ──
    {
        var sec = Buf{ .alloc = alloc };
        defer sec.deinit();
        try sec.u32Leb(1);
        try sec.b(0x00); // min only
        try sec.u32Leb(init_pages);
        try wasm.emitSection(5, &sec);
    }

    // ── Section 6: Globals ──
    {
        var sec = Buf{ .alloc = alloc };
        defer sec.deinit();
        try sec.u32Leb(7);
        // 0: HEAP_PTR (mut i32)
        try sec.b(T_I32);
        try sec.b(0x01);
        try sec.i32c(@intCast(heap_init));
        try sec.b(OP_END);
        // 1: STACK_PTR (mut i32)
        try sec.b(T_I32);
        try sec.b(0x01);
        try sec.i32c(@intCast(stack_base));
        try sec.b(OP_END);
        // 2: HEAP_SECRET (mut i64)
        try sec.b(T_I64);
        try sec.b(0x01);
        try sec.i64c(@bitCast(@as(u64, 0x9e3779b97f4a7c15)));
        try sec.b(OP_END);
        // 3: ARGC (mut i32)
        try sec.b(T_I32);
        try sec.b(0x01);
        try sec.i32c(0);
        try sec.b(OP_END);
        // 4: ARGV_PTR (mut i32)
        try sec.b(T_I32);
        try sec.b(0x01);
        try sec.i32c(0);
        try sec.b(OP_END);
        // 5: HEAP_BASE (const i32)
        try sec.b(T_I32);
        try sec.b(0x00);
        try sec.i32c(@intCast(heap_init));
        try sec.b(OP_END);
        // 6: PAGE_DIR (const i32)
        try sec.b(T_I32);
        try sec.b(0x00);
        try sec.i32c(@intCast(page_dir_base));
        try sec.b(OP_END);
        try wasm.emitSection(6, &sec);
    }

    // ── Section 7: Export ──
    {
        var sec = Buf{ .alloc = alloc };
        defer sec.deinit();
        try sec.u32Leb(2);
        try sec.str("memory");
        try sec.b(0x02);
        try sec.u32Leb(0);
        try sec.str("_start");
        try sec.b(0x00);
        try sec.u32Leb(start_fn_idx);
        try wasm.emitSection(7, &sec);
    }

    // ── Section 10: Code (Runtime helpers + User functions + _start) ──
    {
        var sec = Buf{ .alloc = alloc };
        defer sec.deinit();
        try sec.u32Leb(NUM_RT_HELPERS + module.fn_count + 1);

        try emitRuntimeHelpers(&sec, alloc, module, mfi);

        // User functions
        for (module.fns[0..module.fn_count]) |*f| {
            try emitUserFn(&sec, alloc, module, source, f, &str_vaddrs);
        }

        // _start
        {
            var sb = Buf{ .alloc = alloc };
            defer sb.deinit();
            // Seed HEAP_SECRET via random_get(SCRATCH_ADDR, 8)
            try sb.i32c(SCRATCH_ADDR);
            try sb.i32c(8);
            try sb.call(IMP_RANDOM_GET);
            try sb.b(OP_DROP);
            try sb.i32c(SCRATCH_ADDR);
            try sb.memop(OP_I64_LOAD, 3, 0);
            try sb.i64c(1);
            try sb.b(OP_I64_OR);
            try sb.gset(GLB_HEAP_SECRET);

            // Init WASI argc/argv pointers via args_sizes_get
            try sb.i32c(SCRATCH_ADDR);
            try sb.i32c(SCRATCH_ADDR + 4);
            try sb.call(IMP_ARGS_SIZES_GET);
            try sb.b(OP_DROP);
            try sb.i32c(SCRATCH_ADDR);
            try sb.memop(OP_I32_LOAD, 2, 0);
            try sb.ltee(0); // argc
            try sb.gset(GLB_ARGC);
            try sb.lget(0);
            try sb.b(OP_I32_EQZ);
            try sb.b(OP_IF);
            try sb.b(T_VOID);
            try sb.b(OP_ELSE);
            // argv_arr = malloc(argc * 4 + argbuf_size + 16)
            try sb.lget(0);
            try sb.i32c(2);
            try sb.b(OP_I32_SHL);
            try sb.lset(1); // argv_bytes
            try sb.lget(1);
            try sb.i32c(SCRATCH_ADDR + 4);
            try sb.memop(OP_I32_LOAD, 2, 0);
            try sb.b(OP_I32_ADD);
            try sb.b(OP_I64_EXTEND_I32_U);
            try sb.call(RT_MALLOC);
            try sb.b(OP_I32_WRAP_I64);
            try sb.ltee(2); // argv_ptr
            try sb.gset(GLB_ARGV_PTR);
            try sb.lget(2);
            try sb.lget(2);
            try sb.lget(1);
            try sb.b(OP_I32_ADD);
            try sb.call(IMP_ARGS_GET);
            try sb.b(OP_DROP);
            try sb.b(OP_END);

            var init_args: u32 = 0;
            while (init_args < module.fns[mfi].param_count) : (init_args += 1) {
                try sb.i64c(0);
            }
            try sb.call(USER_FN_BASE + mfi);
            try sb.b(OP_I32_WRAP_I64);
            try sb.call(IMP_PROC_EXIT);
            try writeFnBody(&sec, 0, 3, 0, &sb);
        }

        try wasm.emitSection(10, &sec);
    }

    // ── Section 11: Data (rodata at 0x1000) ──
    if (rodata.data.items.len > 0) {
        var sec = Buf{ .alloc = alloc };
        defer sec.deinit();
        try sec.u32Leb(1);
        try sec.b(0x00); // active segment mem 0
        try sec.i32c(RODATA_BASE);
        try sec.b(OP_END);
        try sec.str(rodata.data.items);
        try wasm.emitSection(11, &sec);
    }

    return try wasm.data.toOwnedSlice(alloc);
}

fn emitUserFn(sec: *Buf, alloc: std.mem.Allocator, module: *const IRModule, source: []const u8, f: *const IRFn, str_vaddrs: *const [512]i64) !void {
    var b = Buf{ .alloc = alloc };
    defer b.deinit();

    const pcount: u32 = @min(f.param_count, 8);
    // Local layout:
    // 0..pcount-1 : params (i64)
    // pcount..pcount+total_locals-1 : IR local slots (1-based -> pcount + slot - 1)
    // vreg_base..vreg_base+vreg_count : IR vregs (i64)
    // phi_tmp_base.. : phi swap temporaries (i64, max 64)
    // i32 locals: pc, prev_pc, saved_sp
    const loc_base: u32 = pcount;
    const n_locs: u32 = @max(f.total_locals, 1);
    const vreg_base: u32 = loc_base + n_locs;
    const n_vregs: u32 = @max(f.vreg_count + 2, 4);
    const phi_tmp_base: u32 = vreg_base + n_vregs;
    const n_phi_tmps: u32 = 64;
    const total_extra_i64: u32 = n_locs + n_vregs + n_phi_tmps;

    const i32_base: u32 = pcount + total_extra_i64;
    const l_pc: u32 = i32_base + 0;
    const l_frame_base: u32 = i32_base + 1;
    const l_saved_sp: u32 = i32_base + 2;

    // Save shadow SP and allocate frame for addr_taken/alloca
    try b.gget(GLB_STACK_PTR);
    try b.ltee(l_saved_sp);
    try b.lset(l_frame_base);
    const frame_bytes: i32 = @intCast((@as(u32, f.total_locals) + 4) * 8);
    try b.lget(l_saved_sp);
    try b.i32c(frame_bytes);
    try b.b(OP_I32_ADD);
    try b.gset(GLB_STACK_PTR);

    // Initialize params into slots & stack frame
    for (0..pcount) |pi| {
        const slot = f.param_slots[pi];
        if (slot > 0) {
            try b.lget(@intCast(pi));
            try b.lset(loc_base + slot - 1);
            try b.lget(l_frame_base);
            try b.lget(@intCast(pi));
            try b.memop(OP_I64_STORE, 3, (slot - 1) * 8);
        }
    }

    const n_blocks: u32 = f.block_count;
    const has_cfg_loop: bool = n_blocks > 1 or blk_cfg: {
        for (f.blocks[0..n_blocks]) |*blk_c| {
            for (blk_c.insts[0..blk_c.inst_count]) |ci| {
                if (ci.op == .jump or ci.op == .cond_jump) break :blk_cfg true;
            }
        }
        break :blk_cfg false;
    };
    if (has_cfg_loop) {
        try b.i32c(0);
        try b.lset(l_pc);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        // Nested blocks: outermost B_{N-1} .. innermost B_0
        var bi_rev: u32 = n_blocks;
        while (bi_rev > 0) {
            bi_rev -= 1;
            try b.b(OP_BLOCK);
            try b.b(T_VOID);
        }
        try b.lget(l_pc);
        try b.b(OP_BR_TABLE);
        try b.u32Leb(n_blocks);
        for (0..n_blocks) |k| try b.u32Leb(@intCast(k));
        try b.u32Leb(n_blocks - 1);
    }

    for (f.blocks[0..n_blocks], 0..) |*blk, bi| {
        if (has_cfg_loop) try b.b(OP_END); // exit block B_{bi} -> land at block code

        const cfg_loop_depth: u32 = if (has_cfg_loop) (n_blocks - 1 - @as(u32, @intCast(bi))) else 0;

        for (blk.insts[0..blk.inst_count]) |inst| {
            if (inst.op == .phi or inst.op == .nop or inst.op == .struct_decl or inst.op == .module_import) continue;
            switch (inst.op) {
                .const_int => {
                    try b.i64c(inst.imm);
                    try b.lset(vreg_base + inst.dest);
                },
                .const_str => {
                    try b.i64c(str_vaddrs[inst.str_idx]);
                    try b.lset(vreg_base + inst.dest);
                },
                .copy => {
                    try b.lget(vreg_base + inst.src1);
                    try b.lset(vreg_base + inst.dest);
                },
                .load_local => {
                    const slot_idx: u32 = if (inst.slot > 0) inst.slot - 1 else 0;
                    if (inst.slot > 0 and inst.slot < f.local_addr_taken.len and f.local_addr_taken[inst.slot]) {
                        try b.lget(l_frame_base);
                        try b.memop(OP_I64_LOAD, 3, slot_idx * 8);
                    } else {
                        try b.lget(loc_base + slot_idx);
                    }
                    try b.lset(vreg_base + inst.dest);
                },
                .store_local => {
                    const slot_idx: u32 = if (inst.slot > 0) inst.slot - 1 else 0;
                    if (inst.slot > 0 and inst.slot < f.local_addr_taken.len and f.local_addr_taken[inst.slot]) {
                        try b.lget(l_frame_base);
                        try b.lget(vreg_base + inst.src1);
                        try b.memop(OP_I64_STORE, 3, slot_idx * 8);
                    } else {
                        try b.lget(vreg_base + inst.src1);
                        try b.lset(loc_base + slot_idx);
                    }
                },
                .addr_of => {
                    const slot_idx: u32 = if (inst.slot > 0) inst.slot - 1 else 0;
                    try b.lget(l_frame_base);
                    try b.i32c(@intCast(slot_idx * 8));
                    try b.b(OP_I32_ADD);
                    try b.b(OP_I64_EXTEND_I32_U);
                    try b.lset(vreg_base + inst.dest);
                },
                .alloca => {
                    // Allocate from global STACK_PTR (zeroed, restored on fn ret)
                    const sz_i32: i32 = @intCast((@max(inst.imm, 8) + 7) & ~@as(i64, 7));
                    try b.gget(GLB_STACK_PTR);
                    try b.b(OP_I64_EXTEND_I32_U);
                    try b.lset(vreg_base + inst.dest);
                    try b.gget(GLB_STACK_PTR);
                    try b.i32c(sz_i32);
                    try b.b(OP_I32_ADD);
                    try b.gset(GLB_STACK_PTR);
                    try b.lget(vreg_base + inst.dest);
                    try b.i64c(0);
                    try b.i64c(sz_i32);
                    try b.call(RT_MEMSET);
                    try b.b(OP_DROP);
                },
                .deref_load, .load_mem => {
                    try b.lget(vreg_base + inst.src1);
                    try b.i64c(8);
                    try b.call(RT_CHK_PTR_N);
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_I32_WRAP_I64);
                    try b.memop(OP_I64_LOAD, 3, 0);
                    try b.lset(vreg_base + inst.dest);
                },
                .deref_store, .store_mem => {
                    try b.lget(vreg_base + inst.src1);
                    try b.i64c(8);
                    try b.call(RT_CHK_PTR_N);
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_I32_WRAP_I64);
                    try b.lget(vreg_base + inst.src2);
                    try b.memop(OP_I64_STORE, 3, 0);
                },
                .field_access => {
                    try b.lget(vreg_base + inst.src1);
                    try b.i64c(@as(i64, inst.field_offset) + 8);
                    try b.call(RT_CHK_PTR_N);
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_I32_WRAP_I64);
                    try b.memop(OP_I64_LOAD, 3, inst.field_offset);
                    try b.lset(vreg_base + inst.dest);
                },
                .field_store => {
                    try b.lget(vreg_base + inst.src1);
                    try b.i64c(@as(i64, inst.field_offset) + 8);
                    try b.call(RT_CHK_PTR_N);
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_I32_WRAP_I64);
                    try b.lget(vreg_base + inst.src2);
                    try b.memop(OP_I64_STORE, 3, inst.field_offset);
                },
                .add => try emitBinOp(&b, vreg_base, inst, OP_I64_ADD),
                .sub => try emitBinOp(&b, vreg_base, inst, OP_I64_SUB),
                .mul => try emitBinOp(&b, vreg_base, inst, OP_I64_MUL),
                .div => try emitBinCall(&b, vreg_base, inst, RT_DIV_I64),
                .udiv => try emitBinOp(&b, vreg_base, inst, OP_I64_DIV_U),
                .@"mod" => try emitBinCall(&b, vreg_base, inst, RT_MOD_I64),
                .umod => try emitBinOp(&b, vreg_base, inst, OP_I64_REM_U),
                .shl => try emitBinCall(&b, vreg_base, inst, RT_SHL_I64),
                .shr => try emitBinCall(&b, vreg_base, inst, RT_SHR_I64),
                .ushr => try emitBinCall(&b, vreg_base, inst, RT_USHR_I64),
                .bit_and => try emitBinOp(&b, vreg_base, inst, OP_I64_AND),
                .bit_or => try emitBinOp(&b, vreg_base, inst, OP_I64_OR),
                .bit_xor => try emitBinOp(&b, vreg_base, inst, OP_I64_XOR),
                .bit_not => {
                    try b.lget(vreg_base + inst.src1);
                    try b.i64c(-1);
                    try b.b(OP_I64_XOR);
                    try b.lset(vreg_base + inst.dest);
                },
                .neg => {
                    try b.i64c(0);
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_I64_SUB);
                    try b.lset(vreg_base + inst.dest);
                },
                .logic_not => {
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_I64_EQZ);
                    try b.b(OP_I64_EXTEND_I32_U);
                    try b.lset(vreg_base + inst.dest);
                },
                .sext8 => {
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_I64_EXTEND8_S);
                    try b.lset(vreg_base + inst.dest);
                },
                .sext16 => {
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_I64_EXTEND16_S);
                    try b.lset(vreg_base + inst.dest);
                },
                .sext32 => {
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_I64_EXTEND32_S);
                    try b.lset(vreg_base + inst.dest);
                },
                .zext8 => {
                    try b.lget(vreg_base + inst.src1);
                    try b.i64c(0xFF);
                    try b.b(OP_I64_AND);
                    try b.lset(vreg_base + inst.dest);
                },
                .zext16 => {
                    try b.lget(vreg_base + inst.src1);
                    try b.i64c(0xFFFF);
                    try b.b(OP_I64_AND);
                    try b.lset(vreg_base + inst.dest);
                },
                .zext32 => {
                    try b.lget(vreg_base + inst.src1);
                    try b.i64c(0xFFFF_FFFF);
                    try b.b(OP_I64_AND);
                    try b.lset(vreg_base + inst.dest);
                },
                .cmp_eq => try emitCmpOp(&b, vreg_base, inst, OP_I64_EQ),
                .cmp_ne => try emitCmpOp(&b, vreg_base, inst, OP_I64_NE),
                .cmp_lt => try emitCmpOp(&b, vreg_base, inst, OP_I64_LT_S),
                .cmp_le => try emitCmpOp(&b, vreg_base, inst, OP_I64_LE_S),
                .cmp_gt => try emitCmpOp(&b, vreg_base, inst, OP_I64_GT_S),
                .cmp_ge => try emitCmpOp(&b, vreg_base, inst, OP_I64_GE_S),
                .ucmp_lt => try emitCmpOp(&b, vreg_base, inst, OP_I64_LT_U),
                .ucmp_le => try emitCmpOp(&b, vreg_base, inst, OP_I64_LE_U),
                .ucmp_gt => try emitCmpOp(&b, vreg_base, inst, OP_I64_GT_U),
                .ucmp_ge => try emitCmpOp(&b, vreg_base, inst, OP_I64_GE_U),
                .fadd => try emitFBinOp(&b, vreg_base, inst, OP_F64_ADD),
                .fsub => try emitFBinOp(&b, vreg_base, inst, OP_F64_SUB),
                .fmul => try emitFBinOp(&b, vreg_base, inst, OP_F64_MUL),
                .fdiv => try emitFBinOp(&b, vreg_base, inst, OP_F64_DIV),
                .fneg => {
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_F64_REINTERPRET_I64);
                    try b.b(OP_F64_NEG);
                    try b.b(OP_I64_REINTERPRET_F64);
                    try b.lset(vreg_base + inst.dest);
                },
                .fcmp_eq => try emitFCmpOp(&b, vreg_base, inst, OP_F64_EQ),
                .fcmp_ne => try emitFCmpOp(&b, vreg_base, inst, OP_F64_NE),
                .fcmp_lt => try emitFCmpOp(&b, vreg_base, inst, OP_F64_LT),
                .fcmp_le => try emitFCmpOp(&b, vreg_base, inst, OP_F64_LE),
                .fcmp_gt => try emitFCmpOp(&b, vreg_base, inst, OP_F64_GT),
                .fcmp_ge => try emitFCmpOp(&b, vreg_base, inst, OP_F64_GE),
                .itof => {
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_F64_CONVERT_I64_S);
                    try b.b(OP_I64_REINTERPRET_F64);
                    try b.lset(vreg_base + inst.dest);
                },
                .uitof => {
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_F64_CONVERT_I64_U);
                    try b.b(OP_I64_REINTERPRET_F64);
                    try b.lset(vreg_base + inst.dest);
                },
                .ftoi => {
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_F64_REINTERPRET_I64);
                    try b.b(OP_I64_TRUNC_F64_S);
                    try b.lset(vreg_base + inst.dest);
                },
                .ftou => {
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_F64_REINTERPRET_I64);
                    try b.b(OP_I64_TRUNC_F64_U);
                    try b.lset(vreg_base + inst.dest);
                },
                .f64_to_f32 => {
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_F64_REINTERPRET_I64);
                    try b.b(OP_F32_DEMOTE_F64);
                    try b.b(OP_I32_REINTERPRET_F32);
                    try b.b(OP_I64_EXTEND_I32_U);
                    try b.lset(vreg_base + inst.dest);
                },
                .f32_to_f64 => {
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_I32_WRAP_I64);
                    try b.b(OP_F32_REINTERPRET_I32);
                    try b.b(OP_F64_PROMOTE_F32);
                    try b.b(OP_I64_REINTERPRET_F64);
                    try b.lset(vreg_base + inst.dest);
                },
                .jump => {
                    if (has_cfg_loop) {
                        try emitEdgePhisWasm(&b, f, @intCast(bi), inst.target_block, vreg_base, phi_tmp_base);
                        try b.i32c(@intCast(inst.target_block));
                        try b.lset(l_pc);
                        try b.b(OP_BR);
                        try b.u32Leb(cfg_loop_depth);
                    }
                },
                .cond_jump => {
                    try b.lget(vreg_base + inst.src1);
                    try b.i64c(0);
                    try b.b(OP_I64_NE);
                    try b.b(OP_IF);
                    try b.b(T_VOID);
                    try emitEdgePhisWasm(&b, f, @intCast(bi), inst.target_block, vreg_base, phi_tmp_base);
                    try b.i32c(@intCast(inst.target_block));
                    try b.lset(l_pc);
                    try b.b(OP_BR);
                    try b.u32Leb(cfg_loop_depth + 1);
                    try b.b(OP_ELSE);
                    try emitEdgePhisWasm(&b, f, @intCast(bi), inst.alt_block, vreg_base, phi_tmp_base);
                    try b.i32c(@intCast(inst.alt_block));
                    try b.lset(l_pc);
                    try b.b(OP_BR);
                    try b.u32Leb(cfg_loop_depth + 1);
                    try b.b(OP_END);
                },
                .ret => {
                    try b.lget(l_saved_sp);
                    try b.gset(GLB_STACK_PTR);
                    try b.lget(vreg_base + inst.src1);
                    try b.b(OP_RETURN);
                },
                .unreachable_trap => try b.b(OP_UNREACHABLE),
                .fn_addr => {
                    try b.i64c(0xC000_0000 + @as(i64, inst.callee_fn_idx));
                    try b.lset(vreg_base + inst.dest);
                },
                .call => {
                    const target_fi: u32 = if (inst.callee_fn_idx >= 0) @intCast(inst.callee_fn_idx) else blk_fi: {
                        const csrc = module.sourceFor(inst.fn_source_id, source);
                        const cname = csrc[inst.fn_name_start..][0..inst.fn_name_len];
                        var found: u32 = 0;
                        for (module.fns[0..module.fn_count], 0..) |*cf, ci| {
                            const cfsrc = module.sourceFor(cf.source_id, source);
                            const cfn = cfsrc[cf.name_start..][0..cf.name_len];
                            if (util.eql(cfn, cname)) {
                                found = @intCast(ci);
                                break;
                            }
                        }
                        break :blk_fi found;
                    };
                    const callee_p = @min(module.fns[target_fi].param_count, 8);
                    for (0..callee_p) |ai| {
                        if (ai < inst.arg_count) try b.lget(vreg_base + inst.args[ai]) else try b.i64c(0);
                    }
                    try b.call(USER_FN_BASE + target_fi);
                    if (inst.dest != 0) try b.lset(vreg_base + inst.dest) else try b.b(OP_DROP);
                },
                .call_indirect => {
                    try b.lget(vreg_base + inst.src1);
                    for (0..8) |ai| {
                        if (ai < inst.arg_count) try b.lget(vreg_base + inst.args[ai]) else try b.i64c(0);
                    }
                    try b.call(RT_CALL_INDIRECT);
                    if (inst.dest != 0) try b.lset(vreg_base + inst.dest) else try b.b(OP_DROP);
                },
                .call_print, .call_println => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.i32c(if (inst.op == .call_println) 1 else 0);
                    try b.call(RT_PRINT_STR);
                },
                .call_print_int => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_PRINT_INT);
                },
                .call_print_float, .call_println_float => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.i32c(if (inst.op == .call_println_float) 1 else 0);
                    try b.call(RT_PRINT_FLOAT);
                },
                .call_printptr => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_PRINT_INT);
                },
                .call_float_to_string => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_FLOAT_TO_STR);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_string_to_float => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_STR_TO_FLOAT);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_sqrt => try emitFUnaryOp(&b, vreg_base, inst, OP_F64_SQRT),
                .call_fabs => try emitFUnaryOp(&b, vreg_base, inst, OP_F64_ABS),
                .call_floor => try emitFUnaryOp(&b, vreg_base, inst, OP_F64_FLOOR),
                .call_ceil => try emitFUnaryOp(&b, vreg_base, inst, OP_F64_CEIL),
                .call_round => try emitFUnaryOp(&b, vreg_base, inst, OP_F64_NEAREST),
                .call_sin => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_SIN);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_cos => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_COS);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_popcount => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I64_POPCNT);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_clz => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I64_CLZ);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_ctz => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I64_CTZ);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_bswap => {
                    // Emit simple byte-swap using helper-free bitwise mask OR loop via stack? Simplest 1-line formula in Wasm:
                    const x = vreg_base + inst.args[0];
                    const shifts = [_]struct { r: i64, l: i64, mask: i64 }{
                        .{ .r = 56, .l = 0, .mask = 0xFF },
                        .{ .r = 40, .l = 8, .mask = 0xFF00 },
                        .{ .r = 24, .l = 16, .mask = 0xFF0000 },
                        .{ .r = 8, .l = 24, .mask = 0xFF000000 },
                    };
                    try b.i64c(0);
                    for (shifts) |sh| {
                        try b.lget(x);
                        try b.i64c(sh.r);
                        try b.b(OP_I64_SHR_U);
                        try b.i64c(0xFF);
                        try b.b(OP_I64_AND);
                        if (sh.l > 0) {
                            try b.i64c(sh.l);
                            try b.b(OP_I64_SHL);
                        }
                        try b.b(OP_I64_OR);
                        try b.lget(x);
                        if (sh.l > 0) {
                            try b.i64c(sh.l);
                            try b.b(OP_I64_SHR_U);
                        }
                        try b.i64c(0xFF);
                        try b.b(OP_I64_AND);
                        try b.i64c(sh.r);
                        try b.b(OP_I64_SHL);
                        try b.b(OP_I64_OR);
                    }
                    try b.lset(vreg_base + inst.dest);
                },
                .call_atomic_add => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_CHK_PTR);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.memop(OP_I64_LOAD, 3, 0);
                    try b.lset(vreg_base + inst.dest);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.lget(vreg_base + inst.dest);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.b(OP_I64_ADD);
                    try b.memop(OP_I64_STORE, 3, 0);
                },
                .call_atomic_cas => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_CHK_PTR);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.memop(OP_I64_LOAD, 3, 0);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.b(OP_I64_EQ);
                    try b.b(OP_IF);
                    try b.b(T_I64);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.lget(vreg_base + inst.args[2]);
                    try b.memop(OP_I64_STORE, 3, 0);
                    try b.i64c(1);
                    try b.b(OP_ELSE);
                    try b.i64c(0);
                    try b.b(OP_END);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_malloc => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_MALLOC);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_free => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_FREE);
                },
                .call_ptr_add => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.b(OP_I64_ADD);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_read_byte => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_CHK_PTR);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.memop(OP_I64_LOAD8_U, 0, 0);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_write_byte => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_CHK_PTR);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.memop(OP_I64_STORE8, 0, 0);
                },
                .call_read_u32 => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.i64c(4);
                    try b.call(RT_CHK_PTR_N);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.memop(OP_I64_LOAD32_U, 2, 0);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_write_u32 => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.i64c(4);
                    try b.call(RT_CHK_PTR_N);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.memop(OP_I64_STORE32, 2, 0);
                },
                .call_read_u64 => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.i64c(8);
                    try b.call(RT_CHK_PTR_N);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.memop(OP_I64_LOAD, 3, 0);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_write_u64 => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.i64c(8);
                    try b.call(RT_CHK_PTR_N);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.memop(OP_I64_STORE, 3, 0);
                },
                .call_memcpy => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.lget(vreg_base + inst.args[2]);
                    try b.call(RT_MEMCPY);
                    if (inst.dest != 0) try b.lset(vreg_base + inst.dest) else try b.b(OP_DROP);
                },
                .call_memset => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.lget(vreg_base + inst.args[2]);
                    try b.call(RT_MEMSET);
                    if (inst.dest != 0) try b.lset(vreg_base + inst.dest) else try b.b(OP_DROP);
                },
                .call_secure_zero => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.call(RT_SECURE_ZERO);
                    try b.b(OP_DROP);
                },
                .call_const_time_eq => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.lget(vreg_base + inst.args[2]);
                    try b.call(RT_CONST_TIME_EQ);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_checked_add => try emitArgs2Call(&b, vreg_base, inst, RT_CHECKED_ADD),
                .call_checked_sub => try emitArgs2Call(&b, vreg_base, inst, RT_CHECKED_SUB),
                .call_checked_mul => try emitArgs2Call(&b, vreg_base, inst, RT_CHECKED_MUL),
                .call_random_u64 => {
                    try b.call(RT_RANDOM_U64);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_random_bytes => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.call(RT_RANDOM_BYTES);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_assert => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I64_EQZ);
                    try b.b(OP_IF);
                    try b.b(T_VOID);
                    try b.b(OP_UNREACHABLE);
                    try b.b(OP_END);
                },
                .call_assert_eq => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.b(OP_I64_NE);
                    try b.b(OP_IF);
                    try b.b(T_VOID);
                    try b.b(OP_UNREACHABLE);
                    try b.b(OP_END);
                },
                .call_panic => {
                    try b.i32c(2);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_STR_LEN);
                    try b.call(RT_WRITE_FD);
                    try b.b(OP_DROP);
                    try b.i32c(SCRATCH_ADDR + 64);
                    try b.i32c('\n');
                    try b.memop(OP_I32_STORE8, 0, 0);
                    try b.i32c(2);
                    try b.i64c(SCRATCH_ADDR + 64);
                    try b.i64c(1);
                    try b.call(RT_WRITE_FD);
                    try b.b(OP_DROP);
                    try b.b(OP_UNREACHABLE);
                },
                .call_exit => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.call(IMP_PROC_EXIT);
                    try b.b(OP_UNREACHABLE);
                },
                .call_string_len => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_STR_LEN);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_string_new => {
                    try b.lget(vreg_base + inst.args[0]);
                    if (inst.arg_count >= 2) try b.lget(vreg_base + inst.args[1]) else try b.i64c(0);
                    try b.i64c(if (inst.arg_count >= 2) 1 else 0);
                    try b.call(RT_STR_NEW);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_string_sub, .call_string_slice => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.lget(vreg_base + inst.args[2]);
                    try b.i64c(if (inst.op == .call_string_slice) 1 else 0);
                    try b.call(RT_STR_SUB);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_string_char_at => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.call(RT_STR_CHAR_AT);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_string_eq => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.call(RT_STR_EQ);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_string_concat => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.call(RT_STR_CONCAT);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_string_split => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.call(RT_STR_SPLIT);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_int_to_string => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_INT_TO_STR);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_string_to_int => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_STR_TO_INT);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_array_new => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_ARRAY_NEW);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_array_push => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.call(RT_ARRAY_PUSH);
                    try b.b(OP_DROP);
                },
                .call_array_get => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.call(RT_ARRAY_GET);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_array_set => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.lget(vreg_base + inst.args[2]);
                    try b.call(RT_ARRAY_SET);
                    if (inst.dest != 0) try b.lset(vreg_base + inst.dest) else try b.b(OP_DROP);
                },
                .call_array_len => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_ARRAY_LEN);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_array_free => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_ARRAY_FREE);
                },
                .call_map_new => {
                    if (inst.arg_count >= 1) try b.lget(vreg_base + inst.args[0]) else try b.i64c(0);
                    try b.call(RT_MAP_NEW);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_map_set => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.lget(vreg_base + inst.args[2]);
                    try b.call(RT_MAP_SET);
                    try b.b(OP_DROP);
                },
                .call_map_get => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.call(RT_MAP_GET);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_map_has => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.call(RT_MAP_HAS);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_map_del => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.call(RT_MAP_DEL);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_map_len => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_MAP_LEN);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_map_free => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_MAP_FREE);
                },
                .call_argc => {
                    try b.gget(GLB_ARGC);
                    try b.b(OP_I64_EXTEND_I32_U);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_argv => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.call(RT_ARGV);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_time_ns => {
                    try b.call(RT_TIME_NS);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_write => {
                    try b.lget(vreg_base + inst.args[0]);
                    try b.b(OP_I32_WRAP_I64);
                    try b.lget(vreg_base + inst.args[1]);
                    try b.lget(vreg_base + inst.args[2]);
                    try b.call(RT_WRITE_FD);
                    if (inst.dest != 0) try b.lset(vreg_base + inst.dest) else try b.b(OP_DROP);
                },
                .call_getenv, .call_sleep_ms => {
                    if (inst.op == .call_getenv) {
                        try b.i64c(0);
                        try b.i64c(0);
                        try b.i64c(1);
                        try b.call(RT_STR_NEW);
                    } else {
                        try b.i64c(0);
                    }
                    if (inst.dest != 0) try b.lset(vreg_base + inst.dest) else try b.b(OP_DROP);
                },
                .call_getpid, .call_getppid, .call_getuid => {
                    try b.i64c(1);
                    try b.lset(vreg_base + inst.dest);
                },
                .call_open, .call_read, .call_close, .call_unlink, .call_mkdir, .call_stat, .call_tcp_socket, .call_tcp_listen, .call_tcp_accept, .call_tcp_connect, .call_sock_send, .call_sock_recv, .call_syscall => {
                    try b.i64c(-38); // -ENOSYS on bare WASI
                    if (inst.dest != 0) try b.lset(vreg_base + inst.dest) else try b.b(OP_DROP);
                },
                .call_chan_new, .call_chan_send, .call_chan_recv, .call_chan_close, .call_thread_create, .call_thread_join, .call_mutex_create, .call_mutex_lock, .call_mutex_unlock => {
                    if (inst.op == .call_mutex_create) {
                        try b.i64c(1);
                        try b.lset(vreg_base + inst.dest);
                    } else if (inst.op == .call_mutex_lock or inst.op == .call_mutex_unlock) {
                        // no-op in single-threaded Wasm
                    } else {
                        try b.b(OP_UNREACHABLE);
                    }
                },
                else => try b.b(OP_UNREACHABLE),
            }
        }
        if (has_cfg_loop) {
            // Fallthrough guard at end of block (dead if block ended in ret/jump)
            try b.b(OP_BR);
            try b.u32Leb(cfg_loop_depth);
        }
    }

    if (has_cfg_loop) try b.b(OP_END); // end loop $cfg
    try b.lget(l_saved_sp);
    try b.gset(GLB_STACK_PTR);
    try b.i64c(0);
    try writeFnBody(sec, total_extra_i64, 3, 0, &b);
}

fn emitBinOp(b: *Buf, vbase: u32, inst: IRInst, op: u8) !void {
    try b.lget(vbase + inst.src1);
    try b.lget(vbase + inst.src2);
    try b.b(op);
    try b.lset(vbase + inst.dest);
}

fn emitBinCall(b: *Buf, vbase: u32, inst: IRInst, fn_idx: u32) !void {
    try b.lget(vbase + inst.src1);
    try b.lget(vbase + inst.src2);
    try b.call(fn_idx);
    try b.lset(vbase + inst.dest);
}

fn emitArgs2Call(b: *Buf, vbase: u32, inst: IRInst, fn_idx: u32) !void {
    try b.lget(vbase + inst.args[0]);
    try b.lget(vbase + inst.args[1]);
    try b.call(fn_idx);
    try b.lset(vbase + inst.dest);
}

fn emitCmpOp(b: *Buf, vbase: u32, inst: IRInst, op: u8) !void {
    try b.lget(vbase + inst.src1);
    try b.lget(vbase + inst.src2);
    try b.b(op);
    try b.b(OP_I64_EXTEND_I32_U);
    try b.lset(vbase + inst.dest);
}

fn emitFBinOp(b: *Buf, vbase: u32, inst: IRInst, op: u8) !void {
    try b.lget(vreg_base_fix(vbase, inst.src1));
    try b.b(OP_F64_REINTERPRET_I64);
    try b.lget(vreg_base_fix(vbase, inst.src2));
    try b.b(OP_F64_REINTERPRET_I64);
    try b.b(op);
    try b.b(OP_I64_REINTERPRET_F64);
    try b.lset(vbase + inst.dest);
}

fn emitFCmpOp(b: *Buf, vbase: u32, inst: IRInst, op: u8) !void {
    try b.lget(vbase + inst.src1);
    try b.b(OP_F64_REINTERPRET_I64);
    try b.lget(vbase + inst.src2);
    try b.b(OP_F64_REINTERPRET_I64);
    try b.b(op);
    try b.b(OP_I64_EXTEND_I32_U);
    try b.lset(vbase + inst.dest);
}

fn emitFUnaryOp(b: *Buf, vbase: u32, inst: IRInst, op: u8) !void {
    try b.lget(vbase + inst.args[0]);
    try b.b(OP_F64_REINTERPRET_I64);
    try b.b(op);
    try b.b(OP_I64_REINTERPRET_F64);
    try b.lset(vbase + inst.dest);
}

inline fn vreg_base_fix(vbase: u32, v: u16) u32 {
    return vbase + v;
}

// ── Wasm Runtime Helper Implementations ─────────────────────────────────────

fn emitRuntimeHelpers(sec: *Buf, alloc: std.mem.Allocator, module: *const IRModule, main_fi: u32) !void {
    _ = main_fi;
    // 0: chk_ptr(p: i64)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.i64c(1);
        try b.call(RT_CHK_PTR_N);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 1: malloc(sz: i64) -> ptr: i64
    // 32-byte chunk header: [0]=req_size:i64, [8]=next_chunk:i32, [16]=canary:i64, [24]=hdr_len:i64
    // user_ptr = base + 32 (preserves [-16]=canary, [-8]=hdr_len LIR ABI)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        // check sz > 0 && sz <= 256M
        try b.lget(0);
        try b.i64c(1);
        try b.b(OP_I64_LT_S);
        try b.lget(0);
        try b.i64c(256 * 1024 * 1024);
        try b.b(OP_I64_GT_S);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        // aligned = (sz_i32 + 7) & ~7; new_end = base + 32 + aligned
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.i32c(7);
        try b.b(OP_I32_ADD);
        try b.i32c(-8);
        try b.b(OP_I32_AND);
        try b.lset(1); // aligned
        try b.gget(GLB_HEAP_PTR);
        try b.lset(2); // base
        try b.lget(2);
        try b.i32c(32);
        try b.b(OP_I32_ADD);
        try b.lget(1);
        try b.b(OP_I32_ADD);
        try b.lset(3); // new_end
        // grow memory if needed
        try b.lget(3);
        try b.b(OP_MEM_SIZE);
        try b.b(0x00);
        try b.i32c(16);
        try b.b(OP_I32_SHL);
        try b.b(OP_I32_GT_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(3);
        try b.b(OP_MEM_SIZE);
        try b.b(0x00);
        try b.i32c(16);
        try b.b(OP_I32_SHL);
        try b.b(OP_I32_SUB);
        try b.i32c(65535);
        try b.b(OP_I32_ADD);
        try b.i32c(16);
        try b.b(OP_I32_SHR_U);
        try b.b(OP_MEM_GROW);
        try b.b(0x00);
        try b.i32c(-1);
        try b.b(OP_I32_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(3);
        try b.gset(GLB_HEAP_PTR);
        // write 32B header: [0]=sz, [8]=new_end, [16]=magic^secret, [24]=sz
        try b.lget(2);
        try b.lget(0);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.lget(2);
        try b.lget(3);
        try b.memop(OP_I32_STORE, 2, 8);
        try b.lget(2);
        try b.i64c(0x4C49524845415031);
        try b.gget(GLB_HEAP_SECRET);
        try b.b(OP_I64_XOR);
        try b.memop(OP_I64_STORE, 3, 16);
        try b.lget(2);
        try b.lget(0);
        try b.memop(OP_I64_STORE, 3, 24);
        // register first chunk per 4KiB page in PAGE_DIR (16384 slots)
        try b.lget(2);
        try b.i32c(12);
        try b.b(OP_I32_SHR_U);
        try b.lset(5); // pg = base >> 12
        try b.lget(3);
        try b.i32c(1);
        try b.b(OP_I32_SUB);
        try b.i32c(12);
        try b.b(OP_I32_SHR_U);
        try b.lset(6); // end_pg = (new_end - 1) >> 12
        try b.lget(6);
        try b.i32c(16384);
        try b.b(OP_I32_GE_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i32c(16383);
        try b.lset(6);
        try b.b(OP_END);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(5);
        try b.lget(6);
        try b.b(OP_I32_LE_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.gget(GLB_PAGE_DIR);
        try b.lget(5);
        try b.i32c(2);
        try b.b(OP_I32_SHL);
        try b.b(OP_I32_ADD);
        try b.ltee(4); // slot addr (reuse loc 4)
        try b.memop(OP_I32_LOAD, 2, 0);
        try b.b(OP_I32_EQZ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(4);
        try b.lget(2);
        try b.memop(OP_I32_STORE, 2, 0);
        try b.b(OP_END);
        try b.lget(5);
        try b.i32c(1);
        try b.b(OP_I32_ADD);
        try b.lset(5);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        // zero fill user bytes
        try b.lget(2);
        try b.i32c(32);
        try b.b(OP_I32_ADD);
        try b.lset(4); // i = user_ptr
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(4);
        try b.lget(3);
        try b.b(OP_I32_LT_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(4);
        try b.i64c(0);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.lget(4);
        try b.i32c(8);
        try b.b(OP_I32_ADD);
        try b.lset(4);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(2);
        try b.i32c(32);
        try b.b(OP_I32_ADD);
        try b.b(OP_I64_EXTEND_I32_U);
        try writeFnBody(sec, 0, 6, 0, &b);
    }

    // 2: free(ptr: i64)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.b(OP_I64_EQZ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(1); // p32
        try b.gget(GLB_HEAP_BASE);
        try b.b(OP_I32_LT_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(1);
        try b.i32c(16);
        try b.b(OP_I32_SUB);
        try b.memop(OP_I64_LOAD, 3, 0);
        try b.i64c(0x4C49524845415031);
        try b.gget(GLB_HEAP_SECRET);
        try b.b(OP_I64_XOR);
        try b.b(OP_I64_NE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        // zero payload first (using exact req_size at p32 - 32), then clear magic
        try b.lget(0);
        try b.lget(1);
        try b.i32c(32);
        try b.b(OP_I32_SUB);
        try b.memop(OP_I64_LOAD, 3, 0);
        try b.call(RT_SECURE_ZERO);
        try b.b(OP_DROP);
        try b.lget(1);
        try b.i32c(16);
        try b.b(OP_I32_SUB);
        try b.i64c(0);
        try b.memop(OP_I64_STORE, 3, 0);
        try writeFnBody(sec, 0, 1, 0, &b);
    }

    // 3: memcpy(dst, src, n) -> dst
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(2);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(2);
        try b.i64c(0);
        try b.b(OP_I64_GT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(2);
        try b.call(RT_CHK_PTR_N);
        try b.lget(1);
        try b.lget(2);
        try b.call(RT_CHK_PTR_N);
        try b.i64c(0);
        try b.lset(3); // i
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(3);
        try b.lget(2);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(3);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.lget(1);
        try b.lget(3);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_LOAD8_U, 0, 0);
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.lget(3);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(3);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(0);
        try writeFnBody(sec, 1, 0, 0, &b);
    }

    // 4: memset(dst, c, n) -> dst
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(2);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(2);
        try b.i64c(0);
        try b.b(OP_I64_GT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(2);
        try b.call(RT_CHK_PTR_N);
        try b.i64c(0);
        try b.lset(3);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(3);
        try b.lget(2);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(3);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.lget(1);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.lget(3);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(3);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(0);
        try writeFnBody(sec, 1, 0, 0, &b);
    }

    // 5: write_fd(fd: i32, ptr: i64, len: i64) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(2);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(2);
        try b.b(OP_I64_EQZ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i64c(0);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        try b.lget(1);
        try b.lget(2);
        try b.call(RT_CHK_PTR_N);
        try b.i32c(SCRATCH_ADDR);
        try b.lget(1);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_STORE, 2, 0);
        try b.i32c(SCRATCH_ADDR);
        try b.lget(2);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_STORE, 2, 4);
        try b.lget(0);
        try b.i32c(SCRATCH_ADDR);
        try b.i32c(1);
        try b.i32c(SCRATCH_ADDR + 8);
        try b.call(IMP_FD_WRITE);
        try b.lset(3); // err
        try b.lget(3);
        try b.b(OP_I32_EQZ);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.i32c(SCRATCH_ADDR + 8);
        try b.memop(OP_I32_LOAD, 2, 0);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.b(OP_ELSE);
        try b.i64c(0);
        try b.lget(3);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.b(OP_I64_SUB);
        try b.b(OP_END);
        try writeFnBody(sec, 0, 1, 0, &b);
    }

    // 6: print_str(s: i64, nl: i32)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.i32c(1);
        try b.lget(0);
        try b.lget(0);
        try b.call(RT_STR_LEN);
        try b.call(RT_WRITE_FD);
        try b.b(OP_DROP);
        try b.lget(1);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i32c(SCRATCH_ADDR + 32);
        try b.i32c('\n');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.i32c(1);
        try b.i64c(SCRATCH_ADDR + 32);
        try b.i64c(1);
        try b.call(RT_WRITE_FD);
        try b.b(OP_DROP);
        try b.b(OP_END);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 7: print_int(v: i64)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_INT_TO_STR);
        try b.i32c(1);
        try b.call(RT_PRINT_STR);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 8: str_len(s: i64) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.b(OP_I64_EQZ);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.i64c(0);
        try b.b(OP_ELSE);
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.i32c(8);
        try b.b(OP_I32_SUB);
        try b.memop(OP_I64_LOAD, 3, 0);
        try b.b(OP_END);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 9: str_new(ptr: i64, len: i64, has_len: i64) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        // if !has_len: scan NUL
        try b.lget(2);
        try b.b(OP_I64_EQZ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i64c(0);
        try b.lset(1);
        try b.lget(0);
        try b.i64c(0);
        try b.b(OP_I64_NE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(1);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_LOAD8_U, 0, 0);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(1);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(1);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);

        // trap on negative or oversized len
        try b.lget(1);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.lget(1);
        try b.i64c(0x7FFF_FFFF);
        try b.b(OP_I64_GT_S);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);

        try b.lget(1);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.call(RT_MALLOC);
        try b.lset(3); // out
        // store exact len at out - 8
        try b.lget(3);
        try b.b(OP_I32_WRAP_I64);
        try b.i32c(8);
        try b.b(OP_I32_SUB);
        try b.lget(1);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.lget(3);
        try b.lget(0);
        try b.lget(1);
        try b.call(RT_MEMCPY);
        try b.b(OP_DROP);
        try b.lget(3);
        try writeFnBody(sec, 1, 0, 0, &b);
    }

    // 10: str_concat(a, b) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_STR_LEN);
        try b.lset(2); // la
        try b.lget(1);
        try b.call(RT_STR_LEN);
        try b.lset(3); // lb
        try b.lget(2);
        try b.i64c(0x7FFF_FFFF);
        try b.b(OP_I64_GT_U);
        try b.lget(3);
        try b.i64c(0x7FFF_FFFF);
        try b.b(OP_I64_GT_U);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(2);
        try b.lget(3);
        try b.b(OP_I64_ADD);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.call(RT_MALLOC);
        try b.lset(4); // out
        try b.lget(4);
        try b.b(OP_I32_WRAP_I64);
        try b.i32c(8);
        try b.b(OP_I32_SUB);
        try b.lget(2);
        try b.lget(3);
        try b.b(OP_I64_ADD);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.lget(4);
        try b.lget(0);
        try b.lget(2);
        try b.call(RT_MEMCPY);
        try b.b(OP_DROP);
        try b.lget(4);
        try b.lget(2);
        try b.b(OP_I64_ADD);
        try b.lget(1);
        try b.lget(3);
        try b.call(RT_MEMCPY);
        try b.b(OP_DROP);
        try b.lget(4);
        try writeFnBody(sec, 3, 0, 0, &b);
    }

    // 11: str_eq(a, b) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_STR_LEN);
        try b.lset(2);
        try b.lget(1);
        try b.call(RT_STR_LEN);
        try b.lset(3);
        try b.lget(2);
        try b.lget(3);
        try b.b(OP_I64_NE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i64c(0);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        try b.lget(0);
        try b.lget(1);
        try b.lget(2);
        try b.call(RT_CONST_TIME_EQ);
        try writeFnBody(sec, 2, 0, 0, &b);
    }

    // 12: str_sub(s, st, arg2, is_slice) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_STR_LEN);
        try b.lset(4); // n
        try b.lget(1);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.lget(1);
        try b.lget(4);
        try b.b(OP_I64_GE_S);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i64c(0);
        try b.i64c(0);
        try b.i64c(1);
        try b.call(RT_STR_NEW);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        // ln = is_slice ? (arg2 - st) : arg2
        try b.lget(3);
        try b.b(OP_I64_EQZ);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.lget(2);
        try b.b(OP_ELSE);
        try b.lget(2);
        try b.lget(1);
        try b.b(OP_I64_SUB);
        try b.b(OP_END);
        try b.lset(5); // ln
        try b.lget(5);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i64c(0);
        try b.lset(5);
        try b.b(OP_END);
        // clamp ln <= n - st
        try b.lget(4);
        try b.lget(1);
        try b.b(OP_I64_SUB);
        try b.ltee(6); // rem
        try b.lget(5);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(6);
        try b.lset(5);
        try b.b(OP_END);
        try b.lget(0);
        try b.lget(1);
        try b.b(OP_I64_ADD);
        try b.lget(5);
        try b.i64c(1);
        try b.call(RT_STR_NEW);
        try writeFnBody(sec, 3, 0, 0, &b);
    }

    // 13: str_char_at(s, idx) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_STR_LEN);
        try b.lset(2);
        try b.lget(1);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.lget(1);
        try b.lget(2);
        try b.b(OP_I64_GE_S);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(0);
        try b.lget(1);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I64_LOAD8_U, 0, 0);
        try writeFnBody(sec, 1, 0, 0, &b);
    }

    // 14: int_to_str(v: i64) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        // Format at SCRATCH_ADDR + 64..96 (u64 div loop avoids MIN_I64 negate overflow!)
        try b.i32c(SCRATCH_ADDR + 96);
        try b.lset(4); // pos (i32)
        try b.lget(0);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.lset(5); // neg (i32)
        try b.lget(5);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.i64c(0);
        try b.lget(0);
        try b.b(OP_I64_SUB);
        try b.b(OP_ELSE);
        try b.lget(0);
        try b.b(OP_END);
        try b.lset(1); // u: i64 (unsigned bits)
        // do-while loop
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(4);
        try b.i32c(1);
        try b.b(OP_I32_SUB);
        try b.ltee(4);
        try b.lget(1);
        try b.i64c(10);
        try b.b(OP_I64_REM_U);
        try b.b(OP_I32_WRAP_I64);
        try b.i32c('0');
        try b.b(OP_I32_ADD);
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.lget(1);
        try b.i64c(10);
        try b.b(OP_I64_DIV_U);
        try b.ltee(1);
        try b.i64c(0);
        try b.b(OP_I64_NE);
        try b.b(OP_BR_IF);
        try b.u32Leb(0);
        try b.b(OP_END);
        try b.lget(5);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(4);
        try b.i32c(1);
        try b.b(OP_I32_SUB);
        try b.ltee(4);
        try b.i32c('-');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.b(OP_END);
        try b.lget(4);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.i32c(SCRATCH_ADDR + 96);
        try b.lget(4);
        try b.b(OP_I32_SUB);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.i64c(1);
        try b.call(RT_STR_NEW);
        try writeFnBody(sec, 3, 2, 0, &b);
    }

    // 15: str_to_int(s: i64) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_STR_LEN);
        try b.lset(1); // n
        try b.i64c(0);
        try b.lset(2); // i
        try b.i64c(0);
        try b.lset(3); // acc
        try b.i32c(0);
        try b.lset(4); // neg
        // skip spaces
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(2);
        try b.lget(1);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(2);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_LOAD8_U, 0, 0);
        try b.i32c(' ');
        try b.b(OP_I32_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(2);
        try b.b(OP_BR);
        try b.u32Leb(2);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(2);
        try b.lget(1);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(2);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_LOAD8_U, 0, 0);
        try b.ltee(5);
        try b.i32c('-');
        try b.b(OP_I32_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i32c(1);
        try b.lset(4);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(2);
        try b.b(OP_ELSE);
        try b.lget(5);
        try b.i32c('+');
        try b.b(OP_I32_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(2);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(2);
        try b.lget(1);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(2);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_LOAD8_U, 0, 0);
        try b.i32c('0');
        try b.b(OP_I32_SUB);
        try b.ltee(5);
        try b.i32c(0);
        try b.b(OP_I32_GE_S);
        try b.lget(5);
        try b.i32c(9);
        try b.b(OP_I32_LE_S);
        try b.b(OP_I32_AND);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(3);
        try b.i64c(10);
        try b.b(OP_I64_MUL);
        try b.lget(5);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.b(OP_I64_ADD);
        try b.lset(3);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(2);
        try b.b(OP_BR);
        try b.u32Leb(2);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(4);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.i64c(0);
        try b.lget(3);
        try b.b(OP_I64_SUB);
        try b.b(OP_ELSE);
        try b.lget(3);
        try b.b(OP_END);
        try writeFnBody(sec, 3, 2, 0, &b);
    }

    // 16..21: Dynamic arrays ([0]=len, [8]=cap, [16]=data_ptr)
    // 16: array_new(cap: i64) -> h
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.i64c(8);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i64c(8);
        try b.lset(0);
        try b.b(OP_END);
        try b.i64c(24);
        try b.call(RT_MALLOC);
        try b.lset(1); // h
        try b.lget(0);
        try b.i64c(8);
        try b.b(OP_I64_MUL);
        try b.call(RT_MALLOC);
        try b.lset(2); // data
        try b.lget(1);
        try b.b(OP_I32_WRAP_I64);
        try b.i64c(0);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.lget(1);
        try b.b(OP_I32_WRAP_I64);
        try b.lget(0);
        try b.memop(OP_I64_STORE, 3, 8);
        try b.lget(1);
        try b.b(OP_I32_WRAP_I64);
        try b.lget(2);
        try b.memop(OP_I64_STORE, 3, 16);
        try b.lget(1);
        try writeFnBody(sec, 2, 0, 0, &b);
    }

    // 17: array_push(h, val) -> 0
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(5); // hp
        try b.memop(OP_I64_LOAD, 3, 0);
        try b.lset(2); // len
        try b.lget(5);
        try b.memop(OP_I64_LOAD, 3, 8);
        try b.lset(3); // cap
        try b.lget(2);
        try b.lget(3);
        try b.b(OP_I64_GE_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(3);
        try b.i64c(2);
        try b.b(OP_I64_MUL);
        try b.ltee(3);
        try b.i64c(8);
        try b.b(OP_I64_MUL);
        try b.call(RT_MALLOC);
        try b.lset(4); // nd
        try b.lget(4);
        try b.lget(5);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.lget(2);
        try b.i64c(8);
        try b.b(OP_I64_MUL);
        try b.call(RT_MEMCPY);
        try b.b(OP_DROP);
        try b.lget(5);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.call(RT_FREE);
        try b.lget(5);
        try b.lget(3);
        try b.memop(OP_I64_STORE, 3, 8);
        try b.lget(5);
        try b.lget(4);
        try b.memop(OP_I64_STORE, 3, 16);
        try b.b(OP_END);
        // data[len] = val; len += 1
        try b.lget(5);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.lget(2);
        try b.i64c(8);
        try b.b(OP_I64_MUL);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.lget(1);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.lget(5);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.i64c(0);
        try writeFnBody(sec, 3, 1, 0, &b);
    }

    // 18: array_get(h, idx) -> val  (i64: 2=len; i32: 3=hp)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(3);
        try b.memop(OP_I64_LOAD, 3, 0);
        try b.lset(2); // len
        try b.lget(1);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.lget(1);
        try b.lget(2);
        try b.b(OP_I64_GE_S);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(3);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.lget(1);
        try b.i64c(8);
        try b.b(OP_I64_MUL);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I64_LOAD, 3, 0);
        try writeFnBody(sec, 1, 1, 0, &b);
    }

    // 19: array_set(h, idx, val) -> val  (i64: 3=len; i32: 4=hp)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(4);
        try b.memop(OP_I64_LOAD, 3, 0);
        try b.lset(3); // len
        try b.lget(1);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.lget(1);
        try b.lget(3);
        try b.b(OP_I64_GE_S);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(4);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.lget(1);
        try b.i64c(8);
        try b.b(OP_I64_MUL);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.lget(2);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.lget(2);
        try writeFnBody(sec, 1, 1, 0, &b);
    }

    // 20: array_len(h) -> len
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I64_LOAD, 3, 0);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 21: array_free(h)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.b(OP_I64_EQZ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.call(RT_FREE);
        try b.lget(0);
        try b.call(RT_FREE);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 22: str_split(s, delim) -> arr
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.i64c(8);
        try b.call(RT_ARRAY_NEW);
        try b.lset(2); // arr
        try b.lget(0);
        try b.call(RT_STR_LEN);
        try b.lset(3); // sl
        try b.lget(1);
        try b.call(RT_STR_LEN);
        try b.lset(4); // dl
        try b.lget(4);
        try b.b(OP_I64_EQZ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(2);
        try b.lget(0);
        try b.lget(3);
        try b.i64c(1);
        try b.call(RT_STR_NEW);
        try b.call(RT_ARRAY_PUSH);
        try b.b(OP_DROP);
        try b.lget(2);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        try b.i64c(0);
        try b.lset(5); // start
        try b.i64c(0);
        try b.lset(6); // i
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(6);
        try b.lget(4);
        try b.b(OP_I64_ADD);
        try b.lget(3);
        try b.b(OP_I64_LE_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(6);
        try b.b(OP_I64_ADD);
        try b.lget(1);
        try b.lget(4);
        try b.call(RT_CONST_TIME_EQ);
        try b.i64c(0);
        try b.b(OP_I64_NE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(2);
        try b.lget(0);
        try b.lget(5);
        try b.b(OP_I64_ADD);
        try b.lget(6);
        try b.lget(5);
        try b.b(OP_I64_SUB);
        try b.i64c(1);
        try b.call(RT_STR_NEW);
        try b.call(RT_ARRAY_PUSH);
        try b.b(OP_DROP);
        try b.lget(6);
        try b.lget(4);
        try b.b(OP_I64_ADD);
        try b.ltee(6);
        try b.lset(5);
        try b.b(OP_ELSE);
        try b.lget(6);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(6);
        try b.b(OP_END);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(2);
        try b.lget(0);
        try b.lget(5);
        try b.b(OP_I64_ADD);
        try b.lget(3);
        try b.lget(5);
        try b.b(OP_I64_SUB);
        try b.i64c(1);
        try b.call(RT_STR_NEW);
        try b.call(RT_ARRAY_PUSH);
        try b.b(OP_DROP);
        try b.lget(2);
        try writeFnBody(sec, 5, 0, 0, &b);
    }

    // 23..30: Maps ([0]=len, [8]=cap, [16]=entries_ptr, [24]=flags, [32]=load)
    // Entry (24B): [0]=state, [8]=key, [16]=val
    // 23: map_hash(k, flags) -> hash
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(1);
        try b.i64c(1);
        try b.b(OP_I64_AND);
        try b.i64c(0);
        try b.b(OP_I64_NE);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.lget(0);
        try b.call(RT_STR_LEN);
        try b.lset(2); // n
        try b.i64c(@bitCast(@as(u64, 14695981039346656037)));
        try b.gget(GLB_HEAP_SECRET);
        try b.b(OP_I64_XOR);
        try b.lset(3); // h
        try b.i64c(0);
        try b.lset(4); // i
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(4);
        try b.lget(2);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(3);
        try b.lget(0);
        try b.lget(4);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I64_LOAD8_U, 0, 0);
        try b.b(OP_I64_XOR);
        try b.i64c(1099511628211);
        try b.b(OP_I64_MUL);
        try b.lset(3);
        try b.lget(4);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(4);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(3);
        try b.b(OP_ELSE);
        try b.lget(0);
        try b.gget(GLB_HEAP_SECRET);
        try b.b(OP_I64_XOR);
        try b.ltee(3);
        try b.lget(3);
        try b.i64c(30);
        try b.b(OP_I64_SHR_U);
        try b.b(OP_I64_XOR);
        try b.i64c(@bitCast(@as(u64, 0xbf58476d1ce4e5b9)));
        try b.b(OP_I64_MUL);
        try b.ltee(3);
        try b.lget(3);
        try b.i64c(27);
        try b.b(OP_I64_SHR_U);
        try b.b(OP_I64_XOR);
        try b.i64c(@bitCast(@as(u64, 0x94d049bb133111eb)));
        try b.b(OP_I64_MUL);
        try b.ltee(3);
        try b.lget(3);
        try b.i64c(31);
        try b.b(OP_I64_SHR_U);
        try b.b(OP_I64_XOR);
        try b.b(OP_END);
        try writeFnBody(sec, 3, 0, 0, &b);
    }

    // 24: map_new(flags) -> h
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.i64c(40);
        try b.call(RT_MALLOC);
        try b.lset(1);
        try b.i64c(64 * 24);
        try b.call(RT_MALLOC);
        try b.lset(2);
        try b.lget(1);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(3);
        try b.i64c(0);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.lget(3);
        try b.i64c(64);
        try b.memop(OP_I64_STORE, 3, 8);
        try b.lget(3);
        try b.lget(2);
        try b.memop(OP_I64_STORE, 3, 16);
        try b.lget(3);
        try b.lget(0);
        try b.memop(OP_I64_STORE, 3, 24);
        try b.lget(3);
        try b.i64c(0);
        try b.memop(OP_I64_STORE, 3, 32);
        try b.lget(1);
        try writeFnBody(sec, 2, 1, 0, &b);
    }

    // 25: map_set(h, k, v) -> 0
    // params: 0=h, 1=k, 2=v
    // i64 locals (10 -> 3..12): 3=cap, 4=flags, 5=i, 6=slot, 7=ents, 8=tomb, 9=ncap, 10=nents, 11=oents, 12=state
    // i32 locals (3  -> 13..15): 13=m, 14=ep, 15=ne
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(13); // m
        try b.memop(OP_I64_LOAD, 3, 8);
        try b.lset(3); // cap
        try b.lget(13);
        try b.memop(OP_I64_LOAD, 3, 24);
        try b.lset(4); // flags
        // rehash if (load + 1)*4 >= cap*3
        try b.lget(13);
        try b.memop(OP_I64_LOAD, 3, 32);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.i64c(4);
        try b.b(OP_I64_MUL);
        try b.lget(3);
        try b.i64c(3);
        try b.b(OP_I64_MUL);
        try b.b(OP_I64_GE_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(3);
        try b.i64c(2);
        try b.b(OP_I64_MUL);
        try b.lset(9); // ncap
        try b.lget(9);
        try b.i64c(24);
        try b.b(OP_I64_MUL);
        try b.call(RT_MALLOC);
        try b.lset(10); // nents
        try b.lget(13);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.lset(11); // oents
        try b.i64c(0);
        try b.lset(5); // i
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(5);
        try b.lget(3);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(11);
        try b.lget(5);
        try b.i64c(24);
        try b.b(OP_I64_MUL);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(14); // oe
        try memop_i64_eq(&b, 0, 1);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(14);
        try b.memop(OP_I64_LOAD, 3, 8);
        try b.lget(4);
        try b.call(RT_MAP_HASH);
        try b.lget(9);
        try b.i64c(1);
        try b.b(OP_I64_SUB);
        try b.b(OP_I64_AND);
        try b.lset(6); // slot
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(10);
        try b.lget(6);
        try b.i64c(24);
        try b.b(OP_I64_MUL);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(15); // ne
        try memop_i64_eq(&b, 0, 1);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(6);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lget(9);
        try b.i64c(1);
        try b.b(OP_I64_SUB);
        try b.b(OP_I64_AND);
        try b.lset(6);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(15);
        try b.i64c(1);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.lget(15);
        try b.lget(14);
        try b.memop(OP_I64_LOAD, 3, 8);
        try b.memop(OP_I64_STORE, 3, 8);
        try b.lget(15);
        try b.lget(14);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.memop(OP_I64_STORE, 3, 16);
        try b.b(OP_END);
        try b.lget(5);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(5);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(11);
        try b.call(RT_FREE);
        try b.lget(13);
        try b.lget(9);
        try b.lset(3);
        try b.lget(3);
        try b.memop(OP_I64_STORE, 3, 8);
        try b.lget(13);
        try b.lget(10);
        try b.memop(OP_I64_STORE, 3, 16);
        try b.lget(13);
        try b.lget(13);
        try b.memop(OP_I64_LOAD, 3, 0);
        try b.memop(OP_I64_STORE, 3, 32);
        try b.b(OP_END);

        // insert/update probe
        try b.lget(13);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.lset(7); // ents
        try b.lget(1);
        try b.lget(4);
        try b.call(RT_MAP_HASH);
        try b.lget(3);
        try b.i64c(1);
        try b.b(OP_I64_SUB);
        try b.b(OP_I64_AND);
        try b.lset(6); // slot
        try b.i64c(-1);
        try b.lset(8); // tomb
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(7);
        try b.lget(6);
        try b.i64c(24);
        try b.b(OP_I64_MUL);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(14); // ep
        try b.memop(OP_I64_LOAD, 3, 0);
        try b.lset(12); // state
        try b.lget(12);
        try b.b(OP_I64_EQZ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(8);
        try b.i64c(0);
        try b.b(OP_I64_GE_S);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.lget(8);
        try b.b(OP_ELSE);
        try b.lget(6);
        try b.b(OP_END);
        try b.lset(6);
        try b.lget(8);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(13);
        try b.lget(13);
        try b.memop(OP_I64_LOAD, 3, 32);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.memop(OP_I64_STORE, 3, 32);
        try b.b(OP_END);
        try b.lget(7);
        try b.lget(6);
        try b.i64c(24);
        try b.b(OP_I64_MUL);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(14);
        try b.i64c(1);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.lget(14);
        try b.lget(1);
        try b.memop(OP_I64_STORE, 3, 8);
        try b.lget(14);
        try b.lget(2);
        try b.memop(OP_I64_STORE, 3, 16);
        try b.lget(13);
        try b.lget(13);
        try b.memop(OP_I64_LOAD, 3, 0);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.memop(OP_I64_STORE, 3, 0);
        try b.i64c(0);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        // state == 1 and key eq
        try b.lget(12);
        try b.i64c(1);
        try b.b(OP_I64_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(4);
        try b.i64c(1);
        try b.b(OP_I64_AND);
        try b.i64c(0);
        try b.b(OP_I64_NE);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.lget(14);
        try b.memop(OP_I64_LOAD, 3, 8);
        try b.lget(1);
        try b.call(RT_STR_EQ);
        try b.b(OP_ELSE);
        try b.lget(14);
        try b.memop(OP_I64_LOAD, 3, 8);
        try b.lget(1);
        try b.b(OP_I64_EQ);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.b(OP_END);
        try b.i64c(0);
        try b.b(OP_I64_NE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(14);
        try b.lget(2);
        try b.memop(OP_I64_STORE, 3, 16);
        try b.i64c(0);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        try b.b(OP_END);
        // state == 2 and tomb < 0
        try b.lget(12);
        try b.i64c(2);
        try b.b(OP_I64_EQ);
        try b.lget(8);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_I32_AND);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(6);
        try b.lset(8);
        try b.b(OP_END);
        try b.lget(6);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lget(3);
        try b.i64c(1);
        try b.b(OP_I64_SUB);
        try b.b(OP_I64_AND);
        try b.lset(6);
        try b.b(OP_BR);
        try b.u32Leb(0);
        try b.b(OP_END);
        try b.i64c(0);
        try writeFnBody(sec, 10, 3, 0, &b);
    }

    // 26: map_get(0=h, 1=k) -> i64
    // 27: map_has(0=h, 1=k) -> i64
    // 28: map_del(0=h, 1=k) -> i64
    // Shared probe pattern: i64 locals (6 -> 2..7): 2=cap, 3=flags, 4=ents, 5=idx, 6=steps, 7=state; i32 (2 -> 8..9): 8=m, 9=ep
    for ([_]u8{ 0, 1, 2 }) |mode| {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(8); // m
        try b.memop(OP_I64_LOAD, 3, 8);
        try b.lset(2); // cap
        try b.lget(8);
        try b.memop(OP_I64_LOAD, 3, 24);
        try b.lset(3); // flags
        try b.lget(8);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.lset(4); // ents
        try b.lget(1);
        try b.lget(3);
        try b.call(RT_MAP_HASH);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_SUB);
        try b.b(OP_I64_AND);
        try b.lset(5); // idx
        try b.i64c(0);
        try b.lset(6); // steps
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(6);
        try b.lget(2);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(4);
        try b.lget(5);
        try b.i64c(24);
        try b.b(OP_I64_MUL);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.ltee(9); // ep
        try b.memop(OP_I64_LOAD, 3, 0);
        try b.ltee(7); // state
        try b.b(OP_I64_EQZ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i64c(0);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        try b.lget(7);
        try b.i64c(1);
        try b.b(OP_I64_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(3);
        try b.i64c(1);
        try b.b(OP_I64_AND);
        try b.i64c(0);
        try b.b(OP_I64_NE);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.lget(9);
        try b.memop(OP_I64_LOAD, 3, 8);
        try b.lget(1);
        try b.call(RT_STR_EQ);
        try b.b(OP_ELSE);
        try b.lget(9);
        try b.memop(OP_I64_LOAD, 3, 8);
        try b.lget(1);
        try b.b(OP_I64_EQ);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.b(OP_END);
        try b.i64c(0);
        try b.b(OP_I64_NE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        if (mode == 0) { // get
            try b.lget(9);
            try b.memop(OP_I64_LOAD, 3, 16);
            try b.b(OP_RETURN);
        } else if (mode == 1) { // has
            try b.i64c(1);
            try b.b(OP_RETURN);
        } else { // del
            try b.lget(9);
            try b.i64c(2);
            try b.memop(OP_I64_STORE, 3, 0);
            try b.lget(8);
            try b.lget(8);
            try b.memop(OP_I64_LOAD, 3, 0);
            try b.i64c(1);
            try b.b(OP_I64_SUB);
            try b.memop(OP_I64_STORE, 3, 0);
            try b.i64c(1);
            try b.b(OP_RETURN);
        }
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(5);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_SUB);
        try b.b(OP_I64_AND);
        try b.lset(5);
        try b.lget(6);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(6);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.i64c(0);
        try writeFnBody(sec, 6, 2, 0, &b);
    }

    // 29: map_len(h) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I64_LOAD, 3, 0);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 30: map_free(h) -> void
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.b(OP_I64_EQZ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        try b.lget(0);
        try b.call(RT_CHK_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.call(RT_FREE);
        try b.lget(0);
        try b.call(RT_FREE);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 31: random_u64() -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.i32c(SCRATCH_ADDR + 104);
        try b.i32c(8);
        try b.call(IMP_RANDOM_GET);
        try b.b(OP_DROP);
        try b.i32c(SCRATCH_ADDR + 104);
        try b.memop(OP_I64_LOAD, 3, 0);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 32: random_bytes(dst, n) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(1);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(1);
        try b.i64c(0);
        try b.b(OP_I64_GT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(1);
        try b.call(RT_CHK_PTR_N);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.lget(1);
        try b.b(OP_I32_WRAP_I64);
        try b.call(IMP_RANDOM_GET);
        try b.b(OP_DROP);
        try b.b(OP_END);
        try b.lget(1);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 33: const_time_eq(0=a, 1=b, 2=n) -> i64  (i64 locals: 3=i, 4=diff)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(2);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(2);
        try b.b(OP_I64_EQZ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i64c(1);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        try b.lget(0);
        try b.lget(2);
        try b.call(RT_CHK_PTR_N);
        try b.lget(1);
        try b.lget(2);
        try b.call(RT_CHK_PTR_N);
        try b.i64c(0);
        try b.lset(3);
        try b.i64c(0);
        try b.lset(4);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(3);
        try b.lget(2);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(4);
        try b.lget(0);
        try b.lget(3);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I64_LOAD8_U, 0, 0);
        try b.lget(1);
        try b.lget(3);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I64_LOAD8_U, 0, 0);
        try b.b(OP_I64_XOR);
        try b.b(OP_I64_OR);
        try b.lset(4);
        try b.lget(3);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(3);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(4);
        try b.b(OP_I64_EQZ);
        try b.b(OP_I64_EXTEND_I32_U);
        try writeFnBody(sec, 2, 0, 0, &b);
    }

    // 34: secure_zero(0=p, 1=n) -> i64  (i64: 2=i)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(1);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(1);
        try b.i64c(0);
        try b.b(OP_I64_GT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(1);
        try b.call(RT_CHK_PTR_N);
        try b.i64c(0);
        try b.lset(2);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(2);
        try b.lget(1);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(2);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.i32c(0);
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(2);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.i64c(0);
        try writeFnBody(sec, 1, 0, 0, &b);
    }

    // 35: checked_add(0=a, 1=b) -> i64  (i64: 2=r)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.lget(1);
        try b.b(OP_I64_ADD);
        try b.ltee(2);
        try b.lget(0);
        try b.b(OP_I64_XOR);
        try b.lget(2);
        try b.lget(1);
        try b.b(OP_I64_XOR);
        try b.b(OP_I64_AND);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(2);
        try writeFnBody(sec, 1, 0, 0, &b);
    }

    // 36: checked_sub(0=a, 1=b) -> i64  (i64: 2=r)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.lget(1);
        try b.b(OP_I64_SUB);
        try b.ltee(2);
        try b.lget(0);
        try b.b(OP_I64_XOR);
        try b.lget(0);
        try b.lget(1);
        try b.b(OP_I64_XOR);
        try b.b(OP_I64_AND);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(2);
        try writeFnBody(sec, 1, 0, 0, &b);
    }

    // 37: checked_mul(0=a, 1=b) -> i64  (i64: 2=r)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.b(OP_I64_EQZ);
        try b.lget(1);
        try b.b(OP_I64_EQZ);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i64c(0);
        try b.b(OP_RETURN);
        try b.b(OP_END);
        try b.lget(0);
        try b.i64c(std.math.minInt(i64));
        try b.b(OP_I64_EQ);
        try b.lget(1);
        try b.i64c(-1);
        try b.b(OP_I64_EQ);
        try b.b(OP_I32_AND);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(0);
        try b.lget(1);
        try b.b(OP_I64_MUL);
        try b.ltee(2);
        try b.lget(0);
        try b.b(OP_I64_DIV_S);
        try b.lget(1);
        try b.b(OP_I64_NE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(2);
        try writeFnBody(sec, 1, 0, 0, &b);
    }

    // 38: div_i64(a, b) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(1);
        try b.b(OP_I64_EQZ);
        try b.lget(0);
        try b.i64c(std.math.minInt(i64));
        try b.b(OP_I64_EQ);
        try b.lget(1);
        try b.i64c(-1);
        try b.b(OP_I64_EQ);
        try b.b(OP_I32_AND);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(0);
        try b.lget(1);
        try b.b(OP_I64_DIV_S);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 39: mod_i64(a, b) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(1);
        try b.b(OP_I64_EQZ);
        try b.lget(0);
        try b.i64c(std.math.minInt(i64));
        try b.b(OP_I64_EQ);
        try b.lget(1);
        try b.i64c(-1);
        try b.b(OP_I64_EQ);
        try b.b(OP_I32_AND);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(0);
        try b.lget(1);
        try b.b(OP_I64_REM_S);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 40..42: shl_i64, shr_i64, ushr_i64
    for ([_]u8{ OP_I64_SHL, OP_I64_SHR_S, OP_I64_SHR_U }) |shift_op| {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(1);
        try b.i64c(64);
        try b.b(OP_I64_GE_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.lget(0);
        try b.lget(1);
        try b.b(shift_op);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 43: time_ns() -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.i32c(1); // MONOTONIC
        try b.i64c(1);
        try b.i32c(SCRATCH_ADDR + 112);
        try b.call(IMP_CLOCK_TIME_GET);
        try b.b(OP_DROP);
        try b.i32c(SCRATCH_ADDR + 112);
        try b.memop(OP_I64_LOAD, 3, 0);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 44: float_to_str(0=bits) -> i64
    // i64 locals (4 -> 1..4): 1=ip, 2=fp, 3=ilen, 4=istr
    // i32 locals (5 -> 5..9): 5=neg, 6=pos, 7=k, 8=use_sci, 9=exp10
    // f64 locals (2 -> 10..11): 10=x, 11=ax
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.b(OP_F64_REINTERPRET_I64);
        try b.ltee(10);
        try b.lget(10);
        try b.b(OP_F64_NE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        // "nan" at SCRATCH_ADDR + 128
        try b.i32c(SCRATCH_ADDR + 128);
        try b.i32c('n');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.i32c(SCRATCH_ADDR + 129);
        try b.i32c('a');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.i32c(SCRATCH_ADDR + 130);
        try b.i32c('n');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.i64c(SCRATCH_ADDR + 128);
        try b.i64c(3);
        try b.i64c(1);
        try b.call(RT_STR_NEW);
        try b.b(OP_RETURN);
        try b.b(OP_END);

        // neg = (bits >> 63) & 1
        try b.lget(0);
        try b.i64c(63);
        try b.b(OP_I64_SHR_U);
        try b.b(OP_I32_WRAP_I64);
        try b.lset(5);
        try b.lget(10);
        try b.b(OP_F64_ABS);
        try b.lset(11);

        // Inf / -Inf: ax - ax != 0.0
        try b.lget(11);
        try b.lget(11);
        try b.b(OP_F64_SUB);
        try b.f64Const(0.0);
        try b.b(OP_F64_NE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i32c(SCRATCH_ADDR + 128);
        try b.i32c('-');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.i32c(SCRATCH_ADDR + 129);
        try b.i32c('i');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.i32c(SCRATCH_ADDR + 130);
        try b.i32c('n');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.i32c(SCRATCH_ADDR + 131);
        try b.i32c('f');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.lget(5);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.i64c(SCRATCH_ADDR + 128);
        try b.b(OP_ELSE);
        try b.i64c(SCRATCH_ADDR + 129);
        try b.b(OP_END);
        try b.lget(5);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.i64c(4);
        try b.b(OP_ELSE);
        try b.i64c(3);
        try b.b(OP_END);
        try b.i64c(1);
        try b.call(RT_STR_NEW);
        try b.b(OP_RETURN);
        try b.b(OP_END);

        // 0.0 / -0.0: ax == 0.0
        try b.lget(11);
        try b.f64Const(0.0);
        try b.b(OP_F64_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i32c(SCRATCH_ADDR + 128);
        try b.i32c('-');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.i32c(SCRATCH_ADDR + 129);
        try b.i32c('0');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.i32c(SCRATCH_ADDR + 130);
        try b.i32c('.');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.i32c(SCRATCH_ADDR + 131);
        try b.i32c('0');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.lget(5);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.i64c(SCRATCH_ADDR + 128);
        try b.b(OP_ELSE);
        try b.i64c(SCRATCH_ADDR + 129);
        try b.b(OP_END);
        try b.lget(5);
        try b.b(OP_IF);
        try b.b(T_I64);
        try b.i64c(4);
        try b.b(OP_ELSE);
        try b.i64c(3);
        try b.b(OP_END);
        try b.i64c(1);
        try b.call(RT_STR_NEW);
        try b.b(OP_RETURN);
        try b.b(OP_END);

        // Scientific normalization for ax >= 1e15 or ax < 1e-4
        try b.i32c(0);
        try b.lset(8); // use_sci = 0
        try b.i32c(0);
        try b.lset(9); // exp10 = 0
        try b.lget(11);
        try b.f64Const(1.0e15);
        try b.b(OP_F64_GE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i32c(1);
        try b.lset(8);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(11);
        try b.f64Const(10.0);
        try b.b(OP_F64_GE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(11);
        try b.f64Const(0.1);
        try b.b(OP_F64_MUL);
        try b.lset(11);
        try b.lget(9);
        try b.i32c(1);
        try b.b(OP_I32_ADD);
        try b.lset(9);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_ELSE);
        try b.lget(11);
        try b.f64Const(1.0e-4);
        try b.b(OP_F64_LT);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i32c(1);
        try b.lset(8);
        try b.i32c(350);
        try b.lset(7); // iter cap
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(11);
        try b.f64Const(1.0);
        try b.b(OP_F64_LT);
        try b.lget(7);
        try b.i32c(0);
        try b.b(OP_I32_GT_S);
        try b.b(OP_I32_AND);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(11);
        try b.f64Const(10.0);
        try b.b(OP_F64_MUL);
        try b.lset(11);
        try b.lget(9);
        try b.i32c(1);
        try b.b(OP_I32_SUB);
        try b.lset(9);
        try b.lget(7);
        try b.i32c(1);
        try b.b(OP_I32_SUB);
        try b.lset(7);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);

        // ip = trunc(ax), fp = trunc((ax - (f64)ip) * 1e6 + 0.5)
        try b.lget(11);
        try b.b(OP_I64_TRUNC_F64_S);
        try b.ltee(1);
        try b.b(OP_F64_CONVERT_I64_S);
        try b.lget(11);
        try b.b(OP_F64_SUB);
        try b.b(OP_F64_NEG);
        try b.f64Const(1000000.0);
        try b.b(OP_F64_MUL);
        try b.f64Const(0.5);
        try b.b(OP_F64_ADD);
        try b.b(OP_I64_TRUNC_F64_S);
        try b.ltee(2);
        try b.i64c(1000000);
        try b.b(OP_I64_GE_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(2);
        try b.i64c(1000000);
        try b.b(OP_I64_SUB);
        try b.lset(2);
        try b.lget(1);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(1);
        try b.b(OP_END);

        // format at SCRATCH_ADDR + 128
        try b.i32c(SCRATCH_ADDR + 128);
        try b.lset(6); // pos
        try b.lget(5);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(6);
        try b.i32c('-');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.lget(6);
        try b.i32c(1);
        try b.b(OP_I32_ADD);
        try b.lset(6);
        try b.b(OP_END);
        try b.lget(1);
        try b.call(RT_INT_TO_STR);
        try b.ltee(4);
        try b.call(RT_STR_LEN);
        try b.lset(3);
        try b.lget(6);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.lget(4);
        try b.lget(3);
        try b.call(RT_MEMCPY);
        try b.b(OP_DROP);
        try b.lget(6);
        try b.lget(3);
        try b.b(OP_I32_WRAP_I64);
        try b.b(OP_I32_ADD);
        try b.ltee(6);
        try b.i32c('.');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.lget(6);
        try b.i32c(1);
        try b.b(OP_I32_ADD);
        try b.lset(6);
        // write 6 fractional digits backwards from k=5..0
        try b.i32c(5);
        try b.lset(7);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(7);
        try b.i32c(0);
        try b.b(OP_I32_GE_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(6);
        try b.lget(7);
        try b.b(OP_I32_ADD);
        try b.lget(2);
        try b.i64c(10);
        try b.b(OP_I64_REM_S);
        try b.b(OP_I32_WRAP_I64);
        try b.i32c('0');
        try b.b(OP_I32_ADD);
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.lget(2);
        try b.i64c(10);
        try b.b(OP_I64_DIV_S);
        try b.lset(2);
        try b.lget(7);
        try b.i32c(1);
        try b.b(OP_I32_SUB);
        try b.lset(7);
        try b.b(OP_BR);
        try b.u32Leb(1);
        try b.b(OP_END);
        try b.b(OP_END);
        // advance pos by 6, trim trailing '0's keeping >=1 fractional digit
        try b.lget(6);
        try b.i32c(6);
        try b.b(OP_I32_ADD);
        try b.lset(6);
        try b.i32c(5);
        try b.lset(7);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(7);
        try b.i32c(0);
        try b.b(OP_I32_GT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(6);
        try b.i32c(1);
        try b.b(OP_I32_SUB);
        try b.memop(OP_I32_LOAD8_U, 0, 0);
        try b.i32c('0');
        try b.b(OP_I32_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(6);
        try b.i32c(1);
        try b.b(OP_I32_SUB);
        try b.lset(6);
        try b.lget(7);
        try b.i32c(1);
        try b.b(OP_I32_SUB);
        try b.lset(7);
        try b.b(OP_BR);
        try b.u32Leb(2);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        // Append 'e' + sign + exp10 if use_sci != 0
        try b.lget(8);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(6);
        try b.i32c('e');
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.lget(6);
        try b.i32c(1);
        try b.b(OP_I32_ADD);
        try b.ltee(6);
        try b.lget(9);
        try b.i32c(0);
        try b.b(OP_I32_GE_S);
        try b.b(OP_IF);
        try b.b(T_I32);
        try b.i32c('+');
        try b.b(OP_ELSE);
        try b.i32c('-');
        try b.b(OP_END);
        try b.memop(OP_I32_STORE8, 0, 0);
        try b.lget(6);
        try b.i32c(1);
        try b.b(OP_I32_ADD);
        try b.lset(6);
        try b.lget(9);
        try b.i32c(0);
        try b.b(OP_I32_LT_S);
        try b.b(OP_IF);
        try b.b(T_I32);
        try b.i32c(0);
        try b.lget(9);
        try b.b(OP_I32_SUB);
        try b.b(OP_ELSE);
        try b.lget(9);
        try b.b(OP_END);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.call(RT_INT_TO_STR);
        try b.ltee(4);
        try b.call(RT_STR_LEN);
        try b.lset(3);
        try b.lget(6);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.lget(4);
        try b.lget(3);
        try b.call(RT_MEMCPY);
        try b.b(OP_DROP);
        try b.lget(6);
        try b.lget(3);
        try b.b(OP_I32_WRAP_I64);
        try b.b(OP_I32_ADD);
        try b.lset(6);
        try b.b(OP_END);
        try b.i64c(SCRATCH_ADDR + 128);
        try b.lget(6);
        try b.i32c(SCRATCH_ADDR + 128);
        try b.b(OP_I32_SUB);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.i64c(1);
        try b.call(RT_STR_NEW);
        try writeFnBody(sec, 4, 5, 2, &b);
    }

    // 45: str_to_float(0=s) -> i64
    // i64 (2 -> 1..2): 1=n, 2=i
    // i32 (2 -> 3..4): 3=neg, 4=c
    // f64 (2 -> 5..6): 5=val, 6=scale
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_STR_LEN);
        try b.lset(1);
        try b.i64c(0);
        try b.lset(2);
        try b.i32c(0);
        try b.lset(3);
        try b.f64Const(0.0);
        try b.lset(5);
        try b.f64Const(1.0);
        try b.lset(6);
        // skip space
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(2);
        try b.lget(1);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(2);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_LOAD8_U, 0, 0);
        try b.i32c(' ');
        try b.b(OP_I32_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(2);
        try b.b(OP_BR);
        try b.u32Leb(2);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        // sign
        try b.lget(2);
        try b.lget(1);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(2);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_LOAD8_U, 0, 0);
        try b.ltee(4);
        try b.i32c('-');
        try b.b(OP_I32_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.i32c(1);
        try b.lset(3);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(2);
        try b.b(OP_ELSE);
        try b.lget(4);
        try b.i32c('+');
        try b.b(OP_I32_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(2);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        // int digits
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(2);
        try b.lget(1);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(2);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_LOAD8_U, 0, 0);
        try b.i32c('0');
        try b.b(OP_I32_SUB);
        try b.ltee(4);
        try b.i32c(0);
        try b.b(OP_I32_GE_S);
        try b.lget(4);
        try b.i32c(9);
        try b.b(OP_I32_LE_S);
        try b.b(OP_I32_AND);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(5);
        try b.f64Const(10.0);
        try b.b(OP_F64_MUL);
        try b.lget(4);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.b(OP_F64_CONVERT_I64_S);
        try b.b(OP_F64_ADD);
        try b.lset(5);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(2);
        try b.b(OP_BR);
        try b.u32Leb(2);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        // '.' fraction
        try b.lget(2);
        try b.lget(1);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(2);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_LOAD8_U, 0, 0);
        try b.i32c('.');
        try b.b(OP_I32_EQ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(2);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(2);
        try b.lget(1);
        try b.b(OP_I64_LT_S);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(0);
        try b.lget(2);
        try b.b(OP_I64_ADD);
        try b.b(OP_I32_WRAP_I64);
        try b.memop(OP_I32_LOAD8_U, 0, 0);
        try b.i32c('0');
        try b.b(OP_I32_SUB);
        try b.ltee(4);
        try b.i32c(0);
        try b.b(OP_I32_GE_S);
        try b.lget(4);
        try b.i32c(9);
        try b.b(OP_I32_LE_S);
        try b.b(OP_I32_AND);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(6);
        try b.f64Const(0.1);
        try b.b(OP_F64_MUL);
        try b.ltee(6);
        try b.lget(4);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.b(OP_F64_CONVERT_I64_S);
        try b.b(OP_F64_MUL);
        try b.lget(5);
        try b.b(OP_F64_ADD);
        try b.lset(5);
        try b.lget(2);
        try b.i64c(1);
        try b.b(OP_I64_ADD);
        try b.lset(2);
        try b.b(OP_BR);
        try b.u32Leb(2);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.b(OP_END);
        try b.lget(3);
        try b.b(OP_IF);
        try b.b(T_F64);
        try b.lget(5);
        try b.b(OP_F64_NEG);
        try b.b(OP_ELSE);
        try b.lget(5);
        try b.b(OP_END);
        try b.b(OP_I64_REINTERPRET_F64);
        try writeFnBody(sec, 2, 2, 2, &b);
    }

    // 46: print_float(bits: i64, nl: i32) -> void
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.call(RT_FLOAT_TO_STR);
        try b.lget(1);
        try b.call(RT_PRINT_STR);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 47: sin(bits: i64) -> i64  (f64 locals: 1=x, 2=x2, 3=k)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.b(OP_F64_REINTERPRET_I64);
        try b.ltee(1);
        // x = x - nearest(x / 2pi) * 2pi
        try b.lget(1);
        try b.f64Const(6.28318530717958647692);
        try b.b(OP_F64_DIV);
        try b.b(OP_F64_NEAREST);
        try b.f64Const(6.28318530717958647692);
        try b.b(OP_F64_MUL);
        try b.b(OP_F64_SUB);
        try b.lset(1);
        // fold into [-pi/2, pi/2]
        try b.lget(1);
        try b.f64Const(1.57079632679489661923);
        try b.b(OP_F64_GT);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.f64Const(3.14159265358979323846);
        try b.lget(1);
        try b.b(OP_F64_SUB);
        try b.lset(1);
        try b.b(OP_ELSE);
        try b.lget(1);
        try b.f64Const(-1.57079632679489661923);
        try b.b(OP_F64_LT);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.f64Const(-3.14159265358979323846);
        try b.lget(1);
        try b.b(OP_F64_SUB);
        try b.lset(1);
        try b.b(OP_END);
        try b.b(OP_END);
        // x2 = x * x
        try b.lget(1);
        try b.lget(1);
        try b.b(OP_F64_MUL);
        try b.lset(2);
        // Horner series: 1 + x2*(-1/6 + x2*(1/120 + x2*(-1/5040 + x2*(1/362880 + x2*(-1/39916800 + x2*(1/6227020800))))))
        try b.f64Const(1.0 / 6227020800.0);
        try b.lget(2);
        try b.b(OP_F64_MUL);
        try b.f64Const(-1.0 / 39916800.0);
        try b.b(OP_F64_ADD);
        try b.lget(2);
        try b.b(OP_F64_MUL);
        try b.f64Const(1.0 / 362880.0);
        try b.b(OP_F64_ADD);
        try b.lget(2);
        try b.b(OP_F64_MUL);
        try b.f64Const(-1.0 / 5040.0);
        try b.b(OP_F64_ADD);
        try b.lget(2);
        try b.b(OP_F64_MUL);
        try b.f64Const(1.0 / 120.0);
        try b.b(OP_F64_ADD);
        try b.lget(2);
        try b.b(OP_F64_MUL);
        try b.f64Const(-1.0 / 6.0);
        try b.b(OP_F64_ADD);
        try b.lget(2);
        try b.b(OP_F64_MUL);
        try b.f64Const(1.0);
        try b.b(OP_F64_ADD);
        try b.lget(1);
        try b.b(OP_F64_MUL);
        try b.b(OP_I64_REINTERPRET_F64);
        try writeFnBody(sec, 0, 0, 2, &b);
    }

    // 48: cos(bits: i64) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.b(OP_F64_REINTERPRET_I64);
        try b.f64Const(1.57079632679489661923);
        try b.b(OP_F64_ADD);
        try b.b(OP_I64_REINTERPRET_F64);
        try b.call(RT_SIN);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 49: call_indirect(0=handle, 1..8=args) -> i64
    {
        var fn_addr_taken: [ir.MAX_FNS]bool = .{false} ** ir.MAX_FNS;
        for (module.fns[0..module.fn_count]) |*mf| {
            for (mf.blocks[0..mf.block_count]) |*mb| {
                for (mb.insts[0..mb.inst_count]) |mi| {
                    if (mi.op == .fn_addr and mi.callee_fn_idx >= 0 and @as(usize, @intCast(mi.callee_fn_idx)) < ir.MAX_FNS) {
                        fn_addr_taken[@intCast(mi.callee_fn_idx)] = true;
                    }
                }
            }
        }
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.i64c(0xC000_0000);
        try b.b(OP_I64_SUB);
        try b.lset(9); // id
        for (module.fns[0..module.fn_count], 0..) |*cf, ci| {
            if (!fn_addr_taken[ci]) continue;
            try b.lget(9);
            try b.i64c(@intCast(ci));
            try b.b(OP_I64_EQ);
            try b.b(OP_IF);
            try b.b(T_VOID);
            const p = @min(cf.param_count, 8);
            for (0..p) |pi| try b.lget(@intCast(1 + pi));
            try b.call(USER_FN_BASE + @as(u32, @intCast(ci)));
            try b.b(OP_RETURN);
            try b.b(OP_END);
        }
        try b.b(OP_UNREACHABLE);
        try writeFnBody(sec, 1, 0, 0, &b);
    }

    // 50: argv(0=idx) -> i64
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        try b.lget(0);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.lget(0);
        try b.gget(GLB_ARGC);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.b(OP_I64_GE_S);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.gget(GLB_ARGV_PTR);
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.i32c(2);
        try b.b(OP_I32_SHL);
        try b.b(OP_I32_ADD);
        try b.memop(OP_I32_LOAD, 2, 0);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.i64c(0);
        try b.i64c(0);
        try b.call(RT_STR_NEW);
        try writeFnBody(sec, 0, 0, 0, &b);
    }

    // 51: chk_ptr_n(0=p: i64, 1=acc_sz: i64) -> void
    // Locals: i64 (2=sz64, 3=off64), i32 (4=p32, 5=pg_or_next, 6=cur)
    {
        var b = Buf{ .alloc = alloc };
        defer b.deinit();
        // if (p < 4096 || (p >>u 32) != 0 || acc_sz < 0) unreachable
        try b.lget(0);
        try b.i64c(4096);
        try b.b(OP_I64_LT_U);
        try b.lget(0);
        try b.i64c(32);
        try b.b(OP_I64_SHR_U);
        try b.i64c(0);
        try b.b(OP_I64_NE);
        try b.b(OP_I32_OR);
        try b.lget(1);
        try b.i64c(0);
        try b.b(OP_I64_LT_S);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);

        // p32 = wrap(p)
        try b.lget(0);
        try b.b(OP_I32_WRAP_I64);
        try b.lset(4);

        // if p32 < GLB_PAGE_DIR: check acc_sz <= GLB_PAGE_DIR - p32 (rodata / scratch)
        try b.lget(4);
        try b.gget(GLB_PAGE_DIR);
        try b.b(OP_I32_LT_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(1);
        try b.gget(GLB_PAGE_DIR);
        try b.lget(4);
        try b.b(OP_I32_SUB);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.b(OP_I64_GT_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.b(OP_RETURN);
        try b.b(OP_END);

        // if p32 < GLB_PAGE_DIR + 65536: unreachable (PAGE_DIR metadata guard)
        try b.lget(4);
        try b.gget(GLB_PAGE_DIR);
        try b.i32c(65536);
        try b.b(OP_I32_ADD);
        try b.b(OP_I32_LT_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);

        // if p32 < GLB_HEAP_BASE: check acc_sz <= GLB_HEAP_BASE - p32 (shadow stack)
        try b.lget(4);
        try b.gget(GLB_HEAP_BASE);
        try b.b(OP_I32_LT_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.lget(1);
        try b.gget(GLB_HEAP_BASE);
        try b.lget(4);
        try b.b(OP_I32_SUB);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.b(OP_I64_GT_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.b(OP_RETURN);
        try b.b(OP_END);

        // if p32 >= GLB_HEAP_PTR: unreachable (past heap top)
        try b.lget(4);
        try b.gget(GLB_HEAP_PTR);
        try b.b(OP_I32_GE_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);

        // pg = p32 >> 12; cur = (pg < 16384) ? load(PAGE_DIR + (pg<<2)) : 0
        try b.lget(4);
        try b.i32c(12);
        try b.b(OP_I32_SHR_U);
        try b.ltee(5);
        try b.i32c(16384);
        try b.b(OP_I32_LT_U);
        try b.b(OP_IF);
        try b.b(T_I32);
        try b.gget(GLB_PAGE_DIR);
        try b.lget(5);
        try b.i32c(2);
        try b.b(OP_I32_SHL);
        try b.b(OP_I32_ADD);
        try b.memop(OP_I32_LOAD, 2, 0);
        try b.b(OP_ELSE);
        try b.i32c(0);
        try b.b(OP_END);
        try b.ltee(6); // cur
        try b.b(OP_I32_EQZ);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.gget(GLB_HEAP_BASE);
        try b.lset(6);
        try b.b(OP_END);

        // walk chunks from cur until p32 < next_chunk
        try b.b(OP_BLOCK);
        try b.b(T_VOID);
        try b.b(OP_LOOP);
        try b.b(T_VOID);
        try b.lget(6);
        try b.gget(GLB_HEAP_PTR);
        try b.b(OP_I32_GE_U);
        try b.b(OP_BR_IF);
        try b.u32Leb(1);

        try b.lget(6);
        try b.memop(OP_I32_LOAD, 2, 8);
        try b.ltee(5); // next_chunk
        try b.lget(6);
        try b.b(OP_I32_LE_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);

        try b.lget(4); // p32
        try b.lget(5); // next_chunk
        try b.b(OP_I32_LT_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        // Check live magic at cur + 16
        try b.lget(6);
        try b.memop(OP_I64_LOAD, 3, 16);
        try b.i64c(0x4C49524845415031);
        try b.gget(GLB_HEAP_SECRET);
        try b.b(OP_I64_XOR);
        try b.b(OP_I64_NE);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        // Check p32 >= cur + 32 (not inside header)
        try b.lget(4);
        try b.lget(6);
        try b.i32c(32);
        try b.b(OP_I32_ADD);
        try b.b(OP_I32_LT_U);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        // Check (p - (cur + 32)) + acc_sz <= req_size
        try b.lget(0);
        try b.lget(6);
        try b.i32c(32);
        try b.b(OP_I32_ADD);
        try b.b(OP_I64_EXTEND_I32_U);
        try b.b(OP_I64_SUB);
        try b.lset(3); // off64
        try b.lget(6);
        try b.memop(OP_I64_LOAD, 3, 0);
        try b.lset(2); // sz64
        try b.lget(3);
        try b.lget(2);
        try b.b(OP_I64_GT_U);
        try b.lget(1);
        try b.lget(2);
        try b.lget(3);
        try b.b(OP_I64_SUB);
        try b.b(OP_I64_GT_U);
        try b.b(OP_I32_OR);
        try b.b(OP_IF);
        try b.b(T_VOID);
        try b.b(OP_UNREACHABLE);
        try b.b(OP_END);
        try b.b(OP_RETURN);
        try b.b(OP_END);

        try b.lget(5);
        try b.lset(6);
        try b.b(OP_BR);
        try b.u32Leb(0);
        try b.b(OP_END);
        try b.b(OP_END);

        try b.b(OP_UNREACHABLE);
        try writeFnBody(sec, 2, 3, 0, &b);
    }
}

fn memop_i64_eq(b: *Buf, off: u32, val: i64) !void {
    try b.memop(OP_I64_LOAD, 3, off);
    try b.i64c(val);
    try b.b(OP_I64_EQ);
}
