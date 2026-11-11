// ════════════════════════════════════════════════════════════════════════════
// BACKEND ABSTRACTION & TARGET DISPATCH
// Routes verified IRModule + Target to the requested or auto-selected backend:
//   - native_elf  : Direct zero-dependency x86-64 Linux ELF64 machine code
//   - native_wasm : Direct zero-dependency wasm32-wasi .wasm binary emitter
//   - c           : Portable C11 emitter + host/cross C toolchain (ELF/Mach-O/PE/WASM)
//   - vm          : Portable in-process IR Virtual Machine (any host CPU/OS)
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const ir = @import("ir.zig");
const target_mod = @import("target.zig");
const ir_codegen_mod = @import("ir_codegen.zig");
const c_backend_mod = @import("c_backend.zig");
const wasm_backend_mod = @import("wasm_backend.zig");
const ir_vm_mod = @import("ir_vm.zig");

pub const Target = target_mod.Target;
pub const BackendKind = target_mod.BackendKind;
pub const VMResult = ir_vm_mod.VMResult;

pub const BackendError = error{
    UnsupportedTargetForNativeElf,
    UnsupportedTargetForNativeWasm,
    InvalidBackendForBuild,
    UndefinedFunctionCall,
    CodeTooLarge,
    InvalidELFSize,
    MissingMain,
    InvalidFunction,
    CCompilerNotFound,
    CCompileFailed,
    OutOfMemory,
};

pub fn emitCSource(
    alloc: std.mem.Allocator,
    module: *const ir.IRModule,
    source: []const u8,
    target: Target,
) ![]u8 {
    return try c_backend_mod.emitC(alloc, module, source, target);
}

pub fn emitBinary(
    alloc: std.mem.Allocator,
    module: *const ir.IRModule,
    source: []const u8,
    target: Target,
    requested_backend: BackendKind,
) ![]u8 {
    const kind = target.resolveBackend(requested_backend);
    switch (kind) {
        .native_elf => {
            if (target.arch != .x86_64 or target.os != .linux) {
                return error.UnsupportedTargetForNativeElf;
            }
            const ir_cg = alloc.create(ir_codegen_mod.IRCodegen) catch return error.OutOfMemory;
            defer alloc.destroy(ir_cg);
            ir_cg.init(source, module);
            ir_cg.compile();
            if (ir_cg.invalid_reference) return error.UndefinedFunctionCall;
            if (ir_cg.overflowed) return error.CodeTooLarge;

            const output_size = ir_cg.requiredOutputSize();
            const output = alloc.alloc(u8, output_size) catch return error.OutOfMemory;
            errdefer alloc.free(output);
            const size = ir_cg.generateELF(output);
            if (size != output.len) return error.InvalidELFSize;
            return output;
        },
        .native_wasm => {
            if (target.arch != .wasm32 and target.os != .wasi) {
                return error.UnsupportedTargetForNativeWasm;
            }
            return try wasm_backend_mod.emitWasm(alloc, module, source);
        },
        .c => {
            return try c_backend_mod.compileToBinary(alloc, module, source, target);
        },
        .vm, .auto => return error.InvalidBackendForBuild,
    }
}

pub fn executeVM(
    alloc: std.mem.Allocator,
    module: *const ir.IRModule,
    source: []const u8,
    prog_args: []const []const u8,
    capture_io: bool,
) !VMResult {
    return try ir_vm_mod.execute(alloc, module, source, prog_args, capture_io);
}
