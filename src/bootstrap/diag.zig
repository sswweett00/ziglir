// ════════════════════════════════════════════════════════════════════════════
// DIAGNOSTICS — Structured compiler errors & warnings with source spans
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");

pub const Severity = enum(u8) {
    err,
    warning,
    note,
};

pub const Diagnostic = struct {
    severity: Severity,
    source_id: u32 = 0,
    line: u32,
    col: u32,
    span_len: u32,
    msg: [192]u8,
    msg_len: u16,

    pub fn text(self: *const Diagnostic) []const u8 {
        return self.msg[0..self.msg_len];
    }
};

pub const DiagList = struct {
    items: [64]Diagnostic = undefined,
    count: u32 = 0,
    error_count: u32 = 0,
    warning_count: u32 = 0,
    overflowed: bool = false,
    quiet: bool = false,

    pub fn init() DiagList {
        return .{};
    }

    pub fn add(self: *DiagList, severity: Severity, line: u32, col: u32, span_len: u32, message: []const u8) void {
        self.addAt(severity, 0, line, col, span_len, message);
    }

    pub fn addAt(self: *DiagList, severity: Severity, source_id: u32, line: u32, col: u32, span_len: u32, message: []const u8) void {
        if (severity == .err) self.error_count += 1;
        if (severity == .warning) self.warning_count += 1;
        if (self.count >= self.items.len) {
            self.overflowed = true;
            return;
        }
        const copy_len: usize = @min(message.len, self.items[0].msg.len);
        var d = Diagnostic{
            .severity = severity,
            .source_id = source_id,
            .line = if (line == 0) 1 else line,
            .col = if (col == 0) 1 else col,
            .span_len = @max(@as(u32, 1), span_len),
            .msg = undefined,
            .msg_len = @intCast(copy_len),
        };
        @memcpy(d.msg[0..copy_len], message[0..copy_len]);
        self.items[self.count] = d;
        self.count += 1;
    }

    pub fn addFmt(self: *DiagList, severity: Severity, line: u32, col: u32, span_len: u32, comptime fmt: []const u8, args: anytype) void {
        self.addFmtAt(severity, 0, line, col, span_len, fmt, args);
    }

    pub fn addFmtAt(self: *DiagList, severity: Severity, source_id: u32, line: u32, col: u32, span_len: u32, comptime fmt: []const u8, args: anytype) void {
        var buf: [192]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        self.addAt(severity, source_id, line, col, span_len, slice);
    }

    pub fn hasErrors(self: *const DiagList) bool {
        return self.error_count > 0;
    }

    pub fn emitAll(self: *const DiagList, filename: []const u8, src: []const u8) void {
        const fnames = [_][]const u8{filename};
        const srcs = [_][]const u8{src};
        self.emitAllSources(&fnames, &srcs);
    }

    pub fn emitAllSources(self: *const DiagList, filenames: []const []const u8, sources: []const []const u8) void {
        if (self.quiet or filenames.len == 0 or sources.len == 0) return;
        for (self.items[0..self.count]) |*d| {
            const sid = if (d.source_id < filenames.len and d.source_id < sources.len) d.source_id else 0;
            const filename = filenames[sid];
            const src = sources[sid];

            util.printErr(filename);
            util.printErr(":");
            util.printErrUsize(d.line);
            util.printErr(":");
            util.printErrUsize(d.col);
            util.printErr(": ");
            switch (d.severity) {
                .err => util.printErr("error: "),
                .warning => util.printErr("warning: "),
                .note => util.printErr("note: "),
            }
            util.printErr(d.text());
            util.printErr("\n");

            if (lineSlice(src, d.line)) |src_line| {
                util.printErr("   ");
                util.printErrUsize(d.line);
                util.printErr(" | ");
                util.printErr(src_line);
                util.printErr("\n");

                // Caret underline
                util.printErr("     | ");
                const col_zero = if (d.col > 0) d.col - 1 else 0;
                const spaces = @min(@as(usize, col_zero), src_line.len + 16);
                var s_idx: usize = 0;
                while (s_idx < spaces) : (s_idx += 1) {
                    if (s_idx < src_line.len and src_line[s_idx] == '\t') {
                        util.printErr("\t");
                    } else {
                        util.printErr(" ");
                    }
                }
                const carets = @min(@as(usize, d.span_len), 40);
                var c_idx: usize = 0;
                while (c_idx < carets) : (c_idx += 1) {
                    util.printErr("^");
                }
                util.printErr("\n");
            }
        }
        if (self.overflowed) {
            util.printErr(filenames[0]);
            util.printErr(": note: additional diagnostics omitted (maximum 64)\n");
        }
    }
};

fn lineSlice(src: []const u8, target_line: u32) ?[]const u8 {
    if (target_line == 0 or src.len == 0) return null;
    var cur_line: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= src.len) : (i += 1) {
        const at_end = (i == src.len);
        if (at_end or src[i] == '\n') {
            if (cur_line == target_line) {
                var end = i;
                if (end > line_start and src[end - 1] == '\r') end -= 1;
                return src[line_start..end];
            }
            cur_line += 1;
            line_start = i + 1;
        }
    }
    return null;
}
