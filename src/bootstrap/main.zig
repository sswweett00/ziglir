// LIR Compiler — Entry Point, Portable CLI, and Public API Exports
//
// Usage: lir build <file.lir> [-o output] [-O0|-O1|-O2] [--target <triple>] [--backend <kind>] [--emit-ir] [--emit-c]
//        lir run <file.lir> [-O0|-O1|-O2] [--target <triple>] [--backend <kind>] [-- args...]
//        lir check <file.lir> [--target <triple>]
//        lir ir <file.lir> [-O0|-O1|-O2] [--target <triple>]
//        lir test [file.lir] [-O0|-O1|-O2] [--target <triple>] [--backend <kind>]
//        lir targets
//        lir init [name]

const std = @import("std");
const builtin = @import("builtin");

const util = @import("util.zig");
const diag_mod = @import("diag.zig");
const lex = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const sema_mod = @import("sema.zig");
const optimizer_mod = @import("optimizer.zig");
const ir_mod = @import("ir.zig");
const ir_gen_mod = @import("ir_gen.zig");
const ir_opt_mod = @import("ir_opt.zig");
const ir_codegen_mod = @import("ir_codegen.zig");
const target_mod = @import("target.zig");
const backend_mod = @import("backend.zig");
const driver_mod = @import("driver.zig");
const c_backend_mod = @import("c_backend.zig");
const wasm_backend_mod = @import("wasm_backend.zig");
const ir_vm_mod = @import("ir_vm.zig");

// Re-export public types for tests and library callers
pub const TokenKind = lex.TokenKind;
pub const Token = lex.Token;
pub const Lexer = lex.Lexer;
pub const NodeKind = parser_mod.NodeKind;
pub const ASTNode = parser_mod.ASTNode;
pub const AST = parser_mod.AST;
pub const Parser = parser_mod.Parser;
pub const Sema = sema_mod.Sema;
pub const SemaInfo = sema_mod.SemaInfo;
pub const Optimizer = optimizer_mod.Optimizer;
pub const IRModule = ir_mod.IRModule;
pub const IRGen = ir_gen_mod.IRGen;
pub const OptLevel = ir_opt_mod.OptLevel;
pub const IRCodegen = ir_codegen_mod.IRCodegen;
pub const DiagList = diag_mod.DiagList;
pub const Target = target_mod.Target;
pub const Arch = target_mod.Arch;
pub const OS = target_mod.OS;
pub const BinaryFormat = target_mod.BinaryFormat;
pub const BackendKind = target_mod.BackendKind;
pub const Backend = backend_mod;
pub const Driver = driver_mod;
pub const Compiler = driver_mod.Compiler;
pub const CBackend = c_backend_mod;
pub const WasmBackend = wasm_backend_mod;
pub const IRVM = ir_vm_mod;

const eql = util.eql;
const printStr = util.printStr;
const printErr = util.printErr;
const printUsize = util.printUsize;
const project = @import("project.zig");
const manifest = @import("manifest.zig");
const sysExit = util.sysExit;

// ════════════════════════════════════════════════════════════════════════════
// CLI
// ════════════════════════════════════════════════════════════════════════════

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const args = std.process.argsAlloc(alloc) catch {
        printErr("Error: unable to read process arguments\n");
        sysExit(1);
    };
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];
    if (eql(command, "help") or eql(command, "--help") or eql(command, "-h")) {
        printUsage();
    } else if (eql(command, "version") or eql(command, "--version") or eql(command, "-V")) {
        printStr("lir 2.2.0\n");
    } else if (eql(command, "targets")) {
        printTargets();
    } else if (eql(command, "build")) {
        cmdBuild(args[2..]);
    } else if (eql(command, "run")) {
        cmdRun(args[2..]);
    } else if (eql(command, "check")) {
        cmdCheck(args[2..]);
    } else if (eql(command, "ir")) {
        cmdIr(args[2..]);
    } else if (eql(command, "test")) {
        cmdTest(args[2..]);
    } else if (eql(command, "init")) {
        if (args.len > 3) unexpectedArgument(args[3]);
        const name = if (args.len >= 3) args[2] else "myproject";
        cmdInit(name);
    } else if (eql(command, "install")) {
        cmdInstall();
    } else {
        printErr("Unknown command: ");
        printErr(command);
        printErr("\nRun 'lir help' for usage.\n");
        sysExit(1);
    }
}

fn printUsage() void {
    printStr(
        \\LIR Compiler v2.2.0
        \\
        \\Usage: lir <command> [options]
        \\
        \\Commands:
        \\  build [file|dir]    Compile LIR source to native or cross-platform binary
        \\    -o <path>           Output binary (or C file when --emit-c is passed)
        \\    -O0 | -O1 | -O2     Optimization level (default: -O2)
        \\    --target <triple>   Target platform (run 'lir targets' for list)
        \\    --backend <kind>    Backend: auto | native | wasm | c | vm
        \\    --emit-ir           Print lowered & optimized IR to stdout
        \\    --emit-c            Emit standalone portable C11 source instead of linking
        \\  run [file|dir]      Compile and execute in one step (supports --backend=vm/wasm/c/native)
        \\  check [file|dir]    Type-check and verify IR without emitting binary
        \\  ir [file|dir]       Dump lowered & optimized IR
        \\  test [file|dir]     Run #[test] suite
        \\  targets             List supported cross-compilation targets and host defaults
        \\  init [name]         Create a new project
        \\  install             Install lir binary to system PATH
        \\  help                Show this help
        \\  version             Show version
        \\
        \\With no file/dir, commands load ./project.manifest.
        \\
        \\Examples:
        \\  lir build main.lir -O2 -o main
        \\  lir build main.lir --target=wasm32-wasi -o main.wasm
        \\  lir build main.lir --target=aarch64-macos -o main_mac
        \\  lir build main.lir --emit-c -o main.c
        \\  lir run main.lir --backend=vm -- arg1 arg2
        \\  lir check main.lir
        \\
    );
}

fn printTargets() void {
    const host = Target.host();
    var buf: [64]u8 = undefined;
    printStr("Host target: ");
    printStr(host.triple(&buf));
    printStr(" (default backend: ");
    printStr(host.resolveBackend(.auto).name());
    printStr(")\n\nSupported targets:\n");
    printStr("  x86_64-linux      ELF64 (native-elf or c11)\n");
    printStr("  aarch64-linux     ELF64 (c11)\n");
    printStr("  riscv64-linux     ELF64 (c11)\n");
    printStr("  aarch64-macos     Mach-O (c11)\n");
    printStr("  x86_64-macos      Mach-O (c11)\n");
    printStr("  x86_64-windows    PE/COFF .exe (c11)\n");
    printStr("  aarch64-windows   PE/COFF .exe (c11)\n");
    printStr("  wasm32-wasi       WebAssembly .wasm (native-wasm or c11)\n");
    printStr("  x86_64-freebsd    ELF64 (c11)\n");
    printStr("  aarch64-freebsd   ELF64 (c11)\n");
    printStr("\nBackends:\n");
    printStr("  auto              native-elf (x86_64-linux), native-wasm (wasm32-wasi), c11 (others)\n");
    printStr("  native | elf      Zero-dependency x86-64 ELF64 machine code backend\n");
    printStr("  wasm              Zero-dependency wasm32-wasi .wasm binary emitter\n");
    printStr("  c | c11           Portable C11 emitter + zig cc / CC cross-compiler\n");
    printStr("  vm                Portable in-process IR VM (runs any program on any host)\n");
}

fn unexpectedArgument(arg: []const u8) noreturn {
    printErr("Error: unexpected argument '");
    printErr(arg);
    printErr("'\n");
    sysExit(1);
}

fn parseOptFlag(arg: []const u8) ?OptLevel {
    if (eql(arg, "-O0")) return .O0;
    if (eql(arg, "-O1")) return .O1;
    if (eql(arg, "-O2")) return .O2;
    return null;
}

fn parseFlagValue(args: []const []const u8, idx: *usize, prefix_eq: []const u8, exact: []const u8) ?[]const u8 {
    const arg = args[idx.*];
    if (std.mem.startsWith(u8, arg, prefix_eq)) {
        return arg[prefix_eq.len..];
    }
    if (eql(arg, exact)) {
        if (idx.* + 1 >= args.len) {
            printErr("Error: missing value after '");
            printErr(exact);
            printErr("'\n");
            sysExit(1);
        }
        idx.* += 1;
        return args[idx.*];
    }
    return null;
}

fn parseTargetOrDie(spec: []const u8) Target {
    return Target.parse(spec) orelse {
        printErr("Error: unsupported target '");
        printErr(spec);
        printErr("' (run 'lir targets' for supported targets)\n");
        sysExit(1);
    };
}

fn parseBackendOrDie(spec: []const u8) BackendKind {
    return BackendKind.parse(spec) orelse {
        printErr("Error: unknown backend '");
        printErr(spec);
        printErr("' (expected auto, native, wasm, c, or vm)\n");
        sysExit(1);
    };
}

// ════════════════════════════════════════════════════════════════════════════
// CLI Commands
// ════════════════════════════════════════════════════════════════════════════

fn selectInput(input: ?[]const u8, test_mode: bool) manifest.Selection {
    return manifest.select(std.heap.page_allocator, input, test_mode) catch |err| {
        printErr("Error: cannot resolve project input: ");
        printErr(@errorName(err));
        printErr(". Use a source file, or a project directory containing project.manifest.\n");
        sysExit(1);
    };
}

fn cmdBuild(args: []const []const u8) void {
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var opt_level: OptLevel = .O2;
    var target = Target.host();
    var backend_kind: BackendKind = .auto;
    var emit_ir = false;
    var emit_c = false;

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (eql(arg, "-o")) {
            if (idx + 1 >= args.len) {
                printErr("Error: missing path after '-o'\n");
                sysExit(1);
            }
            idx += 1;
            output_file = args[idx];
        } else if (parseFlagValue(args, &idx, "--target=", "--target")) |spec| {
            target = parseTargetOrDie(spec);
        } else if (parseFlagValue(args, &idx, "--backend=", "--backend")) |spec| {
            backend_kind = parseBackendOrDie(spec);
        } else if (parseOptFlag(arg)) |ol| {
            opt_level = ol;
        } else if (eql(arg, "--emit-ir")) {
            emit_ir = true;
        } else if (eql(arg, "--emit-c")) {
            emit_c = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            printErr("Error: unknown option '");
            printErr(arg);
            printErr("'\n");
            sysExit(1);
        } else if (input_file == null) {
            input_file = arg;
        } else {
            printErr("Error: unexpected extra positional argument '");
            printErr(arg);
            printErr("'\n");
            sysExit(1);
        }
    }

    const selection = selectInput(input_file, false);
    defer selection.deinit(std.heap.page_allocator);
    const in_path = selection.input;

    const alloc = std.heap.page_allocator;
    const source_buf = util.readFileAlloc(alloc, in_path) catch {
        printErr("Error: cannot read source file '");
        printErr(in_path);
        printErr("'\n");
        sysExit(1);
    };
    defer alloc.free(source_buf);

    var compiler = Compiler.initForTarget(source_buf, in_path, opt_level, target, backend_kind);
    compiler.emit_ir = emit_ir;
    compiler.emit_c = emit_c;
    const result = compiler.compile() catch |err| {
        printErr("Compilation failed: ");
        printErr(@errorName(err));
        printErr("\n");
        sysExit(1);
    };
    defer alloc.free(result);

    const default_output = std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
        selection.output_base orelse "a",
        if (emit_c) ".c" else ".out",
        if (emit_c) "" else target.exeSuffix(),
    }) catch sysExit(1);
    defer alloc.free(default_output);
    const resolved_out = output_file orelse default_output;

    const mode: u64 = if (emit_c or target.os == .wasi) 0o644 else 0o755;
    if (!util.writeFileAtomic(resolved_out, result, mode)) {
        printErr("Error: cannot write '");
        printErr(resolved_out);
        printErr("'\n");
        sysExit(1);
    }

    printStr(if (emit_c) "Emitted C11 " else "Compiled ");
    printStr(in_path);
    printStr(" -> ");
    printStr(resolved_out);
    printStr(" (");
    printUsize(result.len);
    printStr(" bytes)\n");
}

fn cmdCheck(args: []const []const u8) void {
    var in_path: ?[]const u8 = null;
    var target = Target.host();
    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (parseFlagValue(args, &idx, "--target=", "--target")) |spec| {
            target = parseTargetOrDie(spec);
        } else if (arg.len > 0 and arg[0] == '-') {
            printErr("Error: unknown option '");
            printErr(arg);
            printErr("'\n");
            sysExit(1);
        } else if (in_path == null) {
            in_path = arg;
        } else {
            unexpectedArgument(arg);
        }
    }
    const selection = selectInput(in_path, false);
    defer selection.deinit(std.heap.page_allocator);
    const file = selection.input;
    const alloc = std.heap.page_allocator;
    const source_buf = util.readFileAlloc(alloc, file) catch {
        printErr("Error: cannot read source file '");
        printErr(file);
        printErr("'\n");
        sysExit(1);
    };
    defer alloc.free(source_buf);

    var compiler = Compiler.initForTarget(source_buf, file, .O2, target, .auto);
    compiler.check() catch |err| {
        printErr("Check failed: ");
        printErr(@errorName(err));
        printErr("\n");
        sysExit(1);
    };
    printStr("OK: ");
    printStr(file);
    printStr("\n");
}

fn cmdIr(args: []const []const u8) void {
    var input_file: ?[]const u8 = null;
    var opt_level: OptLevel = .O2;
    var target = Target.host();

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (parseOptFlag(arg)) |ol| {
            opt_level = ol;
        } else if (parseFlagValue(args, &idx, "--target=", "--target")) |spec| {
            target = parseTargetOrDie(spec);
        } else if (arg.len > 0 and arg[0] == '-') {
            unexpectedArgument(arg);
        } else if (input_file == null) {
            input_file = arg;
        } else {
            unexpectedArgument(arg);
        }
    }
    const selection = selectInput(input_file, false);
    defer selection.deinit(std.heap.page_allocator);
    const in_path = selection.input;
    const alloc = std.heap.page_allocator;
    const source_buf = util.readFileAlloc(alloc, in_path) catch {
        printErr("Error: cannot read source file\n");
        sysExit(1);
    };
    defer alloc.free(source_buf);

    var compiler = Compiler.initForTarget(source_buf, in_path, opt_level, target, .auto);
    compiler.emit_ir = true;
    compiler.check() catch |err| {
        printErr("IR generation failed: ");
        printErr(@errorName(err));
        printErr("\n");
        sysExit(1);
    };
}

fn findExeInPath(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    const path_env = std.process.getEnvVarOwned(alloc, "PATH") catch return null;
    defer alloc.free(path_env);
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, path_env, sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fs.path.join(alloc, &.{ dir, name }) catch continue;
        if (util.fileExists(full)) return full;
        alloc.free(full);
    }
    return null;
}

fn executeCompiledArtifact(
    alloc: std.mem.Allocator,
    compiler: *Compiler,
    prog_args: []const []const u8,
) void {
    const resolved_backend = compiler.target.resolveBackend(compiler.backend_kind);
    if (resolved_backend == .vm) {
        var vm_argv = std.ArrayListUnmanaged([]const u8){};
        defer vm_argv.deinit(alloc);
        vm_argv.append(alloc, compiler.filename) catch sysExit(1);
        for (prog_args) |pa| vm_argv.append(alloc, pa) catch sysExit(1);
        const res = compiler.runInVM(vm_argv.items, false) catch |err| {
            printErr("VM execution failed: ");
            printErr(@errorName(err));
            printErr("\n");
            sysExit(1);
        };
        if (res.exit_code != 0) sysExit(@bitCast(res.exit_code));
        return;
    }

    const result = compiler.compile() catch |err| {
        printErr("Compilation failed: ");
        printErr(@errorName(err));
        printErr("\n");
        sysExit(1);
    };
    defer alloc.free(result);

    var tdir_buf: [256]u8 = undefined;
    const tdir = util.getTempDir(&tdir_buf);
    const pid = util.sysGetPid();
    const rand_id = util.randomU64();
    const tmp_out = std.fmt.allocPrint(alloc, "{s}/lir_run_{d}_{x}{s}", .{ tdir, pid, rand_id, compiler.target.exeSuffix() }) catch {
        printErr("Error: cannot format temp executable path\n");
        sysExit(1);
    };
    defer {
        std.fs.cwd().deleteFile(tmp_out) catch {};
        alloc.free(tmp_out);
    }

    if (!util.writeFileAtomic(tmp_out, result, 0o700)) {
        printErr("Error: cannot write temp executable\n");
        sysExit(1);
    }

    if (compiler.target.os == .wasi or resolved_backend == .native_wasm) {
        var child_argv = std.ArrayListUnmanaged([]const u8){};
        defer child_argv.deinit(alloc);

        if (findExeInPath(alloc, if (builtin.os.tag == .windows) "wasmtime.exe" else "wasmtime")) |wt| {
            defer alloc.free(wt);
            child_argv.append(alloc, wt) catch sysExit(1);
            child_argv.append(alloc, tmp_out) catch sysExit(1);
            for (prog_args) |pa| child_argv.append(alloc, pa) catch sysExit(1);
            var child = std.process.Child.init(child_argv.items, alloc);
            const term = child.spawnAndWait() catch {
                printErr("Error: failed to execute wasmtime\n");
                sysExit(1);
            };
            std.fs.cwd().deleteFile(tmp_out) catch {};
            switch (term) {
                .Exited => |code| if (code != 0) sysExit(@intCast(code)),
                .Signal => |sig| sysExit(@intCast(128 +% sig)),
                else => sysExit(1),
            }
            return;
        }
        if (findExeInPath(alloc, if (builtin.os.tag == .windows) "node.exe" else "node")) |node_exe| {
            defer alloc.free(node_exe);
            const script = "import{readFileSync}from'fs';import{WASI}from'wasi';const a=process.argv.slice(1);const w=new WASI({version:'preview1',args:a,env:process.env});const m=await WebAssembly.compile(readFileSync(a[0]));const i=await WebAssembly.instantiate(m,w.getImportObject());process.exitCode=w.start(i);";
            child_argv.append(alloc, node_exe) catch sysExit(1);
            child_argv.append(alloc, "--input-type=module") catch sysExit(1);
            child_argv.append(alloc, "-e") catch sysExit(1);
            child_argv.append(alloc, script) catch sysExit(1);
            child_argv.append(alloc, tmp_out) catch sysExit(1);
            for (prog_args) |pa| child_argv.append(alloc, pa) catch sysExit(1);
            var child = std.process.Child.init(child_argv.items, alloc);
            const term = child.spawnAndWait() catch {
                printErr("Error: failed to execute node WASI runner\n");
                sysExit(1);
            };
            std.fs.cwd().deleteFile(tmp_out) catch {};
            switch (term) {
                .Exited => |code| if (code != 0) sysExit(@intCast(code)),
                .Signal => |sig| sysExit(@intCast(128 +% sig)),
                else => sysExit(1),
            }
            return;
        }
        printErr("Error: no WASI runtime found (install wasmtime or node); use --backend=vm or 'lir build --target=wasm'\n");
        sysExit(1);
    }

    if (!compiler.target.isHost()) {
        printErr("Error: cannot execute non-host binary directly; use --backend=vm to run on host or 'lir build --target=...' to emit binary\n");
        sysExit(1);
    }

    var child_argv = std.ArrayListUnmanaged([]const u8){};
    defer child_argv.deinit(alloc);
    child_argv.append(alloc, tmp_out) catch sysExit(1);
    for (prog_args) |pa| child_argv.append(alloc, pa) catch sysExit(1);

    var child = std.process.Child.init(child_argv.items, alloc);
    const term = child.spawnAndWait() catch {
        printErr("Error: failed to execute compiled program\n");
        sysExit(1);
    };
    std.fs.cwd().deleteFile(tmp_out) catch {};
    switch (term) {
        .Exited => |code| if (code != 0) sysExit(@intCast(code)),
        .Signal => |sig| sysExit(@intCast(128 +% sig)),
        else => sysExit(1),
    }
}

fn cmdRun(args: []const []const u8) void {
    var input_file: ?[]const u8 = null;
    var opt_level: OptLevel = .O2;
    var target = Target.host();
    var backend_kind: BackendKind = .auto;
    var prog_args_start: usize = args.len;

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (eql(arg, "--")) {
            prog_args_start = idx + 1;
            break;
        } else if (parseFlagValue(args, &idx, "--target=", "--target")) |spec| {
            target = parseTargetOrDie(spec);
        } else if (parseFlagValue(args, &idx, "--backend=", "--backend")) |spec| {
            backend_kind = parseBackendOrDie(spec);
        } else if (parseOptFlag(arg)) |ol| {
            opt_level = ol;
        } else if (arg.len > 0 and arg[0] == '-' and input_file == null) {
            printErr("Error: unknown option '");
            printErr(arg);
            printErr("'\n");
            sysExit(1);
        } else if (input_file == null) {
            input_file = arg;
        } else {
            prog_args_start = idx;
            break;
        }
    }

    const selection = selectInput(input_file, false);
    defer selection.deinit(std.heap.page_allocator);
    const in_path = selection.input;

    const alloc = std.heap.page_allocator;
    const source_buf = util.readFileAlloc(alloc, in_path) catch {
        printErr("Error: cannot read source file\n");
        sysExit(1);
    };
    defer alloc.free(source_buf);

    var compiler = Compiler.initForTarget(source_buf, in_path, opt_level, target, backend_kind);
    const prog_args = if (prog_args_start < args.len) args[prog_args_start..] else &[_][]const u8{};
    executeCompiledArtifact(alloc, &compiler, prog_args);
}

fn cmdInit(name: []const u8) void {
    project.create(std.fs.cwd(), name) catch |err| {
        printErr("Error: cannot initialize project '");
        printErr(name);
        printErr("': ");
        printErr(@errorName(err));
        printErr(" (use a new directory name; existing work is never overwritten)\n");
        sysExit(1);
    };
    printStr("Created ");
    printStr(name);
    printStr("/project.manifest, src/main.lir, src/lib.lir, src/tests.lir and .gitignore\n\nNext: cd ");
    printStr(name);
    printStr(" && lir run\n");
}

fn cmdTest(args: []const []const u8) void {
    var arg_path: ?[]const u8 = null;
    var opt_level: OptLevel = .O2;
    var target = Target.host();
    var backend_kind: BackendKind = .auto;

    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const s = args[idx];
        if (eql(s, "--help") or eql(s, "-h")) {
            printStr("Usage: lir test [file|dir] [-O0|-O1|-O2] [--target <triple>] [--backend <kind>]\n");
            return;
        } else if (parseFlagValue(args, &idx, "--target=", "--target")) |spec| {
            target = parseTargetOrDie(spec);
        } else if (parseFlagValue(args, &idx, "--backend=", "--backend")) |spec| {
            backend_kind = parseBackendOrDie(spec);
        } else if (parseOptFlag(s)) |ol| {
            opt_level = ol;
        } else if (s.len > 0 and s[0] == '-') {
            printErr("Error: unknown option '");
            printErr(s);
            printErr("'\n");
            sysExit(1);
        } else if (arg_path == null) {
            arg_path = s;
        } else {
            unexpectedArgument(s);
        }
    }
    const selection = selectInput(arg_path, true);
    defer selection.deinit(std.heap.page_allocator);
    const test_path = selection.input;
    printStr("Running tests in ");
    printStr(test_path);
    printStr("...\n");

    const alloc = std.heap.page_allocator;
    const source_buf = util.readFileAlloc(alloc, test_path) catch {
        printErr("Error: cannot read test file '");
        printErr(test_path);
        printErr("'\n");
        sysExit(1);
    };
    defer alloc.free(source_buf);

    var compiler = Compiler.initForTarget(source_buf, test_path, opt_level, target, backend_kind);
    compiler.test_mode = true;
    executeCompiledArtifact(alloc, &compiler, &[_][]const u8{});
}

fn cmdInstall() void {
    const alloc = std.heap.page_allocator;
    const exe_path = std.fs.selfExePathAlloc(alloc) catch {
        printErr("Error: cannot locate current executable\n");
        sysExit(1);
    };
    defer alloc.free(exe_path);

    const bin_buf = util.readFileAlloc(alloc, exe_path) catch {
        printErr("Error: cannot read executable contents\n");
        sysExit(1);
    };
    defer alloc.free(bin_buf);

    if (comptime builtin.os.tag != .windows) {
        const target_path = "/usr/local/bin/lir";
        if (util.writeFileAtomic(target_path, bin_buf, 0o755)) {
            printStr("Installed LIR to /usr/local/bin/lir\n");
            return;
        }
    }

    var home_buf: [512]u8 = undefined;
    const home_opt = util.getEnvVar("HOME", &home_buf) orelse util.getEnvVar("USERPROFILE", &home_buf);
    if (home_opt) |home| {
        const bin_dir = std.fmt.allocPrint(alloc, "{s}/.lir/bin", .{home}) catch sysExit(1);
        defer alloc.free(bin_dir);
        std.fs.cwd().makePath(bin_dir) catch {};
        const exe_name = if (builtin.os.tag == .windows) "lir.exe" else "lir";
        const exe_target = std.fmt.allocPrint(alloc, "{s}/{s}", .{ bin_dir, exe_name }) catch sysExit(1);
        defer alloc.free(exe_target);
        if (util.writeFileAtomic(exe_target, bin_buf, 0o755)) {
            printStr("Installed LIR to ");
            printStr(exe_target);
            printStr("\n");
            return;
        }
    }
    printErr("Error: failed to install LIR binary\n");
    sysExit(1);
}
