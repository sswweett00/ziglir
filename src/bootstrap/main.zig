// LIR Compiler — Entry Point, CLI, and Pipeline Orchestrator
// Compiles LIR source code to native x86-64 Linux ELF executables
//
// Usage: lir build <file.lir> [-o output]
//        lir run <file.lir>
//        lir init [name]

const std = @import("std");

const util = @import("util.zig");
const lex = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const codegen_mod = @import("codegen.zig");
const optimizer_mod = @import("optimizer.zig");
const ir_mod = @import("ir.zig");
const ir_gen_mod = @import("ir_gen.zig");
const ir_codegen_mod = @import("ir_codegen.zig");

// Re-export public types for tests and external use
pub const TokenKind = lex.TokenKind;
pub const Token = lex.Token;
pub const Lexer = lex.Lexer;
pub const NodeKind = parser_mod.NodeKind;
pub const ASTNode = parser_mod.ASTNode;
pub const AST = parser_mod.AST;
pub const Parser = parser_mod.Parser;
pub const Optimizer = optimizer_mod.Optimizer;
pub const Codegen = codegen_mod.Codegen;
pub const IRModule = ir_mod.IRModule;
pub const IRGen = ir_gen_mod.IRGen;
pub const IRCodegen = ir_codegen_mod.IRCodegen;
pub const Compiler = Compiler_;

const eql = util.eql;
const printStr = util.printStr;
const printErr = util.printErr;
const printUsize = util.printUsize;
const readFile = util.readFile;
const writeFile = util.writeFile;
const sysExit = util.sysExit;
const sysOpen = util.sysOpen;
const sysRead = util.sysRead;
const sysClose = util.sysClose;

// ════════════════════════════════════════════════════════════════════════════
// CLI
// ════════════════════════════════════════════════════════════════════════════

pub fn main() !void {
    const cmdline_fd: i64 = sysOpen("/proc/self/cmdline", 0, 0);
    var cmdline: [2048]u8 = undefined;
    var cmdline_len: usize = 0;
    if (cmdline_fd >= 0) {
        const n = sysRead(@intCast(cmdline_fd), &cmdline, 2048);
        if (n > 0) cmdline_len = @intCast(n);
        sysClose(@intCast(cmdline_fd));
    }

    var args: [16][]const u8 = undefined;
    var arg_count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < cmdline_len and arg_count < 16) : (i += 1) {
        if (cmdline[i] == 0) {
            if (i > start) {
                args[arg_count] = cmdline[start..i];
                arg_count += 1;
            }
            start = i + 1;
        }
    }

    if (arg_count < 2) {
        printUsage();
        return;
    }

    const command = args[1];
    if (eql(command, "help") or eql(command, "--help") or eql(command, "-h")) {
        printUsage();
    } else if (eql(command, "version") or eql(command, "--version") or eql(command, "-V")) {
        printStr("lir 2.1.0\n");
    } else if (eql(command, "build")) {
        if (arg_count < 3) {
            printErr("Error: usage: lir build <file.lir> [-o output]\n");
            sysExit(1);
        }
        cmdBuild(args[2..arg_count]);
    } else if (eql(command, "run")) {
        if (arg_count < 3) {
            printErr("Error: usage: lir run <file.lir>\n");
            sysExit(1);
        }
        cmdRun(args[2..arg_count]);
    } else if (eql(command, "init")) {
        const name = if (arg_count >= 3) args[2] else "myproject";
        cmdInit(name);
    } else {
        printErr("Unknown command: ");
        printErr(command);
        printErr("\nRun 'lir help' for usage.\n");
        sysExit(1);
    }
}

fn printUsage() void {
    printStr(
        \\LIR Compiler v2.1.0
        \\
        \\Usage: lir <command> [options]
        \\
        \\Commands:
        \\  build <file.lir>    Compile LIR source to native executable
        \\  run <file.lir>      Compile and run
        \\  init [name]         Create a new project
        \\  help                Show this help
        \\  version             Show version
        \\
        \\Examples:
        \\  lir build main.lir
        \\  lir run main.lir
        \\  lir init myproject
        \\
    );
}

// ════════════════════════════════════════════════════════════════════════════
// Build Command
// ════════════════════════════════════════════════════════════════════════════

fn cmdBuild(args: []const []const u8) void {
    const input_file = args[0];
    var output_file: []const u8 = "a.out";

    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        if (eql(args[idx], "-o") and idx + 1 < args.len) {
            output_file = args[idx + 1];
            idx += 1;
        }
    }

    var src_buf: [1024 * 1024]u8 = undefined;
    const src_len = readFile(input_file, &src_buf) orelse {
        printErr("Error: cannot read '");
        printErr(input_file);
        printErr("'\n");
        sysExit(1);
    };
    const source = src_buf[0..src_len];

    var compiler = Compiler.init(source, input_file);
    const result = compiler.compile() catch |err| {
        printErr("Compilation error: ");
        printErr(@errorName(err));
        printErr("\n");
        sysExit(1);
    };

    if (!writeFile(output_file, result)) {
        printErr("Error: cannot write '");
        printErr(output_file);
        printErr("'\n");
        sysExit(1);
    }

    // chmod 755
    _ = util.syscall3(0x5A, @intFromPtr(output_file.ptr), 0o755, 0);

    printStr("Compiled ");
    printStr(input_file);
    printStr(" -> ");
    printStr(output_file);
    printStr(" (");
    printUsize(result.len);
    printStr(" bytes)\n");
}

fn cmdRun(args: []const []const u8) void {
    const input_file = args[0];
    const tmp_out = "/tmp/lir_out";

    var src_buf: [1024 * 1024]u8 = undefined;
    const src_len = readFile(input_file, &src_buf) orelse {
        printErr("Error: cannot read '");
        printErr(input_file);
        printErr("'\n");
        sysExit(1);
    };
    const source = src_buf[0..src_len];

    var compiler = Compiler.init(source, input_file);
    const result = compiler.compile() catch |err| {
        printErr("Compilation error: ");
        printErr(@errorName(err));
        printErr("\n");
        sysExit(1);
    };

    if (!writeFile(tmp_out, result)) {
        printErr("Error: cannot write temp file\n");
        sysExit(1);
    }
    _ = util.syscall3(0x5A, @intFromPtr(tmp_out.ptr), 0o755, 0);

    const pid = util.syscall3(56, 17, 0, 0);
    if (@as(i64, @bitCast(pid)) == 0) {
        _ = util.syscall3(59, @intFromPtr(tmp_out.ptr), 0, 0);
        sysExit(1);
    } else {
        var status: u32 = 0;
        _ = util.syscall3(61, pid, @intFromPtr(&status), 0);
    }
}

fn cmdInit(name: []const u8) void {
    printStr("Initializing project '");
    printStr(name);
    printStr("'...\n");

    const src_dir = "src";
    _ = util.syscall3(83, @intFromPtr(src_dir.ptr), 0o755, 0);

    var manifest_buf: [512]u8 = undefined;
    var pos: usize = 0;
    const parts = [_][]const u8{
        "{\n  \"name\": \"",
        name,
        "\",\n  \"version\": \"0.1.0\",\n  \"entry\": \"main.lir\",\n  \"source_dir\": \"src\"\n}\n",
    };
    for (parts) |part| {
        for (part) |ch| {
            if (pos < manifest_buf.len) {
                manifest_buf[pos] = ch;
                pos += 1;
            }
        }
    }
    if (!writeFile("project.manifest", manifest_buf[0..pos])) {
        printErr("Error: cannot create project.manifest\n");
        sysExit(1);
    }

    const main_src =
        \\// Main entry point
        \\import core
        \\
        \\fn main() -> i64 {
        \\    println("Hello from LIR!")
        \\    0
        \\}
        \\
    ;
    if (!writeFile("src/main.lir", main_src)) {
        printErr("Error: cannot create src/main.lir\n");
        sysExit(1);
    }

    printStr("Created project.manifest\nCreated src/main.lir\n\nNext: lir build src/main.lir\n");
}

// ════════════════════════════════════════════════════════════════════════════
// COMPILER (orchestrates the pipeline)
// ════════════════════════════════════════════════════════════════════════════

const Compiler_ = struct {
    source: []const u8,
    filename: []const u8,

    pub fn init(source: []const u8, filename: []const u8) Compiler_ {
        return .{ .source = source, .filename = filename };
    }

    pub fn compile(self: *Compiler_) ![]const u8 {
        // Phase 1: Lex
        var lexer = lex.Lexer.init(self.source);
        lexer.tokenize();

        // Phase 2: Parse
        var ast = AST.init();
        var parser_inst = parser_mod.Parser{ .lex = &lexer, .pos = 0, .ast = &ast, .src = self.source };
        parser_inst.parse();

        // Phase 2.5: Optimize the AST
        var optimizer = Optimizer.init(&ast, self.source);
        optimizer.optimize();

        // Phase 2.75: Lower AST to IR
        var ir_gen = ir_gen_mod.IRGen.init(self.source, &ast);
        ir_gen.generate();

        // Phase 3: Codegen from IR
        var ir_cg = ir_codegen_mod.IRCodegen.init(self.source, &ir_gen.mod);
        ir_cg.compile();

        // Phase 3.5: Patch references
        ir_cg.patchStrings();

        // Phase 3.6: Peephole optimizations (TODO: fix false-positive byte scanning)
        // ir_cg.peepholeOptimize();

        // Phase 4: Generate ELF
        var output: [262144]u8 = undefined;
        const size = ir_cg.generateELF(&output);

        const result = std.heap.page_allocator.alloc(u8, size) catch return error.OutOfMemory;
        @memcpy(result, output[0..size]);
        return result;
    }
};
