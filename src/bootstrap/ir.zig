// ════════════════════════════════════════════════════════════════════════════
// INTERMEDIATE REPRESENTATION — Platform-independent IR between AST and codegen
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const eql = util.eql;

/// IR instruction opcodes
pub const IROp = enum {
    // Constants & loads
    const_int, // dest = imm
    const_str, // dest = string ptr, dest2 = string len
    load_local, // dest = local[slot]
    store_local, // local[slot] = src
    // Arithmetic: dest = src1 OP src2
    add,
    sub,
    mul,
    div,
    @"mod",
    shl,
    shr,
    // Comparison: dest = src1 CMP src2 (result 0 or 1)
    cmp_eq,
    cmp_ne,
    cmp_lt,
    cmp_le,
    cmp_gt,
    cmp_ge,
    // Bitwise
    bit_and,
    bit_or,
    bit_xor,
    bit_not,
    // Unary
    neg,
    logic_not,
    // Logical short-circuit (handled specially)
    logic_and,
    logic_or,
    // Ternary: dest = src1 ? src2 : src3
    ternary,
    // Control flow
    jump, // goto target_block
    cond_jump, // if src goto target_block else goto alt_block
    ret, // return src
    // Calls
    call, // dest = call name(args...)
    // Builtins as first-class IR ops
    call_print,
    call_println,
    call_print_int,
    call_exit,
    call_sizeof,
    call_syscall,
    call_memcpy,
    call_memset,
    call_printptr,
    call_malloc,
    call_free,
    call_array_new,
    call_array_push,
    call_array_get,
    call_array_set,
    call_array_len,
    call_array_free,
    call_string_new,
    call_string_len,
    call_string_sub,
    call_string_eq,
    call_string_concat,
    call_string_split,
    call_open,
    call_read,
    call_write,
    call_close,
    // Struct
    struct_decl, // no-op at runtime
    field_access, // dest = base + field_offset
    field_store, // *(base + field_offset) = src
    // Pointer
    addr_of, // dest = address of local[slot]
    deref_load, // dest = *[src]
    deref_store, // *[dst] = src
    // Memory
    store_mem, // mem[addr] = src
    load_mem, // dest = mem[addr]
    // Module import (no-op)
    module_import,
    // Nop
    nop,
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
    target_block: u16 = 0, // for jump / cond_jump
    alt_block: u16 = 0, // for cond_jump (false branch)
    args: [6]u16 = undefined, // argument virtual registers
    arg_count: u8 = 0,
    slot: u16 = 0, // stack slot for load_local / store_local
    field_offset: u16 = 0, // for field_access / field_store
};

pub const MAX_INSTS_PER_BLOCK: u32 = 256;
pub const MAX_BLOCKS_PER_FN: u32 = 16;
pub const MAX_FNS: u32 = 16;

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
    param_slots: [8]u32 = undefined, // stack slots for params
    param_count: u32 = 0,
    blocks: [MAX_BLOCKS_PER_FN]IRBlock = undefined,
    block_count: u16 = 0,
    total_locals: u32 = 0, // total stack slots needed (params + lets)
    ast_idx: u32 = 0, // original AST fn_decl node index
};

/// IR module: collection of functions + string table
pub const IRModule = struct {
    fns: [MAX_FNS]IRFn = undefined,
    fn_count: u32 = 0,
    // String table
    strings: [4096]u8,
    string_len: u32 = 0,
    string_offsets: [256]u32 = undefined,
    string_lens: [256]u32 = undefined,
    string_count: u32 = 0,
    string_overflowed: bool = false,
    // Struct definitions (carried through from AST)
    struct_defs: [128]StructInfo,
    struct_count: u32 = 0,
    // Source references
    sources: [32][]const u8,
    source_count: u32 = 0,

    pub fn init(self: *IRModule) void {
        self.fn_count = 0;
        self.string_len = 0;
        self.string_count = 0;
        self.string_overflowed = false;
        self.struct_count = 0;
        self.source_count = 0;
    }

    pub fn addString(self: *IRModule, str: []const u8) u32 {
        // Keep all metadata and byte writes within their fixed-capacity tables.
        // A failed insertion is sticky; the compiler checks this flag after IR
        // generation and rejects the module instead of emitting corrupt code.
        if (self.string_overflowed) return 0;
        if (self.string_count > self.string_offsets.len or
            self.string_len > self.strings.len)
        {
            self.string_overflowed = true;
            return 0;
        }

        // Deduplicate only entries whose stored ranges are valid.
        var i: u32 = 0;
        while (i < self.string_count) : (i += 1) {
            const idx: usize = i;
            const off: usize = self.string_offsets[idx];
            const len: usize = self.string_lens[idx];
            if (off <= self.string_len and len <= self.string_len - off and len == str.len) {
                if (eql(self.strings[off..][0..len], str)) return i;
            }
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
        self.string_count += 1;
        return idx;
    }

    pub fn dumpModule(self: *const IRModule, source: []const u8) void {
        var fi: u32 = 0;
        while (fi < self.fn_count) : (fi += 1) {
            const f = &self.fns[fi];
            const fn_name = source[f.name_start..][0..f.name_len];
            util.printStr("FN ");
            util.printStr(fn_name);
            util.printStr(" (params=");
            util.printUsize(f.param_count);
            util.printStr(", locals=");
            util.printUsize(f.total_locals);
            util.printStr(", blocks=");
            util.printUsize(f.block_count);
            util.printStr(")\n");
            var bi: u16 = 0;
            while (bi < f.block_count) : (bi += 1) {
                const b = &f.blocks[bi];
                util.printStr("  B");
                util.printUsize(bi);
                util.printStr(":\n");
                var ii: u16 = 0;
                while (ii < b.inst_count) : (ii += 1) {
                    const inst = b.insts[ii];
                    util.printStr("    [");
                    util.printUsize(ii);
                    util.printStr("] ");
                    dumpInst(inst, source);
                }
            }
        }
    }
};

pub const StructInfo = struct {
    name_start: u32,
    name_len: u32,
    field_offsets: [32]u32,
    field_count: u32,
    total_size: u32,
};

fn dumpInst(inst: IRInst, source: []const u8) void {
    _ = source;
    switch (inst.op) {
        .const_int => {
            util.printStr("v"); util.printUsize(inst.dest);
            util.printStr(" = const "); util.printUsize(@bitCast(inst.imm));
            util.printStr("\n");
        },
        .load_local => {
            util.printStr("v"); util.printUsize(inst.dest);
            util.printStr(" = load local["); util.printUsize(inst.slot);
            util.printStr("]\n");
        },
        .store_local => {
            util.printStr("store v"); util.printUsize(inst.src1);
            util.printStr(" -> local["); util.printUsize(inst.slot);
            util.printStr("]\n");
        },
        .add, .sub, .mul, .div, .@"mod", .shl, .shr => {
            util.printStr("v"); util.printUsize(inst.dest);
            util.printStr(" = v"); util.printUsize(inst.src1);
            util.printStr(" op v"); util.printUsize(inst.src2);
            util.printStr("\n");
        },
        .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge => {
            util.printStr("v"); util.printUsize(inst.dest);
            util.printStr(" = v"); util.printUsize(inst.src1);
            util.printStr(" cmp v"); util.printUsize(inst.src2);
            util.printStr("\n");
        },
        .jump => {
            util.printStr("jump B"); util.printUsize(inst.target_block);
            util.printStr("\n");
        },
        .cond_jump => {
            util.printStr("cond_jump v"); util.printUsize(inst.src1);
            util.printStr(" -> B"); util.printUsize(inst.target_block);
            util.printStr(" else B"); util.printUsize(inst.alt_block);
            util.printStr("\n");
        },
        .ret => {
            util.printStr("ret v"); util.printUsize(inst.src1);
            util.printStr("\n");
        },
        .call_print_int => {
            util.printStr("call printInt v"); util.printUsize(inst.args[0]);
            util.printStr("\n");
        },
        .call_print, .call_println => {
            util.printStr("call print v"); util.printUsize(inst.args[0]);
            util.printStr("\n");
        },
        .call_exit => {
            util.printStr("call exit v"); util.printUsize(inst.args[0]);
            util.printStr("\n");
        },
        else => {
            util.printStr("???\n");
        },
    }
}