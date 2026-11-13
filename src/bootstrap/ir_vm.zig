// ════════════════════════════════════════════════════════════════════════════
// PORTABLE IR VIRTUAL MACHINE — Executes verified IRModule on any host OS/CPU
// Provides exact LIR semantics (checked memory, zero-on-free, div/shift traps,
// IEEE-754 floats, closures, dynamic arrays, HashDoS-safe maps, threads/chans)
// with zero external toolchain or OS-specific machine-code dependencies.
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const util = @import("util.zig");

const IRModule = ir.IRModule;
const IRFn = ir.IRFn;
const IRInst = ir.IRInst;
const IROp = ir.IROp;

const RODATA_BASE: u64 = 0x1000_0000;
const STACK_BASE: u64 = 0x2000_0000;
const HEAP_BASE: u64 = 0x4000_0000;
const ARRAY_TAG: u64 = 0x8000_0000;
const MAP_TAG: u64 = 0x9000_0000;
const CHAN_TAG: u64 = 0xA000_0000;
const MUTEX_TAG: u64 = 0xB000_0000;
const FN_TAG: u64 = 0xC000_0000;

const MAX_CALL_DEPTH: u32 = 2048;

pub const VMError = error{
    MissingMain,
    InvalidFunction,
    Trap,
    StackOverflow,
    MemoryFault,
    OutOfMemory,
};

pub const VMResult = struct {
    exit_code: i64 = 0,
    stdout: []u8 = &[_]u8{},
    stderr: []u8 = &[_]u8{},
    trapped: bool = false,

    pub fn deinit(self: *VMResult, alloc: std.mem.Allocator) void {
        if (self.stdout.len > 0) alloc.free(self.stdout);
        if (self.stderr.len > 0) alloc.free(self.stderr);
        self.stdout = &[_]u8{};
        self.stderr = &[_]u8{};
    }
};

const HeapAlloc = struct {
    addr: u64,
    data: []u8,
    freed: bool = false,
};

const MapEntry = struct {
    key_int: u64 = 0,
    key_str: []u8 = &[_]u8{},
    val: u64 = 0,
    occupied: bool = false,
};

const VMArr = struct {
    items: std.ArrayListUnmanaged(u64) = .{},
    freed: bool = false,
};

const VMMap = struct {
    str_keys: bool = false,
    entries: std.ArrayListUnmanaged(MapEntry) = .{},
    count: usize = 0,
    freed: bool = false,
};

const VMChan = struct {
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    not_full: std.Thread.Condition = .{},
    buf: std.ArrayListUnmanaged(u64) = .{},
    cap: usize = 1,
    closed: bool = false,
};

const VMThread = struct {
    thread: std.Thread,
    exit_val: i64 = 0,
    joined: bool = false,
};

const OpenFile = struct {
    file: std.fs.File,
    open: bool = true,
};

pub const VMState = struct {
    alloc: std.mem.Allocator,
    module: *const IRModule,
    source: []const u8,

    // Read-only interned strings buffer ([len:u64][bytes][NUL])
    rodata: std.ArrayListUnmanaged(u8) = .{},
    str_vaddrs: [512]u64 = .{0} ** 512,

    // Stack virtual memory arena (one slice backing stack frames)
    stack_mem: std.ArrayListUnmanaged(u8) = .{},
    stack_top: u64 = 0,

    // Heap allocations
    mem_lock: std.Thread.Mutex = .{},
    heap_allocs: std.ArrayListUnmanaged(HeapAlloc) = .{},
    next_heap_addr: u64 = HEAP_BASE,

    // Arrays, maps, channels, mutexes, threads
    arrays: std.ArrayListUnmanaged(VMArr) = .{},
    maps: std.ArrayListUnmanaged(VMMap) = .{},
    chans: std.ArrayListUnmanaged(*VMChan) = .{},
    mutexes: std.ArrayListUnmanaged(*std.Thread.Mutex) = .{},
    threads: std.ArrayListUnmanaged(*VMThread) = .{},

    // Virtual file descriptors (0,1,2 reserved for stdio)
    files: std.ArrayListUnmanaged(?std.fs.File) = .{},

    // Program arguments
    prog_args: []const []const u8 = &[_][]const u8{},

    // Optional stdio capture (for differential tests)
    capture_io: bool = false,
    io_lock: std.Thread.Mutex = .{},
    out_buf: std.ArrayListUnmanaged(u8) = .{},
    err_buf: std.ArrayListUnmanaged(u8) = .{},

    // Monotonic timer start
    start_ns: i128 = 0,
    fn_addr_taken: [ir.MAX_FNS]bool = .{false} ** ir.MAX_FNS,

    pub fn init(alloc: std.mem.Allocator, module: *const IRModule, source: []const u8) !*VMState {
        const self = try alloc.create(VMState);
        self.* = .{
            .alloc = alloc,
            .module = module,
            .source = source,
            .start_ns = std.time.nanoTimestamp(),
        };
        for (module.fns[0..module.fn_count]) |*mf| {
            for (mf.blocks[0..mf.block_count]) |*mb| {
                for (mb.insts[0..mb.inst_count]) |mi| {
                    if (mi.op == .fn_addr and mi.callee_fn_idx >= 0 and @as(usize, @intCast(mi.callee_fn_idx)) < ir.MAX_FNS) {
                        self.fn_addr_taken[@intCast(mi.callee_fn_idx)] = true;
                    }
                }
            }
        }

        // Populate rodata matching LIR ABI: 8-byte len before string pointer, NUL after
        var si: u32 = 0;
        while (si < module.string_count) : (si += 1) {
            const off = module.string_offsets[si];
            const len = module.string_lens[si];
            const bytes = module.strings[off..][0..len];
            // Align each string header to 8 bytes
            while ((self.rodata.items.len & 7) != 0) {
                try self.rodata.append(alloc, 0);
            }
            var len_le: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_le, len, .little);
            try self.rodata.appendSlice(alloc, &len_le);
            const ptr_off = self.rodata.items.len;
            try self.rodata.appendSlice(alloc, bytes);
            try self.rodata.append(alloc, 0);
            self.str_vaddrs[si] = RODATA_BASE + ptr_off;
        }
        try self.stack_mem.resize(alloc, 2 * 1024 * 1024);
        @memset(self.stack_mem.items, 0);
        // Reserve 0..2 as stdin/stdout/stderr placeholders
        try self.files.append(alloc, null);
        try self.files.append(alloc, null);
        try self.files.append(alloc, null);
        return self;
    }

    pub fn deinit(self: *VMState) void {
        for (self.threads.items) |th| {
            if (!th.joined) th.thread.join();
            self.alloc.destroy(th);
        }
        self.threads.deinit(self.alloc);
        for (self.files.items) |mf| {
            if (mf) |f| f.close();
        }
        self.files.deinit(self.alloc);
        for (self.heap_allocs.items) |*ha| {
            if (!ha.freed) @memset(ha.data, 0);
            self.alloc.free(ha.data);
        }
        self.heap_allocs.deinit(self.alloc);
        for (self.arrays.items) |*a| a.items.deinit(self.alloc);
        self.arrays.deinit(self.alloc);
        for (self.maps.items) |*m| {
            for (m.entries.items) |e| {
                if (e.occupied and e.key_str.len > 0) self.alloc.free(e.key_str);
            }
            m.entries.deinit(self.alloc);
        }
        self.maps.deinit(self.alloc);
        for (self.chans.items) |c| {
            c.buf.deinit(self.alloc);
            self.alloc.destroy(c);
        }
        self.chans.deinit(self.alloc);
        for (self.mutexes.items) |mx| self.alloc.destroy(mx);
        self.mutexes.deinit(self.alloc);
        self.rodata.deinit(self.alloc);
        self.stack_mem.deinit(self.alloc);
        self.out_buf.deinit(self.alloc);
        self.err_buf.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    fn writeOut(self: *VMState, s: []const u8) void {
        if (self.capture_io) {
            self.io_lock.lock();
            defer self.io_lock.unlock();
            self.out_buf.appendSlice(self.alloc, s) catch {};
        } else {
            util.printStr(s);
        }
    }

    fn writeErr(self: *VMState, s: []const u8) void {
        if (self.capture_io) {
            self.io_lock.lock();
            defer self.io_lock.unlock();
            self.err_buf.appendSlice(self.alloc, s) catch {};
        } else {
            util.printErr(s);
        }
    }

    fn fnName(self: *const VMState, fi: u32) []const u8 {
        const f = &self.module.fns[fi];
        const fsrc = self.module.sourceFor(f.source_id, self.source);
        if (@as(usize, f.name_start) + @as(usize, f.name_len) <= fsrc.len) {
            return fsrc[f.name_start..][0..f.name_len];
        }
        return "";
    }

    fn findFn(self: *const VMState, name: []const u8) ?u32 {
        var i: u32 = 0;
        while (i < self.module.fn_count) : (i += 1) {
            if (util.eql(self.fnName(i), name)) return i;
        }
        return null;
    }

    fn allocHeap(self: *VMState, req_size: i64) VMError!u64 {
        if (req_size <= 0 or req_size > 256 * 1024 * 1024) return error.Trap;
        const sz: usize = @intCast(req_size);
        const total = std.math.add(usize, sz, 8) catch return error.Trap;
        const buf = self.alloc.alloc(u8, total) catch return error.OutOfMemory;
        @memset(buf, 0);
        std.mem.writeInt(u64, buf[0..8], sz, .little);
        self.mem_lock.lock();
        defer self.mem_lock.unlock();
        const vaddr = self.next_heap_addr;
        // Align next address generously with unmapped guard gap
        self.next_heap_addr += ((@as(u64, total) + 64 + 15) & ~@as(u64, 15));
        self.heap_allocs.append(self.alloc, .{ .addr = vaddr, .data = buf }) catch {
            self.alloc.free(buf);
            return error.OutOfMemory;
        };
        return vaddr + 8;
    }

    fn freeHeap(self: *VMState, ptr: u64) VMError!void {
        if (ptr == 0) return;
        if (ptr < HEAP_BASE) return error.MemoryFault;
        self.mem_lock.lock();
        defer self.mem_lock.unlock();
        for (self.heap_allocs.items) |*ha| {
            if (ptr == ha.addr + 8) {
                if (ha.freed) return error.MemoryFault; // double free
                @memset(ha.data, 0); // zero-wipe on free
                ha.freed = true;
                return;
            }
        }
        return error.MemoryFault;
    }

    fn resolveSlice(self: *VMState, ptr: u64, size: usize, write_access: bool) VMError![]u8 {
        if (ptr < 4096) return error.MemoryFault;
        if (ptr >= RODATA_BASE and ptr < STACK_BASE) {
            if (write_access) return error.MemoryFault; // W^X: rodata is read-only
            // Allow reading header at ptr-8 (within rodata)
            const off: usize = @intCast(ptr - RODATA_BASE);
            if (off > self.rodata.items.len or size > self.rodata.items.len - off) return error.MemoryFault;
            return self.rodata.items[off..][0..size];
        }
        if (ptr >= STACK_BASE and ptr < HEAP_BASE) {
            const off: usize = @intCast(ptr - STACK_BASE);
            if (off > self.stack_mem.items.len or size > self.stack_mem.items.len - off) return error.MemoryFault;
            return self.stack_mem.items[off..][0..size];
        }
        if (ptr >= HEAP_BASE and ptr < ARRAY_TAG) {
            self.mem_lock.lock();
            defer self.mem_lock.unlock();
            for (self.heap_allocs.items) |ha| {
                const start = ha.addr;
                const end = start + ha.data.len;
                if (ptr >= start and ptr < end) {
                    if (ha.freed) return error.MemoryFault; // UAF trap
                    const off: usize = @intCast(ptr - start);
                    if (size > ha.data.len - off) return error.MemoryFault;
                    return ha.data[off..][0..size];
                }
            }
        }
        return error.MemoryFault;
    }

    fn readU8(self: *VMState, ptr: u64) VMError!u8 {
        const s = try self.resolveSlice(ptr, 1, false);
        return s[0];
    }
    fn writeU8(self: *VMState, ptr: u64, val: u8) VMError!void {
        const s = try self.resolveSlice(ptr, 1, true);
        s[0] = val;
    }
    fn readU32(self: *VMState, ptr: u64) VMError!u32 {
        const s = try self.resolveSlice(ptr, 4, false);
        return std.mem.readInt(u32, s[0..4], .little);
    }
    fn writeU32(self: *VMState, ptr: u64, val: u32) VMError!void {
        const s = try self.resolveSlice(ptr, 4, true);
        std.mem.writeInt(u32, s[0..4], val, .little);
    }
    fn readU64(self: *VMState, ptr: u64) VMError!u64 {
        const s = try self.resolveSlice(ptr, 8, false);
        return std.mem.readInt(u64, s[0..8], .little);
    }
    fn writeU64(self: *VMState, ptr: u64, val: u64) VMError!void {
        const s = try self.resolveSlice(ptr, 8, true);
        std.mem.writeInt(u64, s[0..8], val, .little);
    }

    fn readLirString(self: *VMState, ptr: u64) VMError![]const u8 {
        if (ptr == 0) return "";
        if (ptr < 4096) return error.MemoryFault;
        const len_u64 = try self.readU64(ptr - 8);
        if (len_u64 > 64 * 1024 * 1024) return error.MemoryFault;
        const len: usize = @intCast(len_u64);
        if (len == 0) return "";
        return try self.resolveSlice(ptr, len, false);
    }

    fn readCString(self: *VMState, ptr: u64) VMError![]const u8 {
        if (ptr < 4096) return error.MemoryFault;
        // Fast path if LIR string (rodata or string_new)
        if (ptr >= RODATA_BASE and ptr < STACK_BASE) {
            const off: usize = @intCast(ptr - RODATA_BASE);
            if (off < self.rodata.items.len) {
                const rest = self.rodata.items[off..];
                const nul = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
                return rest[0..nul];
            }
        }
        var len: usize = 0;
        while (len < 65536) : (len += 1) {
            const b = try self.readU8(ptr + len);
            if (b == 0) break;
        }
        return try self.resolveSlice(ptr, len, false);
    }

    fn allocLirString(self: *VMState, bytes: []const u8) VMError!u64 {
        // Store as [len:u64][bytes][NUL] so ptr - 8 == len
        const sz: i64 = @intCast(bytes.len + 1);
        const p = try self.allocHeap(sz);
        // Overwrite the 8-byte header at p - 8 with exact string byte length
        self.mem_lock.lock();
        for (self.heap_allocs.items) |ha| {
            if (p == ha.addr + 8) {
                std.mem.writeInt(u64, ha.data[0..8], bytes.len, .little);
                if (bytes.len > 0) @memcpy(ha.data[8..][0..bytes.len], bytes);
                ha.data[8 + bytes.len] = 0;
                break;
            }
        }
        self.mem_lock.unlock();
        return p;
    }

    pub fn run(self: *VMState) VMError!i64 {
        const main_fi = self.findFn("main") orelse return error.MissingMain;
        return try self.callFn(main_fi, &[_]u64{}, 0);
    }

    fn execThreadEntry(self: *VMState, fi: u32, arg: u64, th: *VMThread) void {
        const args = [_]u64{arg};
        th.exit_val = self.callFn(fi, &args, 0) catch 0;
    }

    fn callFn(self: *VMState, fi: u32, args: []const u64, depth: u32) VMError!i64 {
        if (depth >= MAX_CALL_DEPTH) return error.StackOverflow;
        if (fi >= self.module.fn_count) return error.InvalidFunction;
        const f = &self.module.fns[fi];

        // Allocate vregs and local slots
        const vreg_n = @max(@as(usize, f.vreg_count) + 4, 32);
        const local_n = @max(@as(usize, f.total_locals) + 2, 16);
        const vregs = self.alloc.alloc(u64, vreg_n) catch return error.OutOfMemory;
        defer self.alloc.free(vregs);
        @memset(vregs, 0);

        const locals = self.alloc.alloc(u64, local_n) catch return error.OutOfMemory;
        defer self.alloc.free(locals);
        @memset(locals, 0);

        // Reserve virtual stack frame for addr_of / alloca
        self.mem_lock.lock();
        const saved_stack_top = self.stack_top;
        const frame_bytes = ((local_n * 8 + 15) & ~@as(usize, 15));
        if (self.stack_top + frame_bytes > self.stack_mem.items.len) {
            self.mem_lock.unlock();
            return error.StackOverflow;
        }
        const frame_base_off: usize = @intCast(self.stack_top);
        const frame_base_vaddr = STACK_BASE + self.stack_top;
        self.stack_top += frame_bytes;
        @memset(self.stack_mem.items[frame_base_off..][0..frame_bytes], 0);
        self.mem_lock.unlock();
        defer {
            self.mem_lock.lock();
            @memset(self.stack_mem.items[frame_base_off..][0..frame_bytes], 0);
            self.stack_top = saved_stack_top;
            self.mem_lock.unlock();
        }

        // Bind incoming parameters
        var pi: usize = 0;
        while (pi < f.param_count and pi < args.len) : (pi += 1) {
            const slot = f.param_slots[pi];
            if (slot < locals.len) {
                locals[slot] = args[pi];
                if (slot > 0 and slot < f.local_addr_taken.len and f.local_addr_taken[slot]) {
                    try self.writeU64(frame_base_vaddr + (@as(u64, slot) - 1) * 8, args[pi]);
                }
            }
        }

        var cur_blk: u16 = 0;
        var prev_blk: u16 = 0;
        var phi_vals: [256]u64 = undefined;

        while (true) {
            const blk = &f.blocks[cur_blk];
            // Evaluate all leading phi nodes simultaneously using prev_blk
            var ii: usize = 0;
            var phi_count: usize = 0;
            while (ii < blk.inst_count and blk.insts[ii].op == .phi) : (ii += 1) {
                const pinst = blk.insts[ii];
                var val: u64 = 0;
                for (0..pinst.arg_count) |ai| {
                    if (pinst.phi_blocks[ai] == prev_blk) {
                        val = if (pinst.args[ai] < vregs.len) vregs[pinst.args[ai]] else 0;
                        break;
                    }
                }
                if (phi_count < phi_vals.len) {
                    phi_vals[phi_count] = val;
                    phi_count += 1;
                }
            }
            for (0..phi_count) |k| {
                const d = blk.insts[k].dest;
                if (d < vregs.len) vregs[d] = phi_vals[k];
            }

            while (ii < blk.inst_count) : (ii += 1) {
                const inst = blk.insts[ii];
                switch (inst.op) {
                    .nop, .struct_decl, .module_import, .phi => {},
                    .const_int => vregs[inst.dest] = @bitCast(inst.imm),
                    .const_str => vregs[inst.dest] = self.str_vaddrs[inst.str_idx],
                    .copy => vregs[inst.dest] = vregs[inst.src1],
                    .load_local => {
                        const slot_idx: u64 = if (inst.slot > 0) @as(u64, inst.slot) - 1 else 0;
                        if (inst.slot > 0 and inst.slot < f.local_addr_taken.len and f.local_addr_taken[inst.slot]) {
                            vregs[inst.dest] = try self.readU64(frame_base_vaddr + slot_idx * 8);
                        } else {
                            vregs[inst.dest] = locals[inst.slot];
                        }
                    },
                    .store_local => {
                        const slot_idx: u64 = if (inst.slot > 0) @as(u64, inst.slot) - 1 else 0;
                        if (inst.slot > 0 and inst.slot < f.local_addr_taken.len and f.local_addr_taken[inst.slot]) {
                            try self.writeU64(frame_base_vaddr + slot_idx * 8, vregs[inst.src1]);
                        } else {
                            locals[inst.slot] = vregs[inst.src1];
                        }
                    },
                    .addr_of => vregs[inst.dest] = frame_base_vaddr + (if (inst.slot > 0) @as(u64, inst.slot) - 1 else 0) * 8,
                    .alloca => {
                        const base_slot_addr = frame_base_vaddr + (if (inst.slot > 0) @as(u64, inst.slot) - 1 else 0) * 8;
                        // Extra bytes beyond total_locals? Reserve from stack arena cleanly!
                        self.mem_lock.lock();
                        const sz: usize = @intCast(@max(inst.imm, 8));
                        const aligned = (sz + 15) & ~@as(usize, 15);
                        if (self.stack_top + aligned > self.stack_mem.items.len) {
                            self.mem_lock.unlock();
                            return error.StackOverflow;
                        }
                        const a_off: usize = @intCast(self.stack_top);
                        const a_vaddr = STACK_BASE + self.stack_top;
                        self.stack_top += aligned;
                        @memset(self.stack_mem.items[a_off..][0..aligned], 0);
                        self.mem_lock.unlock();
                        _ = base_slot_addr;
                        vregs[inst.dest] = a_vaddr;
                    },
                    .deref_load => vregs[inst.dest] = try self.readU64(vregs[inst.src1]),
                    .deref_store => try self.writeU64(vregs[inst.src1], vregs[inst.src2]),
                    .field_access => vregs[inst.dest] = try self.readU64(vregs[inst.src1] +% inst.field_offset),
                    .field_store => try self.writeU64(vregs[inst.src1] +% inst.field_offset, vregs[inst.src2]),
                    .load_mem => vregs[inst.dest] = try self.readU64(vregs[inst.src1]),
                    .store_mem => try self.writeU64(vregs[inst.src1], vregs[inst.src2]),
                    .add => vregs[inst.dest] = vregs[inst.src1] +% vregs[inst.src2],
                    .sub => vregs[inst.dest] = vregs[inst.src1] -% vregs[inst.src2],
                    .mul => vregs[inst.dest] = vregs[inst.src1] *% vregs[inst.src2],
                    .div => {
                        const a: i64 = @bitCast(vregs[inst.src1]);
                        const b: i64 = @bitCast(vregs[inst.src2]);
                        if (b == 0 or (a == std.math.minInt(i64) and b == -1)) return error.Trap;
                        vregs[inst.dest] = @bitCast(@divTrunc(a, b));
                    },
                    .udiv => {
                        if (vregs[inst.src2] == 0) return error.Trap;
                        vregs[inst.dest] = vregs[inst.src1] / vregs[inst.src2];
                    },
                    .@"mod" => {
                        const a: i64 = @bitCast(vregs[inst.src1]);
                        const b: i64 = @bitCast(vregs[inst.src2]);
                        if (b == 0 or (a == std.math.minInt(i64) and b == -1)) return error.Trap;
                        vregs[inst.dest] = @bitCast(@rem(a, b));
                    },
                    .umod => {
                        if (vregs[inst.src2] == 0) return error.Trap;
                        vregs[inst.dest] = vregs[inst.src1] % vregs[inst.src2];
                    },
                    .shl => {
                        const sh = vregs[inst.src2];
                        if (sh >= 64) return error.Trap;
                        vregs[inst.dest] = vregs[inst.src1] << @intCast(sh);
                    },
                    .shr => {
                        const sh = vregs[inst.src2];
                        if (sh >= 64) return error.Trap;
                        const a: i64 = @bitCast(vregs[inst.src1]);
                        vregs[inst.dest] = @bitCast(a >> @intCast(sh));
                    },
                    .ushr => {
                        const sh = vregs[inst.src2];
                        if (sh >= 64) return error.Trap;
                        vregs[inst.dest] = vregs[inst.src1] >> @intCast(sh);
                    },
                    .bit_and => vregs[inst.dest] = vregs[inst.src1] & vregs[inst.src2],
                    .bit_or => vregs[inst.dest] = vregs[inst.src1] | vregs[inst.src2],
                    .bit_xor => vregs[inst.dest] = vregs[inst.src1] ^ vregs[inst.src2],
                    .bit_not => vregs[inst.dest] = ~vregs[inst.src1],
                    .neg => {
                        const a: i64 = @bitCast(vregs[inst.src1]);
                        vregs[inst.dest] = @bitCast(-%a);
                    },
                    .logic_not => vregs[inst.dest] = if (vregs[inst.src1] == 0) 1 else 0,
                    .sext8 => {
                        const b: i8 = @bitCast(@as(u8, @truncate(vregs[inst.src1])));
                        vregs[inst.dest] = @bitCast(@as(i64, b));
                    },
                    .sext16 => {
                        const b: i16 = @bitCast(@as(u16, @truncate(vregs[inst.src1])));
                        vregs[inst.dest] = @bitCast(@as(i64, b));
                    },
                    .sext32 => {
                        const b: i32 = @bitCast(@as(u32, @truncate(vregs[inst.src1])));
                        vregs[inst.dest] = @bitCast(@as(i64, b));
                    },
                    .zext8 => vregs[inst.dest] = vregs[inst.src1] & 0xFF,
                    .zext16 => vregs[inst.dest] = vregs[inst.src1] & 0xFFFF,
                    .zext32 => vregs[inst.dest] = vregs[inst.src1] & 0xFFFF_FFFF,
                    .cmp_eq => vregs[inst.dest] = @intFromBool(vregs[inst.src1] == vregs[inst.src2]),
                    .cmp_ne => vregs[inst.dest] = @intFromBool(vregs[inst.src1] != vregs[inst.src2]),
                    .cmp_lt => vregs[inst.dest] = @intFromBool(@as(i64, @bitCast(vregs[inst.src1])) < @as(i64, @bitCast(vregs[inst.src2]))),
                    .cmp_le => vregs[inst.dest] = @intFromBool(@as(i64, @bitCast(vregs[inst.src1])) <= @as(i64, @bitCast(vregs[inst.src2]))),
                    .cmp_gt => vregs[inst.dest] = @intFromBool(@as(i64, @bitCast(vregs[inst.src1])) > @as(i64, @bitCast(vregs[inst.src2]))),
                    .cmp_ge => vregs[inst.dest] = @intFromBool(@as(i64, @bitCast(vregs[inst.src1])) >= @as(i64, @bitCast(vregs[inst.src2]))),
                    .ucmp_lt => vregs[inst.dest] = @intFromBool(vregs[inst.src1] < vregs[inst.src2]),
                    .ucmp_le => vregs[inst.dest] = @intFromBool(vregs[inst.src1] <= vregs[inst.src2]),
                    .ucmp_gt => vregs[inst.dest] = @intFromBool(vregs[inst.src1] > vregs[inst.src2]),
                    .ucmp_ge => vregs[inst.dest] = @intFromBool(vregs[inst.src1] >= vregs[inst.src2]),
                    .fadd => vregs[inst.dest] = @bitCast(@as(f64, @bitCast(vregs[inst.src1])) + @as(f64, @bitCast(vregs[inst.src2]))),
                    .fsub => vregs[inst.dest] = @bitCast(@as(f64, @bitCast(vregs[inst.src1])) - @as(f64, @bitCast(vregs[inst.src2]))),
                    .fmul => vregs[inst.dest] = @bitCast(@as(f64, @bitCast(vregs[inst.src1])) * @as(f64, @bitCast(vregs[inst.src2]))),
                    .fdiv => vregs[inst.dest] = @bitCast(@as(f64, @bitCast(vregs[inst.src1])) / @as(f64, @bitCast(vregs[inst.src2]))),
                    .fneg => vregs[inst.dest] = @bitCast(-@as(f64, @bitCast(vregs[inst.src1]))),
                    .fcmp_eq => vregs[inst.dest] = @intFromBool(@as(f64, @bitCast(vregs[inst.src1])) == @as(f64, @bitCast(vregs[inst.src2]))),
                    .fcmp_ne => vregs[inst.dest] = @intFromBool(@as(f64, @bitCast(vregs[inst.src1])) != @as(f64, @bitCast(vregs[inst.src2]))),
                    .fcmp_lt => vregs[inst.dest] = @intFromBool(@as(f64, @bitCast(vregs[inst.src1])) < @as(f64, @bitCast(vregs[inst.src2]))),
                    .fcmp_le => vregs[inst.dest] = @intFromBool(@as(f64, @bitCast(vregs[inst.src1])) <= @as(f64, @bitCast(vregs[inst.src2]))),
                    .fcmp_gt => vregs[inst.dest] = @intFromBool(@as(f64, @bitCast(vregs[inst.src1])) > @as(f64, @bitCast(vregs[inst.src2]))),
                    .fcmp_ge => vregs[inst.dest] = @intFromBool(@as(f64, @bitCast(vregs[inst.src1])) >= @as(f64, @bitCast(vregs[inst.src2]))),
                    .itof => vregs[inst.dest] = @bitCast(@as(f64, @floatFromInt(@as(i64, @bitCast(vregs[inst.src1]))))),
                    .uitof => vregs[inst.dest] = @bitCast(@as(f64, @floatFromInt(vregs[inst.src1]))),
                    .ftoi => {
                        const fv: f64 = @bitCast(vregs[inst.src1]);
                        if (std.math.isNan(fv) or fv < -9223372036854775808.0 or fv >= 9223372036854775808.0) return error.Trap;
                        vregs[inst.dest] = @bitCast(@as(i64, @intFromFloat(fv)));
                    },
                    .ftou => {
                        const fv: f64 = @bitCast(vregs[inst.src1]);
                        if (std.math.isNan(fv) or fv < 0.0 or fv >= 18446744073709551616.0) return error.Trap;
                        vregs[inst.dest] = @intFromFloat(fv);
                    },
                    .f64_to_f32 => {
                        const f32v: f32 = @floatCast(@as(f64, @bitCast(vregs[inst.src1])));
                        vregs[inst.dest] = @as(u32, @bitCast(f32v));
                    },
                    .f32_to_f64 => {
                        const f32v: f32 = @bitCast(@as(u32, @truncate(vregs[inst.src1])));
                        vregs[inst.dest] = @bitCast(@as(f64, f32v));
                    },
                    .jump => {
                        prev_blk = cur_blk;
                        cur_blk = inst.target_block;
                        break;
                    },
                    .cond_jump => {
                        prev_blk = cur_blk;
                        cur_blk = if (vregs[inst.src1] != 0) inst.target_block else inst.alt_block;
                        break;
                    },
                    .ret => return @bitCast(vregs[inst.src1]),
                    .unreachable_trap => return error.Trap,
                    .fn_addr => vregs[inst.dest] = FN_TAG + @as(u64, @intCast(inst.callee_fn_idx)),
                    .call => {
                        var cargs: [8]u64 = undefined;
                        for (0..inst.arg_count) |ai| cargs[ai] = vregs[inst.args[ai]];
                        const target_fi: u32 = if (inst.callee_fn_idx >= 0)
                            @intCast(inst.callee_fn_idx)
                        else blk_c: {
                            const csrc = self.module.sourceFor(inst.fn_source_id, self.source);
                            const cname = csrc[inst.fn_name_start..][0..inst.fn_name_len];
                            break :blk_c self.findFn(cname) orelse return error.InvalidFunction;
                        };
                        const rv = try self.callFn(target_fi, cargs[0..inst.arg_count], depth + 1);
                        if (inst.dest != 0) vregs[inst.dest] = @bitCast(rv);
                    },
                    .call_indirect => {
                        const target = vregs[inst.src1];
                        if (target < FN_TAG or target >= FN_TAG + self.module.fn_count) return error.MemoryFault;
                        const target_fi: u32 = @intCast(target - FN_TAG);
                        if (!self.fn_addr_taken[target_fi]) return error.MemoryFault;
                        var cargs: [8]u64 = undefined;
                        for (0..inst.arg_count) |ai| cargs[ai] = vregs[inst.args[ai]];
                        const rv = try self.callFn(target_fi, cargs[0..inst.arg_count], depth + 1);
                        if (inst.dest != 0) vregs[inst.dest] = @bitCast(rv);
                    },
                    else => try self.execBuiltin(inst, vregs),
                }
            }
        }
    }

    fn execBuiltin(self: *VMState, inst: IRInst, vregs: []u64) VMError!void {
        var b: [128]u8 = undefined;
        switch (inst.op) {
            .call_print, .call_println => {
                const s = try self.readLirString(vregs[inst.args[0]]);
                self.writeOut(s);
                if (inst.op == .call_println) self.writeOut("\n");
            },
            .call_print_int => {
                const iv: i64 = @bitCast(vregs[inst.args[0]]);
                const txt = std.fmt.bufPrint(&b, "{d}\n", .{iv}) catch "";
                self.writeOut(txt);
            },
            .call_print_float, .call_println_float => {
                const s = formatLirFloat(&b, vregs[inst.args[0]]);
                self.writeOut(s);
                if (inst.op == .call_println_float) self.writeOut("\n");
            },
            .call_printptr => {
                const iv: i64 = @bitCast(vregs[inst.args[0]]);
                const txt = std.fmt.bufPrint(&b, "{d}\n", .{iv}) catch "";
                self.writeOut(txt);
            },
            .call_float_to_string => {
                const s = formatLirFloat(&b, vregs[inst.args[0]]);
                vregs[inst.dest] = try self.allocLirString(s);
            },
            .call_string_to_float => {
                const s = try self.readLirString(vregs[inst.args[0]]);
                const fv = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch 0.0;
                vregs[inst.dest] = @bitCast(fv);
            },
            .call_sqrt => vregs[inst.dest] = @bitCast(@sqrt(@as(f64, @bitCast(vregs[inst.args[0]])))),
            .call_fabs => vregs[inst.dest] = @bitCast(@abs(@as(f64, @bitCast(vregs[inst.args[0]])))),
            .call_floor => vregs[inst.dest] = @bitCast(@floor(@as(f64, @bitCast(vregs[inst.args[0]])))),
            .call_ceil => vregs[inst.dest] = @bitCast(@ceil(@as(f64, @bitCast(vregs[inst.args[0]])))),
            .call_round => vregs[inst.dest] = @bitCast(@round(@as(f64, @bitCast(vregs[inst.args[0]])))),
            .call_sin => vregs[inst.dest] = @bitCast(@sin(@as(f64, @bitCast(vregs[inst.args[0]])))),
            .call_cos => vregs[inst.dest] = @bitCast(@cos(@as(f64, @bitCast(vregs[inst.args[0]])))),
            .call_popcount => vregs[inst.dest] = @popCount(vregs[inst.args[0]]),
            .call_clz => vregs[inst.dest] = @clz(vregs[inst.args[0]]),
            .call_ctz => vregs[inst.dest] = @ctz(vregs[inst.args[0]]),
            .call_bswap => vregs[inst.dest] = @byteSwap(vregs[inst.args[0]]),
            .call_atomic_add => {
                const cur: i64 = @bitCast(try self.readU64(vregs[inst.args[0]]));
                const addv: i64 = @bitCast(vregs[inst.args[1]]);
                try self.writeU64(vregs[inst.args[0]], @bitCast(cur +% addv));
                vregs[inst.dest] = @bitCast(cur);
            },
            .call_atomic_cas => {
                const cur = try self.readU64(vregs[inst.args[0]]);
                if (cur == vregs[inst.args[1]]) {
                    try self.writeU64(vregs[inst.args[0]], vregs[inst.args[2]]);
                    vregs[inst.dest] = 1;
                } else {
                    vregs[inst.dest] = 0;
                }
            },
            .call_malloc => vregs[inst.dest] = try self.allocHeap(@bitCast(vregs[inst.args[0]])),
            .call_free => try self.freeHeap(vregs[inst.args[0]]),
            .call_ptr_add => vregs[inst.dest] = vregs[inst.args[0]] +% vregs[inst.args[1]],
            .call_read_byte => vregs[inst.dest] = try self.readU8(vregs[inst.args[0]]),
            .call_write_byte => try self.writeU8(vregs[inst.args[0]], @truncate(vregs[inst.args[1]])),
            .call_read_u32 => vregs[inst.dest] = try self.readU32(vregs[inst.args[0]]),
            .call_write_u32 => try self.writeU32(vregs[inst.args[0]], @truncate(vregs[inst.args[1]])),
            .call_read_u64 => vregs[inst.dest] = try self.readU64(vregs[inst.args[0]]),
            .call_write_u64 => try self.writeU64(vregs[inst.args[0]], vregs[inst.args[1]]),
            .call_memcpy => {
                const n_i: i64 = @bitCast(vregs[inst.args[2]]);
                if (n_i < 0) return error.Trap;
                if (n_i > 0) {
                    const n: usize = @intCast(n_i);
                    const dst = try self.resolveSlice(vregs[inst.args[0]], n, true);
                    const src_s = try self.resolveSlice(vregs[inst.args[1]], n, false);
                    std.mem.copyForwards(u8, dst, src_s);
                }
                if (inst.dest != 0) vregs[inst.dest] = vregs[inst.args[0]];
            },
            .call_memset => {
                const n_i: i64 = @bitCast(vregs[inst.args[2]]);
                if (n_i < 0) return error.Trap;
                if (n_i > 0) {
                    const dst = try self.resolveSlice(vregs[inst.args[0]], @intCast(n_i), true);
                    @memset(dst, @truncate(vregs[inst.args[1]]));
                }
                if (inst.dest != 0) vregs[inst.dest] = vregs[inst.args[0]];
            },
            .call_secure_zero => {
                const n_i: i64 = @bitCast(vregs[inst.args[1]]);
                if (n_i < 0) return error.Trap;
                if (n_i > 0) {
                    const dst = try self.resolveSlice(vregs[inst.args[0]], @intCast(n_i), true);
                    std.crypto.utils.secureZero(u8, dst);
                }
            },
            .call_const_time_eq => {
                const n_i: i64 = @bitCast(vregs[inst.args[2]]);
                if (n_i < 0) return error.Trap;
                if (n_i == 0) {
                    vregs[inst.dest] = 1;
                    return;
                }
                const n: usize = @intCast(n_i);
                const sa = try self.resolveSlice(vregs[inst.args[0]], n, false);
                const sb = try self.resolveSlice(vregs[inst.args[1]], n, false);
                var diff: u8 = 0;
                for (sa, sb) |ca, cb| diff |= ca ^ cb;
                vregs[inst.dest] = @intFromBool(diff == 0);
            },
            .call_checked_add => {
                const a: i64 = @bitCast(vregs[inst.args[0]]);
                const bv: i64 = @bitCast(vregs[inst.args[1]]);
                const res = std.math.add(i64, a, bv) catch return error.Trap;
                vregs[inst.dest] = @bitCast(res);
            },
            .call_checked_sub => {
                const a: i64 = @bitCast(vregs[inst.args[0]]);
                const bv: i64 = @bitCast(vregs[inst.args[1]]);
                const res = std.math.sub(i64, a, bv) catch return error.Trap;
                vregs[inst.dest] = @bitCast(res);
            },
            .call_checked_mul => {
                const a: i64 = @bitCast(vregs[inst.args[0]]);
                const bv: i64 = @bitCast(vregs[inst.args[1]]);
                const res = std.math.mul(i64, a, bv) catch return error.Trap;
                vregs[inst.dest] = @bitCast(res);
            },
            .call_random_u64 => vregs[inst.dest] = util.randomU64(),
            .call_random_bytes => {
                const n_i: i64 = @bitCast(vregs[inst.args[1]]);
                if (n_i < 0) return error.Trap;
                if (n_i > 0) {
                    const dst = try self.resolveSlice(vregs[inst.args[0]], @intCast(n_i), true);
                    std.crypto.random.bytes(dst);
                }
                vregs[inst.dest] = vregs[inst.args[1]];
            },
            .call_assert => {
                if (vregs[inst.args[0]] == 0) {
                    self.writeErr("assertion failed\n");
                    return error.Trap;
                }
            },
            .call_assert_eq => {
                if (vregs[inst.args[0]] != vregs[inst.args[1]]) {
                    self.writeErr("assert_eq failed\n");
                    return error.Trap;
                }
            },
            .call_panic => {
                const msg = try self.readLirString(vregs[inst.args[0]]);
                self.writeErr(msg);
                self.writeErr("\n");
                return error.Trap;
            },
            .call_exit => std.process.exit(@truncate(vregs[inst.args[0]])),
            .call_string_len => {
                const s = try self.readLirString(vregs[inst.args[0]]);
                vregs[inst.dest] = @intCast(s.len);
            },
            .call_string_new => {
                const ptr = vregs[inst.args[0]];
                const n_i: i64 = if (inst.arg_count >= 2) @bitCast(vregs[inst.args[1]]) else blk_slen: {
                    const cs = try self.readCString(ptr);
                    break :blk_slen @intCast(cs.len);
                };
                if (n_i < 0) return error.Trap;
                const s = try self.resolveSlice(ptr, @intCast(n_i), false);
                vregs[inst.dest] = try self.allocLirString(s);
            },
            .call_string_sub, .call_string_slice => {
                const s = try self.readLirString(vregs[inst.args[0]]);
                const st_i: i64 = @bitCast(vregs[inst.args[1]]);
                const ln_i: i64 = @bitCast(vregs[inst.args[2]]);
                if (st_i < 0 or ln_i <= 0 or @as(usize, @intCast(st_i)) >= s.len) {
                    vregs[inst.dest] = try self.allocLirString("");
                } else {
                    const st: usize = @intCast(st_i);
                    const ln: usize = if (inst.op == .call_string_sub)
                        @min(@as(usize, @intCast(ln_i)), s.len - st)
                    else
                        @min(@max(@as(usize, @intCast(ln_i)), st) - st, s.len - st);
                    vregs[inst.dest] = try self.allocLirString(s[st..][0..ln]);
                }
            },
            .call_string_char_at => {
                const s = try self.readLirString(vregs[inst.args[0]]);
                const idx_i: i64 = @bitCast(vregs[inst.args[1]]);
                if (idx_i < 0 or @as(usize, @intCast(idx_i)) >= s.len) return error.Trap;
                vregs[inst.dest] = s[@intCast(idx_i)];
            },
            .call_string_eq => {
                const sa = try self.readLirString(vregs[inst.args[0]]);
                const sb = try self.readLirString(vregs[inst.args[1]]);
                vregs[inst.dest] = @intFromBool(std.mem.eql(u8, sa, sb));
            },
            .call_string_concat => {
                const sa = try self.readLirString(vregs[inst.args[0]]);
                const sb = try self.readLirString(vregs[inst.args[1]]);
                const combined = self.alloc.alloc(u8, sa.len + sb.len) catch return error.OutOfMemory;
                defer self.alloc.free(combined);
                @memcpy(combined[0..sa.len], sa);
                @memcpy(combined[sa.len..], sb);
                vregs[inst.dest] = try self.allocLirString(combined);
            },
            .call_string_split => {
                const s = try self.readLirString(vregs[inst.args[0]]);
                const delim = try self.readLirString(vregs[inst.args[1]]);
                self.mem_lock.lock();
                const arr_idx = self.arrays.items.len;
                self.arrays.append(self.alloc, .{}) catch {
                    self.mem_lock.unlock();
                    return error.OutOfMemory;
                };
                self.mem_lock.unlock();
                if (delim.len == 0) {
                    const sp = try self.allocLirString(s);
                    try self.arrays.items[arr_idx].items.append(self.alloc, sp);
                } else {
                    var it = std.mem.splitSequence(u8, s, delim);
                    while (it.next()) |part| {
                        const sp = try self.allocLirString(part);
                        try self.arrays.items[arr_idx].items.append(self.alloc, sp);
                    }
                }
                vregs[inst.dest] = ARRAY_TAG + arr_idx;
            },
            .call_int_to_string => {
                const iv: i64 = @bitCast(vregs[inst.args[0]]);
                const txt = std.fmt.bufPrint(&b, "{d}", .{iv}) catch "0";
                vregs[inst.dest] = try self.allocLirString(txt);
            },
            .call_string_to_int => {
                const s = try self.readLirString(vregs[inst.args[0]]);
                const iv = std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch 0;
                vregs[inst.dest] = @bitCast(iv);
            },
            .call_array_new => {
                self.mem_lock.lock();
                const id = self.arrays.items.len;
                self.arrays.append(self.alloc, .{}) catch {
                    self.mem_lock.unlock();
                    return error.OutOfMemory;
                };
                self.mem_lock.unlock();
                vregs[inst.dest] = ARRAY_TAG + id;
            },
            .call_array_push => {
                const id = try self.checkArrayId(vregs[inst.args[0]]);
                try self.arrays.items[id].items.append(self.alloc, vregs[inst.args[1]]);
            },
            .call_array_get => {
                const id = try self.checkArrayId(vregs[inst.args[0]]);
                const idx_i: i64 = @bitCast(vregs[inst.args[1]]);
                if (idx_i < 0 or @as(usize, @intCast(idx_i)) >= self.arrays.items[id].items.items.len) return error.Trap;
                vregs[inst.dest] = self.arrays.items[id].items.items[@intCast(idx_i)];
            },
            .call_array_set => {
                const id = try self.checkArrayId(vregs[inst.args[0]]);
                const idx_i: i64 = @bitCast(vregs[inst.args[1]]);
                if (idx_i < 0 or @as(usize, @intCast(idx_i)) >= self.arrays.items[id].items.items.len) return error.Trap;
                self.arrays.items[id].items.items[@intCast(idx_i)] = vregs[inst.args[2]];
                if (inst.dest != 0) vregs[inst.dest] = vregs[inst.args[2]];
            },
            .call_array_len => {
                const id = try self.checkArrayId(vregs[inst.args[0]]);
                vregs[inst.dest] = @intCast(self.arrays.items[id].items.items.len);
            },
            .call_array_free => {
                const id = try self.checkArrayId(vregs[inst.args[0]]);
                self.arrays.items[id].items.clearAndFree(self.alloc);
                self.arrays.items[id].freed = true;
            },
            .call_map_new => {
                const flags = if (inst.arg_count >= 1) vregs[inst.args[0]] else 0;
                self.mem_lock.lock();
                const id = self.maps.items.len;
                self.maps.append(self.alloc, .{ .str_keys = (flags & 1) != 0 }) catch {
                    self.mem_lock.unlock();
                    return error.OutOfMemory;
                };
                self.mem_lock.unlock();
                vregs[inst.dest] = MAP_TAG + id;
            },
            .call_map_set => {
                const id = try self.checkMapId(vregs[inst.args[0]]);
                var m = &self.maps.items[id];
                const k = vregs[inst.args[1]];
                const val = vregs[inst.args[2]];
                if (m.str_keys) {
                    const ks = try self.readLirString(k);
                    for (m.entries.items) |*e| {
                        if (e.occupied and std.mem.eql(u8, e.key_str, ks)) {
                            e.val = val;
                            return;
                        }
                    }
                    const dup = try self.alloc.dupe(u8, ks);
                    try m.entries.append(self.alloc, .{ .key_str = dup, .val = val, .occupied = true });
                } else {
                    for (m.entries.items) |*e| {
                        if (e.occupied and e.key_int == k) {
                            e.val = val;
                            return;
                        }
                    }
                    try m.entries.append(self.alloc, .{ .key_int = k, .val = val, .occupied = true });
                }
                m.count += 1;
            },
            .call_map_get => {
                const id = try self.checkMapId(vregs[inst.args[0]]);
                const m = &self.maps.items[id];
                const k = vregs[inst.args[1]];
                if (m.str_keys) {
                    const ks = try self.readLirString(k);
                    for (m.entries.items) |e| {
                        if (e.occupied and std.mem.eql(u8, e.key_str, ks)) {
                            vregs[inst.dest] = e.val;
                            return;
                        }
                    }
                } else {
                    for (m.entries.items) |e| {
                        if (e.occupied and e.key_int == k) {
                            vregs[inst.dest] = e.val;
                            return;
                        }
                    }
                }
                vregs[inst.dest] = 0;
            },
            .call_map_has => {
                const id = try self.checkMapId(vregs[inst.args[0]]);
                const m = &self.maps.items[id];
                const k = vregs[inst.args[1]];
                var found = false;
                if (m.str_keys) {
                    const ks = try self.readLirString(k);
                    for (m.entries.items) |e| {
                        if (e.occupied and std.mem.eql(u8, e.key_str, ks)) {
                            found = true;
                            break;
                        }
                    }
                } else {
                    for (m.entries.items) |e| {
                        if (e.occupied and e.key_int == k) {
                            found = true;
                            break;
                        }
                    }
                }
                vregs[inst.dest] = @intFromBool(found);
            },
            .call_map_del => {
                const id = try self.checkMapId(vregs[inst.args[0]]);
                var m = &self.maps.items[id];
                const k = vregs[inst.args[1]];
                var deleted = false;
                if (m.str_keys) {
                    const ks = try self.readLirString(k);
                    for (m.entries.items) |*e| {
                        if (e.occupied and std.mem.eql(u8, e.key_str, ks)) {
                            self.alloc.free(e.key_str);
                            e.key_str = &[_]u8{};
                            e.occupied = false;
                            m.count -= 1;
                            deleted = true;
                            break;
                        }
                    }
                } else {
                    for (m.entries.items) |*e| {
                        if (e.occupied and e.key_int == k) {
                            e.occupied = false;
                            m.count -= 1;
                            deleted = true;
                            break;
                        }
                    }
                }
                vregs[inst.dest] = @intFromBool(deleted);
            },
            .call_map_len => {
                const id = try self.checkMapId(vregs[inst.args[0]]);
                vregs[inst.dest] = @intCast(self.maps.items[id].count);
            },
            .call_map_free => {
                const id = try self.checkMapId(vregs[inst.args[0]]);
                for (self.maps.items[id].entries.items) |*e| {
                    if (e.occupied and e.key_str.len > 0) self.alloc.free(e.key_str);
                    e.occupied = false;
                }
                self.maps.items[id].entries.clearAndFree(self.alloc);
                self.maps.items[id].count = 0;
                self.maps.items[id].freed = true;
            },
            .call_chan_new => {
                const cap: usize = @intCast(@max(@as(i64, @bitCast(if (inst.arg_count >= 1) vregs[inst.args[0]] else 1)), 1));
                const ch = try self.alloc.create(VMChan);
                ch.* = .{ .cap = cap };
                self.mem_lock.lock();
                const id = self.chans.items.len;
                self.chans.append(self.alloc, ch) catch {
                    self.mem_lock.unlock();
                    return error.OutOfMemory;
                };
                self.mem_lock.unlock();
                vregs[inst.dest] = CHAN_TAG + id;
            },
            .call_chan_send => {
                const id = try self.checkChanId(vregs[inst.args[0]]);
                const ch = self.chans.items[id];
                ch.mutex.lock();
                defer ch.mutex.unlock();
                while (!ch.closed and ch.buf.items.len >= ch.cap) ch.not_full.wait(&ch.mutex);
                if (!ch.closed) {
                    try ch.buf.append(self.alloc, vregs[inst.args[1]]);
                    ch.not_empty.signal();
                }
            },
            .call_chan_recv => {
                const id = try self.checkChanId(vregs[inst.args[0]]);
                const ch = self.chans.items[id];
                ch.mutex.lock();
                defer ch.mutex.unlock();
                while (!ch.closed and ch.buf.items.len == 0) ch.not_empty.wait(&ch.mutex);
                if (ch.buf.items.len == 0) {
                    vregs[inst.dest] = 0;
                } else {
                    const val = ch.buf.orderedRemove(0);
                    ch.not_full.signal();
                    vregs[inst.dest] = val;
                }
            },
            .call_chan_close => {
                const id = try self.checkChanId(vregs[inst.args[0]]);
                const ch = self.chans.items[id];
                ch.mutex.lock();
                ch.closed = true;
                ch.not_empty.broadcast();
                ch.not_full.broadcast();
                ch.mutex.unlock();
            },
            .call_mutex_create => {
                const mx = try self.alloc.create(std.Thread.Mutex);
                mx.* = .{};
                self.mem_lock.lock();
                const id = self.mutexes.items.len;
                self.mutexes.append(self.alloc, mx) catch {
                    self.mem_lock.unlock();
                    return error.OutOfMemory;
                };
                self.mem_lock.unlock();
                vregs[inst.dest] = MUTEX_TAG + id;
            },
            .call_mutex_lock => {
                const id = try self.checkMutexId(vregs[inst.args[0]]);
                self.mutexes.items[id].lock();
            },
            .call_mutex_unlock => {
                const id = try self.checkMutexId(vregs[inst.args[0]]);
                self.mutexes.items[id].unlock();
            },
            .call_thread_create => {
                const csrc = self.module.sourceFor(inst.fn_source_id, self.source);
                const fname = if (@as(usize, inst.fn_name_start) + @as(usize, inst.fn_name_len) <= csrc.len)
                    csrc[inst.fn_name_start..][0..inst.fn_name_len]
                else
                    return error.InvalidFunction;
                const fi = self.findFn(fname) orelse return error.InvalidFunction;
                const th = try self.alloc.create(VMThread);
                th.* = .{ .thread = undefined };
                th.thread = std.Thread.spawn(.{}, VMState.execThreadEntry, .{ self, fi, vregs[inst.args[1]], th }) catch return error.Trap;
                self.mem_lock.lock();
                const id = self.threads.items.len;
                self.threads.append(self.alloc, th) catch {
                    self.mem_lock.unlock();
                    return error.OutOfMemory;
                };
                self.mem_lock.unlock();
                vregs[inst.dest] = @intCast(id + 1);
            },
            .call_thread_join => {
                const tid = vregs[inst.args[0]];
                if (tid == 0 or tid > self.threads.items.len) return error.Trap;
                const th = self.threads.items[@intCast(tid - 1)];
                if (!th.joined) {
                    th.thread.join();
                    th.joined = true;
                }
                vregs[inst.dest] = @bitCast(th.exit_val);
            },
            .call_argc => vregs[inst.dest] = @intCast(self.prog_args.len),
            .call_argv => {
                const idx_i: i64 = @bitCast(vregs[inst.args[0]]);
                if (idx_i < 0 or @as(usize, @intCast(idx_i)) >= self.prog_args.len) return error.Trap;
                vregs[inst.dest] = try self.allocLirString(self.prog_args[@intCast(idx_i)]);
            },
            .call_getenv => {
                const key = try self.readLirString(vregs[inst.args[0]]);
                if (key.len == 0) {
                    vregs[inst.dest] = try self.allocLirString("");
                } else if (std.process.getEnvVarOwned(self.alloc, key)) |val| {
                    defer self.alloc.free(val);
                    vregs[inst.dest] = try self.allocLirString(val);
                } else |_| {
                    vregs[inst.dest] = try self.allocLirString("");
                }
            },
            .call_sleep_ms => {
                const ms: i64 = @bitCast(vregs[inst.args[0]]);
                if (ms > 0) std.time.sleep(@intCast(@as(u64, @intCast(ms)) * 1_000_000));
                if (inst.dest != 0) vregs[inst.dest] = 0;
            },
            .call_time_ns => {
                const diff: i128 = std.time.nanoTimestamp() - self.start_ns;
                vregs[inst.dest] = @intCast(@max(diff, 0));
            },
            .call_getpid => vregs[inst.dest] = util.sysGetPid(),
            .call_getppid => vregs[inst.dest] = 1,
            .call_getuid => vregs[inst.dest] = if (comptime builtin.os.tag == .linux)
                @intCast(std.os.linux.getuid())
            else if (comptime builtin.link_libc and builtin.os.tag != .windows and builtin.os.tag != .wasi)
                @intCast(std.c.getuid())
            else
                1000,
            .call_unlink => {
                const p = try self.readCString(vregs[inst.args[0]]);
                std.fs.cwd().deleteFile(p) catch {
                    vregs[inst.dest] = @bitCast(@as(i64, -2));
                    return;
                };
                vregs[inst.dest] = 0;
            },
            .call_mkdir => {
                const p = try self.readCString(vregs[inst.args[0]]);
                std.fs.cwd().makePath(p) catch {
                    vregs[inst.dest] = @bitCast(@as(i64, -1));
                    return;
                };
                vregs[inst.dest] = 0;
            },
            .call_open => {
                const p = try self.readCString(vregs[inst.args[0]]);
                const flags = vregs[inst.args[1]];
                const acc = flags & 3;
                const O_CREAT = 0x40;
                const O_TRUNC = 0x200;
                const O_APPEND = 0x400;
                const file_res = if ((flags & O_CREAT) != 0) blk_open: {
                    const f = std.fs.cwd().createFile(p, .{ .read = (acc == 2), .truncate = (flags & O_TRUNC) != 0 }) catch {
                        vregs[inst.dest] = @bitCast(@as(i64, -2));
                        return;
                    };
                    if ((flags & O_APPEND) != 0) f.seekFromEnd(0) catch {};
                    break :blk_open f;
                } else std.fs.cwd().openFile(p, .{ .mode = if (acc == 0) .read_only else if (acc == 1) .write_only else .read_write }) catch {
                    vregs[inst.dest] = @bitCast(@as(i64, -2));
                    return;
                };
                self.mem_lock.lock();
                const fd = self.files.items.len;
                self.files.append(self.alloc, file_res) catch {
                    self.mem_lock.unlock();
                    file_res.close();
                    return error.OutOfMemory;
                };
                self.mem_lock.unlock();
                vregs[inst.dest] = @intCast(fd);
            },
            .call_read => {
                const fd_i: i64 = @bitCast(vregs[inst.args[0]]);
                const n_i: i64 = @bitCast(vregs[inst.args[2]]);
                if (n_i < 0) return error.Trap;
                var empty_buf: [0]u8 = .{};
                const dst: []u8 = if (n_i > 0) try self.resolveSlice(vregs[inst.args[1]], @intCast(n_i), true) else &empty_buf;
                if (fd_i < 0 or @as(usize, @intCast(fd_i)) >= self.files.items.len) {
                    vregs[inst.dest] = @bitCast(@as(i64, -9));
                    return;
                }
                if (n_i == 0) {
                    vregs[inst.dest] = 0;
                    return;
                }
                if (fd_i == 0) {
                    const n = std.io.getStdIn().read(dst) catch {
                        vregs[inst.dest] = @bitCast(@as(i64, -5));
                        return;
                    };
                    vregs[inst.dest] = @intCast(n);
                } else if (self.files.items[@intCast(fd_i)]) |f| {
                    const n = f.read(dst) catch {
                        vregs[inst.dest] = @bitCast(@as(i64, -5));
                        return;
                    };
                    vregs[inst.dest] = @intCast(n);
                } else {
                    vregs[inst.dest] = @bitCast(@as(i64, -9));
                }
            },
            .call_write => {
                const fd_i: i64 = @bitCast(vregs[inst.args[0]]);
                const n_i: i64 = @bitCast(vregs[inst.args[2]]);
                if (n_i < 0) return error.Trap;
                const src_s = if (n_i > 0) try self.resolveSlice(vregs[inst.args[1]], @intCast(n_i), false) else "";
                if (fd_i < 0) {
                    vregs[inst.dest] = @bitCast(@as(i64, -9));
                    return;
                }
                if (fd_i == 1) {
                    self.writeOut(src_s);
                    vregs[inst.dest] = @intCast(src_s.len);
                } else if (fd_i == 2) {
                    self.writeErr(src_s);
                    vregs[inst.dest] = @intCast(src_s.len);
                } else if (@as(usize, @intCast(fd_i)) < self.files.items.len and self.files.items[@intCast(fd_i)] != null) {
                    const f = self.files.items[@intCast(fd_i)].?;
                    const n = f.write(src_s) catch {
                        vregs[inst.dest] = @bitCast(@as(i64, -5));
                        return;
                    };
                    vregs[inst.dest] = @intCast(n);
                } else {
                    vregs[inst.dest] = @bitCast(@as(i64, -9));
                }
            },
            .call_close => {
                const fd_i: i64 = @bitCast(vregs[inst.args[0]]);
                if (fd_i >= 3 and @as(usize, @intCast(fd_i)) < self.files.items.len) {
                    if (self.files.items[@intCast(fd_i)]) |f| {
                        f.close();
                        self.files.items[@intCast(fd_i)] = null;
                        vregs[inst.dest] = 0;
                        return;
                    }
                }
                vregs[inst.dest] = @bitCast(@as(i64, -9));
            },
            .call_stat => {
                const p = try self.readCString(vregs[inst.args[0]]);
                if (inst.arg_count >= 2) {
                    const buf = try self.resolveSlice(vregs[inst.args[1]], 144, true);
                    const st = std.fs.cwd().statFile(p) catch {
                        vregs[inst.dest] = @bitCast(@as(i64, -2));
                        return;
                    };
                    @memset(buf, 0);
                    std.mem.writeInt(i64, buf[48..56], @intCast(st.size), .little);
                    vregs[inst.dest] = 0;
                } else {
                    const st = std.fs.cwd().statFile(p) catch {
                        vregs[inst.dest] = @bitCast(@as(i64, -2));
                        return;
                    };
                    vregs[inst.dest] = @intCast(st.size);
                }
            },
            .call_tcp_socket, .call_tcp_listen, .call_tcp_accept, .call_tcp_connect, .call_sock_send, .call_sock_recv, .call_syscall => {
                vregs[inst.dest] = @bitCast(@as(i64, -38)); // -ENOSYS in VM
            },
            else => return error.Trap,
        }
    }

    fn checkArrayId(self: *VMState, handle: u64) VMError!usize {
        if (handle < ARRAY_TAG or handle >= MAP_TAG) return error.MemoryFault;
        const id: usize = @intCast(handle - ARRAY_TAG);
        if (id >= self.arrays.items.len or self.arrays.items[id].freed) return error.MemoryFault;
        return id;
    }

    fn checkMapId(self: *VMState, handle: u64) VMError!usize {
        if (handle < MAP_TAG or handle >= CHAN_TAG) return error.MemoryFault;
        const id: usize = @intCast(handle - MAP_TAG);
        if (id >= self.maps.items.len or self.maps.items[id].freed) return error.MemoryFault;
        return id;
    }

    fn checkChanId(self: *VMState, handle: u64) VMError!usize {
        if (handle < CHAN_TAG or handle >= MUTEX_TAG) return error.MemoryFault;
        const id: usize = @intCast(handle - CHAN_TAG);
        if (id >= self.chans.items.len) return error.MemoryFault;
        return id;
    }

    fn checkMutexId(self: *VMState, handle: u64) VMError!usize {
        if (handle < MUTEX_TAG or handle >= FN_TAG) return error.MemoryFault;
        const id: usize = @intCast(handle - MUTEX_TAG);
        if (id >= self.mutexes.items.len) return error.MemoryFault;
        return id;
    }
};

fn formatLirFloat(buf: []u8, bits: u64) []const u8 {
    const x: f64 = @bitCast(bits);
    if (std.math.isNan(x)) return "nan";
    var pos: usize = 0;
    if ((bits >> 63) != 0) {
        buf[pos] = '-';
        pos += 1;
    }
    var ax = @abs(x);
    if (std.math.isInf(ax)) {
        @memcpy(buf[pos..][0..3], "inf");
        return buf[0 .. pos + 3];
    }
    if (ax == 0.0) {
        @memcpy(buf[pos..][0..3], "0.0");
        return buf[0 .. pos + 3];
    }
    var use_sci = false;
    var exp10: i32 = 0;
    if (ax >= 1.0e15) {
        use_sci = true;
        while (ax >= 10.0) {
            ax *= 0.1;
            exp10 += 1;
        }
    } else if (ax < 1.0e-4) {
        use_sci = true;
        var it: usize = 0;
        while (it < 350 and ax < 1.0) : (it += 1) {
            ax *= 10.0;
            exp10 -= 1;
        }
    }
    var ip: i64 = @intFromFloat(ax);
    var fp: i64 = @intFromFloat((ax - @as(f64, @floatFromInt(ip))) * 1_000_000.0 + 0.5);
    if (fp >= 1_000_000) {
        fp -= 1_000_000;
        ip += 1;
    }
    const ip_s = std.fmt.bufPrint(buf[pos..], "{d}.", .{ip}) catch return "0.0";
    pos += ip_s.len;
    var fbuf: [6]u8 = undefined;
    var k: usize = 6;
    while (k > 0) {
        k -= 1;
        fbuf[k] = @intCast('0' + @rem(fp, 10));
        fp = @divTrunc(fp, 10);
    }
    var flen: usize = 6;
    while (flen > 1 and fbuf[flen - 1] == '0') flen -= 1;
    @memcpy(buf[pos..][0..flen], fbuf[0..flen]);
    pos += flen;
    if (use_sci) {
        const sign_ch: u8 = if (exp10 >= 0) '+' else '-';
        const ae: u32 = @intCast(if (exp10 >= 0) exp10 else -exp10);
        const es = std.fmt.bufPrint(buf[pos..], "e{c}{d}", .{ sign_ch, ae }) catch return buf[0..pos];
        pos += es.len;
    }
    return buf[0..pos];
}

pub fn execute(
    alloc: std.mem.Allocator,
    module: *const IRModule,
    source: []const u8,
    prog_args: []const []const u8,
    capture_io: bool,
) !VMResult {
    const vm = try VMState.init(alloc, module, source);
    defer vm.deinit();
    vm.prog_args = prog_args;
    vm.capture_io = capture_io;
    var result = VMResult{};
    if (vm.run()) |code| {
        result.exit_code = code;
    } else |err| {
        result.trapped = true;
        result.exit_code = switch (err) {
            error.Trap, error.MemoryFault, error.StackOverflow => 132,
            else => 1,
        };
    }
    if (capture_io) {
        result.stdout = try vm.out_buf.toOwnedSlice(alloc);
        result.stderr = try vm.err_buf.toOwnedSlice(alloc);
    }
    return result;
}
