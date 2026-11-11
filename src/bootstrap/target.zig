// ════════════════════════════════════════════════════════════════════════════
// TARGET — Cross-platform Target Triple, ABI, Format & Backend Descriptor
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const builtin = @import("builtin");

pub const Arch = enum(u8) {
    x86_64 = 0,
    aarch64 = 1,
    riscv64 = 2,
    wasm32 = 3,

    pub fn name(self: Arch) []const u8 {
        return switch (self) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .riscv64 => "riscv64",
            .wasm32 => "wasm32",
        };
    }

    pub fn ptrSize(self: Arch) u8 {
        return switch (self) {
            .wasm32 => 4,
            .x86_64, .aarch64, .riscv64 => 8,
        };
    }
};

pub const OS = enum(u8) {
    linux = 0,
    macos = 1,
    windows = 2,
    wasi = 3,
    freebsd = 4,

    pub fn name(self: OS) []const u8 {
        return switch (self) {
            .linux => "linux",
            .macos => "macos",
            .windows => "windows",
            .wasi => "wasi",
            .freebsd => "freebsd",
        };
    }
};

pub const BinaryFormat = enum(u8) {
    elf = 0,
    macho = 1,
    pe = 2,
    wasm = 3,

    pub fn name(self: BinaryFormat) []const u8 {
        return switch (self) {
            .elf => "ELF",
            .macho => "Mach-O",
            .pe => "PE/COFF",
            .wasm => "WebAssembly",
        };
    }
};

pub const BackendKind = enum(u8) {
    auto = 0,
    native_elf = 1,
    native_wasm = 2,
    c = 3,
    vm = 4,

    pub fn parse(s: []const u8) ?BackendKind {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        if (std.mem.eql(u8, s, "native") or std.mem.eql(u8, s, "elf")) return .native_elf;
        if (std.mem.eql(u8, s, "wasm")) return .native_wasm;
        if (std.mem.eql(u8, s, "c") or std.mem.eql(u8, s, "c11")) return .c;
        if (std.mem.eql(u8, s, "vm") or std.mem.eql(u8, s, "interp")) return .vm;
        return null;
    }

    pub fn name(self: BackendKind) []const u8 {
        return switch (self) {
            .auto => "auto",
            .native_elf => "native-elf",
            .native_wasm => "native-wasm",
            .c => "c11",
            .vm => "ir-vm",
        };
    }
};

pub const Target = struct {
    arch: Arch,
    os: OS,

    pub fn host() Target {
        const arch: Arch = switch (builtin.cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            .riscv64 => .riscv64,
            .wasm32 => .wasm32,
            else => .x86_64,
        };
        const os: OS = switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            .wasi => .wasi,
            .freebsd => .freebsd,
            else => .linux,
        };
        return .{ .arch = arch, .os = os };
    }

    pub fn isHost(self: Target) bool {
        const h = Target.host();
        return self.arch == h.arch and self.os == h.os;
    }

    /// Returns whether this architecture/OS pair is implemented by the bootstrap compiler.
    /// Keep this list aligned with Target.parse and the backend toolchain support matrix.
    pub fn isSupported(self: Target) bool {
        return switch (self.os) {
            .linux => self.arch == .x86_64 or self.arch == .aarch64 or self.arch == .riscv64,
            .macos => self.arch == .x86_64 or self.arch == .aarch64,
            .windows => self.arch == .x86_64 or self.arch == .aarch64,
            .wasi => self.arch == .wasm32,
            .freebsd => self.arch == .x86_64 or self.arch == .aarch64,
        };
    }

    /// The direct WebAssembly emitter only supports the wasm32-wasi ABI pair.
    pub fn isWasm32Wasi(self: Target) bool {
        return self.arch == .wasm32 and self.os == .wasi;
    }

    pub fn binaryFormat(self: Target) BinaryFormat {
        return switch (self.os) {
            .linux, .freebsd => .elf,
            .macos => .macho,
            .windows => .pe,
            .wasi => .wasm,
        };
    }

    pub fn exeSuffix(self: Target) []const u8 {
        return switch (self.os) {
            .windows => ".exe",
            .wasi => ".wasm",
            else => "",
        };
    }

    pub fn triple(self: Target, buf: *[64]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}-{s}", .{ self.arch.name(), self.os.name() }) catch "x86_64-linux";
    }

    pub fn zigTriple(self: Target) []const u8 {
        return switch (self.os) {
            .linux => switch (self.arch) {
                .x86_64 => "x86_64-linux-musl",
                .aarch64 => "aarch64-linux-musl",
                .riscv64 => "riscv64-linux-musl",
                .wasm32 => "wasm32-wasi",
            },
            .macos => switch (self.arch) {
                .x86_64 => "x86_64-macos",
                .aarch64 => "aarch64-macos",
                else => "x86_64-macos",
            },
            .windows => switch (self.arch) {
                .x86_64 => "x86_64-windows-gnu",
                .aarch64 => "aarch64-windows-gnu",
                else => "x86_64-windows-gnu",
            },
            .wasi => "wasm32-wasi",
            .freebsd => switch (self.arch) {
                .x86_64 => "x86_64-freebsd",
                .aarch64 => "aarch64-freebsd",
                else => "x86_64-freebsd",
            },
        };
    }

    /// Resolve effective execution/codegen backend for this target.
    pub fn resolveBackend(self: Target, requested: BackendKind) BackendKind {
        if (requested != .auto) return requested;
        if (self.arch == .x86_64 and self.os == .linux) return .native_elf;
        if (self.isWasm32Wasi()) return .native_wasm;
        return .c;
    }

    pub fn parse(spec: []const u8) ?Target {
        if (std.mem.eql(u8, spec, "host") or std.mem.eql(u8, spec, "native")) return Target.host();
        if (std.mem.eql(u8, spec, "linux") or std.mem.eql(u8, spec, "x86_64-linux") or std.mem.eql(u8, spec, "x86_64-linux-gnu") or std.mem.eql(u8, spec, "x86_64-linux-musl")) {
            return .{ .arch = .x86_64, .os = .linux };
        }
        if (std.mem.eql(u8, spec, "aarch64-linux") or std.mem.eql(u8, spec, "arm64-linux") or std.mem.eql(u8, spec, "linux-arm64") or std.mem.eql(u8, spec, "aarch64-linux-gnu") or std.mem.eql(u8, spec, "aarch64-linux-musl")) {
            return .{ .arch = .aarch64, .os = .linux };
        }
        if (std.mem.eql(u8, spec, "riscv64-linux") or std.mem.eql(u8, spec, "riscv64-linux-gnu") or std.mem.eql(u8, spec, "riscv64-linux-musl")) {
            return .{ .arch = .riscv64, .os = .linux };
        }
        if (std.mem.eql(u8, spec, "macos") or std.mem.eql(u8, spec, "darwin") or std.mem.eql(u8, spec, "aarch64-macos") or std.mem.eql(u8, spec, "arm64-macos") or std.mem.eql(u8, spec, "aarch64-darwin") or std.mem.eql(u8, spec, "arm64-darwin")) {
            return .{ .arch = .aarch64, .os = .macos };
        }
        if (std.mem.eql(u8, spec, "x86_64-macos") or std.mem.eql(u8, spec, "x86_64-darwin")) {
            return .{ .arch = .x86_64, .os = .macos };
        }
        if (std.mem.eql(u8, spec, "windows") or std.mem.eql(u8, spec, "win64") or std.mem.eql(u8, spec, "x86_64-windows") or std.mem.eql(u8, spec, "x86_64-windows-gnu") or std.mem.eql(u8, spec, "x86_64-windows-msvc")) {
            return .{ .arch = .x86_64, .os = .windows };
        }
        if (std.mem.eql(u8, spec, "aarch64-windows") or std.mem.eql(u8, spec, "arm64-windows") or std.mem.eql(u8, spec, "aarch64-windows-gnu")) {
            return .{ .arch = .aarch64, .os = .windows };
        }
        if (std.mem.eql(u8, spec, "wasm") or std.mem.eql(u8, spec, "wasm32") or std.mem.eql(u8, spec, "wasi") or std.mem.eql(u8, spec, "wasm32-wasi")) {
            return .{ .arch = .wasm32, .os = .wasi };
        }
        if (std.mem.eql(u8, spec, "freebsd") or std.mem.eql(u8, spec, "x86_64-freebsd")) {
            return .{ .arch = .x86_64, .os = .freebsd };
        }
        if (std.mem.eql(u8, spec, "aarch64-freebsd") or std.mem.eql(u8, spec, "arm64-freebsd")) {
            return .{ .arch = .aarch64, .os = .freebsd };
        }
        return null;
    }

    pub const supported_list_text =
        \\Supported LIR Targets:
        \\  x86_64-linux       ELF64    default backend: native-elf (direct x86-64 machine code)
        \\  aarch64-linux      ELF64    default backend: c11 (cross/native via cc / zig cc)
        \\  riscv64-linux      ELF64    default backend: c11 (cross/native via cc / zig cc)
        \\  x86_64-macos       Mach-O   default backend: c11 (cross/native via cc / zig cc)
        \\  aarch64-macos      Mach-O   default backend: c11 (cross/native via cc / zig cc)
        \\  x86_64-windows     PE/COFF  default backend: c11 (cross/native via cc / zig cc)
        \\  aarch64-windows    PE/COFF  default backend: c11 (cross/native via cc / zig cc)
        \\  x86_64-freebsd     ELF64    default backend: c11 (cross/native via cc / zig cc)
        \\  aarch64-freebsd    ELF64    default backend: c11 (cross/native via cc / zig cc)
        \\  wasm32-wasi        WASM     default backend: native-wasm (direct .wasm emitter)
        \\
        \\Portable execution backends (all host platforms):
        \\  --backend vm       In-process IR VM (runs any verified LIR program without external tools)
        \\  --backend c        Portable C11 backend (+ --emit-c for raw .c output)
        \\  --backend wasm     Direct WebAssembly WASI binary emitter (.wasm)
        \\  --backend native   Direct x86-64 Linux ELF64 backend
        \\
    ;
};
