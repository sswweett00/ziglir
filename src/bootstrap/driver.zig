// ════════════════════════════════════════════════════════════════════════════
// COMPILER DRIVER — Frontend, Module Loader, IR Lowering & Backend Dispatch
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const diag_mod = @import("diag.zig");
const lex = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const sema_mod = @import("sema.zig");
const expand_mod = @import("expand.zig");
const stdlib_mod = @import("stdlib.zig");
const optimizer_mod = @import("optimizer.zig");
const ir_mod = @import("ir.zig");
const ir_gen_mod = @import("ir_gen.zig");
const ir_opt_mod = @import("ir_opt.zig");
const ir_verify_mod = @import("ir_verify.zig");
const target_mod = @import("target.zig");
const backend_mod = @import("backend.zig");

const AST = parser_mod.AST;
const Sema = sema_mod.Sema;
const SemaInfo = sema_mod.SemaInfo;
const Optimizer = optimizer_mod.Optimizer;
const OptLevel = ir_opt_mod.OptLevel;
const DiagList = diag_mod.DiagList;
const Target = target_mod.Target;
const BackendKind = target_mod.BackendKind;
const eql = util.eql;

pub const LoadedSources = struct {
    paths: [parser_mod.MAX_SOURCES][]u8 = undefined,
    bufs: [parser_mod.MAX_SOURCES][]u8 = undefined,
    is_static: [parser_mod.MAX_SOURCES]bool = .{false} ** parser_mod.MAX_SOURCES,
    extra_count: u32 = 0,

    pub fn deinit(self: *LoadedSources, alloc: std.mem.Allocator) void {
        var i: u32 = 0;
        while (i < self.extra_count) : (i += 1) {
            alloc.free(self.paths[i]);
            if (!self.is_static[i]) alloc.free(self.bufs[i]);
        }
        self.extra_count = 0;
    }

    pub fn containsPath(self: *const LoadedSources, entry_path: []const u8, candidate: []const u8) bool {
        if (eql(entry_path, candidate)) return true;
        var i: u32 = 0;
        while (i < self.extra_count) : (i += 1) {
            if (eql(self.paths[i], candidate)) return true;
        }
        return false;
    }
};

fn resolveImportPath(alloc: std.mem.Allocator, importer_path: []const u8, rel_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel_path)) {
        return try std.fs.path.resolve(alloc, &.{rel_path});
    }
    const dir = std.fs.path.dirname(importer_path) orelse ".";
    return try std.fs.path.resolve(alloc, &.{ dir, rel_path });
}

pub const Compiler = struct {
    source: []const u8,
    filename: []const u8,
    opt_level: OptLevel = .O2,
    target: Target = Target.host(),
    backend_kind: BackendKind = .auto,
    emit_ir: bool = false,
    emit_c: bool = false,
    quiet: bool = false,
    test_mode: bool = false,
    last_diag_count: u32 = 0,
    last_diag_source_id: u32 = 0,
    last_diag_line: u32 = 0,

    pub fn init(source: []const u8, filename: []const u8) Compiler {
        return .{ .source = source, .filename = filename };
    }

    pub fn initWithOpts(source: []const u8, filename: []const u8, opt_level: OptLevel) Compiler {
        return .{ .source = source, .filename = filename, .opt_level = opt_level };
    }

    pub fn initForTarget(
        source: []const u8,
        filename: []const u8,
        opt_level: OptLevel,
        target: Target,
        backend_kind: BackendKind,
    ) Compiler {
        return .{
            .source = source,
            .filename = filename,
            .opt_level = opt_level,
            .target = target,
            .backend_kind = backend_kind,
        };
    }

    fn lexAndParseInto(
        alloc: std.mem.Allocator,
        src: []const u8,
        source_id: u32,
        ast: *AST,
        diag: *DiagList,
    ) !void {
        const lexer = alloc.create(lex.Lexer) catch return error.OutOfMemory;
        defer alloc.destroy(lexer);
        lexer.* = lex.Lexer.init(src);
        lexer.tokenize();
        if (lexer.overflowed) {
            diag.addAt(.err, source_id, 1, 1, 1, "token capacity exceeded (maximum 16384 tokens)");
            return error.TooManyTokens;
        }
        if (lexer.invalid) {
            diag.addAt(.err, source_id, lexer.invalid_line, lexer.invalid_col, 1, "invalid character, malformed escape, or unterminated literal");
            return error.InvalidToken;
        }

        var parser_inst = parser_mod.Parser{
            .lex = lexer,
            .pos = 0,
            .ast = ast,
            .src = src,
            .source_id = source_id,
            .diag = diag,
        };
        parser_inst.parse();
        if (parser_inst.invalid_syntax) return error.InvalidSyntax;
        if (parser_inst.unsupported_float_literal) return error.UnsupportedFloatLiteral;
        if (ast.overflowed) {
            diag.addAt(.err, source_id, 1, 1, 1, "AST or metadata capacity exceeded");
            return error.TooManyASTNodes;
        }
        if (parser_inst.invalid_integer_literal) {
            diag.addAt(.err, source_id, parser_inst.invalid_integer_line, parser_inst.invalid_integer_col, parser_inst.invalid_integer_len, "malformed or out-of-range i64 integer literal");
            return error.InvalidIntegerLiteral;
        }
    }

    fn loadImportsInRange(
        self: *Compiler,
        alloc: std.mem.Allocator,
        ast: *AST,
        diag: *DiagList,
        loaded: *LoadedSources,
        entry_norm: []const u8,
        start_idx: u32,
        end_idx: u32,
    ) anyerror!void {
        var idx = start_idx;
        while (idx < end_idx) : (idx += 1) {
            const node = ast.nodes[idx];
            if (node.kind != .module_import) continue;
            const mod_name = ast.nodeText(idx);
            if (mod_name.len == 0) continue;

            const importer_path: []const u8 = if (node.source_id == 0)
                entry_norm
            else if (node.source_id - 1 < loaded.extra_count)
                loaded.paths[node.source_id - 1]
            else
                entry_norm;

            var rel_buf: [512]u8 = undefined;
            var is_explicit_path = (node.flags & 1) != 0;
            var std_src: ?[]const u8 = null;
            const rel_path: []const u8 = if (is_explicit_path)
                mod_name
            else blk: {
                if (!std.mem.containsAtLeast(u8, mod_name, 1, "::")) {
                    const cand = std.fmt.bufPrint(&rel_buf, "{s}.lir", .{mod_name}) catch "";
                    if (cand.len > 0) {
                        if (resolveImportPath(alloc, importer_path, cand)) |probe_path| {
                            defer alloc.free(probe_path);
                            if (util.fileExists(probe_path)) {
                                is_explicit_path = true;
                                break :blk cand;
                            }
                        } else |_| {}
                    }
                }
                std_src = stdlib_mod.lookup(mod_name);
                break :blk mod_name;
            };
            if (!is_explicit_path and std_src == null) continue;

            if (std_src) |embedded_src| {
                const canonical = if (std.mem.startsWith(u8, mod_name, "std::")) mod_name["std::".len..] else mod_name;
                const tag = std.fmt.allocPrint(alloc, "<std:{s}>", .{canonical}) catch return error.OutOfMemory;
                if (loaded.containsPath(entry_norm, tag)) {
                    alloc.free(tag);
                    continue;
                }
                if (ast.source_count >= parser_mod.SYNTH_SOURCE_ID) {
                    alloc.free(tag);
                    diag.addAt(.err, node.source_id, node.line, node.col, node.text_len, "maximum number of source modules exceeded (63)");
                    return error.TooManySources;
                }
                const sid = ast.source_count;
                ast.sources[sid] = embedded_src;
                ast.source_count += 1;
                loaded.paths[loaded.extra_count] = tag;
                loaded.bufs[loaded.extra_count] = @constCast(embedded_src);
                loaded.is_static[loaded.extra_count] = true;
                loaded.extra_count += 1;

                const child_start = ast.count;
                try lexAndParseInto(alloc, embedded_src, sid, ast, diag);
                const child_end = ast.count;
                try self.loadImportsInRange(alloc, ast, diag, loaded, entry_norm, child_start, child_end);
                continue;
            }

            const resolved = resolveImportPath(alloc, importer_path, rel_path) catch {
                diag.addFmtAt(.err, node.source_id, node.line, node.col, node.text_len, "cannot resolve import path '{s}'", .{rel_path});
                return error.ImportNotFound;
            };
            if (loaded.containsPath(entry_norm, resolved)) {
                alloc.free(resolved);
                continue;
            }
            if (ast.source_count >= parser_mod.SYNTH_SOURCE_ID) {
                alloc.free(resolved);
                diag.addAt(.err, node.source_id, node.line, node.col, node.text_len, "maximum number of source modules exceeded (63)");
                return error.TooManySources;
            }

            const mod_src = util.readFileAlloc(alloc, resolved) catch {
                diag.addFmtAt(.err, node.source_id, node.line, node.col, node.text_len, "cannot read imported module '{s}'", .{rel_path});
                alloc.free(resolved);
                return error.ImportNotFound;
            };

            const sid = ast.source_count;
            ast.sources[sid] = mod_src;
            ast.source_count += 1;
            loaded.paths[loaded.extra_count] = resolved;
            loaded.bufs[loaded.extra_count] = mod_src;
            loaded.extra_count += 1;

            const child_start = ast.count;
            try lexAndParseInto(alloc, mod_src, sid, ast, diag);
            const child_end = ast.count;
            try self.loadImportsInRange(alloc, ast, diag, loaded, entry_norm, child_start, child_end);
        }
    }

    fn lowerAndVerify(self: *Compiler, ir_mod_out: *ir_mod.IRModule, diag: *DiagList, loaded: *LoadedSources) !void {
        // Reject unsupported triples before lexing, parsing, or allocating compiler state.
        if (!self.target.isSupported()) return error.UnsupportedTarget;

        const alloc = std.heap.page_allocator;

        const ast = alloc.create(AST) catch return error.OutOfMemory;
        defer alloc.destroy(ast);
        ast.initInPlace();
        ast.sources[0] = self.source;
        ast.source_count = 1;

        const entry_norm = if (eql(self.filename, "<test>"))
            alloc.dupe(u8, "<test>") catch return error.OutOfMemory
        else
            std.fs.path.resolve(alloc, &.{self.filename}) catch alloc.dupe(u8, self.filename) catch return error.OutOfMemory;
        defer alloc.free(entry_norm);

        // Phase 1 & 2: Lex + Parse entry file, then depth-first resolve multi-file imports
        try lexAndParseInto(alloc, self.source, 0, ast, diag);
        const entry_end = ast.count;
        try self.loadImportsInRange(alloc, ast, diag, loaded, entry_norm, 1, entry_end);

        // Phase 2.5: Macro/Generics/Comptime/Test expansion
        try expand_mod.expand(ast, diag, self.test_mode);
        if (ast.overflowed) {
            diag.addAt(.err, 0, 1, 1, 1, "AST or metadata capacity exceeded during expansion");
            return error.TooManyASTNodes;
        }

        // Phase 3: Semantic analysis & type checking
        const sema_info = alloc.create(SemaInfo) catch return error.OutOfMemory;
        defer alloc.destroy(sema_info);
        const sema = alloc.create(Sema) catch return error.OutOfMemory;
        defer alloc.destroy(sema);
        sema.* = Sema.init(ast, diag, sema_info);
        sema.analyze() catch |err| {
            return err;
        };

        // Phase 4: Optimize the AST (when optimization enabled)
        if (self.opt_level != .O0) {
            var optimizer = Optimizer.init(ast, self.source);
            optimizer.sema_info = sema_info;
            optimizer.optimize();
        }

        // Phase 5: Lower AST + SemaInfo to CFG IR (target-aware for @target_* intrinsics)
        const ir_gen = alloc.create(ir_gen_mod.IRGen) catch return error.OutOfMemory;
        defer alloc.destroy(ir_gen);
        ir_gen.* = ir_gen_mod.IRGen.initWithContext(ast, ir_mod_out, self.source, sema_info, diag);
        ir_gen.target = self.target;
        try ir_gen.generate();
        if (ir_mod_out.string_overflowed) {
            diag.add(.err, 1, 1, 1, "IR string table capacity exceeded");
            return error.StringTableOverflow;
        }

        // Phase 6: Pre-optimization IR verification
        try ir_verify_mod.verify(ir_mod_out, self.source);

        // Phase 7: IR optimization passes (-O0 / -O1 / -O2)
        ir_opt_mod.optimize(ir_mod_out, self.opt_level);

        // Phase 8: Post-optimization IR verification
        try ir_verify_mod.verify(ir_mod_out, self.source);
    }

    fn emitDiag(self: *Compiler, diag: *const DiagList, loaded: *const LoadedSources) void {
        self.last_diag_count = diag.count;
        if (diag.count > 0) {
            self.last_diag_source_id = diag.items[0].source_id;
            self.last_diag_line = diag.items[0].line;
        }
        var filenames: [parser_mod.MAX_SOURCES][]const u8 = undefined;
        var sources: [parser_mod.MAX_SOURCES][]const u8 = undefined;
        filenames[0] = self.filename;
        sources[0] = self.source;
        const extra = @min(loaded.extra_count, parser_mod.MAX_SOURCES - 1);
        var i: u32 = 0;
        while (i < extra) : (i += 1) {
            filenames[i + 1] = loaded.paths[i];
            sources[i + 1] = loaded.bufs[i];
        }
        diag.emitAllSources(filenames[0 .. 1 + extra], sources[0 .. 1 + extra]);
    }

    pub fn compileToIR(self: *Compiler, ir_module: *ir_mod.IRModule) !void {
        const alloc = std.heap.page_allocator;
        ir_module.init();
        var loaded = LoadedSources{};
        defer loaded.deinit(alloc);
        var diag = DiagList.init();
        diag.quiet = self.quiet;
        self.lowerAndVerify(ir_module, &diag, &loaded) catch |err| {
            self.emitDiag(&diag, &loaded);
            return err;
        };
    }

    pub fn check(self: *Compiler) !void {
        const alloc = std.heap.page_allocator;
        const ir_module = alloc.create(ir_mod.IRModule) catch return error.OutOfMemory;
        defer alloc.destroy(ir_module);
        ir_module.init();

        var loaded = LoadedSources{};
        defer loaded.deinit(alloc);

        var diag = DiagList.init();
        diag.quiet = self.quiet;
        self.lowerAndVerify(ir_module, &diag, &loaded) catch |err| {
            self.emitDiag(&diag, &loaded);
            return err;
        };
        if (self.emit_ir) {
            ir_module.dumpModule(self.source);
        }
    }

    pub fn compileToC(self: *Compiler) ![]u8 {
        const alloc = std.heap.page_allocator;
        const ir_module = alloc.create(ir_mod.IRModule) catch return error.OutOfMemory;
        defer alloc.destroy(ir_module);
        ir_module.init();

        var loaded = LoadedSources{};
        defer loaded.deinit(alloc);

        var diag = DiagList.init();
        diag.quiet = self.quiet;
        self.lowerAndVerify(ir_module, &diag, &loaded) catch |err| {
            self.emitDiag(&diag, &loaded);
            return err;
        };

        if (self.emit_ir) {
            ir_module.dumpModule(self.source);
        }
        return try backend_mod.emitCSource(alloc, ir_module, self.source, self.target);
    }

    pub fn runInVM(self: *Compiler, prog_args: []const []const u8, capture_io: bool) !backend_mod.VMResult {
        const alloc = std.heap.page_allocator;
        const ir_module = alloc.create(ir_mod.IRModule) catch return error.OutOfMemory;
        defer alloc.destroy(ir_module);
        ir_module.init();

        var loaded = LoadedSources{};
        defer loaded.deinit(alloc);

        var diag = DiagList.init();
        diag.quiet = self.quiet;
        self.lowerAndVerify(ir_module, &diag, &loaded) catch |err| {
            self.emitDiag(&diag, &loaded);
            return err;
        };

        if (self.emit_ir) {
            ir_module.dumpModule(self.source);
        }
        return try backend_mod.executeVM(alloc, ir_module, self.source, prog_args, capture_io);
    }

    pub fn compile(self: *Compiler) ![]const u8 {
        const alloc = std.heap.page_allocator;
        const ir_module = alloc.create(ir_mod.IRModule) catch return error.OutOfMemory;
        defer alloc.destroy(ir_module);
        ir_module.init();

        var loaded = LoadedSources{};
        defer loaded.deinit(alloc);

        var diag = DiagList.init();
        diag.quiet = self.quiet;
        self.lowerAndVerify(ir_module, &diag, &loaded) catch |err| {
            self.emitDiag(&diag, &loaded);
            return err;
        };

        if (self.emit_ir) {
            ir_module.dumpModule(self.source);
        }
        if (self.emit_c) {
            return try backend_mod.emitCSource(alloc, ir_module, self.source, self.target);
        }

        return try backend_mod.emitBinary(alloc, ir_module, self.source, self.target, self.backend_kind);
    }
};
