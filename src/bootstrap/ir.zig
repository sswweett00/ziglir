// ════════════════════════════════════════════════════════════════════════════
// INTERMEDIATE REPRESENTATION — Platform-independent IR between AST and codegen
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const eql = util.eql;

fn stringHash(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| hash = (hash ^ byte) *% 1099511628211;
    return hash;
}

/// IR instruction opcodes
pub const IROp = enum {
    // Constants, copies & locals
    const_int, // dest = imm
    const_str, // dest = string ptr (rodata, [ptr-8] holds len)
    copy, // dest = src1
    phi, // dest = phi(args[0..arg_count] from phi_blocks[0..arg_count])
    load_local, // dest = local[slot]
    store_local, // local[slot] = src1
    alloca, // dest = base address of local stack buffer starting at slot (imm bytes)
    // Arithmetic: dest = src1 OP src2
    add,
    sub,
    mul,
    div,
    udiv,
    @"mod",
    umod,
    shl,
    shr,
    ushr,
    // IEEE-754 floating-point arithmetic & casts (64-bit bits in vregs)
    fadd,
    fsub,
    fmul,
    fdiv,
    fneg,
    fcmp_eq,
    fcmp_ne,
    fcmp_lt,
    fcmp_le,
    fcmp_gt,
    fcmp_ge,
    itof,
    uitof,
    ftoi,
    ftou,
    f32_to_f64,
    f64_to_f32,
    // Width casts / extensions
    sext8,
    sext16,
    sext32,
    zext8,
    zext16,
    zext32,
    // Comparison: dest = src1 CMP src2 (result 0 or 1)
    cmp_eq,
    cmp_ne,
    cmp_lt,
    cmp_le,
    cmp_gt,
    cmp_ge,
    ucmp_lt,
    ucmp_le,
    ucmp_gt,
    ucmp_ge,
    // Bitwise
    bit_and,
    bit_or,
    bit_xor,
    bit_not,
    // Unary
    neg,
    logic_not,
    // Legacy compound logical/ternary placeholders (lowered in IRGen)
    logic_and,
    logic_or,
    ternary,
    // Control flow
    jump, // goto target_block
    cond_jump, // if src1 != 0 goto target_block else goto alt_block
    ret, // return src1
    unreachable_trap, // trap if control reaches a statically unreachable point
    // Calls & function pointers
    call, // dest = call name(args...)
    fn_addr, // dest = code address of callee_fn_idx
    call_indirect, // dest = call (*src1)(args...)
    // Builtins as first-class IR ops
    call_print,
    call_println,
    call_print_int,
    call_print_float,
    call_println_float,
    call_float_to_string,
    call_string_to_float,
    call_sqrt,
    call_fabs,
    call_floor,
    call_ceil,
    call_round,
    call_sin,
    call_cos,
    call_popcount,
    call_clz,
    call_ctz,
    call_bswap,
    call_atomic_add,
    call_atomic_cas,
    call_map_new,
    call_map_set,
    call_map_get,
    call_map_has,
    call_map_del,
    call_map_len,
    call_map_free,
    call_chan_new,
    call_chan_send,
    call_chan_recv,
    call_chan_close,
    call_assert,
    call_assert_eq,
    call_random_u64,
    call_random_bytes,
    call_secure_zero,
    call_const_time_eq,
    call_checked_add,
    call_checked_sub,
    call_checked_mul,
    call_getenv,
    call_sleep_ms,
    call_read_u32,
    call_write_u32,
    call_read_u64,
    call_write_u64,
    call_exit,
    call_panic,
    call_sizeof,
    call_syscall,
    call_memcpy,
    call_memset,
    call_printptr,
    call_malloc,
    call_free,
    call_ptr_add,
    call_read_byte,
    call_write_byte,
    call_array_new,
    call_array_push,
    call_array_get,
    call_array_set,
    call_array_len,
    call_array_free,
    call_string_new,
    call_string_len,
    call_string_sub,
    call_string_slice,
    call_string_char_at,
    call_string_eq,
    call_string_concat,
    call_string_split,
    call_int_to_string,
    call_string_to_int,
    call_open,
    call_read,
    call_write,
    call_close,
    call_unlink,
    call_mkdir,
    call_stat,
    call_getpid,
    call_getppid,
    call_getuid,
    call_term_size,
    call_set_raw_mode,
    call_read_key,
    call_tcp_socket,
    call_tcp_listen,
    call_tcp_accept,
    call_tcp_connect,
    call_sock_send,
    call_sock_recv,
    call_thread_create,
    call_thread_join,
    call_mutex_create,
    call_mutex_lock,
    call_mutex_unlock,
    call_argc,
    call_argv,
    call_time_ns,
    // Struct
    struct_decl, // no-op at runtime
    field_access, // dest = *(src1 + field_offset)
    field_store, // *(src1 + field_offset) = src2
    // Pointer
    addr_of, // dest = address of local[slot]
    deref_load, // dest = *[src1]
    deref_store, // *[src1] = src2
    // Memory
    store_mem, // mem[src1] = src2
    load_mem, // dest = mem[src1]
    // Module import (no-op)
    module_import,
    // Nop
    nop,

    pub fn isTerminator(self: IROp) bool {
        return switch (self) {
            .jump, .cond_jump, .ret, .unreachable_trap => true,
            else => false,
        };
    }

    pub fn hasSideEffects(self: IROp) bool {
        return switch (self) {
            .store_local,
            .jump,
            .cond_jump,
            .ret,
            .unreachable_trap,
            .call,
            .call_indirect,
            .call_print,
            .call_println,
            .call_print_int,
            .call_print_float,
            .call_println_float,
            .call_float_to_string,
            .call_string_to_float,
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
            .call_checked_add,
            .call_checked_sub,
            .call_checked_mul,
            .call_getenv,
            .call_sleep_ms,
            .call_read_u32,
            .call_write_u32,
            .call_read_u64,
            .call_write_u64,
            .call_exit,
            .call_panic,
            .call_syscall,
            .call_memcpy,
            .call_memset,
            .call_printptr,
            .call_malloc,
            .call_free,
            .call_write_byte,
            .call_array_new,
            .call_array_push,
            .call_array_set,
            .call_array_free,
            .call_string_new,
            .call_string_sub,
            .call_string_slice,
            .call_string_concat,
            .call_string_split,
            .call_int_to_string,
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
            .call_term_size,
            .call_set_raw_mode,
            .call_read_key,
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
            .call_time_ns,
            .field_store,
            .deref_store,
            .store_mem,
            .div,
            .udiv,
            .@"mod",
            .umod,
            .load_mem,
            .deref_load,
            .field_access,
            .call_array_get,
            .call_read_byte,
            .call_string_char_at,
            => true,
            else => false,
        };
    }

    pub fn isPureFoldable(self: IROp) bool {
        return switch (self) {
            .const_int,
            .copy,
            .add,
            .sub,
            .mul,
            .shl,
            .shr,
            .ushr,
            .sext8,
            .sext16,
            .sext32,
            .zext8,
            .zext16,
            .zext32,
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
            .bit_and,
            .bit_or,
            .bit_xor,
            .bit_not,
            .neg,
            .logic_not,
            => true,
            else => false,
        };
    }
};

/// Single IR instruction — compact layout
pub const IRInst = struct {
    op: IROp,
    dest: u16 = 0, // destination virtual register
    src1: u16 = 0, // first source operand (virtual register)
    src2: u16 = 0, // second source operand
    imm: i64 = 0, // immediate value
    str_idx: u16 = 0, // string table index (for const_str)
    str_len: u16 = 0, // string length (for const_str)
    fn_name_start: u32 = 0, // function name in source
    fn_name_len: u16 = 0,
    fn_source_id: u16 = 0,
    callee_fn_idx: i32 = -1, // resolved IRFn index for O(1) dispatch & method calls
    target_block: u16 = 0, // for jump / cond_jump
    alt_block: u16 = 0, // for cond_jump (false branch)
    args: [8]u16 = .{0} ** 8, // argument virtual registers (up to 8 args, or phi incoming vregs)
    phi_blocks: [8]u16 = .{0} ** 8, // incoming block index for each phi operand
    arg_count: u8 = 0,
    slot: u16 = 0, // stack slot for load_local / store_local / addr_of / alloca
    field_offset: u16 = 0, // for field_access / field_store
};

pub const MAX_INSTS_PER_BLOCK: u32 = 384;
pub const MAX_BLOCKS_PER_FN: u32 = 192;
pub const MAX_FNS: u32 = 256;

/// Basic block: a sequence of instructions ending with a terminator
pub const IRBlock = struct {
    label: u16 = 0,
    insts: [MAX_INSTS_PER_BLOCK]IRInst = undefined,
    inst_count: u16 = 0,
};

/// IR function
pub const IRFn = struct {
    name_start: u32,
    name_len: u32,
    source_id: u16 = 0,
    owner_struct_plus1: u32 = 0,
    param_slots: [8]u32 = .{0} ** 8,
    param_count: u32 = 0,
    blocks: [MAX_BLOCKS_PER_FN]IRBlock = undefined,
    block_count: u16 = 0,
    total_locals: u32 = 0,
    vreg_count: u16 = 1,
    ast_idx: u32 = 0,
    local_addr_taken: [256]bool = .{false} ** 256,
};

pub const StructInfo = struct {
    name_start: u32,
    name_len: u32,
    source_id: u16 = 0,
    field_offsets: [32]u32,
    field_count: u32,
    total_size: u32,
    is_union: bool = false,
};

/// IR module: collection of functions + string table
pub const IRModule = struct {
    fns: [MAX_FNS]IRFn = undefined,
    fn_count: u32 = 0,
    // String table
    strings: [16384]u8 = undefined,
    string_len: u32 = 0,
    string_offsets: [512]u32 = undefined,
    string_lens: [512]u32 = undefined,
    string_hashes: [512]u64 = undefined,
    string_hash_slots: [1024]u16 = .{0} ** 1024,
    string_count: u32 = 0,
    string_overflowed: bool = false,
    // Struct definitions (carried through from AST)
    struct_defs: [256]StructInfo = undefined,
    struct_count: u32 = 0,
    // Source references + owned synthetic text buffer (source_id == 63)
    sources: [64][]const u8 = undefined,
    source_count: u32 = 0,
    synth_buf: [65536]u8 = undefined,
    synth_len: u32 = 0,

    pub fn init(self: *IRModule) void {
        self.fn_count = 0;
        self.string_len = 0;
        self.string_count = 0;
        @memset(&self.string_hash_slots, 0);
        self.string_overflowed = false;
        self.struct_count = 0;
        self.source_count = 0;
        self.synth_len = 0;
    }

    pub fn initFnSlot(f: *IRFn, name_start: u32, name_len: u32, source_id: u16, ast_idx: u32, owner_struct_plus1: u32) void {
        f.name_start = name_start;
        f.name_len = name_len;
        f.source_id = source_id;
        f.owner_struct_plus1 = owner_struct_plus1;
        @memset(&f.param_slots, 0);
        f.param_count = 0;
        f.block_count = 0;
        f.total_locals = 0;
        f.vreg_count = 1;
        f.ast_idx = ast_idx;
        @memset(&f.local_addr_taken, false);
    }

    pub fn addSynthName(self: *IRModule, name: []const u8) struct { start: u32, len: u32 } {
        const start = self.synth_len;
        const avail = self.synth_buf.len - @as(usize, start);
        const len: u32 = @intCast(@min(name.len, avail));
        if (len > 0) {
            @memcpy(self.synth_buf[start..][0..len], name[0..len]);
            self.synth_len += len;
        }
        return .{ .start = start, .len = len };
    }

    pub fn addString(self: *IRModule, str: []const u8) u32 {
        if (self.string_overflowed) return 0;
        if (self.string_count > self.string_offsets.len or
            self.string_len > self.strings.len)
        {
            self.string_overflowed = true;
            return 0;
        }

        const hash = stringHash(str);
        const mask: usize = self.string_hash_slots.len - 1;
        var bucket: usize = @intCast(hash & mask);
        while (true) {
            const entry = self.string_hash_slots[bucket];
            if (entry == 0) break;
            const idx: usize = @as(usize, entry) - 1;
            if (idx >= self.string_count) {
                self.string_overflowed = true;
                return 0;
            }
            const off: usize = self.string_offsets[idx];
            const len: usize = self.string_lens[idx];
            if (self.string_hashes[idx] == hash and off <= self.string_len and
                len <= self.string_len - off and len == str.len and
                eql(self.strings[off..][0..len], str))
            {
                return @intCast(idx);
            }
            bucket = (bucket + 1) & mask;
        }

        const needed = std.math.add(usize, str.len, 1) catch {
            self.string_overflowed = true;
            return 0;
        };
        const used: usize = self.string_len;
        if (@as(usize, self.string_count) >= self.string_offsets.len or
            used > self.strings.len or needed > self.strings.len - used)
        {
            self.string_overflowed = true;
            return 0;
        }

        const idx = self.string_count;
        const off = self.string_len;
        @memcpy(self.strings[used..][0..str.len], str);
        self.strings[used + str.len] = 0;
        self.string_len += @intCast(needed);
        self.string_offsets[idx] = off;
        self.string_lens[idx] = @intCast(str.len);
        self.string_hashes[idx] = hash;

        bucket = @intCast(hash & mask);
        while (self.string_hash_slots[bucket] != 0) : (bucket = (bucket + 1) & mask) {}
        self.string_hash_slots[bucket] = @intCast(idx + 1);
        self.string_count += 1;
        return idx;
    }

    pub fn sourceFor(self: *const IRModule, source_id: u16, fallback: []const u8) []const u8 {
        if (source_id == 63) return self.synth_buf[0..self.synth_len];
        if (source_id < self.source_count) return self.sources[source_id];
        return fallback;
    }

    pub fn formatModule(self: *const IRModule, source: []const u8, writer: anytype) !void {
        var fi: u32 = 0;
        while (fi < self.fn_count) : (fi += 1) {
            const f = &self.fns[fi];
            const fsrc = self.sourceFor(f.source_id, source);
            const fn_name = if (@as(usize, f.name_start) + @as(usize, f.name_len) <= fsrc.len)
                fsrc[f.name_start..][0..f.name_len]
            else
                "<fn>";
            try writer.print("FN {s} (params={d}, locals={d}, blocks={d}):\n", .{
                fn_name,
                f.param_count,
                f.total_locals,
                f.block_count,
            });
            var bi: u16 = 0;
            while (bi < f.block_count) : (bi += 1) {
                const b = &f.blocks[bi];
                try writer.print("  B{d}:\n", .{bi});
                var ii: u16 = 0;
                while (ii < b.inst_count) : (ii += 1) {
                    const inst = b.insts[ii];
                    try writer.print("    [{d}] ", .{ii});
                    try formatInst(inst, self, source, writer);
                }
            }
        }
    }

    pub fn dumpModule(self: *const IRModule, source: []const u8) void {
        var buf: [65536]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        self.formatModule(source, fbs.writer()) catch {};
        util.printStr(fbs.getWritten());
    }
};

fn formatInst(inst: IRInst, module: *const IRModule, source: []const u8, writer: anytype) !void {
    switch (inst.op) {
        .const_int => try writer.print("v{d} = const {d}\n", .{ inst.dest, inst.imm }),
        .const_str => try writer.print("v{d} = const_str #{d} (len={d})\n", .{ inst.dest, inst.str_idx, inst.str_len }),
        .copy => try writer.print("v{d} = copy v{d}\n", .{ inst.dest, inst.src1 }),
        .phi => {
            try writer.print("v{d} = phi(", .{inst.dest});
            for (0..inst.arg_count) |pi| {
                if (pi > 0) try writer.print(", ", .{});
                try writer.print("B{d}: v{d}", .{ inst.phi_blocks[pi], inst.args[pi] });
            }
            try writer.print(")\n", .{});
        },
        .load_local => try writer.print("v{d} = load local[{d}]\n", .{ inst.dest, inst.slot }),
        .store_local => try writer.print("store v{d} -> local[{d}]\n", .{ inst.src1, inst.slot }),
        .alloca => try writer.print("v{d} = alloca local[{d}] ({d}B)\n", .{ inst.dest, inst.slot, inst.imm }),
        .addr_of => try writer.print("v{d} = addr_of local[{d}]\n", .{ inst.dest, inst.slot }),
        .deref_load => try writer.print("v{d} = *v{d}\n", .{ inst.dest, inst.src1 }),
        .deref_store => try writer.print("*v{d} = v{d}\n", .{ inst.src1, inst.src2 }),
        .field_access => try writer.print("v{d} = *(v{d} + {d})\n", .{ inst.dest, inst.src1, inst.field_offset }),
        .field_store => try writer.print("*(v{d} + {d}) = v{d}\n", .{ inst.src1, inst.field_offset, inst.src2 }),
        .add, .sub, .mul, .div, .udiv, .@"mod", .umod, .shl, .shr, .ushr, .bit_and, .bit_or, .bit_xor, .fadd, .fsub, .fmul, .fdiv => try writer.print("v{d} = {s} v{d}, v{d}\n", .{ inst.dest, @tagName(inst.op), inst.src1, inst.src2 }),
        .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge, .ucmp_lt, .ucmp_le, .ucmp_gt, .ucmp_ge, .fcmp_eq, .fcmp_ne, .fcmp_lt, .fcmp_le, .fcmp_gt, .fcmp_ge => try writer.print("v{d} = {s} v{d}, v{d}\n", .{ inst.dest, @tagName(inst.op), inst.src1, inst.src2 }),
        .neg, .fneg, .itof, .uitof, .ftoi, .ftou, .f32_to_f64, .f64_to_f32, .bit_not, .logic_not, .sext8, .sext16, .sext32, .zext8, .zext16, .zext32 => try writer.print("v{d} = {s} v{d}\n", .{ inst.dest, @tagName(inst.op), inst.src1 }),
        .fn_addr => try writer.print("v{d} = fn_addr #{d}\n", .{ inst.dest, inst.callee_fn_idx }),
        .call_indirect => try writer.print("v{d} = call_indirect v{d}({d} args)\n", .{ inst.dest, inst.src1, inst.arg_count }),
        .jump => try writer.print("jump B{d}\n", .{inst.target_block}),
        .cond_jump => try writer.print("cond_jump v{d} ? B{d} : B{d}\n", .{ inst.src1, inst.target_block, inst.alt_block }),
        .ret => try writer.print("ret v{d}\n", .{inst.src1}),
        .unreachable_trap => try writer.print("unreachable\n", .{}),
        .call => {
            const csrc = module.sourceFor(inst.fn_source_id, source);
            const cname = if (@as(usize, inst.fn_name_start) + @as(usize, inst.fn_name_len) <= csrc.len)
                csrc[inst.fn_name_start..][0..inst.fn_name_len]
            else
                "<call>";
            try writer.print("v{d} = call {s}({d} args)\n", .{ inst.dest, cname, inst.arg_count });
        },
        else => try writer.print("v{d} = {s} (args={d})\n", .{ inst.dest, @tagName(inst.op), inst.arg_count }),
    }
}
