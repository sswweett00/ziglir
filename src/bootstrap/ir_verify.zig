// Structural verifier for the bootstrap IR. Reject malformed IR before machine-code emission.
const ir = @import("ir.zig");

pub const VerifyError = error{
    TooManyFunctions,
    TooManyStrings,
    InvalidFunctionNameRange,
    InvalidBlockCount,
    InvalidInstructionCount,
    InvalidBranchTarget,
    InvalidStringIndex,
    InvalidCallArgumentCount,
    InvalidCallNameRange,
    TooManyStructs,
    InvalidStructNameRange,
    InvalidStructFieldCount,
    InvalidStructLayout,
    InvalidLocalSlot,
    InvalidParameterSlot,
    StackFrameTooLarge,
};

fn validRange(source: []const u8, start: u32, len: u32) bool {
    const s: usize = start;
    const n: usize = len;
    return s <= source.len and n <= source.len - s;
}

pub fn verify(module: *const ir.IRModule, source: []const u8) VerifyError!void {
    if (module.fn_count > module.fns.len) return error.TooManyFunctions;
    if (module.string_count > module.string_offsets.len or module.string_len > module.strings.len)
        return error.TooManyStrings;

    for (module.string_offsets[0..module.string_count], module.string_lens[0..module.string_count]) |off_u32, len_u32| {
        const off: usize = off_u32;
        const len: usize = len_u32;
        if (off > module.string_len or len >= module.string_len - off) return error.TooManyStrings;
        if (module.strings[off + len] != 0) return error.TooManyStrings;
    }

    if (module.struct_count > module.struct_defs.len) return error.TooManyStructs;
    for (module.struct_defs[0..module.struct_count]) |st| {
        if (!validRange(source, st.name_start, st.name_len)) return error.InvalidStructNameRange;
        if (st.field_count > st.field_offsets.len) return error.InvalidStructFieldCount;
        if (st.total_size % 8 != 0 or st.total_size / 8 != st.field_count) return error.InvalidStructLayout;
        for (st.field_offsets[0..st.field_count], 0..) |off, index| {
            if (off != index * 8 or off >= st.total_size) return error.InvalidStructLayout;
        }
    }

    for (module.fns[0..module.fn_count]) |*function| {
        if (!validRange(source, function.name_start, function.name_len)) return error.InvalidFunctionNameRange;
        if (function.block_count == 0 or function.block_count > function.blocks.len) return error.InvalidBlockCount;
        if (function.param_count > function.param_slots.len) return error.InvalidBlockCount;
        for (function.param_slots[0..function.param_count]) |slot| {
            if (slot == 0 or slot > function.total_locals) return error.InvalidParameterSlot;
        }

        // Bound the current backend's combined local/register stack frame before
        // its u32 size arithmetic and signed stack displacement calculations.
        var max_vreg: u32 = 0;
        for (function.blocks[0..function.block_count]) |*block| {
            if (block.inst_count > block.insts.len) return error.InvalidInstructionCount;
            for (block.insts[0..block.inst_count]) |inst| {
                max_vreg = @max(max_vreg, inst.dest);
                max_vreg = @max(max_vreg, inst.src1);
                max_vreg = @max(max_vreg, inst.src2);
                if (inst.arg_count > inst.args.len) return error.InvalidCallArgumentCount;
                for (inst.args[0..inst.arg_count]) |arg| max_vreg = @max(max_vreg, arg);
                switch (inst.op) {
                    .load_local, .store_local, .addr_of => {
                        if (inst.slot == 0 or inst.slot > function.total_locals) return error.InvalidLocalSlot;
                    },
                    else => {},
                }
            }
        }
        const stack_slots = @as(u64, function.total_locals) + max_vreg;
        if (stack_slots > (16 * 1024 * 1024) / 8) return error.StackFrameTooLarge;

        for (function.blocks[0..function.block_count]) |*block| {
            if (block.inst_count > block.insts.len) return error.InvalidInstructionCount;
            for (block.insts[0..block.inst_count]) |inst| {
                switch (inst.op) {
                    .jump => {
                        if (inst.target_block >= function.block_count) return error.InvalidBranchTarget;
                    },
                    .cond_jump => {
                        if (inst.target_block >= function.block_count or inst.alt_block >= function.block_count)
                            return error.InvalidBranchTarget;
                    },
                    .const_str => {
                        if (inst.str_idx >= module.string_count) return error.InvalidStringIndex;
                    },
                    .call => {
                        if (inst.arg_count > inst.args.len) return error.InvalidCallArgumentCount;
                        if (!validRange(source, inst.fn_name_start, inst.fn_name_len)) return error.InvalidCallNameRange;
                    },
                    else => {
                        if (inst.op == .call_print or inst.op == .call_println or inst.op == .call_print_int or
                            inst.op == .call_exit or inst.op == .call_sizeof or inst.op == .call_syscall or
                            inst.op == .call_memcpy or inst.op == .call_memset or inst.op == .call_printptr or
                            inst.op == .call_malloc or inst.op == .call_free or inst.op == .call_array_new or
                            inst.op == .call_array_push or inst.op == .call_array_get or inst.op == .call_array_set or
                            inst.op == .call_array_len or inst.op == .call_array_free or inst.op == .call_string_new or
                            inst.op == .call_string_len or inst.op == .call_string_sub or inst.op == .call_string_eq or
                            inst.op == .call_string_concat or inst.op == .call_string_split or inst.op == .call_open or
                            inst.op == .call_read or inst.op == .call_write or inst.op == .call_close)
                        {
                            if (inst.arg_count > inst.args.len) return error.InvalidCallArgumentCount;
                        }
                    },
                }
            }
        }
    }
}
