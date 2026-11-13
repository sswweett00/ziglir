// ════════════════════════════════════════════════════════════════════════════
// SEMA — Semantic analysis, name resolution, scoping, and type checking
// ════════════════════════════════════════════════════════════════════════════

const std = @import("std");
const util = @import("util.zig");
const lex = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const diag_mod = @import("diag.zig");

const TokenKind = lex.TokenKind;
const AST = parser_mod.AST;
const ASTNode = parser_mod.ASTNode;
const NodeKind = parser_mod.NodeKind;
const TypeTag = parser_mod.TypeTag;
const DiagList = diag_mod.DiagList;
const MAX_AST_NODES = parser_mod.MAX_AST_NODES;

pub const SemaType = union(enum) {
    int: struct { bits: u8, unsigned: bool },
    float: u8, // 32 or 64
    bool,
    string,
    ptr,
    ptr_struct: u32,
    null_t,
    array: TypeTag,
    fixed_array: struct { elem: TypeTag, len: u32 },
    struct_t: u32,
    enum_t: u32,
    fn_t: u32,
    tuple_t: u32,
    dyn_trait: u32,
    map_t: u32, // 0=int keys, 1=string keys
    chan_t,
    void,
    never,
    unknown,

    pub const i64_t: SemaType = .{ .int = .{ .bits = 64, .unsigned = false } };
    pub const f64_t: SemaType = .{ .float = 64 };
    pub const array_t: SemaType = .{ .array = .none };

    pub fn fromTypeTag(tag: TypeTag, extra: u32, elem_type: TypeTag) SemaType {
        return switch (tag) {
            .i8 => .{ .int = .{ .bits = 8, .unsigned = false } },
            .i16 => .{ .int = .{ .bits = 16, .unsigned = false } },
            .i32 => .{ .int = .{ .bits = 32, .unsigned = false } },
            .i64, .isize => .{ .int = .{ .bits = 64, .unsigned = false } },
            .u8 => .{ .int = .{ .bits = 8, .unsigned = true } },
            .u16 => .{ .int = .{ .bits = 16, .unsigned = true } },
            .u32 => .{ .int = .{ .bits = 32, .unsigned = true } },
            .u64, .usize => .{ .int = .{ .bits = 64, .unsigned = true } },
            .f32 => .{ .float = 32 },
            .f64 => .{ .float = 64 },
            .bool => .bool,
            .string => .string,
            .void => .void,
            .never => .never,
            .ptr => if (elem_type == .struct_type and extra > 0) .{ .ptr_struct = extra - 1 } else .ptr,
            .struct_type => if (extra > 0) .{ .struct_t = extra - 1 } else .ptr,
            .enum_type => if (extra > 0) .{ .enum_t = extra - 1 } else i64_t,
            .fixed_array => .{ .fixed_array = .{ .elem = elem_type, .len = extra & 0x7FFFFFFF } },
            .fn_ptr => .{ .fn_t = extra },
            .tuple => .{ .tuple_t = extra },
            .dyn_trait => if ((extra & 0x80000000) == 0 and extra > 0) .{ .dyn_trait = extra - 1 } else .{ .dyn_trait = 0 },
            .map => .{ .map_t = extra },
            .chan => .chan_t,
            .slice => .{ .array = elem_type },
            else => .unknown,
        };
    }

    pub fn isInt(self: SemaType) bool {
        return self == .int;
    }

    pub fn isFloat(self: SemaType) bool {
        return self == .float;
    }

    pub fn isUnsigned(self: SemaType) bool {
        return switch (self) {
            .int => |iv| iv.unsigned,
            else => false,
        };
    }

    pub fn toTypeTag(self: SemaType) parser_mod.TypeTag {
        return switch (self) {
            .int => |iv| if (iv.unsigned) (if (iv.bits == 8) .u8 else if (iv.bits == 16) .u16 else if (iv.bits == 32) .u32 else .u64) else (if (iv.bits == 8) .i8 else if (iv.bits == 16) .i16 else if (iv.bits == 32) .i32 else .i64),
            .float => |fb| if (fb == 32) .f32 else .f64,
            .bool => .bool,
            .string => .string,
            .ptr, .ptr_struct, .null_t => .ptr,
            .struct_t => .struct_type,
            .enum_t => .enum_type,
            .void => .void,
            else => .i64,
        };
    }

    pub fn isScalar(self: SemaType) bool {
        return switch (self) {
            .int, .float, .bool, .ptr, .ptr_struct, .array, .fixed_array, .enum_t, .fn_t, .tuple_t, .dyn_trait, .map_t, .chan_t, .unknown => true,
            else => false,
        };
    }

    pub fn eql(a: SemaType, b: SemaType) bool {
        return switch (a) {
            .int => |ia| switch (b) {
                .int => |ib| ia.bits == ib.bits and ia.unsigned == ib.unsigned,
                else => false,
            },
            .float => |fa| switch (b) {
                .float => |fb| fa == fb,
                else => false,
            },
            .bool => b == .bool,
            .string => b == .string,
            .ptr => b == .ptr,
            .ptr_struct => |sa| switch (b) {
                .ptr_struct => |sb| sa == sb,
                .ptr => true,
                else => false,
            },
            .null_t => b == .null_t,
            .array => |ea| switch (b) {
                .array => |eb| ea == eb or ea == .none or eb == .none,
                else => false,
            },
            .fixed_array => |fa| switch (b) {
                .fixed_array => |fb| (fa.elem == fb.elem or fa.elem == .none or fb.elem == .none) and fa.len == fb.len,
                else => false,
            },
            .void => b == .void,
            .never => b == .never,
            .unknown => b == .unknown,
            .struct_t => |sa| switch (b) {
                .struct_t => |sb| sa == sb,
                else => false,
            },
            .enum_t => |ea| switch (b) {
                .enum_t => |eb| ea == eb,
                else => false,
            },
            .fn_t => b == .fn_t,
            .tuple_t => |ta| switch (b) {
                .tuple_t => |tb| ta == tb,
                else => false,
            },
            .dyn_trait => |da| switch (b) {
                .dyn_trait => |db| da == db,
                else => false,
            },
            .map_t => b == .map_t,
            .chan_t => b == .chan_t,
        };
    }

    pub fn compatibleWith(expected: SemaType, actual: SemaType) bool {
        if (actual == .never or actual == .unknown or expected == .unknown) return true;
        if (expected.eql(actual)) return true;
        if (expected == .float and actual == .float) return expected.float >= actual.float;
        if (expected == .dyn_trait) {
            return (actual == .dyn_trait and expected.dyn_trait == actual.dyn_trait) or actual == .struct_t or actual == .ptr_struct;
        }
        if (expected == .fn_t) return actual == .fn_t;
        if (expected == .tuple_t) return actual == .tuple_t;
        if (expected == .map_t) return actual == .map_t;
        if (expected == .chan_t) return actual == .chan_t;
        if (expected == .int) return actual == .int;
        if (expected == .enum_t) return actual == .enum_t and expected.enum_t == actual.enum_t;
        if (expected == .null_t) return actual == .null_t or actual == .ptr or actual == .ptr_struct;
        if (expected == .ptr) {
            return actual == .ptr or actual == .ptr_struct or actual == .null_t or actual == .string or actual == .array;
        }
        if (expected == .ptr_struct) {
            return (actual == .ptr_struct and expected.ptr_struct == actual.ptr_struct) or actual == .ptr or actual == .null_t;
        }
        if (expected == .bool) return actual == .bool;
        if (expected == .struct_t) return actual == .struct_t and expected.struct_t == actual.struct_t;
        if (expected == .fixed_array and actual == .fixed_array) {
            return expected.fixed_array.len == actual.fixed_array.len and
                (expected.fixed_array.elem == actual.fixed_array.elem or expected.fixed_array.elem == .none or actual.fixed_array.elem == .none);
        }
        return false;
    }
};

pub const SemaError = error{
    UndefinedFunctionCall,
    DuplicateDeclaration,
    UndefinedVariable,
    UndefinedStruct,
    UnknownField,
    InvalidArgumentCount,
    TooManyArguments,
    LoopControlOutsideLoop,
    InvalidAddressOf,
    InvalidAssignmentTarget,
    TypeMismatch,
    TooManySymbols,
};

pub const MAX_PARAMS = 8;

const FnSig = struct {
    name: []const u8,
    owner_struct_plus1: u32, // 0 for free fn, struct_idx+1 for method
    node_idx: u32,
    line: u32,
    param_count: u32,
    param_types: [MAX_PARAMS]SemaType,
    param_is_mut: [MAX_PARAMS]bool = .{false} ** MAX_PARAMS,
    param_nodes: [MAX_PARAMS]u32 = .{0} ** MAX_PARAMS,
    self_is_mut: bool = false,
    self_is_ref: bool = false,
    ret_type: SemaType,
    has_explicit_ret: bool,
};

const ResState = enum(u8) {
    normal,
    heap_alive,
    freed,
    maybe_freed,
    fd_alive,
    fd_closed,
    fd_maybe_closed,
    escaped,
};

const VarEntry = struct {
    name: []const u8,
    scope_depth: u32,
    ty: SemaType,
    is_mut: bool,
    is_const: bool = false,
    is_float: bool = false,
    is_ref_imm: bool = false,
    const_val: i64 = 0,
    res_state: ResState = .normal,
    alloc_loop_depth: u32 = 0,
    heap_alloc_size: i64 = -1,
    has_deferred_free: bool = false,
    local_ref_origin: u32 = 0,
    borrow_target: i32 = -1,
    borrow_is_mut: bool = false,
    shared_borrows: u16 = 0,
    mut_borrowed: bool = false,
    alias_root: i32 = -1,
    thread_active: bool = false,
    thread_handle_var: i32 = -1,
    holds_local_ref_closure: bool = false,
    decl_source_id: u32 = 0,
    decl_line: u32 = 0,
    decl_col: u32 = 0,
};

const ConstEntry = struct {
    name: []const u8,
    ty: SemaType,
    val: i64,
    is_float: bool = false,
};

const BuiltinSpec = struct {
    name: []const u8,
    min_args: u8,
    max_args: u8,
    ret: SemaType,
};

const builtins = [_]BuiltinSpec{
    .{ .name = "@rotl", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@rotr", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@bit_reverse", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@is_power_of_two", .min_args = 1, .max_args = 1, .ret = .bool },
    .{ .name = "@signum", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@wrapping_add", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@wrapping_sub", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@wrapping_mul", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },

    .{ .name = "printInt", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "print", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "println", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "exit", .min_args = 1, .max_args = 1, .ret = .never },
    .{ .name = "@syscall", .min_args = 1, .max_args = 7, .ret = SemaType.i64_t },
    .{ .name = "@array_new", .min_args = 1, .max_args = 2, .ret = SemaType.array_t },
    .{ .name = "@array_push", .min_args = 2, .max_args = 2, .ret = .void },
    .{ .name = "@array_get", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@array_set", .min_args = 3, .max_args = 3, .ret = SemaType.i64_t },
    .{ .name = "@array_len", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@array_free", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "@string_new", .min_args = 1, .max_args = 2, .ret = .string },
    .{ .name = "@string_len", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@string_concat", .min_args = 2, .max_args = 2, .ret = .string },
    .{ .name = "@string_eq", .min_args = 2, .max_args = 2, .ret = .bool },
    .{ .name = "@string_sub", .min_args = 3, .max_args = 3, .ret = .string },
    .{ .name = "@string_slice", .min_args = 3, .max_args = 3, .ret = .string },
    .{ .name = "@string_char_at", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@string_split", .min_args = 2, .max_args = 2, .ret = .{ .array = .string } },
    .{ .name = "@int_to_string", .min_args = 1, .max_args = 1, .ret = .string },
    .{ .name = "@string_to_int", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@malloc", .min_args = 1, .max_args = 1, .ret = .ptr },
    .{ .name = "@alloc", .min_args = 1, .max_args = 1, .ret = .ptr },
    .{ .name = "@free", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "@memcpy", .min_args = 3, .max_args = 3, .ret = .ptr },
    .{ .name = "@memset", .min_args = 3, .max_args = 3, .ret = .ptr },
    .{ .name = "@ptr_add", .min_args = 2, .max_args = 2, .ret = .ptr },
    .{ .name = "@read_byte", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@write_byte", .min_args = 2, .max_args = 2, .ret = .void },
    .{ .name = "@open", .min_args = 2, .max_args = 3, .ret = SemaType.i64_t },
    .{ .name = "@read", .min_args = 3, .max_args = 3, .ret = SemaType.i64_t },
    .{ .name = "@write", .min_args = 3, .max_args = 3, .ret = SemaType.i64_t },
    .{ .name = "@close", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@unlink", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@mkdir", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@stat", .min_args = 1, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@getpid", .min_args = 0, .max_args = 0, .ret = SemaType.i64_t },
    .{ .name = "@getppid", .min_args = 0, .max_args = 0, .ret = SemaType.i64_t },
    .{ .name = "@getuid", .min_args = 0, .max_args = 0, .ret = SemaType.i64_t },
    .{ .name = "@tcp_socket", .min_args = 0, .max_args = 0, .ret = SemaType.i64_t },
    .{ .name = "@tcp_listen", .min_args = 3, .max_args = 3, .ret = SemaType.i64_t },
    .{ .name = "@tcp_accept", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@tcp_connect", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@sock_send", .min_args = 3, .max_args = 3, .ret = SemaType.i64_t },
    .{ .name = "@sock_recv", .min_args = 3, .max_args = 3, .ret = SemaType.i64_t },
    .{ .name = "@target_os", .min_args = 0, .max_args = 0, .ret = SemaType.i64_t },
    .{ .name = "@target_arch", .min_args = 0, .max_args = 0, .ret = SemaType.i64_t },
    .{ .name = "@target_ptr_bits", .min_args = 0, .max_args = 0, .ret = SemaType.i64_t },
    .{ .name = "@thread_create", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@thread_join", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@mutex_create", .min_args = 0, .max_args = 0, .ret = .ptr },
    .{ .name = "@mutex_init", .min_args = 0, .max_args = 0, .ret = .ptr },
    .{ .name = "@mutex_lock", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "@mutex_unlock", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "@print", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "@println", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "@exit", .min_args = 1, .max_args = 1, .ret = .never },
    .{ .name = "@panic", .min_args = 1, .max_args = 1, .ret = .never },
    .{ .name = "@argc", .min_args = 0, .max_args = 0, .ret = SemaType.i64_t },
    .{ .name = "@argv", .min_args = 1, .max_args = 1, .ret = .string },
    .{ .name = "@time_ns", .min_args = 0, .max_args = 0, .ret = .{ .int = .{ .bits = 64, .unsigned = true } } },
    .{ .name = "printFloat", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "printlnFloat", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "@float_to_string", .min_args = 1, .max_args = 1, .ret = .string },
    .{ .name = "@string_to_float", .min_args = 1, .max_args = 1, .ret = SemaType.f64_t },
    .{ .name = "@sqrt", .min_args = 1, .max_args = 1, .ret = SemaType.f64_t },
    .{ .name = "@fabs", .min_args = 1, .max_args = 1, .ret = SemaType.f64_t },
    .{ .name = "@floor", .min_args = 1, .max_args = 1, .ret = SemaType.f64_t },
    .{ .name = "@ceil", .min_args = 1, .max_args = 1, .ret = SemaType.f64_t },
    .{ .name = "@round", .min_args = 1, .max_args = 1, .ret = SemaType.f64_t },
    .{ .name = "@sin", .min_args = 1, .max_args = 1, .ret = SemaType.f64_t },
    .{ .name = "@cos", .min_args = 1, .max_args = 1, .ret = SemaType.f64_t },
    .{ .name = "@min", .min_args = 2, .max_args = 2, .ret = .unknown },
    .{ .name = "@max", .min_args = 2, .max_args = 2, .ret = .unknown },
    .{ .name = "@clamp", .min_args = 3, .max_args = 3, .ret = .unknown },
    .{ .name = "@popcount", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@clz", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@ctz", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@bswap", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@atomic_add", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@atomic_cas", .min_args = 3, .max_args = 3, .ret = .bool },
    .{ .name = "@map_new", .min_args = 0, .max_args = 1, .ret = .{ .map_t = 0 } },
    .{ .name = "@map_set", .min_args = 3, .max_args = 3, .ret = .void },
    .{ .name = "@map_get", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@map_has", .min_args = 2, .max_args = 2, .ret = .bool },
    .{ .name = "@map_del", .min_args = 2, .max_args = 2, .ret = .bool },
    .{ .name = "@map_len", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@map_free", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "@chan_new", .min_args = 0, .max_args = 1, .ret = .chan_t },
    .{ .name = "@chan_send", .min_args = 2, .max_args = 2, .ret = .void },
    .{ .name = "@chan_recv", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@chan_close", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "@assert", .min_args = 1, .max_args = 1, .ret = .void },
    .{ .name = "@assert_eq", .min_args = 2, .max_args = 2, .ret = .void },
    .{ .name = "@panic", .min_args = 1, .max_args = 1, .ret = .never },
    .{ .name = "@array_map", .min_args = 2, .max_args = 2, .ret = SemaType.array_t },
    .{ .name = "@array_filter", .min_args = 2, .max_args = 2, .ret = SemaType.array_t },
    .{ .name = "@array_reduce", .min_args = 3, .max_args = 3, .ret = .unknown },
    .{ .name = "@size_of", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@align_of", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@type_name", .min_args = 1, .max_args = 1, .ret = .string },
    // High-security & zero-wrapper systems builtins
    .{ .name = "@random_u64", .min_args = 0, .max_args = 0, .ret = .{ .int = .{ .bits = 64, .unsigned = true } } },
    .{ .name = "@random_bytes", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@secure_zero", .min_args = 2, .max_args = 2, .ret = .void },
    .{ .name = "@const_time_eq", .min_args = 3, .max_args = 3, .ret = .bool },
    .{ .name = "@checked_add", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@checked_sub", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@checked_mul", .min_args = 2, .max_args = 2, .ret = SemaType.i64_t },
    .{ .name = "@getenv", .min_args = 1, .max_args = 1, .ret = .string },
    .{ .name = "@sleep_ms", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@read_u8", .min_args = 1, .max_args = 1, .ret = .{ .int = .{ .bits = 8, .unsigned = true } } },
    .{ .name = "@write_u8", .min_args = 2, .max_args = 2, .ret = .void },
    .{ .name = "@read_u32", .min_args = 1, .max_args = 1, .ret = .{ .int = .{ .bits = 32, .unsigned = true } } },
    .{ .name = "@write_u32", .min_args = 2, .max_args = 2, .ret = .void },
    .{ .name = "@read_u64", .min_args = 1, .max_args = 1, .ret = SemaType.i64_t },
    .{ .name = "@write_u64", .min_args = 2, .max_args = 2, .ret = .void },
};

pub fn isIntegerIntrinsic(name: []const u8) bool {
    inline for (.{ "@rotl", "@rotr", "@bit_reverse", "@is_power_of_two", "@signum", "@wrapping_add", "@wrapping_sub", "@wrapping_mul" }) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

pub fn lookupBuiltin(name: []const u8) ?BuiltinSpec {
    for (builtins) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

pub const ClosureInfo = struct {
    node_idx: u32 = 0,
    capture_count: u8 = 0,
    cap_names: [16][]const u8 = undefined,
    cap_types: [16]SemaType = undefined,
    cap_var_indices: [16]u32 = .{0} ** 16,
    captures_local_ref: bool = false,
    param_count: u8 = 0,
    param_types: [MAX_PARAMS]SemaType = .{SemaType.i64_t} ** MAX_PARAMS,
    ret_type: SemaType = SemaType.i64_t,
};

pub const SemaInfo = struct {
    node_types: [MAX_AST_NODES]SemaType,
    field_offsets: [MAX_AST_NODES]u32,
    struct_indices: [MAX_AST_NODES]u32,
    is_string_op: [MAX_AST_NODES]bool,
    is_float_op: [MAX_AST_NODES]bool,
    is_tail_expr: [MAX_AST_NODES]bool,
    is_len_prop: [MAX_AST_NODES]bool,
    is_const_val: [MAX_AST_NODES]bool,
    is_pattern_binding: [MAX_AST_NODES]bool,
    const_vals: [MAX_AST_NODES]i64,
    method_fn_nodes: [MAX_AST_NODES]u32,
    direct_call_fns: [MAX_AST_NODES]u32,
    call_arg_targets: [MAX_AST_NODES]u8,
    is_method_auto_ref: [MAX_AST_NODES]bool,
    is_unsigned_op: [MAX_AST_NODES]bool,
    enum_def_idx: [MAX_AST_NODES]u16,
    enum_variant_idx: [MAX_AST_NODES]u16,
    closure_ids: [MAX_AST_NODES]u16,
    trait_impl_idx: [MAX_AST_NODES]u16,
    closures: [128]ClosureInfo,
    closure_count: u32,
    tuple_descs: [256]parser_mod.TypeDesc,
    tuple_desc_count: u32,

    pub fn initInPlace(self: *SemaInfo) void {
        @memset(&self.node_types, .unknown);
        @memset(&self.field_offsets, 0);
        @memset(&self.struct_indices, 0);
        @memset(&self.is_string_op, false);
        @memset(&self.is_float_op, false);
        @memset(&self.is_tail_expr, false);
        @memset(&self.is_len_prop, false);
        @memset(&self.is_const_val, false);
        @memset(&self.is_pattern_binding, false);
        @memset(&self.const_vals, 0);
        @memset(&self.method_fn_nodes, 0);
        @memset(&self.direct_call_fns, 0);
        @memset(&self.call_arg_targets, 0);
        @memset(&self.is_method_auto_ref, false);
        @memset(&self.is_unsigned_op, false);
        @memset(&self.enum_def_idx, 0);
        @memset(&self.enum_variant_idx, 0);
        @memset(&self.closure_ids, 0);
        @memset(&self.trait_impl_idx, 0);
        self.closure_count = 0;
        self.tuple_desc_count = 0;
    }
};

pub const Sema = struct {
    ast: *const AST,
    diag: *DiagList,
    info: *SemaInfo,

    fns: [512]FnSig = undefined,
    fn_count: u32 = 0,

    consts: [256]ConstEntry = undefined,
    const_count: u32 = 0,

    vars: [512]VarEntry = undefined,
    var_count: u32 = 0,
    scope_depth: u32 = 0,
    loop_depth: u32 = 0,
    defer_depth: u32 = 0,
    closure_var_base: u32 = 0,
    cur_closure_id: u16 = 0,
    in_spawn: bool = false,
    spawn_mutex_depth: u32 = 0,
    cur_fn_stack_bytes: u64 = 0,
    skip_res_check_node: u32 = 0,

    cur_ret_type: SemaType = .unknown,
    cur_has_explicit_ret: bool = false,
    first_error: ?SemaError = null,

    pub fn init(ast: *const AST, diag: *DiagList, info: *SemaInfo) Sema {
        info.initInPlace();
        return .{
            .ast = ast,
            .diag = diag,
            .info = info,
        };
    }

    fn text(self: *const Sema, idx: u32) []const u8 {
        if (idx == 0 or idx >= self.ast.count) return "";
        const n = self.ast.nodes[idx];
        return self.ast.nodeTextSrcFrom(n.text_start, n.text_len, n.source_id);
    }

    fn srcText(self: *const Sema, start: u32, len: u32, source_id: u32) []const u8 {
        return self.ast.nodeTextSrcFrom(start, len, source_id);
    }

    fn fail(self: *Sema, err: SemaError, line: u32, col: u32, span_len: u32, comptime fmt: []const u8, args: anytype) void {
        self.failAt(err, 0, line, col, span_len, fmt, args);
    }

    fn failAt(self: *Sema, err: SemaError, source_id: u32, line: u32, col: u32, span_len: u32, comptime fmt: []const u8, args: anytype) void {
        if (self.first_error == null) self.first_error = err;
        self.diag.addFmtAt(.err, source_id, line, col, span_len, fmt, args);
    }

    fn checkCrossNamespaceConflict(self: *Sema, name: []const u8, allow_kind: enum { struct_k, enum_k, alias_k, const_k, fn_k }, source_id: u32, line: u32, col: u32) void {
        if (name.len == 0) return;
        const slen: u32 = @intCast(@max(name.len, 1));
        if (allow_kind != .struct_k) {
            const sc = @min(@as(u32, self.ast.struct_count), @as(u32, @intCast(self.ast.struct_defs.len)));
            for (0..sc) |i| {
                const sd = self.ast.struct_defs[i];
                if (std.mem.eql(u8, self.srcText(sd.name_start, sd.name_len, sd.source_id), name)) {
                    self.failAt(error.DuplicateDeclaration, source_id, line, col, slen, "name '{s}' conflicts with struct '{s}'", .{ name, name });
                    return;
                }
            }
        }
        if (allow_kind != .enum_k) {
            const ec = @min(@as(u32, self.ast.enum_count), @as(u32, @intCast(self.ast.enum_defs.len)));
            for (0..ec) |i| {
                const ed = self.ast.enum_defs[i];
                if (std.mem.eql(u8, self.srcText(ed.name_start, ed.name_len, ed.source_id), name)) {
                    self.failAt(error.DuplicateDeclaration, source_id, line, col, slen, "name '{s}' conflicts with enum '{s}'", .{ name, name });
                    return;
                }
            }
        }
        if (allow_kind != .alias_k) {
            const tc = @min(@as(u32, self.ast.alias_count), @as(u32, @intCast(self.ast.alias_defs.len)));
            for (0..tc) |i| {
                const td = self.ast.alias_defs[i];
                if (std.mem.eql(u8, self.srcText(td.name_start, td.name_len, td.source_id), name)) {
                    self.failAt(error.DuplicateDeclaration, source_id, line, col, slen, "name '{s}' conflicts with type alias '{s}'", .{ name, name });
                    return;
                }
            }
        }
        if (allow_kind != .const_k) {
            if (self.lookupGlobalConst(name) != null) {
                self.failAt(error.DuplicateDeclaration, source_id, line, col, slen, "name '{s}' conflicts with global const '{s}'", .{ name, name });
                return;
            }
        }
        if (allow_kind != .fn_k) {
            if (self.findFn(name, 0) != null) {
                self.failAt(error.DuplicateDeclaration, source_id, line, col, slen, "name '{s}' conflicts with function '{s}'", .{ name, name });
                return;
            }
        }
    }

    fn pushScope(self: *Sema) void {
        self.scope_depth += 1;
    }

    fn popScope(self: *Sema) void {
        while (self.var_count > 0 and self.vars[self.var_count - 1].scope_depth == self.scope_depth) {
            const v = self.vars[self.var_count - 1];
            if (v.borrow_target >= 0) {
                const bt: usize = @intCast(v.borrow_target);
                if (bt < self.var_count - 1) {
                    if (v.borrow_is_mut) {
                        self.vars[bt].mut_borrowed = false;
                    } else if (self.vars[bt].shared_borrows > 0) {
                        self.vars[bt].shared_borrows -= 1;
                    }
                }
            }
            if (v.alloc_loop_depth > 0 and !v.has_deferred_free) {
                if (v.res_state == .heap_alive) {
                    self.failAt(
                        error.TypeMismatch,
                        v.decl_source_id,
                        v.decl_line,
                        v.decl_col,
                        @intCast(@max(v.name.len, 1)),
                        "memory leak and allocation churn in loop: '{s}' allocated inside loop is neither freed nor escaped",
                        .{v.name},
                    );
                } else if (v.res_state == .fd_alive) {
                    self.failAt(
                        error.TypeMismatch,
                        v.decl_source_id,
                        v.decl_line,
                        v.decl_col,
                        @intCast(@max(v.name.len, 1)),
                        "file descriptor leak in loop: '{s}' opened inside loop is neither closed nor escaped",
                        .{v.name},
                    );
                }
            }
            self.var_count -= 1;
        }
        if (self.scope_depth > 0) self.scope_depth -= 1;
    }

    fn addVar(self: *Sema, name: []const u8, ty: SemaType, is_mut: bool, source_id: u32, line: u32, col: u32) void {
        var i: u32 = self.var_count;
        while (i > 0) {
            i -= 1;
            if (self.vars[i].scope_depth < self.scope_depth) break;
            if (std.mem.eql(u8, self.vars[i].name, name)) {
                self.failAt(error.DuplicateDeclaration, source_id, line, col, @intCast(@max(name.len, 1)), "duplicate variable '{s}' in same scope", .{name});
                return;
            }
        }
        if (self.var_count >= self.vars.len) {
            self.failAt(error.TooManySymbols, source_id, line, col, 1, "too many local variables in scope", .{});
            return;
        }
        self.vars[self.var_count] = .{
            .name = name,
            .scope_depth = self.scope_depth,
            .ty = ty,
            .is_mut = is_mut,
            .decl_source_id = source_id,
            .decl_line = line,
            .decl_col = col,
        };
        self.var_count += 1;
    }

    fn addConstLocal(self: *Sema, name: []const u8, ty: SemaType, val: i64, source_id: u32, line: u32, col: u32) void {
        self.addVar(name, ty, false, source_id, line, col);
        if (self.var_count > 0) {
            self.vars[self.var_count - 1].is_const = true;
            self.vars[self.var_count - 1].const_val = val;
        }
    }

    fn lookupVarIdx(self: *const Sema, name: []const u8) ?u32 {
        var i: u32 = self.var_count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.vars[i].name, name)) return i;
        }
        return null;
    }

    fn lookupVar(self: *const Sema, name: []const u8) ?VarEntry {
        const idx = self.lookupVarIdx(name) orelse return null;
        return self.vars[idx];
    }

    fn lookupGlobalConst(self: *const Sema, name: []const u8) ?ConstEntry {
        for (self.consts[0..self.const_count]) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    fn findFn(self: *const Sema, name: []const u8, owner_struct_plus1: u32) ?FnSig {
        for (self.fns[0..self.fn_count]) |f| {
            if (f.owner_struct_plus1 == owner_struct_plus1 and std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    fn findTraitImpl(self: *const Sema, trait_idx: u32, struct_idx: u32) ?u32 {
        const ic = @min(self.ast.trait_impl_count, @as(u32, @intCast(self.ast.trait_impls.len)));
        for (0..ic) |i| {
            const imp = self.ast.trait_impls[i];
            if (imp.trait_idx == trait_idx and imp.struct_idx == struct_idx) return @intCast(i);
        }
        return null;
    }

    fn getTupleDesc(self: *const Sema, id: u32) ?parser_mod.TypeDesc {
        if ((id & 0x80000000) != 0) {
            const idx = id & 0x7FFFFFFF;
            if (idx < self.info.tuple_desc_count) return self.info.tuple_descs[idx];
            return null;
        }
        if (id > 0 and id < self.ast.type_desc_count) return self.ast.type_descs[id];
        return null;
    }

    fn recordClosureCapture(self: *Sema, vi: u32, name: []const u8, ty: SemaType) void {
        if (self.cur_closure_id == 0) return;
        const ci = self.cur_closure_id - 1;
        if (ci >= self.info.closure_count) return;
        const cl = &self.info.closures[ci];
        if (vi < self.var_count and self.vars[vi].local_ref_origin != 0) {
            cl.captures_local_ref = true;
        }
        for (0..cl.capture_count) |k| {
            if (std.mem.eql(u8, cl.cap_names[k], name)) return;
        }
        if (cl.capture_count < cl.cap_names.len) {
            cl.cap_names[cl.capture_count] = name;
            cl.cap_types[cl.capture_count] = ty;
            cl.cap_var_indices[cl.capture_count] = vi;
            cl.capture_count += 1;
        }
    }

    fn fitsIntRange(val: i64, bits: u8, unsigned: bool) bool {
        if (unsigned) {
            if (val < 0) return false;
            return switch (bits) {
                8 => val <= 255,
                16 => val <= 65535,
                32 => val <= 4294967295,
                else => true,
            };
        } else {
            return switch (bits) {
                8 => val >= -128 and val <= 127,
                16 => val >= -32768 and val <= 32767,
                32 => val >= -2147483648 and val <= 2147483647,
                else => true,
            };
        }
    }

    fn fnSigFromType(self: *const Sema, fid: u32, pcount_out: *u8, params_out: *[MAX_PARAMS]SemaType, ret_out: *SemaType) bool {
        if (fid == 0) return false;
        if ((fid & 0x40000000) != 0) {
            const cid = (fid & 0x3FFFFFFF) - 1;
            if (cid < self.info.closure_count) {
                const cl = self.info.closures[cid];
                pcount_out.* = cl.param_count;
                for (0..@min(cl.param_count, MAX_PARAMS)) |k| params_out[k] = cl.param_types[k];
                ret_out.* = cl.ret_type;
                return true;
            }
            return false;
        }
        if (self.getTupleDesc(fid)) |td| {
            pcount_out.* = td.param_count;
            for (0..@min(td.param_count, MAX_PARAMS)) |k| {
                params_out[k] = SemaType.fromTypeTag(td.param_tags[k], td.param_extras[k], td.param_elems[k]);
            }
            ret_out.* = SemaType.fromTypeTag(td.ret_tag, td.ret_extra, td.ret_elem);
            return true;
        }
        return false;
    }

    fn toTypeSpec(ty: SemaType) struct { tag: TypeTag, extra: u32, elem: TypeTag } {
        return switch (ty) {
            .int => .{ .tag = ty.toTypeTag(), .extra = 0, .elem = .none },
            .float => |fb| .{ .tag = if (fb == 32) .f32 else .f64, .extra = 0, .elem = .none },
            .bool => .{ .tag = .bool, .extra = 0, .elem = .none },
            .string => .{ .tag = .string, .extra = 0, .elem = .none },
            .void => .{ .tag = .void, .extra = 0, .elem = .none },
            .never => .{ .tag = .never, .extra = 0, .elem = .none },
            .ptr, .null_t => .{ .tag = .ptr, .extra = 0, .elem = .none },
            .ptr_struct => |si| .{ .tag = .ptr, .extra = si + 1, .elem = .struct_type },
            .struct_t => |si| .{ .tag = .struct_type, .extra = si + 1, .elem = .none },
            .enum_t => |ei| .{ .tag = .enum_type, .extra = ei + 1, .elem = .none },
            .fn_t => |fi| .{ .tag = .fn_ptr, .extra = fi, .elem = .none },
            .tuple_t => |ti| .{ .tag = .tuple, .extra = ti, .elem = .none },
            .dyn_trait => |di| .{ .tag = .dyn_trait, .extra = di + 1, .elem = .none },
            .map_t => |mi| .{ .tag = .map, .extra = mi, .elem = .none },
            .chan_t => .{ .tag = .chan, .extra = 0, .elem = .none },
            .array => |ea| .{ .tag = .slice, .extra = 0, .elem = ea },
            .fixed_array => |fa| .{ .tag = .fixed_array, .extra = fa.len, .elem = fa.elem },
            .unknown => .{ .tag = .i64, .extra = 0, .elem = .none },
        };
    }

    fn isExprCompatible(self: *const Sema, expected: SemaType, actual: SemaType, expr_idx: u32) bool {
        if (actual == .never or actual == .unknown or expected == .unknown) return true;
        if (expected == .fixed_array and actual == .array and expr_idx != 0 and self.ast.nodes[expr_idx].kind == .array_lit) {
            const fa = expected.fixed_array;
            const expected_elem = SemaType.fromTypeTag(fa.elem, 0, .none);
            var elem = self.ast.nodes[expr_idx].child0;
            var count: u32 = 0;
            while (elem != 0) : (elem = self.ast.nodes[elem].child1) {
                const e = self.ast.nodes[elem].child0;
                if (!self.isExprCompatible(expected_elem, self.info.node_types[e], e)) return false;
                count += 1;
            }
            return count <= fa.len;
        }
        if (!expected.compatibleWith(actual)) return false;
        if (expected == .dyn_trait and (actual == .struct_t or actual == .ptr_struct)) {
            const si = if (actual == .struct_t) actual.struct_t else actual.ptr_struct;
            if (self.findTraitImpl(expected.dyn_trait, si) == null) return false;
        }
        if (expected == .int and actual == .int) {
            const is_explicit_cast = (expr_idx != 0 and self.ast.nodes[expr_idx].kind == .cast_expr);
            if (!is_explicit_cast and expr_idx != 0) {
                if (self.evalConstExpr(expr_idx)) |cval| {
                    return fitsIntRange(cval, expected.int.bits, expected.int.unsigned);
                }
            }
            if (expected.int.unsigned == actual.int.unsigned) {
                return expected.int.bits >= actual.int.bits;
            }
            return !expected.int.unsigned and actual.int.unsigned and expected.int.bits > actual.int.bits;
        }
        if (expected == .tuple_t and actual == .tuple_t and expected.tuple_t != actual.tuple_t) {
            const etd = self.getTupleDesc(expected.tuple_t) orelse return true;
            const atd = self.getTupleDesc(actual.tuple_t) orelse return true;
            if (etd.param_count != atd.param_count) return false;
            for (0..etd.param_count) |k| {
                const et = SemaType.fromTypeTag(etd.param_tags[k], etd.param_extras[k], etd.param_elems[k]);
                const at = SemaType.fromTypeTag(atd.param_tags[k], atd.param_extras[k], atd.param_elems[k]);
                if (!self.isExprCompatible(et, at, 0)) return false;
            }
        }
        if (expected == .fn_t and actual == .fn_t and expected.fn_t != actual.fn_t) {
            var epc: u8 = 0;
            var eparams: [MAX_PARAMS]SemaType = .{SemaType.i64_t} ** MAX_PARAMS;
            var eret: SemaType = .unknown;
            var apc: u8 = 0;
            var aparams: [MAX_PARAMS]SemaType = .{SemaType.i64_t} ** MAX_PARAMS;
            var aret: SemaType = .unknown;
            if (self.fnSigFromType(expected.fn_t, &epc, &eparams, &eret) and
                self.fnSigFromType(actual.fn_t, &apc, &aparams, &aret))
            {
                if (epc != apc) return false;
                for (0..@min(epc, MAX_PARAMS)) |k| {
                    if (!eparams[k].compatibleWith(aparams[k])) return false;
                }
                if (!eret.compatibleWith(aret)) return false;
            }
        }
        return true;
    }

    fn extractLValueRootVar(self: *const Sema, idx: u32) ?u32 {
        if (idx == 0 or idx >= self.ast.count) return null;
        const n = self.ast.nodes[idx];
        return switch (n.kind) {
            .identifier => self.lookupVarIdx(self.text(idx)),
            .field_access => self.extractLValueRootVar(n.child0),
            .index_expr => self.extractLValueRootVar(n.child0),
            .cast_expr => self.extractLValueRootVar(n.child0),
            else => null,
        };
    }

    fn extractPtrRootVar(self: *const Sema, idx: u32) ?u32 {
        if (idx == 0 or idx >= self.ast.count) return null;
        const n = self.ast.nodes[idx];
        return switch (n.kind) {
            .identifier => self.lookupVarIdx(self.text(idx)),
            .cast_expr => self.extractPtrRootVar(n.child0),
            .call_expr => if (n.child0 != 0 and self.ast.nodes[n.child0].kind == .identifier and
                std.mem.eql(u8, self.text(n.child0), "@ptr_add") and n.child2 != 0)
                self.extractPtrRootVar(self.ast.nodes[n.child2].child0)
            else
                null,
            else => null,
        };
    }

    fn checkExprLocalRefOrigin(self: *const Sema, idx: u32) u32 {
        if (idx == 0 or idx >= self.ast.count) return 0;
        const n = self.ast.nodes[idx];
        return switch (n.kind) {
            .addr_of => blk: {
                if (self.extractLValueRootVar(n.child0)) |vi| {
                    if (self.vars[vi].ty != .ptr and self.vars[vi].ty != .ptr_struct and
                        self.vars[vi].ty != .array and self.vars[vi].ty != .map_t)
                    {
                        break :blk vi + 1;
                    }
                    // Taking address of a local pointer variable &p is ALSO a stack pointer!
                    if (self.ast.nodes[n.child0].kind == .identifier) break :blk vi + 1;
                }
                break :blk 0;
            },
            .identifier => blk: {
                if (self.lookupVarIdx(self.text(idx))) |vi| break :blk self.vars[vi].local_ref_origin;
                break :blk 0;
            },
            .cast_expr => self.checkExprLocalRefOrigin(n.child0),
            .ternary_expr => blk_t: {
                const o1 = self.checkExprLocalRefOrigin(n.child1);
                if (o1 != 0) break :blk_t o1;
                break :blk_t self.checkExprLocalRefOrigin(n.child2);
            },
            .call_expr => if (n.child0 != 0 and self.ast.nodes[n.child0].kind == .identifier and
                std.mem.eql(u8, self.text(n.child0), "@ptr_add") and n.child2 != 0)
                self.checkExprLocalRefOrigin(self.ast.nodes[n.child2].child0)
            else
                0,
            else => 0,
        };
    }

    fn evalConstFloat(self: *const Sema, idx: u32) ?f64 {
        if (idx == 0 or idx >= self.ast.count) return null;
        const n = self.ast.nodes[idx];
        return switch (n.kind) {
            .float_literal => @bitCast(n.int_val),
            .identifier => blk: {
                const name = self.text(idx);
                if (self.lookupGlobalConst(name)) |ce| {
                    if (ce.is_float) break :blk @bitCast(ce.val);
                }
                break :blk null;
            },
            .unary_expr => blk: {
                const sub = self.evalConstFloat(n.child0) orelse return null;
                const op: TokenKind = @enumFromInt(n.op);
                break :blk switch (op) {
                    .plus => sub,
                    .minus => -sub,
                    else => null,
                };
            },
            .binary_expr => blk: {
                const lhs = self.evalConstFloat(n.child0) orelse
                    if (self.evalConstExpr(n.child0)) |iv| @as(f64, @floatFromInt(iv)) else return null;
                const rhs = self.evalConstFloat(n.child1) orelse
                    if (self.evalConstExpr(n.child1)) |iv| @as(f64, @floatFromInt(iv)) else return null;
                // Only treat binary_expr as float if at least one operand was float
                if (self.evalConstFloat(n.child0) == null and self.evalConstFloat(n.child1) == null) return null;
                const op: TokenKind = @enumFromInt(n.op);
                break :blk switch (op) {
                    .plus => lhs + rhs,
                    .minus => lhs - rhs,
                    .star => lhs * rhs,
                    .slash => if (rhs != 0.0) lhs / rhs else null,
                    else => null,
                };
            },
            .cast_expr => if (n.type_tag == .f32 or n.type_tag == .f64) blk: {
                if (self.evalConstFloat(n.child0)) |fv| break :blk fv;
                if (self.evalConstExpr(n.child0)) |iv| break :blk @as(f64, @floatFromInt(iv));
                break :blk null;
            } else null,
            else => null,
        };
    }

    fn evalConstExpr(self: *const Sema, idx: u32) ?i64 {
        if (idx == 0 or idx >= self.ast.count) return null;
        const n = self.ast.nodes[idx];
        return switch (n.kind) {
            .int_literal => n.int_val,
            .identifier => blk: {
                const name = self.text(idx);
                if (self.lookupVar(name)) |ve| {
                    if (ve.is_const) break :blk ve.const_val;
                }
                if (self.lookupGlobalConst(name)) |ce| break :blk ce.val;
                break :blk null;
            },
            .unary_expr => blk: {
                const sub = self.evalConstExpr(n.child0) orelse return null;
                const op: TokenKind = @enumFromInt(n.op);
                break :blk switch (op) {
                    .plus => sub,
                    .minus => std.math.negate(sub) catch null,
                    .bang => if (sub == 0) @as(i64, 1) else 0,
                    .tilde => ~sub,
                    else => null,
                };
            },
            .binary_expr => blk: {
                const lhs = self.evalConstExpr(n.child0) orelse return null;
                const rhs = self.evalConstExpr(n.child1) orelse return null;
                const op: TokenKind = @enumFromInt(n.op);
                break :blk switch (op) {
                    .plus => std.math.add(i64, lhs, rhs) catch null,
                    .minus => std.math.sub(i64, lhs, rhs) catch null,
                    .star => std.math.mul(i64, lhs, rhs) catch null,
                    .star_star => util.powWrapping(lhs, rhs),
                    .slash => if (rhs != 0 and !(lhs == std.math.minInt(i64) and rhs == -1)) @divTrunc(lhs, rhs) else null,
                    .percent => if (rhs != 0 and !(lhs == std.math.minInt(i64) and rhs == -1)) @rem(lhs, rhs) else null,
                    .lshift => if (rhs >= 0 and rhs < 64) lhs << @intCast(rhs) else null,
                    .rshift => if (rhs >= 0 and rhs < 64) lhs >> @intCast(rhs) else null,
                    .amp => lhs & rhs,
                    .pipe => lhs | rhs,
                    .caret => lhs ^ rhs,
                    .eq => if (lhs == rhs) @as(i64, 1) else 0,
                    .ne => if (lhs != rhs) @as(i64, 1) else 0,
                    .lt => if (lhs < rhs) @as(i64, 1) else 0,
                    .le => if (lhs <= rhs) @as(i64, 1) else 0,
                    .gt => if (lhs > rhs) @as(i64, 1) else 0,
                    .ge => if (lhs >= rhs) @as(i64, 1) else 0,
                    .and_and => if (lhs != 0 and rhs != 0) @as(i64, 1) else 0,
                    .pipe_pipe => if (lhs != 0 or rhs != 0) @as(i64, 1) else 0,
                    else => null,
                };
            },
            .cast_expr => self.evalConstExpr(n.child0),
            .call_expr => blk: {
                if (n.child0 != 0 and self.ast.nodes[n.child0].kind == .identifier and
                    std.mem.eql(u8, self.text(n.child0), "@ptr_add"))
                {
                    const a0 = n.child2;
                    const a1 = if (a0 != 0) self.ast.nodes[a0].child1 else 0;
                    if (a0 != 0 and a1 != 0) {
                        const base = self.evalConstExpr(self.ast.nodes[a0].child0) orelse break :blk null;
                        const off = self.evalConstExpr(self.ast.nodes[a1].child0) orelse break :blk null;
                        break :blk std.math.add(i64, base, off) catch null;
                    }
                }
                break :blk null;
            },
            .field_access, .scoped_access => blk: {
                const base = self.ast.nodes[n.child0];
                if (base.kind == .identifier) {
                    const ename = self.text(n.child0);
                    const vname = self.text(idx);
                    if (self.ast.findEnumBySlice(self.ast.sources[0], ename)) |ei| {
                        const ed = self.ast.enum_defs[ei];
                        const vc = @min(ed.variant_count, @as(u32, @intCast(ed.variants.len)));
                        for (0..vc) |vi| {
                            const ev = ed.variants[vi];
                            if (std.mem.eql(u8, self.srcText(ev.name_start, ev.name_len, ed.source_id), vname)) {
                                break :blk ev.value;
                            }
                        }
                    }
                }
                break :blk null;
            },
            else => null,
        };
    }

    pub fn analyze(self: *Sema) SemaError!void {
        self.collectStructs();
        self.collectEnums();
        self.collectTypeAliases();
        self.collectConsts();
        self.collectFns();
        self.checkTraits();

        var i: u32 = 1;
        while (i < self.ast.count) : (i += 1) {
            if (self.ast.nodes[i].kind == .fn_decl and (self.ast.nodes[i].flags & 64) == 0) {
                self.analyzeFn(i);
            }
        }

        if (self.first_error) |err| return err;
    }

    fn collectTypeAliases(self: *Sema) void {
        const tc = @min(@as(u32, self.ast.alias_count), @as(u32, @intCast(self.ast.alias_defs.len)));
        var i: u32 = 0;
        while (i < tc) : (i += 1) {
            const td = self.ast.alias_defs[i];
            const tname = self.srcText(td.name_start, td.name_len, td.source_id);
            self.checkCrossNamespaceConflict(tname, .alias_k, td.source_id, 1, 1);
            var j: u32 = 0;
            while (j < i) : (j += 1) {
                const prev = self.ast.alias_defs[j];
                if (std.mem.eql(u8, self.srcText(prev.name_start, prev.name_len, prev.source_id), tname)) {
                    self.failAt(error.DuplicateDeclaration, td.source_id, 1, 1, @intCast(@max(tname.len, 1)), "duplicate type alias '{s}'", .{tname});
                    break;
                }
            }
        }
    }

    fn validateTypeForUnion(self: *const Sema, tag: TypeTag, extra: u32, elem: TypeTag, depth: u32) bool {
        if (depth > 16) return false;
        return switch (tag) {
            .i8, .i16, .i32, .i64, .isize, .u8, .u16, .u32, .u64, .usize, .f32, .f64, .bool => true,
            .enum_type => blk: {
                if (extra == 0 or extra - 1 >= self.ast.enum_count) break :blk false;
                break :blk !self.ast.enum_defs[extra - 1].has_payloads;
            },
            .fixed_array => self.validateTypeForUnion(elem, 0, .none, depth + 1),
            .struct_type => blk: {
                if (extra == 0 or extra - 1 >= self.ast.struct_count) break :blk false;
                const sd = self.ast.struct_defs[extra - 1];
                if (sd.is_generic) break :blk false;
                const fc = @min(sd.field_count, @as(u32, @intCast(sd.fields.len)));
                for (0..fc) |k| {
                    const f = sd.fields[k];
                    if (!self.validateTypeForUnion(f.type_tag, f.extra, f.elem_type, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn collectStructs(self: *Sema) void {
        const scount = @min(@as(u32, self.ast.struct_count), @as(u32, @intCast(self.ast.struct_defs.len)));
        var i: u32 = 0;
        while (i < scount) : (i += 1) {
            const sd = self.ast.struct_defs[i];
            if (sd.is_generic or sd.generic_param_count > 0) continue;
            const sname = self.srcText(sd.name_start, sd.name_len, sd.source_id);
            self.checkCrossNamespaceConflict(sname, .struct_k, sd.source_id, sd.line, 1);
            var j: u32 = 0;
            while (j < i) : (j += 1) {
                const prev = self.ast.struct_defs[j];
                if (prev.is_generic or prev.generic_param_count > 0) continue;
                if (std.mem.eql(u8, self.srcText(prev.name_start, prev.name_len, prev.source_id), sname)) {
                    self.failAt(error.DuplicateDeclaration, sd.source_id, sd.line, 1, @intCast(@max(sname.len, 1)), "duplicate struct '{s}'", .{sname});
                    break;
                }
            }
            const fcount = @min(sd.field_count, @as(u32, @intCast(sd.fields.len)));
            var f0: u32 = 0;
            while (f0 < fcount) : (f0 += 1) {
                const fname0 = self.srcText(sd.fields[f0].name_start, sd.fields[f0].name_len, sd.source_id);
                var f1: u32 = 0;
                while (f1 < f0) : (f1 += 1) {
                    const fname1 = self.srcText(sd.fields[f1].name_start, sd.fields[f1].name_len, sd.source_id);
                    if (std.mem.eql(u8, fname0, fname1)) {
                        self.failAt(error.DuplicateDeclaration, sd.source_id, sd.line, 1, @intCast(@max(fname0.len, 1)), "duplicate field '{s}' in struct '{s}'", .{ fname0, sname });
                        break;
                    }
                }
                if (sd.is_union) {
                    const f = sd.fields[f0];
                    if (!self.validateTypeForUnion(f.type_tag, f.extra, f.elem_type, 0)) {
                        self.failAt(error.TypeMismatch, sd.source_id, sd.line, 1, @intCast(@max(fname0.len, 1)), "unsafe union field '{s}' in '{s}': untagged unions only permit POD scalar/value types (no pointers, references, strings, handles, or closures)", .{ fname0, sname });
                    }
                }
            }
        }
    }

    fn collectEnums(self: *Sema) void {
        const ecount = @min(@as(u32, self.ast.enum_count), @as(u32, @intCast(self.ast.enum_defs.len)));
        var i: u32 = 0;
        while (i < ecount) : (i += 1) {
            const ed = self.ast.enum_defs[i];
            if (ed.is_generic or ed.generic_param_count > 0) continue;
            const ename = self.srcText(ed.name_start, ed.name_len, ed.source_id);
            self.checkCrossNamespaceConflict(ename, .enum_k, ed.source_id, ed.line, 1);
            var j: u32 = 0;
            while (j < i) : (j += 1) {
                const prev = self.ast.enum_defs[j];
                if (prev.is_generic or prev.generic_param_count > 0) continue;
                if (std.mem.eql(u8, self.srcText(prev.name_start, prev.name_len, prev.source_id), ename)) {
                    self.failAt(error.DuplicateDeclaration, ed.source_id, ed.line, 1, @intCast(@max(ename.len, 1)), "duplicate enum '{s}'", .{ename});
                    break;
                }
            }
            const vcount = @min(ed.variant_count, @as(u32, @intCast(ed.variants.len)));
            var v0: u32 = 0;
            while (v0 < vcount) : (v0 += 1) {
                const vn0 = self.srcText(ed.variants[v0].name_start, ed.variants[v0].name_len, ed.source_id);
                var v1: u32 = 0;
                while (v1 < v0) : (v1 += 1) {
                    const vn1 = self.srcText(ed.variants[v1].name_start, ed.variants[v1].name_len, ed.source_id);
                    if (std.mem.eql(u8, vn0, vn1)) {
                        self.failAt(error.DuplicateDeclaration, ed.source_id, ed.line, 1, @intCast(@max(vn0.len, 1)), "duplicate variant '{s}' in enum '{s}'", .{ vn0, ename });
                        break;
                    }
                }
            }
        }
    }

    fn collectConsts(self: *Sema) void {
        // Fixed-point evaluation across imported modules so order-independent
        // global constants (e.g. const B = A + 1 before const A = 10) resolve,
        // while cycles/non-const initializers are caught cleanly.
        var inside_block: [MAX_AST_NODES]bool = .{false} ** MAX_AST_NODES;
        var resolved: [MAX_AST_NODES]bool = .{false} ** MAX_AST_NODES;
        var i: u32 = 1;
        while (i < self.ast.count) : (i += 1) {
            if (self.ast.nodes[i].kind == .block) {
                var st = self.ast.nodes[i].child0;
                while (st != 0) : (st = self.ast.stmt_chains[st]) {
                    inside_block[st] = true;
                }
            }
        }

        // First pass: check duplicate/conflict declarations
        i = 1;
        while (i < self.ast.count) : (i += 1) {
            const n = self.ast.nodes[i];
            if (n.kind != .const_decl or inside_block[i]) continue;
            const cname = self.text(i);
            self.checkCrossNamespaceConflict(cname, .const_k, n.source_id, n.line, n.col);
        }

        // Fixed-point resolution loop
        while (true) {
            var progressed = false;
            var remaining = false;
            i = 1;
            while (i < self.ast.count) : (i += 1) {
                const n = self.ast.nodes[i];
                if (n.kind != .const_decl or inside_block[i] or resolved[i]) continue;
                const cname = self.text(i);
                if (self.lookupGlobalConst(cname) != null) {
                    self.failAt(error.DuplicateDeclaration, n.source_id, n.line, n.col, n.text_len, "duplicate const '{s}'", .{cname});
                    resolved[i] = true;
                    continue;
                }
                if (self.evalConstFloat(n.child0)) |fval| {
                    const bits: i64 = @bitCast(fval);
                    const ty = if (n.type_tag == .f32) SemaType{ .float = 32 } else SemaType.f64_t;
                    if (self.const_count < self.consts.len) {
                        self.consts[self.const_count] = .{ .name = cname, .ty = ty, .val = bits, .is_float = true };
                        self.const_count += 1;
                    }
                    self.info.is_const_val[i] = true;
                    self.info.is_float_op[i] = true;
                    self.info.const_vals[i] = bits;
                    resolved[i] = true;
                    progressed = true;
                } else if (self.evalConstExpr(n.child0)) |val| {
                    const ty = if (n.type_tag == .none) SemaType.i64_t else SemaType.fromTypeTag(n.type_tag, n.extra, .none);
                    if (self.const_count < self.consts.len) {
                        self.consts[self.const_count] = .{ .name = cname, .ty = ty, .val = val };
                        self.const_count += 1;
                    }
                    self.info.is_const_val[i] = true;
                    self.info.const_vals[i] = val;
                    resolved[i] = true;
                    progressed = true;
                } else {
                    remaining = true;
                }
            }
            if (!remaining or !progressed) break;
        }

        i = 1;
        while (i < self.ast.count) : (i += 1) {
            const n = self.ast.nodes[i];
            if (n.kind != .const_decl or inside_block[i] or resolved[i]) continue;
            const cname = self.text(i);
            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "const '{s}' initializer is not a compile-time constant expression (or has cycle)", .{cname});
        }
    }

    fn collectFns(self: *Sema) void {
        var i: u32 = 1;
        while (i < self.ast.count) : (i += 1) {
            const n = self.ast.nodes[i];
            if (n.kind != .fn_decl or (n.flags & 64) != 0) continue;
            const fname = self.text(i);
            const owner = n.extra; // 0 = free fn, struct_idx+1 = method
            if (owner == 0) {
                self.checkCrossNamespaceConflict(fname, .fn_k, n.source_id, n.line, n.col);
            }
            if (self.findFn(fname, owner) != null) {
                self.failAt(error.DuplicateDeclaration, n.source_id, n.line, n.col, n.text_len, "duplicate function '{s}'", .{fname});
                continue;
            }
            if (self.fn_count >= self.fns.len) {
                self.failAt(error.TooManySymbols, n.source_id, n.line, n.col, n.text_len, "too many function declarations", .{});
                continue;
            }

            var sig = FnSig{
                .name = fname,
                .owner_struct_plus1 = owner,
                .node_idx = i,
                .line = n.line,
                .param_count = 0,
                .param_types = .{SemaType.i64_t} ** MAX_PARAMS,
                .ret_type = if (n.type_tag == .none) .unknown else SemaType.fromTypeTag(n.type_tag, n.child1, n.elem_type),
                .has_explicit_ret = (n.type_tag != .none),
            };
            var p = n.child0;
            var seen_default = false;
            while (p != 0) : (p = self.ast.nodes[p].child1) {
                if (sig.param_count >= MAX_PARAMS) {
                    self.failAt(error.TooManyArguments, self.ast.nodes[p].source_id, self.ast.nodes[p].line, self.ast.nodes[p].col, 1, "function '{s}' exceeds maximum of {d} parameters", .{ fname, MAX_PARAMS });
                    break;
                }
                const pn = self.ast.nodes[p];
                const pty = if (pn.type_tag == .none) SemaType.i64_t else SemaType.fromTypeTag(pn.type_tag, pn.child0, pn.elem_type);
                sig.param_nodes[sig.param_count] = p;
                if (pn.child2 != 0) {
                    seen_default = true;
                    const expr = pn.child2;
                    const dn = self.ast.nodes[expr];
                    if (owner != 0) self.failAt(error.TypeMismatch, pn.source_id, pn.line, pn.col, 1, "default parameters currently require a free function", .{});
                    if (std.mem.eql(u8, fname, "main")) self.failAt(error.TypeMismatch, pn.source_id, pn.line, pn.col, 1, "entry-point parameters cannot have defaults", .{});
                    const int_value = self.evalConstExpr(expr);
                    const float_value = self.evalConstFloat(expr);
                    if (dn.kind != .string_literal and int_value == null and float_value == null) {
                        self.failAt(error.TypeMismatch, dn.source_id, dn.line, dn.col, 1, "default argument must be a scalar compile-time constant or string literal", .{});
                    } else {
                        const actual = self.analyzeExpr(expr);
                        if (!self.isExprCompatible(pty, actual, expr)) self.failAt(error.TypeMismatch, dn.source_id, dn.line, dn.col, 1, "default argument type mismatches parameter", .{});
                        if (dn.kind != .string_literal) {
                            self.info.is_const_val[expr] = true;
                            self.info.const_vals[expr] = if (float_value) |v| @bitCast(v) else int_value.?;
                        }
                    }
                } else if (seen_default) {
                    self.failAt(error.TypeMismatch, pn.source_id, pn.line, pn.col, 1, "required parameter cannot follow a default parameter", .{});
                }
                sig.param_types[sig.param_count] = pty;
                sig.param_is_mut[sig.param_count] = (pn.flags & 1) != 0;
                if (sig.param_count == 0 and owner > 0 and std.mem.eql(u8, self.text(p), "self")) {
                    if ((pn.flags & 1) != 0) sig.self_is_mut = true;
                    if ((pn.flags & 2) != 0) sig.self_is_ref = true;
                }
                sig.param_count += 1;
            }
            self.fns[self.fn_count] = sig;
            self.fn_count += 1;
        }
    }

    fn checkTraits(self: *Sema) void {
        const ic = @min(self.ast.trait_impl_count, @as(u32, @intCast(self.ast.trait_impls.len)));
        for (0..ic) |i| {
            const imp = self.ast.trait_impls[i];
            if (imp.trait_idx >= self.ast.trait_count or imp.struct_idx >= self.ast.struct_count) continue;
            const td = self.ast.trait_defs[imp.trait_idx];
            const sd = self.ast.struct_defs[imp.struct_idx];
            const tname = self.srcText(td.name.start, td.name.len, td.name.source_id);
            const sname = self.srcText(sd.name_start, sd.name_len, sd.source_id);
            for (0..td.method_count) |mi| {
                const tm = td.methods[mi];
                const mname = self.srcText(tm.name.start, tm.name.len, tm.name.source_id);
                if (self.findFn(mname, imp.struct_idx + 1) == null) {
                    self.failAt(error.UndefinedFunctionCall, sd.source_id, sd.line, 1, @intCast(@max(mname.len, 1)), "impl '{s}' for '{s}' is missing required method '{s}'", .{ tname, sname, mname });
                }
            }
        }
    }

    fn containsBreak(self: *const Sema, idx: u32) bool {
        if (idx == 0 or idx >= self.ast.count) return false;
        const n = self.ast.nodes[idx];
        return switch (n.kind) {
            .break_stmt => true,
            .block => blk: {
                var s = n.child0;
                while (s != 0) : (s = self.ast.stmt_chains[s]) {
                    if (self.containsBreak(s)) break :blk true;
                }
                break :blk false;
            },
            .if_stmt => self.containsBreak(n.child1) or self.containsBreak(n.child2),
            .defer_stmt => self.containsBreak(n.child0),
            .match_expr => blk: {
                var arm = n.child1;
                while (arm != 0) : (arm = self.ast.nodes[arm].child2) {
                    if (self.containsBreak(self.ast.nodes[arm].child1)) break :blk true;
                }
                break :blk self.containsBreak(n.child2);
            },
            // Inner nested loops absorb their own break statements
            else => false,
        };
    }

    fn stmtDefinitelyReturns(self: *const Sema, idx: u32) bool {
        if (idx == 0 or idx >= self.ast.count) return false;
        if (self.info.is_tail_expr[idx]) return true;
        const n = self.ast.nodes[idx];
        return switch (n.kind) {
            .return_stmt, .unreachable_stmt => true,
            .expr_stmt => if (n.child0 != 0) self.stmtDefinitelyReturns(n.child0) else false,
            .block => self.blockDefinitelyReturns(idx, false),
            .if_stmt => n.child2 != 0 and self.stmtDefinitelyReturns(n.child1) and self.stmtDefinitelyReturns(n.child2),
            .while_stmt => blk: {
                if (self.evalConstExpr(n.child0)) |cv| {
                    if (cv != 0 and !self.containsBreak(n.child1)) break :blk true;
                }
                break :blk false;
            },
            .match_expr => blk: {
                if (n.child2 == 0 and self.info.enum_def_idx[idx] == 0) break :blk false;
                var arm = n.child1;
                while (arm != 0) : (arm = self.ast.nodes[arm].child2) {
                    if (!self.stmtDefinitelyReturns(self.ast.nodes[arm].child1)) break :blk false;
                }
                break :blk if (n.child2 != 0) self.stmtDefinitelyReturns(n.child2) else true;
            },
            .call_expr, .method_call => self.info.node_types[idx] == .never,
            else => self.info.node_types[idx] == .never,
        };
    }

    fn blockDefinitelyReturns(self: *const Sema, block_idx: u32, is_fn_root: bool) bool {
        if (block_idx == 0 or block_idx >= self.ast.count) return false;
        var stmt = self.ast.nodes[block_idx].child0;
        while (stmt != 0) {
            const next = self.ast.stmt_chains[stmt];
            if (self.stmtDefinitelyReturns(stmt)) return true;
            if (is_fn_root and next == 0 and self.info.is_tail_expr[stmt]) return true;
            stmt = next;
        }
        return false;
    }

    fn stmtDefinitelyExitsBlock(self: *const Sema, idx: u32) bool {
        if (idx == 0 or idx >= self.ast.count) return false;
        const n = self.ast.nodes[idx];
        return switch (n.kind) {
            .return_stmt, .break_stmt, .continue_stmt, .unreachable_stmt => true,
            .expr_stmt => if (n.child0 != 0) self.stmtDefinitelyExitsBlock(n.child0) else false,
            .block => blk: {
                var s = n.child0;
                while (s != 0) {
                    if (self.stmtDefinitelyExitsBlock(s)) break :blk true;
                    s = self.ast.stmt_chains[s];
                }
                break :blk false;
            },
            .if_stmt => n.child2 != 0 and self.stmtDefinitelyExitsBlock(n.child1) and self.stmtDefinitelyExitsBlock(n.child2),
            else => self.info.node_types[idx] == .never,
        };
    }

    fn mergeBranchResStates(a: ResState, b: ResState) ResState {
        if (a == b) return a;
        if ((a == .freed or a == .maybe_freed) and (b == .freed or b == .maybe_freed)) {
            return if (a == .freed and b == .freed) .freed else .maybe_freed;
        }
        if (a == .freed or b == .freed or a == .maybe_freed or b == .maybe_freed) {
            return .maybe_freed;
        }
        if ((a == .fd_closed or a == .fd_maybe_closed) and (b == .fd_closed or b == .fd_maybe_closed)) {
            return if (a == .fd_closed and b == .fd_closed) .fd_closed else .fd_maybe_closed;
        }
        if (a == .fd_closed or b == .fd_closed or a == .fd_maybe_closed or b == .fd_maybe_closed) {
            return .fd_maybe_closed;
        }
        if (a == .escaped or b == .escaped) return .escaped;
        return a;
    }

    fn checkConstPtrValid(self: *Sema, arg_idx: u32, allow_null: bool, ctx_desc: []const u8) void {
        if (arg_idx == 0 or arg_idx >= self.ast.count) return;
        const val = self.evalConstExpr(arg_idx) orelse return;
        if (allow_null and val == 0) return;
        const uval: u64 = @bitCast(val);
        if (val < 0 or uval < 4096) {
            const n = self.ast.nodes[arg_idx];
            self.failAt(
                error.TypeMismatch,
                n.source_id,
                n.line,
                n.col,
                @max(n.text_len, 1),
                "compile-time invalid {s} pointer address 0x{x} (null, low-page <4096, or kernel-space)",
                .{ ctx_desc, uval },
            );
        }
    }

    const AllocPtrRef = struct { var_idx: u32, off: i64 };

    fn extractAllocVarAndOffset(self: *const Sema, expr_idx: u32) ?AllocPtrRef {
        if (expr_idx == 0 or expr_idx >= self.ast.count) return null;
        const n = self.ast.nodes[expr_idx];
        switch (n.kind) {
            .cast_expr => return self.extractAllocVarAndOffset(n.child0),
            .identifier => {
                const vi = self.lookupVarIdx(self.text(expr_idx)) orelse return null;
                if (self.vars[vi].heap_alloc_size > 0) {
                    return .{ .var_idx = vi, .off = 0 };
                }
                return null;
            },
            .call_expr => {
                if (n.child0 != 0 and self.ast.nodes[n.child0].kind == .identifier and
                    std.mem.eql(u8, self.text(n.child0), "@ptr_add"))
                {
                    const a0 = n.child2;
                    const a1 = if (a0 != 0) self.ast.nodes[a0].child1 else 0;
                    if (a0 != 0 and a1 != 0) {
                        const base = self.extractAllocVarAndOffset(self.ast.nodes[a0].child0) orelse return null;
                        const off = self.evalConstExpr(self.ast.nodes[a1].child0) orelse return null;
                        const sum = std.math.add(i64, base.off, off) catch return null;
                        return .{ .var_idx = base.var_idx, .off = sum };
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    fn checkHeapBounds(self: *Sema, ptr_expr: u32, access_bytes: i64, ctx_node_idx: u32) void {
        if (access_bytes < 0) return;
        const ref = self.extractAllocVarAndOffset(ptr_expr) orelse return;
        const v = self.vars[ref.var_idx];
        if (v.heap_alloc_size <= 0) return;
        const end_off = std.math.add(i64, ref.off, access_bytes) catch {
            const n = self.ast.nodes[ctx_node_idx];
            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "compile-time heap buffer overflow on '{s}'", .{v.name});
            return;
        };
        if (ref.off < 0 or end_off > v.heap_alloc_size) {
            const n = self.ast.nodes[ctx_node_idx];
            self.failAt(
                error.TypeMismatch,
                n.source_id,
                n.line,
                n.col,
                1,
                "compile-time heap buffer overflow on '{s}': access [{d}..{d}) exceeds @malloc({d}) bounds",
                .{ v.name, ref.off, end_off, v.heap_alloc_size },
            );
        }
    }

    fn markExprEscaped(self: *Sema, idx: u32) void {
        if (idx == 0 or idx >= self.ast.count) return;
        const n = self.ast.nodes[idx];
        switch (n.kind) {
            .identifier => {
                if (self.lookupVarIdx(self.text(idx))) |vi| {
                    if (self.vars[vi].res_state == .heap_alive or self.vars[vi].res_state == .fd_alive) {
                        self.vars[vi].res_state = .escaped;
                    }
                }
            },
            .cast_expr, .try_expr, .comptime_expr => self.markExprEscaped(n.child0),
            .call_expr => {
                if (n.child0 != 0 and self.ast.nodes[n.child0].kind == .identifier and
                    std.mem.eql(u8, self.text(n.child0), "@ptr_add") and n.child2 != 0)
                {
                    self.markExprEscaped(self.ast.nodes[n.child2].child0);
                } else {
                    var ai = n.child2;
                    while (ai != 0) : (ai = self.ast.nodes[ai].child1) {
                        self.markExprEscaped(self.ast.nodes[ai].child0);
                    }
                }
            },
            .ternary_expr => {
                self.markExprEscaped(n.child1);
                self.markExprEscaped(n.child2);
            },
            .array_lit, .tuple_lit => {
                if (n.kind == .array_lit and (n.flags & 1) != 0) {
                    self.markExprEscaped(n.child0);
                    return;
                }
                var elem = n.child0;
                while (elem != 0) : (elem = self.ast.nodes[elem].child1) {
                    self.markExprEscaped(self.ast.nodes[elem].child0);
                }
            },
            .map_lit => {
                var pair = n.child0;
                while (pair != 0) : (pair = self.ast.nodes[pair].child1) {
                    self.markExprEscaped(self.ast.nodes[pair].child0);
                    self.markExprEscaped(self.ast.nodes[pair].child2);
                }
            },
            .struct_init => {
                var fi = n.child2;
                while (fi != 0) : (fi = self.ast.nodes[fi].child1) {
                    self.markExprEscaped(self.ast.nodes[fi].child0);
                }
            },
            else => {},
        }
    }

    fn exprUsesVar(self: *const Sema, idx: u32, target: []const u8) bool {
        if (idx == 0 or idx >= self.ast.count) return false;
        const n = self.ast.nodes[idx];
        return switch (n.kind) {
            .identifier => std.mem.eql(u8, self.text(idx), target),
            .unary_expr, .cast_expr, .deref, .addr_of, .try_expr, .comptime_expr => self.exprUsesVar(n.child0, target),
            .binary_expr, .index_expr, .coalesce_expr => self.exprUsesVar(n.child0, target) or self.exprUsesVar(n.child1, target),
            .ternary_expr => self.exprUsesVar(n.child0, target) or self.exprUsesVar(n.child1, target) or self.exprUsesVar(n.child2, target),
            .field_access => self.exprUsesVar(n.child0, target),
            .call_expr, .method_call, .scoped_access => blk: {
                if (self.exprUsesVar(n.child0, target)) break :blk true;
                var ai = n.child2;
                while (ai != 0) : (ai = self.ast.nodes[ai].child1) {
                    if (self.exprUsesVar(self.ast.nodes[ai].child0, target)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn decodedStringLiteralBytes(raw: []const u8, out: []u8) usize {
        var len: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            var ch = raw[i];
            if (ch == '\\' and i + 1 < raw.len) {
                i += 1;
                ch = switch (raw[i]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '\\' => '\\',
                    '"' => '"',
                    '\'' => '\'',
                    '0' => 0,
                    'x' => blk: {
                        if (i + 2 < raw.len) {
                            const b = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch 'x';
                            i += 2;
                            break :blk b;
                        }
                        break :blk 'x';
                    },
                    else => raw[i],
                };
            }
            if (len < out.len) out[len] = ch;
            len += 1;
        }
        return len;
    }

    fn collectExprVarNames(self: *const Sema, idx: u32, names: *[16][]const u8, count: *u32) void {
        if (idx == 0 or idx >= self.ast.count or count.* >= names.len) return;
        const n = self.ast.nodes[idx];
        switch (n.kind) {
            .int_literal, .float_literal, .string_literal => {},
            .identifier => {
                const nm = self.text(idx);
                if (nm.len > 0 and self.lookupGlobalConst(nm) == null) {
                    if (self.lookupVar(nm)) |ve| {
                        if (ve.is_const) return;
                    }
                    for (names[0..count.*]) |ex| {
                        if (std.mem.eql(u8, ex, nm)) return;
                    }
                    names[count.*] = nm;
                    count.* += 1;
                }
            },
            .unary_expr, .cast_expr, .deref, .addr_of, .try_expr, .comptime_expr, .field_access => {
                self.collectExprVarNames(n.child0, names, count);
            },
            .binary_expr, .index_expr, .coalesce_expr => {
                self.collectExprVarNames(n.child0, names, count);
                self.collectExprVarNames(n.child1, names, count);
            },
            .ternary_expr => {
                self.collectExprVarNames(n.child0, names, count);
                self.collectExprVarNames(n.child1, names, count);
                self.collectExprVarNames(n.child2, names, count);
            },
            else => {
                // Any call/match/complex expr inside while condition counts as dynamic
                if (count.* < names.len) {
                    names[count.*] = "*";
                    count.* += 1;
                }
            },
        }
    }

    fn bodyHasLoopProgress(self: *const Sema, idx: u32, cond_vars: []const []const u8) bool {
        if (idx == 0 or idx >= self.ast.count) return false;
        const n = self.ast.nodes[idx];
        switch (n.kind) {
            .return_stmt, .break_stmt, .unreachable_stmt, .call_expr, .method_call, .spawn_expr => return true,
            .expr_stmt => return if (n.child0 != 0) self.bodyHasLoopProgress(n.child0, cond_vars) else false,
            .block => {
                var s = n.child0;
                while (s != 0) {
                    if (self.bodyHasLoopProgress(s, cond_vars)) return true;
                    s = self.ast.stmt_chains[s];
                }
                return false;
            },
            .assign_stmt => {
                if (n.text_len == 0) return true; // pointer / field / array memory store
                const lhs = self.text(idx);
                for (cond_vars) |cv| {
                    if (std.mem.eql(u8, cv, lhs) or std.mem.eql(u8, cv, "*")) return true;
                }
                return self.bodyHasLoopProgress(n.child0, cond_vars) or self.bodyHasLoopProgress(n.child1, cond_vars);
            },
            .let_stmt => return if (n.child0 != 0) self.bodyHasLoopProgress(n.child0, cond_vars) else false,
            .if_stmt => {
                return self.bodyHasLoopProgress(n.child0, cond_vars) or
                    self.bodyHasLoopProgress(n.child1, cond_vars) or
                    self.bodyHasLoopProgress(n.child2, cond_vars);
            },
            .while_stmt => {
                return self.bodyHasLoopProgress(n.child0, cond_vars) or self.bodyHasLoopProgress(n.child1, cond_vars);
            },
            .for_stmt => return self.bodyHasLoopProgress(n.child1, cond_vars),
            .match_expr => {
                if (self.bodyHasLoopProgress(n.child0, cond_vars)) return true;
                var arm = n.child1;
                while (arm != 0) : (arm = self.ast.nodes[arm].child2) {
                    if (self.bodyHasLoopProgress(self.ast.nodes[arm].child1, cond_vars)) return true;
                }
                return self.bodyHasLoopProgress(n.child2, cond_vars);
            },
            .defer_stmt => return self.bodyHasLoopProgress(n.child0, cond_vars),
            else => return false,
        }
    }

    fn checkWhileSpinSafety(self: *Sema, while_idx: u32) void {
        const n = self.ast.nodes[while_idx];
        if (self.evalConstExpr(n.child0)) |cv| {
            if (cv == 0) return; // `while false` is statically dead and optimized away
        }
        var cond_vars: [16][]const u8 = undefined;
        var cond_var_count: u32 = 0;
        self.collectExprVarNames(n.child0, &cond_vars, &cond_var_count);
        for (cond_vars[0..cond_var_count]) |cv| {
            if (std.mem.eql(u8, cv, "*")) return;
        }
        if (!self.bodyHasLoopProgress(n.child1, cond_vars[0..cond_var_count])) {
            self.failAt(
                error.TypeMismatch,
                n.source_id,
                n.line,
                n.col,
                5,
                "compile-time non-terminating spin loop: loop condition never changes and body has no exit or call",
                .{},
            );
        }
    }

    fn analyzeFn(self: *Sema, fn_idx: u32) void {
        const fn_node = self.ast.nodes[fn_idx];
        const sig = self.findFn(self.text(fn_idx), fn_node.extra) orelse return;
        self.cur_ret_type = sig.ret_type;
        self.cur_has_explicit_ret = sig.has_explicit_ret;
        self.var_count = 0;
        self.scope_depth = 0;
        self.loop_depth = 0;
        self.defer_depth = 0;
        self.closure_var_base = 0;
        self.cur_closure_id = 0;
        self.cur_fn_stack_bytes = 0;
        self.skip_res_check_node = 0;

        self.pushScope();
        var p = fn_node.child0;
        var pidx: u32 = 0;
        while (p != 0) : (p = self.ast.nodes[p].child1) {
            const pn = self.ast.nodes[p];
            const pname = self.text(p);
            const pty: SemaType = if (pidx < sig.param_count) sig.param_types[pidx] else SemaType.i64_t;
            const pmut: bool = if (pidx < sig.param_count) sig.param_is_mut[pidx] else false;
            self.addVar(pname, pty, pmut, pn.source_id, pn.line, pn.col);
            if (self.var_count > 0 and pidx == 0 and sig.self_is_ref) {
                self.vars[self.var_count - 1].is_ref_imm = true;
            }
            pidx += 1;
        }

        const body = fn_node.child2;
        if (body != 0 and body < self.ast.count) {
            self.analyzeBlock(body, false, true);
            if (sig.has_explicit_ret and sig.ret_type != .void and sig.ret_type != .never) {
                if (!self.blockDefinitelyReturns(body, true)) {
                    self.failAt(
                        error.TypeMismatch,
                        fn_node.source_id,
                        fn_node.line,
                        fn_node.col,
                        fn_node.text_len,
                        "non-void function '{s}' may reach end without returning a value",
                        .{sig.name},
                    );
                }
            }
        }
        self.popScope();
    }

    fn analyzeBlockValue(self: *Sema, block_idx: u32) SemaType {
        self.pushScope();
        var res_ty: SemaType = .void;
        var stmt = self.ast.nodes[block_idx].child0;
        while (stmt != 0) {
            const next = self.ast.stmt_chains[stmt];
            const is_last = (next == 0);
            const sk = self.ast.nodes[stmt].kind;
            if (is_last and (isExprKind(sk) or (sk == .if_stmt and self.ast.nodes[stmt].child2 != 0 and !self.stmtDefinitelyReturns(stmt)))) {
                res_ty = self.analyzeExpr(stmt);
                self.markExprEscaped(stmt);
                if (res_ty != .void and res_ty != .never) {
                    self.info.is_tail_expr[stmt] = true;
                }
            } else {
                self.analyzeStmt(stmt);
                if (is_last and self.stmtDefinitelyReturns(stmt)) res_ty = .never;
            }
            stmt = next;
        }
        self.popScope();
        return res_ty;
    }

    fn analyzeBlock(self: *Sema, block_idx: u32, create_scope: bool, is_fn_root: bool) void {
        if (create_scope) self.pushScope();
        var stmt = self.ast.nodes[block_idx].child0;
        while (stmt != 0) {
            const next = self.ast.stmt_chains[stmt];
            const is_last = (next == 0);
            const sk = self.ast.nodes[stmt].kind;
            if (is_fn_root and is_last and (isExprKind(sk) or (sk == .if_stmt and self.ast.nodes[stmt].child2 != 0 and !self.stmtDefinitelyReturns(stmt)))) {
                const ty = self.analyzeExpr(stmt);
                self.markExprEscaped(stmt);
                if (ty != .void and ty != .never) {
                    self.info.is_tail_expr[stmt] = true;
                    if (self.cur_has_explicit_ret and self.cur_ret_type != .void and
                        !self.isExprCompatible(self.cur_ret_type, ty, stmt))
                    {
                        const sn = self.ast.nodes[stmt];
                        self.failAt(error.TypeMismatch, sn.source_id, sn.line, sn.col, 1, "tail expression type mismatches declared return type", .{});
                    }
                    if (self.checkExprLocalRefOrigin(stmt) != 0) {
                        const sn = self.ast.nodes[stmt];
                        self.failAt(error.TypeMismatch, sn.source_id, sn.line, sn.col, 1, "dangling reference: cannot return pointer/reference to local stack variable", .{});
                    }
                    if (ty == .fn_t) {
                        const sn = self.ast.nodes[stmt];
                        if (sn.kind == .closure_expr) {
                            const cid1 = self.info.closure_ids[stmt];
                            if (cid1 > 0 and cid1 - 1 < self.info.closure_count and self.info.closures[cid1 - 1].captures_local_ref) {
                                self.failAt(error.TypeMismatch, sn.source_id, sn.line, sn.col, 1, "dangling reference: cannot return closure capturing local stack reference", .{});
                            }
                        } else if (sn.kind == .identifier) {
                            if (self.lookupVar(self.text(stmt))) |ve| {
                                if (ve.holds_local_ref_closure) {
                                    self.failAt(error.TypeMismatch, sn.source_id, sn.line, sn.col, 1, "dangling reference: cannot return closure capturing local stack reference", .{});
                                }
                            }
                        }
                    }
                }
            } else {
                self.analyzeStmt(stmt);
            }
            stmt = next;
        }
        if (create_scope) self.popScope();
    }

    pub fn isExprKind(kind: NodeKind) bool {
        return switch (kind) {
            .call_expr,
            .method_call,
            .scoped_access,
            .binary_expr,
            .unary_expr,
            .cast_expr,
            .identifier,
            .int_literal,
            .float_literal,
            .string_literal,
            .struct_init,
            .field_access,
            .addr_of,
            .deref,
            .index_expr,
            .ternary_expr,
            .match_expr,
            .array_lit,
            .tuple_lit,
            .closure_expr,
            .try_expr,
            .coalesce_expr,
            .comptime_expr,
            .list_comp,
            .map_lit,
            .spawn_expr,
            .interp_string,
            .generic_call,
            => true,
            else => false,
        };
    }

    fn tagTraitImplIfDyn(self: *Sema, expected: SemaType, actual: SemaType, expr_idx: u32) void {
        if (expr_idx == 0 or expected != .dyn_trait) return;
        const si: u32 = switch (actual) {
            .struct_t => |s| s,
            .ptr_struct => |s| s,
            else => return,
        };
        if (self.findTraitImpl(expected.dyn_trait, si)) |imp_i| {
            self.info.trait_impl_idx[expr_idx] = @intCast(imp_i + 1);
        }
    }

    fn analyzeStmt(self: *Sema, stmt_idx: u32) void {
        if (stmt_idx == 0 or stmt_idx >= self.ast.count) return;
        const n = self.ast.nodes[stmt_idx];
        switch (n.kind) {
            .block => self.analyzeBlock(stmt_idx, true, false),
            .let_stmt => {
                if ((n.flags & 4) != 0 and n.child2 != 0) {
                    const rhs_ty = if (n.child0 != 0) self.analyzeExpr(n.child0) else SemaType.unknown;
                    self.markExprEscaped(n.child0);
                    const tdesc = if (rhs_ty == .tuple_t) self.getTupleDesc(rhs_ty.tuple_t) else null;
                    var pattern_count: u32 = 0;
                    var cursor = self.ast.nodes[n.child2].child0;
                    while (cursor != 0) : (cursor = self.ast.nodes[cursor].child1) pattern_count += 1;
                    if (tdesc == null or pattern_count != tdesc.?.param_count) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "tuple destructuring requires a tuple with the same number of fields", .{});
                    }
                    var p = self.ast.nodes[n.child2].child0;
                    var pi: usize = 0;
                    while (p != 0) : ({
                        p = self.ast.nodes[p].child1;
                        pi += 1;
                    }) {
                        const pn = self.ast.nodes[p];
                        const pname = self.text(p);
                        const elem_ty: SemaType = if (tdesc != null and pi < tdesc.?.param_count)
                            SemaType.fromTypeTag(tdesc.?.param_tags[pi], tdesc.?.param_extras[pi], tdesc.?.param_elems[pi])
                        else
                            SemaType.i64_t;
                        self.addVar(pname, elem_ty, (pn.flags & 1) != 0, pn.source_id, pn.line, pn.col);
                        self.info.node_types[p] = elem_ty;
                    }
                    self.info.node_types[stmt_idx] = rhs_ty;
                    return;
                }
                const var_name = self.text(stmt_idx);
                if (n.child0 == 0) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, @max(n.text_len, 1), "variable '{s}' must be explicitly initialized", .{var_name});
                }
                var ty: SemaType = SemaType.i64_t;
                if (n.child0 != 0) {
                    ty = self.analyzeExpr(n.child0);
                }
                if (n.type_tag != .none) {
                    const ann = SemaType.fromTypeTag(n.type_tag, n.extra, n.elem_type);
                    if (n.child0 != 0 and !self.isExprCompatible(ann, ty, n.child0)) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "initializer type is incompatible with annotation on '{s}'", .{var_name});
                    }
                    self.tagTraitImplIfDyn(ann, ty, n.child0);
                    ty = ann;
                } else if (ty == .null_t) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, @max(n.text_len, 1), "cannot infer pointer type for 'null' initializer on '{s}'; add type annotation", .{var_name});
                }
                if (ty == .fixed_array) {
                    const fa_bytes: u64 = @as(u64, ty.fixed_array.len) * 8;
                    self.cur_fn_stack_bytes +|= fa_bytes;
                    if (self.cur_fn_stack_bytes > 32768) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, @max(n.text_len, 1), "stack-allocated fixed array '{s}' exceeds safe 32 KiB per-function stack budget; use @malloc or @array_new", .{var_name});
                    }
                }
                self.addVar(var_name, ty, (n.flags & 1) != 0, n.source_id, n.line, n.col);
                if (self.var_count > 0 and n.child0 != 0) {
                    const new_vi = self.var_count - 1;
                    var init_idx = n.child0;
                    while (init_idx != 0 and self.ast.nodes[init_idx].kind == .cast_expr) {
                        init_idx = self.ast.nodes[init_idx].child0;
                    }
                    const init_n = self.ast.nodes[init_idx];
                    self.vars[new_vi].local_ref_origin = self.checkExprLocalRefOrigin(n.child0);
                    if (init_n.kind == .closure_expr) {
                        const cid1 = self.info.closure_ids[init_idx];
                        if (cid1 > 0 and cid1 - 1 < self.info.closure_count and self.info.closures[cid1 - 1].captures_local_ref) {
                            self.vars[new_vi].holds_local_ref_closure = true;
                        }
                    } else if (init_n.kind == .identifier) {
                        if (self.lookupVarIdx(self.text(init_idx))) |src_vi| {
                            self.vars[new_vi].holds_local_ref_closure = self.vars[src_vi].holds_local_ref_closure;
                            if (self.vars[src_vi].alias_root >= 0) {
                                self.vars[new_vi].alias_root = self.vars[src_vi].alias_root;
                            } else if (self.vars[src_vi].res_state == .heap_alive or self.vars[src_vi].res_state == .fd_alive) {
                                self.vars[new_vi].alias_root = @intCast(src_vi);
                            }
                        }
                    }
                    if (init_n.kind == .addr_of and self.ast.nodes[init_n.child0].kind == .identifier) {
                        if (self.lookupVarIdx(self.text(init_n.child0))) |tgt_vi| {
                            const is_mb = (init_n.flags & 1) != 0;
                            self.vars[new_vi].borrow_target = @intCast(tgt_vi);
                            self.vars[new_vi].borrow_is_mut = is_mb;
                            if (is_mb) {
                                self.vars[tgt_vi].mut_borrowed = true;
                            } else {
                                self.vars[tgt_vi].shared_borrows += 1;
                            }
                        }
                    }
                    if (init_n.kind == .spawn_expr) {
                        const cl_node = if (init_n.child0 != 0 and self.ast.nodes[init_n.child0].kind == .closure_expr) init_n.child0 else 0;
                        if (cl_node != 0) {
                            const cid1 = self.info.closure_ids[cl_node];
                            if (cid1 > 0 and cid1 - 1 < self.info.closure_count) {
                                const cl = self.info.closures[cid1 - 1];
                                for (0..cl.capture_count) |k| {
                                    const cvi = cl.cap_var_indices[k];
                                    if (cvi < new_vi and
                                        (self.vars[cvi].res_state == .heap_alive or self.vars[cvi].res_state == .escaped) and
                                        (self.vars[cvi].ty == .ptr or self.vars[cvi].ty == .ptr_struct or self.vars[cvi].ty == .array or self.vars[cvi].ty == .map_t))
                                    {
                                        self.vars[cvi].thread_active = true;
                                        self.vars[cvi].thread_handle_var = @intCast(new_vi);
                                    }
                                }
                            }
                        }
                    } else if (init_n.kind == .call_expr and init_n.child0 != 0 and self.ast.nodes[init_n.child0].kind == .identifier) {
                        const cn = self.text(init_n.child0);
                        if (std.mem.eql(u8, cn, "@malloc") or std.mem.eql(u8, cn, "@alloc")) {
                            self.vars[new_vi].res_state = .heap_alive;
                            self.vars[new_vi].alloc_loop_depth = self.loop_depth;
                            if (init_n.child2 != 0) {
                                if (self.evalConstExpr(self.ast.nodes[init_n.child2].child0)) |sz| {
                                    if (sz > 0) self.vars[new_vi].heap_alloc_size = sz;
                                }
                            }
                        } else if (std.mem.eql(u8, cn, "@array_new") or std.mem.eql(u8, cn, "@map_new")) {
                            self.vars[new_vi].res_state = .heap_alive;
                            self.vars[new_vi].alloc_loop_depth = self.loop_depth;
                        } else if (std.mem.eql(u8, cn, "@open")) {
                            self.vars[new_vi].res_state = .fd_alive;
                            self.vars[new_vi].alloc_loop_depth = self.loop_depth;
                        }
                    } else if (init_n.kind == .identifier) {
                        self.markExprEscaped(n.child0);
                    }
                }
                self.info.node_types[stmt_idx] = ty;
            },
            .const_decl => {
                const cname = self.text(stmt_idx);
                if (self.evalConstFloat(n.child0)) |fval| {
                    const bits: i64 = @bitCast(fval);
                    const ty = if (n.type_tag == .f32) SemaType{ .float = 32 } else SemaType.f64_t;
                    self.addConstLocal(cname, ty, bits, n.source_id, n.line, n.col);
                    if (self.var_count > 0) self.vars[self.var_count - 1].is_float = true;
                    self.info.is_const_val[stmt_idx] = true;
                    self.info.is_float_op[stmt_idx] = true;
                    self.info.const_vals[stmt_idx] = bits;
                } else {
                    const val = self.evalConstExpr(n.child0) orelse blk: {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "local const '{s}' must be a compile-time constant expression", .{cname});
                        break :blk 0;
                    };
                    const ty = if (n.type_tag == .none) SemaType.i64_t else SemaType.fromTypeTag(n.type_tag, n.extra, .none);
                    self.addConstLocal(cname, ty, val, n.source_id, n.line, n.col);
                    self.info.is_const_val[stmt_idx] = true;
                    self.info.const_vals[stmt_idx] = val;
                }
            },
            .defer_stmt => {
                self.defer_depth += 1;
                self.analyzeStmt(n.child0);
                self.defer_depth -= 1;
            },
            .assign_stmt => {
                if (n.text_len > 0) {
                    const vname = self.text(stmt_idx);
                    const rhs_ty = self.analyzeExpr(n.child0);
                    if ((n.op == @intFromEnum(TokenKind.slash_eq) or n.op == @intFromEnum(TokenKind.percent_eq))) {
                        if (self.evalConstExpr(n.child0)) |rhs_val| {
                            if (rhs_val == 0) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "compound division or modulo by constant zero", .{});
                            }
                        }
                    }
                    if (n.op == @intFromEnum(TokenKind.lshift_eq) or n.op == @intFromEnum(TokenKind.rshift_eq)) {
                        if (self.evalConstExpr(n.child0)) |sv| {
                            if (sv < 0 or sv >= 64) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "compile-time invalid shift amount {d} in compound shift (must be 0..63)", .{sv});
                            }
                        }
                    }
                    if (self.lookupVarIdx(vname)) |vi| {
                        const ve = self.vars[vi];
                        if (ve.ty == .float or rhs_ty == .float) self.info.is_float_op[stmt_idx] = true;
                        if (ve.ty.isUnsigned()) self.info.is_unsigned_op[stmt_idx] = true;
                        if (ve.is_const) {
                            self.failAt(error.InvalidAssignmentTarget, n.source_id, n.line, n.col, n.text_len, "cannot assign to constant '{s}'", .{vname});
                        } else if (!ve.is_mut) {
                            self.failAt(error.InvalidAssignmentTarget, n.source_id, n.line, n.col, n.text_len, "cannot assign to immutable variable '{s}'; declare with 'var' or 'let mut'", .{vname});
                        } else if (ve.shared_borrows > 0 or ve.mut_borrowed) {
                            self.failAt(error.InvalidAssignmentTarget, n.source_id, n.line, n.col, n.text_len, "cannot assign to '{s}' while it is borrowed", .{vname});
                        } else if (self.in_spawn and vi < self.closure_var_base) {
                            self.failAt(error.InvalidAssignmentTarget, n.source_id, n.line, n.col, n.text_len, "cannot mutate captured outer variable '{s}' inside spawn", .{vname});
                        } else if (n.op != @intFromEnum(TokenKind.assign)) {
                            if (ve.res_state == .freed or ve.res_state == .maybe_freed) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "compile-time use-after-free on '{s}'", .{vname});
                            } else if (ve.res_state == .fd_closed or ve.res_state == .fd_maybe_closed) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "compile-time use-after-close on file descriptor '{s}'", .{vname});
                            }
                            if (!ve.ty.isScalar() or !rhs_ty.isScalar()) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "compound assignment requires scalar operands", .{});
                            }
                        } else if (!self.isExprCompatible(ve.ty, rhs_ty, n.child0)) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "incompatible assignment to variable '{s}'", .{vname});
                        } else {
                            self.tagTraitImplIfDyn(ve.ty, rhs_ty, n.child0);
                            if (ve.res_state == .heap_alive and ve.alloc_loop_depth > 0 and !ve.has_deferred_free and !self.exprUsesVar(n.child0, vname)) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "overwriting unfreed heap allocation '{s}' inside loop leaks memory", .{vname});
                            } else if (ve.res_state == .fd_alive and ve.alloc_loop_depth > 0 and !self.exprUsesVar(n.child0, vname)) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "overwriting unclosed file descriptor '{s}' inside loop leaks resource", .{vname});
                            }
                            if (self.vars[vi].borrow_target >= 0) {
                                const old_bt: usize = @intCast(self.vars[vi].borrow_target);
                                if (old_bt < self.var_count) {
                                    if (self.vars[vi].borrow_is_mut) {
                                        self.vars[old_bt].mut_borrowed = false;
                                    } else if (self.vars[old_bt].shared_borrows > 0) {
                                        self.vars[old_bt].shared_borrows -= 1;
                                    }
                                }
                                self.vars[vi].borrow_target = -1;
                                self.vars[vi].borrow_is_mut = false;
                            }
                            const orig = self.checkExprLocalRefOrigin(n.child0);
                            if (orig != 0 and orig - 1 < self.var_count and self.vars[orig - 1].scope_depth > ve.scope_depth) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "dangling reference: cannot assign pointer/reference to inner local '{s}' into outer variable '{s}'", .{ self.vars[orig - 1].name, vname });
                            }
                            self.vars[vi].local_ref_origin = orig;
                            if (!self.exprUsesVar(n.child0, vname)) {
                                self.markExprEscaped(n.child0);
                                self.vars[vi].res_state = .normal;
                                self.vars[vi].heap_alloc_size = -1;
                                self.vars[vi].has_deferred_free = false;
                                self.vars[vi].alias_root = -1;
                                self.vars[vi].holds_local_ref_closure = false;
                                var rhs_idx = n.child0;
                                while (rhs_idx != 0 and self.ast.nodes[rhs_idx].kind == .cast_expr) {
                                    rhs_idx = self.ast.nodes[rhs_idx].child0;
                                }
                                const rn = self.ast.nodes[rhs_idx];
                                if (rn.kind == .closure_expr) {
                                    const cid1 = self.info.closure_ids[rhs_idx];
                                    if (cid1 > 0 and cid1 - 1 < self.info.closure_count and self.info.closures[cid1 - 1].captures_local_ref) {
                                        self.vars[vi].holds_local_ref_closure = true;
                                    }
                                } else if (rn.kind == .identifier) {
                                    if (self.lookupVarIdx(self.text(rhs_idx))) |src_vi| {
                                        self.vars[vi].holds_local_ref_closure = self.vars[src_vi].holds_local_ref_closure;
                                        if (self.vars[src_vi].alias_root >= 0) {
                                            self.vars[vi].alias_root = self.vars[src_vi].alias_root;
                                        } else if (self.vars[src_vi].res_state == .heap_alive or self.vars[src_vi].res_state == .fd_alive) {
                                            self.vars[vi].alias_root = @intCast(src_vi);
                                        }
                                    }
                                } else if (rn.kind == .addr_of and self.ast.nodes[rn.child0].kind == .identifier) {
                                    if (self.lookupVarIdx(self.text(rn.child0))) |tgt_vi| {
                                        const is_mb = (rn.flags & 1) != 0;
                                        self.vars[vi].borrow_target = @intCast(tgt_vi);
                                        self.vars[vi].borrow_is_mut = is_mb;
                                        if (is_mb) {
                                            self.vars[tgt_vi].mut_borrowed = true;
                                        } else {
                                            self.vars[tgt_vi].shared_borrows += 1;
                                        }
                                    }
                                } else if (rn.kind == .call_expr and rn.child0 != 0 and self.ast.nodes[rn.child0].kind == .identifier) {
                                    const cn = self.text(rn.child0);
                                    if (std.mem.eql(u8, cn, "@malloc") or std.mem.eql(u8, cn, "@alloc")) {
                                        self.vars[vi].res_state = .heap_alive;
                                        self.vars[vi].alloc_loop_depth = self.loop_depth;
                                        if (rn.child2 != 0) {
                                            if (self.evalConstExpr(self.ast.nodes[rn.child2].child0)) |sz| {
                                                if (sz > 0) self.vars[vi].heap_alloc_size = sz;
                                            }
                                        }
                                    } else if (std.mem.eql(u8, cn, "@array_new") or std.mem.eql(u8, cn, "@map_new")) {
                                        self.vars[vi].res_state = .heap_alive;
                                        self.vars[vi].alloc_loop_depth = self.loop_depth;
                                    } else if (std.mem.eql(u8, cn, "@open")) {
                                        self.vars[vi].res_state = .fd_alive;
                                        self.vars[vi].alloc_loop_depth = self.loop_depth;
                                    }
                                }
                            } else {
                                self.vars[vi].heap_alloc_size = -1;
                            }
                        }
                    } else if (self.lookupGlobalConst(vname) != null) {
                        self.failAt(error.InvalidAssignmentTarget, n.source_id, n.line, n.col, n.text_len, "cannot assign to constant '{s}'", .{vname});
                    } else {
                        self.failAt(error.UndefinedVariable, n.source_id, n.line, n.col, n.text_len, "assignment to undeclared variable '{s}'", .{vname});
                    }
                } else {
                    const target_kind = if (n.child0 != 0) self.ast.nodes[n.child0].kind else NodeKind.identifier;
                    var lhs_ty: SemaType = .unknown;
                    if (target_kind != .deref and target_kind != .field_access and target_kind != .index_expr) {
                        self.failAt(error.InvalidAssignmentTarget, n.source_id, n.line, n.col, 1, "invalid assignment target", .{});
                    } else {
                        lhs_ty = self.analyzeExpr(n.child0);
                        if (lhs_ty == .float) self.info.is_float_op[stmt_idx] = true;
                        const root_node = if (target_kind == .deref) self.ast.nodes[n.child0].child0 else n.child0;
                        if (self.extractLValueRootVar(root_node)) |rvi| {
                            const rv = self.vars[rvi];
                            if (rv.is_ref_imm) {
                                self.failAt(error.InvalidAssignmentTarget, n.source_id, n.line, n.col, 1, "cannot mutate through immutable '&self' reference; change parameter to '&mut self'", .{});
                            } else if (target_kind != .deref and !rv.is_mut and (rv.ty == .struct_t or rv.ty == .fixed_array)) {
                                self.failAt(error.InvalidAssignmentTarget, n.source_id, n.line, n.col, 1, "cannot mutate field/element of immutable '{s}'; declare with 'var' or 'let mut'", .{rv.name});
                            } else if (target_kind == .deref and rv.borrow_target >= 0 and !rv.borrow_is_mut) {
                                self.failAt(error.InvalidAssignmentTarget, n.source_id, n.line, n.col, 1, "cannot mutate through immutable reference '{s}'; use '&mut'", .{rv.name});
                            }
                        }
                        if (self.in_spawn and self.spawn_mutex_depth == 0) {
                            const ptr_sub = if (target_kind == .deref or target_kind == .field_access) self.ast.nodes[n.child0].child0 else 0;
                            if (self.extractPtrRootVar(ptr_sub)) |pvi| {
                                if (pvi < self.closure_var_base and (self.vars[pvi].ty == .ptr or self.vars[pvi].ty == .ptr_struct)) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "unsynchronized non-atomic write to shared pointer '{s}' inside spawn; use @atomic_add/@atomic_cas or mutex", .{self.vars[pvi].name});
                                }
                            }
                        }
                    }
                    const rhs_ty = self.analyzeExpr(n.child1);
                    self.markExprEscaped(n.child1);
                    if (rhs_ty == .float) self.info.is_float_op[stmt_idx] = true;
                    const orig = self.checkExprLocalRefOrigin(n.child1);
                    if (orig != 0 and orig - 1 < self.var_count) {
                        const root_node = if (target_kind == .deref) self.ast.nodes[n.child0].child0 else n.child0;
                        if (self.extractLValueRootVar(root_node)) |rvi| {
                            if (self.vars[orig - 1].scope_depth > self.vars[rvi].scope_depth) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "dangling reference: cannot store reference to inner local '{s}' into outer '{s}'", .{ self.vars[orig - 1].name, self.vars[rvi].name });
                            }
                        }
                    }
                    if (n.op == @intFromEnum(TokenKind.slash_eq) or n.op == @intFromEnum(TokenKind.percent_eq)) {
                        if (self.evalConstExpr(n.child1)) |rhs_val| {
                            if (rhs_val == 0) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "compound division or modulo by constant zero", .{});
                            }
                        }
                    }
                    if (n.op == @intFromEnum(TokenKind.lshift_eq) or n.op == @intFromEnum(TokenKind.rshift_eq)) {
                        if (self.evalConstExpr(n.child1)) |sv| {
                            if (sv < 0 or sv >= 64) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "compile-time invalid shift amount {d} in compound shift (must be 0..63)", .{sv});
                            }
                        }
                    }
                    if (lhs_ty.isUnsigned()) self.info.is_unsigned_op[stmt_idx] = true;
                    const is_untyped_container_idx = (target_kind == .index_expr and blk_idx: {
                        const base_ty = self.info.node_types[self.ast.nodes[n.child0].child0];
                        break :blk_idx (base_ty == .array or base_ty == .map_t);
                    });
                    if (!is_untyped_container_idx and lhs_ty != .unknown and rhs_ty != .unknown) {
                        if (n.op != @intFromEnum(TokenKind.assign)) {
                            if (!lhs_ty.isScalar() or !rhs_ty.isScalar()) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "compound assignment requires scalar operands", .{});
                            }
                        } else if (!self.isExprCompatible(lhs_ty, rhs_ty, n.child1)) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "incompatible assignment to target", .{});
                        } else {
                            self.tagTraitImplIfDyn(lhs_ty, rhs_ty, n.child1);
                        }
                    }
                }
            },
            .return_stmt => {
                if (self.defer_depth > 0) {
                    self.failAt(error.LoopControlOutsideLoop, n.source_id, n.line, n.col, 6, "'return' is not allowed inside defer", .{});
                }
                if (n.child0 != 0) {
                    const rty = self.analyzeExpr(n.child0);
                    self.markExprEscaped(n.child0);
                    if (self.cur_has_explicit_ret) {
                        if (self.cur_ret_type == .void) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 6, "cannot return a value from void function", .{});
                        } else if (!self.isExprCompatible(self.cur_ret_type, rty, n.child0)) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 6, "return type mismatches function signature", .{});
                        } else {
                            self.tagTraitImplIfDyn(self.cur_ret_type, rty, n.child0);
                        }
                    }
                    if (self.checkExprLocalRefOrigin(n.child0) != 0) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 6, "dangling reference: cannot return pointer/reference to local stack variable", .{});
                    }
                    if (rty == .fn_t) {
                        const rn = self.ast.nodes[n.child0];
                        if (rn.kind == .closure_expr) {
                            const cid1 = self.info.closure_ids[n.child0];
                            if (cid1 > 0 and cid1 - 1 < self.info.closure_count and self.info.closures[cid1 - 1].captures_local_ref) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 6, "dangling reference: cannot return closure capturing local stack reference", .{});
                            }
                        } else if (rn.kind == .identifier) {
                            if (self.lookupVar(self.text(n.child0))) |ve| {
                                if (ve.holds_local_ref_closure) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 6, "dangling reference: cannot return closure capturing local stack reference", .{});
                                }
                            }
                        }
                    }
                } else if (self.cur_has_explicit_ret and self.cur_ret_type != .void) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 6, "non-void function must return a value", .{});
                }
            },
            .if_stmt => {
                const cond_ty = self.analyzeExpr(n.child0);
                if (cond_ty != .bool and cond_ty != .unknown and cond_ty != .never) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "if condition must be a bool", .{});
                }
                const saved_vc = self.var_count;
                var pre_states: [512]ResState = undefined;
                var pre_defers: [512]bool = undefined;
                for (0..saved_vc) |vi| {
                    pre_states[vi] = self.vars[vi].res_state;
                    pre_defers[vi] = self.vars[vi].has_deferred_free;
                }
                if (n.child1 != 0) self.analyzeStmt(n.child1);
                const then_exits = (n.child1 != 0 and self.stmtDefinitelyExitsBlock(n.child1));
                var then_states: [512]ResState = undefined;
                var then_defers: [512]bool = undefined;
                for (0..saved_vc) |vi| {
                    then_states[vi] = self.vars[vi].res_state;
                    then_defers[vi] = self.vars[vi].has_deferred_free;
                    self.vars[vi].res_state = pre_states[vi];
                    self.vars[vi].has_deferred_free = pre_defers[vi];
                }
                if (n.child2 != 0) self.analyzeStmt(n.child2);
                const else_exits = (n.child2 != 0 and self.stmtDefinitelyExitsBlock(n.child2));
                if (then_exits and !else_exits) {
                    // Keep else states as current
                } else if (!then_exits and else_exits) {
                    for (0..saved_vc) |vi| {
                        self.vars[vi].res_state = then_states[vi];
                        self.vars[vi].has_deferred_free = then_defers[vi];
                    }
                } else if (!then_exits and !else_exits) {
                    for (0..saved_vc) |vi| {
                        self.vars[vi].res_state = mergeBranchResStates(then_states[vi], self.vars[vi].res_state);
                        self.vars[vi].has_deferred_free = then_defers[vi] or self.vars[vi].has_deferred_free;
                    }
                }
            },
            .while_stmt => {
                const cond_ty = self.analyzeExpr(n.child0);
                if (cond_ty != .bool and cond_ty != .unknown and cond_ty != .never) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 5, "while condition must be a bool", .{});
                }
                self.checkWhileSpinSafety(stmt_idx);
                const pre_vc = self.var_count;
                var pre_states: [512]ResState = undefined;
                for (0..pre_vc) |vi| pre_states[vi] = self.vars[vi].res_state;
                self.loop_depth += 1;
                if (n.child1 != 0) self.analyzeStmt(n.child1);
                self.loop_depth -= 1;
                if (n.child1 != 0 and !self.stmtDefinitelyExitsBlock(n.child1)) {
                    for (0..pre_vc) |vi| {
                        const before = pre_states[vi];
                        const after = self.vars[vi].res_state;
                        if (before == .heap_alive and (after == .freed or after == .maybe_freed)) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 5, "freeing outer variable '{s}' inside loop causes double-free on next iteration", .{self.vars[vi].name});
                        } else if (before == .fd_alive and (after == .fd_closed or after == .fd_maybe_closed)) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 5, "closing outer file descriptor '{s}' inside loop causes use-after-close on next iteration", .{self.vars[vi].name});
                        } else if (after == .heap_alive and self.vars[vi].alloc_loop_depth > self.loop_depth and !self.vars[vi].has_deferred_free) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 5, "unfreed heap allocation '{s}' assigned inside loop leaks on subsequent iterations", .{self.vars[vi].name});
                        } else if (after == .fd_alive and self.vars[vi].alloc_loop_depth > self.loop_depth and !self.vars[vi].has_deferred_free) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 5, "unclosed file descriptor '{s}' assigned inside loop leaks on subsequent iterations", .{self.vars[vi].name});
                        }
                    }
                }
            },
            .for_stmt => {
                const iter_ty = self.analyzeExpr(n.child0);
                if (n.int_val == 1 and n.child2 != 0) {
                    const end_ty = self.analyzeExpr(n.child2);
                    if ((iter_ty != .int and iter_ty != .unknown) or (end_ty != .int and end_ty != .unknown)) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 3, "for-range bounds must be integers", .{});
                    }
                } else if (iter_ty != .array and iter_ty != .fixed_array and iter_ty != .string and iter_ty != .unknown) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 3, "for-in target must be an array or string", .{});
                }
                const pre_vc = self.var_count;
                var pre_states: [512]ResState = undefined;
                for (0..pre_vc) |vi| pre_states[vi] = self.vars[vi].res_state;
                self.loop_depth += 1;
                self.pushScope();
                const loop_var = self.text(stmt_idx);
                const elem_ty: SemaType = switch (iter_ty) {
                    .string => .{ .int = .{ .bits = 8, .unsigned = true } },
                    .fixed_array => |fa| SemaType.fromTypeTag(fa.elem, 0, .none),
                    .array => |ea| if (ea != .none) SemaType.fromTypeTag(ea, 0, .none) else SemaType.i64_t,
                    else => SemaType.i64_t,
                };
                self.addVar(loop_var, elem_ty, false, n.source_id, n.line, n.col);
                if (n.child1 != 0) {
                    if (self.ast.nodes[n.child1].kind == .block) {
                        self.analyzeBlock(n.child1, false, false);
                    } else {
                        self.analyzeStmt(n.child1);
                    }
                }
                self.popScope();
                self.loop_depth -= 1;
                if (n.child1 != 0 and !self.stmtDefinitelyExitsBlock(n.child1)) {
                    for (0..pre_vc) |vi| {
                        const before = pre_states[vi];
                        const after = self.vars[vi].res_state;
                        if (before == .heap_alive and (after == .freed or after == .maybe_freed)) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 3, "freeing outer variable '{s}' inside loop causes double-free on next iteration", .{self.vars[vi].name});
                        } else if (before == .fd_alive and (after == .fd_closed or after == .fd_maybe_closed)) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 3, "closing outer file descriptor '{s}' inside loop causes use-after-close on next iteration", .{self.vars[vi].name});
                        } else if (after == .heap_alive and self.vars[vi].alloc_loop_depth > self.loop_depth and !self.vars[vi].has_deferred_free) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 3, "unfreed heap allocation '{s}' assigned inside loop leaks on subsequent iterations", .{self.vars[vi].name});
                        } else if (after == .fd_alive and self.vars[vi].alloc_loop_depth > self.loop_depth and !self.vars[vi].has_deferred_free) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 3, "unclosed file descriptor '{s}' assigned inside loop leaks on subsequent iterations", .{self.vars[vi].name});
                        }
                    }
                }
            },
            .break_stmt => {
                if (self.loop_depth == 0 or self.defer_depth > 0) {
                    self.failAt(error.LoopControlOutsideLoop, n.source_id, n.line, n.col, 5, "'break' used outside of a loop", .{});
                }
            },
            .continue_stmt => {
                if (self.loop_depth == 0 or self.defer_depth > 0) {
                    self.failAt(error.LoopControlOutsideLoop, n.source_id, n.line, n.col, 8, "'continue' used outside of a loop", .{});
                }
            },
            .unreachable_stmt => {
                self.info.node_types[stmt_idx] = .never;
            },
            else => {
                if (n.kind == .call_expr and n.child0 != 0 and self.ast.nodes[n.child0].kind == .identifier) {
                    const cn = self.text(n.child0);
                    if (std.mem.eql(u8, cn, "@malloc") or std.mem.eql(u8, cn, "@alloc") or
                        std.mem.eql(u8, cn, "@array_new") or std.mem.eql(u8, cn, "@map_new") or
                        std.mem.eql(u8, cn, "@open"))
                    {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, @max(n.text_len, 1), "discarding return value of '{s}' immediately leaks allocated resource", .{cn});
                    }
                }
                _ = self.analyzeExpr(stmt_idx);
            },
        }
    }

    fn resolveStructMethod(self: *Sema, si: u32, mname: []const u8, call_node_idx: u32, argc: u32, arg_types: []const SemaType, arg_nodes: []const u32, is_instance: bool, recv_is_ptr: bool, recv_is_mut: bool, source_id: u32, line: u32, col: u32, span_len: u32) SemaType {
        const sig = self.findFn(mname, si + 1) orelse {
            const sd = self.ast.struct_defs[si];
            self.failAt(error.UndefinedFunctionCall, source_id, line, col, span_len, "struct '{s}' has no method '{s}'", .{ self.srcText(sd.name_start, sd.name_len, sd.source_id), mname });
            return .unknown;
        };
        if (is_instance and sig.self_is_mut and !recv_is_mut) {
            self.failAt(error.InvalidAssignmentTarget, source_id, line, col, span_len, "cannot call '&mut self' method '{s}' on immutable receiver; declare with 'var' or 'let mut'", .{mname});
        }
        const total_argc = argc + @as(u32, if (is_instance) 1 else 0);
        if (total_argc > MAX_PARAMS) {
            self.failAt(error.TooManyArguments, source_id, line, col, span_len, "method call '{s}' exceeds maximum of {d} arguments", .{ mname, MAX_PARAMS });
        } else if (total_argc != sig.param_count) {
            self.failAt(error.InvalidArgumentCount, source_id, line, col, span_len, "method '{s}' expects {d} arguments, got {d}", .{ mname, sig.param_count, total_argc });
        } else {
            const start_k: u32 = if (is_instance) 1 else 0;
            var k: u32 = 0;
            while (k < argc) : (k += 1) {
                const an = if (k < arg_nodes.len) arg_nodes[k] else 0;
                if (!self.isExprCompatible(sig.param_types[k + start_k], arg_types[k], an)) {
                    self.failAt(error.TypeMismatch, source_id, line, col, span_len, "argument {d} type mismatches parameter of '{s}'", .{ k + 1, mname });
                } else {
                    self.tagTraitImplIfDyn(sig.param_types[k + start_k], arg_types[k], an);
                }
            }
        }
        self.info.method_fn_nodes[call_node_idx] = sig.node_idx;
        if (is_instance and !recv_is_ptr and sig.param_count > 0 and
            (sig.param_types[0] == .ptr or sig.param_types[0] == .ptr_struct))
        {
            self.info.is_method_auto_ref[call_node_idx] = true;
        }
        return if (sig.ret_type == .unknown) SemaType.i64_t else sig.ret_type;
    }

    fn analyzeArmBody(self: *Sema, body_idx: u32) SemaType {
        if (body_idx == 0 or body_idx >= self.ast.count) return .void;
        const bn = self.ast.nodes[body_idx];
        if (bn.kind == .block) {
            self.pushScope();
            var st = bn.child0;
            var last_ty: SemaType = .void;
            while (st != 0) {
                const next = self.ast.stmt_chains[st];
                if (next == 0 and isExprKind(self.ast.nodes[st].kind)) {
                    last_ty = self.analyzeExpr(st);
                } else {
                    self.analyzeStmt(st);
                }
                st = next;
            }
            self.popScope();
            return last_ty;
        }
        if (bn.kind == .expr_stmt and bn.child0 != 0) {
            if (isExprKind(self.ast.nodes[bn.child0].kind)) return self.analyzeExpr(bn.child0);
        }
        if (isExprKind(bn.kind)) return self.analyzeExpr(body_idx);
        self.analyzeStmt(body_idx);
        return .void;
    }

    // A constructor covers its whole variant only if every payload is
    // irrefutable. Some(0) must not establish coverage for all Some values.
    fn analyzeVariantPayloads(self: *Sema, pat: u32, args_head: u32, ei: u32, vi: u32) bool {
        const ev = self.ast.enum_defs[ei].variants[vi];
        var ai = args_head;
        var count: usize = 0;
        while (ai != 0) : (ai = self.ast.nodes[ai].child1) count += 1;
        if (count != ev.payload_count) {
            const pattern = self.ast.nodes[pat];
            self.failAt(error.InvalidArgumentCount, pattern.source_id, pattern.line, pattern.col, 1, "enum pattern expects {d} payload patterns, got {d}", .{ ev.payload_count, count });
            return false;
        }
        ai = args_head;
        var pk: usize = 0;
        var irrefutable = true;
        while (ai != 0) : ({
            ai = self.ast.nodes[ai].child1;
            pk += 1;
        }) {
            const ty = SemaType.fromTypeTag(ev.payload_tags[pk], ev.payload_extras[pk], ev.payload_elems[pk]);
            const coverage = self.analyzeMatchPattern(self.ast.nodes[ai].child0, ty);
            if (coverage != .catch_all) irrefutable = false;
        }
        return irrefutable;
    }

    const MatchPatCoverage = union(enum) {
        specific,
        catch_all,
        enum_variant: u32,
        bool_val: bool,
    };

    fn analyzeMatchPattern(self: *Sema, pat: u32, scrut_ty: SemaType) MatchPatCoverage {
        if (pat == 0 or pat >= self.ast.count) return .specific;
        const pn = self.ast.nodes[pat];
        self.info.node_types[pat] = scrut_ty;
        if (pn.kind == .tuple_lit) {
            if (scrut_ty != .tuple_t) {
                self.failAt(error.TypeMismatch, pn.source_id, pn.line, pn.col, 1, "tuple pattern requires a tuple scrutinee", .{});
                return .specific;
            }
            const td = self.getTupleDesc(scrut_ty.tuple_t) orelse return .specific;
            if (pn.int_val != td.param_count) {
                self.failAt(error.TypeMismatch, pn.source_id, pn.line, pn.col, 1, "tuple pattern has {d} fields, expected {d}", .{ pn.int_val, td.param_count });
                return .specific;
            }
            self.info.node_types[pat] = scrut_ty;
            var elem = pn.child0;
            var k: usize = 0;
            var irrefutable = true;
            while (elem != 0 and k < td.param_count) : (k += 1) {
                const ty = SemaType.fromTypeTag(td.param_tags[k], td.param_extras[k], td.param_elems[k]);
                const cov = self.analyzeMatchPattern(self.ast.nodes[elem].child0, ty);
                if (cov != .catch_all) irrefutable = false;
                elem = self.ast.nodes[elem].child1;
            }
            return if (irrefutable) .catch_all else .specific;
        }
        if (pn.kind == .binary_expr) {
            const op: TokenKind = @enumFromInt(pn.op);
            if (op == .dot_dot or op == .dot_dot_eq) {
                const lo = self.analyzeExpr(pn.child0);
                const hi = self.analyzeExpr(pn.child1);
                if (scrut_ty != .int or !self.isExprCompatible(scrut_ty, lo, pn.child0) or !self.isExprCompatible(scrut_ty, hi, pn.child1)) {
                    self.failAt(error.TypeMismatch, pn.source_id, pn.line, pn.col, 2, "range pattern requires compatible integer bounds", .{});
                }
                if (self.evalConstExpr(pn.child0) == null or self.evalConstExpr(pn.child1) == null) {
                    self.failAt(error.TypeMismatch, pn.source_id, pn.line, pn.col, 2, "range pattern bounds must be compile-time constants", .{});
                }
                return .specific;
            }
        }
        if (pn.kind == .scoped_access and pn.child0 != 0) {
            const bname = self.text(pn.child0);
            const vname = self.text(pat);
            if (self.ast.findEnumBySlice(self.ast.sources[0], bname)) |ei| {
                const ed = self.ast.enum_defs[ei];
                const vc = @min(ed.variant_count, @as(u32, @intCast(ed.variants.len)));
                for (0..vc) |vi| {
                    const ev = ed.variants[vi];
                    if (std.mem.eql(u8, self.srcText(ev.name_start, ev.name_len, ed.source_id), vname)) {
                        self.info.enum_def_idx[pat] = @intCast(ei + 1);
                        self.info.enum_variant_idx[pat] = @intCast(vi);
                        self.info.is_const_val[pat] = true;
                        self.info.const_vals[pat] = ev.value;
                        self.info.node_types[pat] = .{ .enum_t = ei };
                        const irrefutable = self.analyzeVariantPayloads(pat, pn.child2, ei, @intCast(vi));
                        if (scrut_ty != .enum_t or scrut_ty.enum_t != ei) {
                            self.failAt(error.TypeMismatch, pn.source_id, pn.line, pn.col, pn.text_len, "pattern enum '{s}' does not match scrutinee enum", .{bname});
                            return .specific;
                        }
                        return if (irrefutable) .{ .enum_variant = @intCast(vi) } else .specific;
                    }
                }
            }
        }
        if (pn.kind == .call_expr and pn.child0 != 0 and scrut_ty == .enum_t) {
            const ei = scrut_ty.enum_t;
            const ed = self.ast.enum_defs[ei];
            const vname = self.text(pn.child0);
            const vc = @min(ed.variant_count, @as(u32, @intCast(ed.variants.len)));
            for (0..vc) |vi| {
                const ev = ed.variants[vi];
                if (std.mem.eql(u8, self.srcText(ev.name_start, ev.name_len, ed.source_id), vname)) {
                    self.info.enum_def_idx[pat] = @intCast(ei + 1);
                    self.info.enum_variant_idx[pat] = @intCast(vi);
                    self.info.is_const_val[pat] = true;
                    self.info.const_vals[pat] = ev.value;
                    self.info.node_types[pat] = .{ .enum_t = ei };
                    const irrefutable = self.analyzeVariantPayloads(pat, pn.child2, ei, @intCast(vi));
                    return if (irrefutable) .{ .enum_variant = @intCast(vi) } else .specific;
                }
            }
        }
        if (pn.kind == .identifier) {
            const pname = self.text(pat);
            if (scrut_ty == .enum_t) {
                const ei = scrut_ty.enum_t;
                const ed = self.ast.enum_defs[ei];
                const vc = @min(ed.variant_count, @as(u32, @intCast(ed.variants.len)));
                for (0..vc) |vi| {
                    const ev = ed.variants[vi];
                    if (std.mem.eql(u8, self.srcText(ev.name_start, ev.name_len, ed.source_id), pname)) {
                        self.info.enum_def_idx[pat] = @intCast(ei + 1);
                        self.info.enum_variant_idx[pat] = @intCast(vi);
                        self.info.is_const_val[pat] = true;
                        self.info.const_vals[pat] = ev.value;
                        self.info.node_types[pat] = .{ .enum_t = ei };
                        const irrefutable = self.analyzeVariantPayloads(pat, 0, ei, @intCast(vi));
                        return if (irrefutable) .{ .enum_variant = @intCast(vi) } else .specific;
                    }
                }
            }
            if (std.mem.eql(u8, pname, "_")) return .catch_all;
            if (self.lookupVarIdx(pname)) |vi| {
                if (self.vars[vi].scope_depth == self.scope_depth) {
                    self.failAt(error.DuplicateDeclaration, pn.source_id, pn.line, pn.col, pn.text_len, "duplicate pattern binding '{s}'", .{pname});
                    return .specific;
                }
            }
            if (self.lookupVar(pname) == null and self.lookupGlobalConst(pname) == null) {
                self.addVar(pname, scrut_ty, false, pn.source_id, pn.line, pn.col);
                self.info.node_types[pat] = scrut_ty;
                self.info.is_pattern_binding[pat] = true;
                return .catch_all;
            }
        }
        const pattern_ty = self.analyzeExpr(pat);
        if (!self.isExprCompatible(scrut_ty, pattern_ty, pat)) {
            self.failAt(error.TypeMismatch, pn.source_id, pn.line, pn.col, 1, "pattern type does not match scrutinee type", .{});
        }
        if (scrut_ty == .bool) {
            if (self.evalConstExpr(pat)) |cv| {
                return .{ .bool_val = (cv != 0) };
            }
        }
        return .specific;
    }

    fn isUntypedIntExpr(self: *const Sema, idx: u32) bool {
        if (idx == 0 or idx >= self.ast.count) return false;
        const n = self.ast.nodes[idx];
        return switch (n.kind) {
            .int_literal => (n.flags & 3) == 0,
            .unary_expr => (n.op == @intFromEnum(TokenKind.minus) or n.op == @intFromEnum(TokenKind.plus) or n.op == @intFromEnum(TokenKind.tilde)) and self.isUntypedIntExpr(n.child0),
            .binary_expr => self.isUntypedIntExpr(n.child0) and self.isUntypedIntExpr(n.child1),
            else => false,
        };
    }

    fn binIntCompat(self: *const Sema, lhs_ty: SemaType, rhs_ty: SemaType, lhs_node: u32, rhs_node: u32) ?SemaType {
        if (lhs_ty == .unknown or lhs_ty == .never) return rhs_ty;
        if (rhs_ty == .unknown or rhs_ty == .never) return lhs_ty;
        if (lhs_ty != .int or rhs_ty != .int) return null;
        if (lhs_ty.eql(rhs_ty)) return lhs_ty;
        if (self.isUntypedIntExpr(rhs_node)) {
            if (self.evalConstExpr(rhs_node)) |cv| {
                if (fitsIntRange(cv, lhs_ty.int.bits, lhs_ty.int.unsigned)) return lhs_ty;
            }
        }
        if (self.isUntypedIntExpr(lhs_node)) {
            if (self.evalConstExpr(lhs_node)) |cv| {
                if (fitsIntRange(cv, rhs_ty.int.bits, rhs_ty.int.unsigned)) return rhs_ty;
            }
        }
        return null;
    }

    fn analyzeExpr(self: *Sema, idx: u32) SemaType {
        if (idx == 0 or idx >= self.ast.count) return .unknown;
        const n = self.ast.nodes[idx];
        if (n.kind == .call_expr or n.kind == .method_call or n.kind == .scoped_access) {
            var arg = n.child2;
            while (arg != 0) : (arg = self.ast.nodes[arg].child1) {
                const wrap = self.ast.nodes[arg];
                if ((wrap.flags & 128) == 0) continue;
                const direct = n.kind == .call_expr and n.child0 != 0 and self.ast.nodes[n.child0].kind == .identifier and
                    lookupBuiltin(self.text(n.child0)) == null and self.lookupVar(self.text(n.child0)) == null and self.findFn(self.text(n.child0), 0) != null;
                if (!direct) self.failAt(error.TypeMismatch, wrap.source_id, wrap.line, wrap.col, wrap.text_len, "named arguments currently require a direct free-function call", .{});
            }
        }
        const ty: SemaType = switch (n.kind) {
            .int_literal => if ((n.flags & 2) != 0) .null_t else if ((n.flags & 1) != 0) .bool else SemaType.i64_t,
            .float_literal => blk: {
                self.info.is_float_op[idx] = true;
                break :blk SemaType.f64_t;
            },
            .string_literal => .string,
            .identifier => blk: {
                const name = self.text(idx);
                if (self.lookupVarIdx(name)) |vi| {
                    const ve = self.vars[vi];
                    if (idx != self.skip_res_check_node) {
                        if (ve.res_state == .freed) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "compile-time use-after-free on '{s}'", .{name});
                        } else if (ve.res_state == .maybe_freed) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "potential use-after-free on '{s}' (freed in conditional branch)", .{name});
                        } else if (ve.res_state == .fd_closed) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "compile-time use-after-close on file descriptor '{s}'", .{name});
                        } else if (ve.res_state == .fd_maybe_closed) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "potential use-after-close on file descriptor '{s}'", .{name});
                        } else if (ve.alias_root >= 0) {
                            const avi: usize = @intCast(ve.alias_root);
                            if (avi < self.var_count) {
                                const av = self.vars[avi];
                                if (av.res_state == .freed) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "compile-time use-after-free via alias '{s}' of '{s}'", .{ name, av.name });
                                } else if (av.res_state == .maybe_freed) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "potential use-after-free via alias '{s}' of '{s}'", .{ name, av.name });
                                } else if (av.res_state == .fd_closed) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "compile-time use-after-close via alias '{s}' of '{s}'", .{ name, av.name });
                                } else if (av.res_state == .fd_maybe_closed) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "potential use-after-close via alias '{s}' of '{s}'", .{ name, av.name });
                                }
                            }
                        }
                    }
                    if (ve.is_const) {
                        self.info.is_const_val[idx] = true;
                        self.info.const_vals[idx] = ve.const_val;
                        if (ve.is_float) self.info.is_float_op[idx] = true;
                    } else if (self.cur_closure_id > 0 and vi < self.closure_var_base) {
                        self.recordClosureCapture(vi, ve.name, ve.ty);
                    }
                    break :blk ve.ty;
                }
                if (self.lookupGlobalConst(name)) |ce| {
                    self.info.is_const_val[idx] = true;
                    self.info.const_vals[idx] = ce.val;
                    if (ce.is_float) self.info.is_float_op[idx] = true;
                    break :blk ce.ty;
                }
                if (self.findFn(name, 0)) |sig| {
                    var td = parser_mod.TypeDesc{ .kind = .fn_ptr };
                    td.param_count = @intCast(@min(sig.param_count, MAX_PARAMS));
                    for (0..td.param_count) |pk| {
                        const pspec = toTypeSpec(sig.param_types[pk]);
                        td.param_tags[pk] = pspec.tag;
                        td.param_extras[pk] = pspec.extra;
                        td.param_elems[pk] = pspec.elem;
                    }
                    const rspec = toTypeSpec(sig.ret_type);
                    td.ret_tag = rspec.tag;
                    td.ret_extra = rspec.extra;
                    td.ret_elem = rspec.elem;
                    if (self.info.tuple_desc_count < self.info.tuple_descs.len) {
                        const tid = self.info.tuple_desc_count;
                        self.info.tuple_descs[tid] = td;
                        self.info.tuple_desc_count += 1;
                        break :blk .{ .fn_t = tid | 0x80000000 };
                    }
                    break :blk .{ .fn_t = 0 };
                }
                self.failAt(error.UndefinedVariable, n.source_id, n.line, n.col, n.text_len, "use of undeclared identifier '{s}'", .{name});
                break :blk .unknown;
            },
            .unary_expr => blk: {
                const op: TokenKind = @enumFromInt(n.op);
                const sub = self.analyzeExpr(n.child0);
                if (op == .bang) {
                    if (sub != .bool and sub != .unknown and sub != .never) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "logical '!' requires a bool operand", .{});
                    }
                    break :blk SemaType.bool;
                }
                if (op == .tilde) {
                    if (sub != .int and sub != .unknown and sub != .never) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "bitwise '~' requires an integer operand", .{});
                    }
                    break :blk sub;
                }
                if (sub != .int and sub != .float and sub != .unknown and sub != .never) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "unary sign requires numeric operand", .{});
                }
                if (sub == .float) self.info.is_float_op[idx] = true;
                break :blk sub;
            },
            .cast_expr => blk: {
                const src_ty = self.analyzeExpr(n.child0);
                const dst_ty = SemaType.fromTypeTag(n.type_tag, n.extra, n.elem_type);
                if (dst_ty == .fn_t and src_ty != .fn_t and src_ty != .unknown) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "cannot forge function pointer by casting non-function type", .{});
                } else if (src_ty == .fn_t and dst_ty != .fn_t and dst_ty != .unknown) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "cannot cast function pointer to non-function type", .{});
                } else if (src_ty == .void or dst_ty == .void or src_ty == .struct_t or dst_ty == .struct_t or
                    src_ty == .fixed_array or dst_ty == .fixed_array or src_ty == .tuple_t or dst_ty == .tuple_t or
                    src_ty == .map_t or dst_ty == .map_t)
                {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "invalid cast involving composite or void type", .{});
                } else if (src_ty == .null_t and dst_ty != .ptr and dst_ty != .ptr_struct and dst_ty != .unknown) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "cannot cast null to non-pointer type", .{});
                } else if ((src_ty == .float and (dst_ty == .ptr or dst_ty == .ptr_struct or dst_ty == .string)) or
                    (dst_ty == .float and (src_ty == .ptr or src_ty == .ptr_struct or src_ty == .string)))
                {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "cannot cast between float and pointer or string", .{});
                } else if (src_ty == .bool and (dst_ty == .ptr or dst_ty == .ptr_struct or dst_ty == .string or dst_ty == .float)) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "cannot cast bool to pointer, string, or float", .{});
                } else if (dst_ty == .bool and src_ty != .bool and src_ty != .unknown) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "cannot cast non-bool to bool; use explicit comparison", .{});
                } else if (src_ty == .string and dst_ty != .string and dst_ty != .ptr and dst_ty != .ptr_struct and
                    !(dst_ty == .int and dst_ty.int.bits == 64) and dst_ty != .unknown)
                {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "invalid cast from string", .{});
                } else if (dst_ty == .string and src_ty != .string and src_ty != .unknown) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "cannot cast non-string to string", .{});
                } else if (src_ty == .enum_t and (self.ast.enum_defs[src_ty.enum_t].has_payloads or
                    (dst_ty != .int and !(dst_ty == .enum_t and dst_ty.enum_t == src_ty.enum_t) and dst_ty != .unknown)))
                {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "invalid cast from enum type", .{});
                } else if (dst_ty == .enum_t and (self.ast.enum_defs[dst_ty.enum_t].has_payloads or
                    (src_ty != .int and !(src_ty == .enum_t and src_ty.enum_t == dst_ty.enum_t) and src_ty != .unknown)))
                {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "invalid cast to enum type", .{});
                }
                if (src_ty == .float or dst_ty == .float) self.info.is_float_op[idx] = true;
                self.tagTraitImplIfDyn(dst_ty, src_ty, idx);
                break :blk dst_ty;
            },
            .binary_expr => blk: {
                const op: TokenKind = @enumFromInt(n.op);
                const lhs = self.analyzeExpr(n.child0);
                const rhs = self.analyzeExpr(n.child1);
                if (op == .and_and or op == .pipe_pipe) {
                    if ((lhs != .bool and lhs != .unknown and lhs != .never) or
                        (rhs != .bool and rhs != .unknown and rhs != .never))
                    {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "logical operators require bool operands", .{});
                    }
                    break :blk SemaType.bool;
                }
                if ((op == .plus or op == .eq or op == .ne) and (lhs == .string or rhs == .string)) {
                    if ((lhs != .string and lhs != .unknown) or (rhs != .string and rhs != .unknown)) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "string operator requires both operands to be strings", .{});
                        break :blk .unknown;
                    }
                    self.info.is_string_op[idx] = true;
                    break :blk if (op == .plus) SemaType.string else SemaType.bool;
                }
                if (op == .eq or op == .ne) {
                    const ptr_zero_cmp = ((lhs == .ptr or lhs == .ptr_struct) and self.isUntypedIntExpr(n.child1) and (self.evalConstExpr(n.child1) orelse 1) == 0) or
                        ((rhs == .ptr or rhs == .ptr_struct) and self.isUntypedIntExpr(n.child0) and (self.evalConstExpr(n.child0) orelse 1) == 0);
                    if (!ptr_zero_cmp and lhs != .unknown and rhs != .unknown and lhs != .never and rhs != .never) {
                        if (lhs == .int and rhs == .int) {
                            if (self.binIntCompat(lhs, rhs, n.child0, n.child1) == null) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "cannot compare mismatched integer types; use explicit 'as' cast", .{});
                            }
                        } else if (!lhs.compatibleWith(rhs) and !rhs.compatibleWith(lhs)) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "incompatible operand types for equality comparison", .{});
                        } else if (lhs == .struct_t or rhs == .struct_t or lhs == .fixed_array or rhs == .fixed_array) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "cannot directly compare aggregate values with == or !=", .{});
                        }
                    }
                    if (lhs == .float or rhs == .float) self.info.is_float_op[idx] = true;
                    if (lhs.isUnsigned() or rhs.isUnsigned()) self.info.is_unsigned_op[idx] = true;
                    break :blk SemaType.bool;
                }
                if (op == .star_star) {
                    if (!lhs.eql(SemaType.i64_t) or !rhs.eql(SemaType.i64_t)) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "integer power requires i64 operands", .{});
                    }
                    if (self.evalConstExpr(n.child1)) |exponent| {
                        if (exponent < 0) self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "integer power exponent must be nonnegative", .{});
                    }
                    break :blk SemaType.i64_t;
                }
                if (lhs == .float or rhs == .float) {
                    self.info.is_float_op[idx] = true;
                    if ((lhs != .float and lhs != .unknown and lhs != .never) or
                        (rhs != .float and rhs != .unknown and rhs != .never))
                    {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "cannot mix float and non-float operands; use explicit 'as' cast", .{});
                    } else if (op == .amp or op == .pipe or op == .caret or op == .lshift or op == .rshift) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "bitwise operator is not valid on float operands", .{});
                    }
                    break :blk switch (op) {
                        .eq, .ne, .lt, .gt, .le, .ge => SemaType.bool,
                        else => if (lhs == .float) lhs else rhs,
                    };
                }
                if (op == .lt or op == .gt or op == .le or op == .ge) {
                    const is_ptr_cmp = (lhs == .ptr or lhs == .ptr_struct) and (rhs == .ptr or rhs == .ptr_struct);
                    if (!is_ptr_cmp and lhs != .unknown and rhs != .unknown and lhs != .never and rhs != .never) {
                        if (lhs != .int or rhs != .int or self.binIntCompat(lhs, rhs, n.child0, n.child1) == null) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "ordering comparison requires compatible numeric or pointer operands", .{});
                        }
                    }
                    if (lhs.isUnsigned() or rhs.isUnsigned()) self.info.is_unsigned_op[idx] = true;
                    break :blk SemaType.bool;
                }
                if (lhs == .void or lhs == .struct_t or lhs == .bool or lhs == .ptr or lhs == .ptr_struct or lhs == .null_t or
                    rhs == .void or rhs == .struct_t or rhs == .bool or rhs == .ptr or rhs == .ptr_struct or rhs == .null_t or
                    lhs == .string or rhs == .string or lhs == .enum_t or rhs == .enum_t or lhs == .fn_t or rhs == .fn_t or
                    lhs == .fixed_array or rhs == .fixed_array)
                {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "invalid operand types for binary operator", .{});
                    break :blk .unknown;
                }
                var res_ty: SemaType = SemaType.i64_t;
                if (op == .lshift or op == .rshift) {
                    if (lhs != .int and lhs != .unknown and lhs != .never) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "shift left operand must be integer", .{});
                    } else if (rhs != .int and rhs != .unknown and rhs != .never) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "shift amount must be integer", .{});
                    }
                    res_ty = if (lhs == .int) lhs else SemaType.i64_t;
                } else {
                    res_ty = self.binIntCompat(lhs, rhs, n.child0, n.child1) orelse blk_bi: {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "integer operands have mismatched types; use explicit 'as' cast", .{});
                        break :blk_bi SemaType.i64_t;
                    };
                }
                const uns = res_ty.isUnsigned();
                if (uns) self.info.is_unsigned_op[idx] = true;
                if (op == .slash or op == .percent) {
                    if (self.evalConstExpr(n.child1)) |rhs_val| {
                        if (rhs_val == 0) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "division or modulo by constant zero", .{});
                        } else if (!uns and rhs_val == -1) {
                            if (self.evalConstExpr(n.child0)) |lhs_val| {
                                if (lhs_val == std.math.minInt(i64)) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "compile-time signed division overflow (MIN_I64 / -1)", .{});
                                }
                            }
                        }
                    }
                } else if (op == .lshift or op == .rshift) {
                    if (self.evalConstExpr(n.child1)) |sh_val| {
                        if (sh_val < 0 or sh_val >= 64) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "shift amount {d} out of range 0..63", .{sh_val});
                        }
                    }
                }
                break :blk res_ty;
            },
            .ternary_expr => blk: {
                const c = self.analyzeExpr(n.child0);
                if (c != .bool and c != .unknown and c != .never) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "ternary condition must be a bool", .{});
                }
                const t = self.analyzeExpr(n.child1);
                const f = self.analyzeExpr(n.child2);
                if (!self.isExprCompatible(t, f, n.child2) and !self.isExprCompatible(f, t, n.child1)) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "ternary branches have incompatible types", .{});
                }
                if (t == .never or t == .null_t) break :blk if (f != .unknown) f else t;
                break :blk if (t != .unknown) t else f;
            },
            .match_expr => blk: {
                const scrut_ty = self.analyzeExpr(n.child0);
                var result_ty: SemaType = .unknown;
                var has_catch_all = (n.child2 != 0);
                var covered: [64]bool = .{false} ** 64;
                var seen_false = false;
                var seen_true = false;
                const saved_vc = self.var_count;
                var pre_states: [512]ResState = undefined;
                var pre_defers: [512]bool = undefined;
                var merged_states: [512]ResState = undefined;
                var merged_defers: [512]bool = undefined;
                var have_merged = false;
                for (0..saved_vc) |vi| {
                    pre_states[vi] = self.vars[vi].res_state;
                    pre_defers[vi] = self.vars[vi].has_deferred_free;
                }
                var arm = n.child1;
                while (arm != 0) : (arm = self.ast.nodes[arm].child2) {
                    for (0..saved_vc) |vi| {
                        self.vars[vi].res_state = pre_states[vi];
                        self.vars[vi].has_deferred_free = pre_defers[vi];
                    }
                    self.pushScope();
                    const is_unguarded = (self.ast.nodes[arm].extra == 0);
                    var pat = self.ast.nodes[arm].child0;
                    const has_alternatives = self.ast.stmt_chains[pat] != 0;
                    const bindings_base = self.var_count;
                    while (pat != 0) : (pat = self.ast.stmt_chains[pat]) {
                        const cov = self.analyzeMatchPattern(pat, scrut_ty);
                        if (is_unguarded) {
                            switch (cov) {
                                .catch_all => has_catch_all = true,
                                .enum_variant => |vi| if (vi < 64) {
                                    covered[vi] = true;
                                },
                                .bool_val => |bv| {
                                    if (bv) seen_true = true else seen_false = true;
                                },
                                .specific => {},
                            }
                        }
                    }
                    if (has_alternatives and self.var_count != bindings_base) {
                        self.failAt(error.TypeMismatch, n.source_id, self.ast.nodes[arm].line, self.ast.nodes[arm].col, 1, "bindings in alternative patterns are not yet supported; use separate arms", .{});
                    }
                    if (self.ast.nodes[arm].extra != 0) {
                        const guard_ty = self.analyzeExpr(self.ast.nodes[arm].extra);
                        if (guard_ty != .bool and guard_ty != .never and guard_ty != .unknown) {
                            self.failAt(error.TypeMismatch, n.source_id, self.ast.nodes[arm].line, self.ast.nodes[arm].col, 1, "match guard must be bool", .{});
                        }
                    }
                    const arm_body = self.ast.nodes[arm].child1;
                    const arm_ty = self.analyzeArmBody(arm_body);
                    const arm_exits = self.stmtDefinitelyExitsBlock(arm_body);
                    self.popScope();
                    if (!arm_exits) {
                        if (!have_merged) {
                            for (0..saved_vc) |vi| {
                                merged_states[vi] = self.vars[vi].res_state;
                                merged_defers[vi] = self.vars[vi].has_deferred_free;
                            }
                            have_merged = true;
                        } else {
                            for (0..saved_vc) |vi| {
                                merged_states[vi] = mergeBranchResStates(merged_states[vi], self.vars[vi].res_state);
                                merged_defers[vi] = merged_defers[vi] or self.vars[vi].has_deferred_free;
                            }
                        }
                    }
                    if (!arm_exits and arm_ty != .never) {
                        if (result_ty == .unknown) result_ty = arm_ty else if (!self.isExprCompatible(result_ty, arm_ty, arm_body)) {
                            self.failAt(error.TypeMismatch, n.source_id, self.ast.nodes[arm].line, self.ast.nodes[arm].col, 1, "match arms have incompatible result types", .{});
                        }
                    }
                }
                if (n.child2 != 0) {
                    for (0..saved_vc) |vi| {
                        self.vars[vi].res_state = pre_states[vi];
                        self.vars[vi].has_deferred_free = pre_defers[vi];
                    }
                    const def_ty = self.analyzeArmBody(n.child2);
                    const def_exits = self.stmtDefinitelyExitsBlock(n.child2);
                    if (!def_exits) {
                        if (!have_merged) {
                            for (0..saved_vc) |vi| {
                                merged_states[vi] = self.vars[vi].res_state;
                                merged_defers[vi] = self.vars[vi].has_deferred_free;
                            }
                            have_merged = true;
                        } else {
                            for (0..saved_vc) |vi| {
                                merged_states[vi] = mergeBranchResStates(merged_states[vi], self.vars[vi].res_state);
                                merged_defers[vi] = merged_defers[vi] or self.vars[vi].has_deferred_free;
                            }
                        }
                    }
                    if (!def_exits and def_ty != .never) {
                        if (result_ty == .unknown) result_ty = def_ty else if (!self.isExprCompatible(result_ty, def_ty, n.child2)) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 5, "match arms have incompatible result types", .{});
                        }
                    }
                }
                if (have_merged) {
                    for (0..saved_vc) |vi| {
                        self.vars[vi].res_state = merged_states[vi];
                        self.vars[vi].has_deferred_free = merged_defers[vi];
                    }
                } else {
                    for (0..saved_vc) |vi| {
                        self.vars[vi].res_state = pre_states[vi];
                        self.vars[vi].has_deferred_free = pre_defers[vi];
                    }
                }
                if (!has_catch_all) {
                    if (scrut_ty == .enum_t) {
                        const ei = scrut_ty.enum_t;
                        const ed = self.ast.enum_defs[ei];
                        const ename = self.srcText(ed.name_start, ed.name_len, ed.source_id);
                        const vc = @min(ed.variant_count, @as(u32, @intCast(ed.variants.len)));
                        if (vc > 64) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 5, "non-exhaustive match on enum '{s}': add '_' or 'else' arm", .{ename});
                        } else {
                            var all_covered = true;
                            for (0..vc) |vi| {
                                if (!covered[vi]) {
                                    all_covered = false;
                                    const ev = ed.variants[vi];
                                    const vname = self.srcText(ev.name_start, ev.name_len, ed.source_id);
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 5, "non-exhaustive match on enum '{s}': missing variant '{s}' or 'else' arm", .{ ename, vname });
                                    break;
                                }
                            }
                            if (all_covered) self.info.enum_def_idx[idx] = 1;
                        }
                    } else if (scrut_ty == .bool) {
                        if (seen_false and seen_true) {
                            self.info.enum_def_idx[idx] = 1;
                        } else {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 5, "non-exhaustive match on bool: missing case or 'else' arm", .{});
                        }
                    } else if (scrut_ty != .unknown) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 5, "non-exhaustive match: missing '_' wildcard or 'else' arm", .{});
                    }
                } else {
                    self.info.enum_def_idx[idx] = 1;
                }
                break :blk if (result_ty == .unknown) SemaType.never else result_ty;
            },
            .array_lit => blk: {
                if ((n.flags & 1) != 0) {
                    const elem_ty = self.analyzeExpr(n.child0);
                    self.markExprEscaped(n.child0);
                    const count = self.evalConstExpr(n.child1) orelse blk_cnt: {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "repeat array count must be a compile-time constant integer", .{});
                        break :blk_cnt 1;
                    };
                    if (count <= 0 or count > 4096) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "repeat array count {d} must be between 1 and 4096", .{count});
                    }
                    self.info.const_vals[idx] = count;
                    const etag = SemaType.toTypeTag(elem_ty);
                    break :blk .{ .fixed_array = .{ .elem = etag, .len = if (count > 0) @intCast(count) else 1 } };
                }
                var elem = n.child0;
                var elem_tag: TypeTag = .none;
                var first = true;
                while (elem != 0) : (elem = self.ast.nodes[elem].child1) {
                    const e = self.ast.nodes[elem].child0;
                    const ety = self.analyzeExpr(e);
                    self.markExprEscaped(e);
                    const etag = SemaType.toTypeTag(ety);
                    if (first) {
                        elem_tag = etag;
                        first = false;
                    } else if (elem_tag != etag) {
                        elem_tag = .none;
                    }
                }
                break :blk .{ .array = elem_tag };
            },
            .if_stmt => blk: {
                const cond_ty = self.analyzeExpr(n.child0);
                if (cond_ty != .bool and cond_ty != .unknown and cond_ty != .never) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "if condition must be a bool", .{});
                }
                if (n.child2 == 0) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "if expression requires an 'else' branch", .{});
                    _ = self.analyzeBlockValue(n.child1);
                    break :blk .unknown;
                }
                const saved_vc = @min(self.var_count, 512);
                var pre_states: [512]ResState = undefined;
                var pre_defers: [512]bool = undefined;
                for (0..saved_vc) |vi| {
                    pre_states[vi] = self.vars[vi].res_state;
                    pre_defers[vi] = self.vars[vi].has_deferred_free;
                }
                const then_ty = self.analyzeBlockValue(n.child1);
                const then_exits = self.stmtDefinitelyExitsBlock(n.child1);
                var then_states: [512]ResState = undefined;
                var then_defers: [512]bool = undefined;
                for (0..saved_vc) |vi| {
                    then_states[vi] = self.vars[vi].res_state;
                    then_defers[vi] = self.vars[vi].has_deferred_free;
                    self.vars[vi].res_state = pre_states[vi];
                    self.vars[vi].has_deferred_free = pre_defers[vi];
                }
                const else_ty = if (self.ast.nodes[n.child2].kind == .if_stmt)
                    self.analyzeExpr(n.child2)
                else
                    self.analyzeBlockValue(n.child2);
                const else_exits = self.stmtDefinitelyExitsBlock(n.child2);
                if (then_exits and else_exits) {
                    for (0..saved_vc) |vi| self.vars[vi].res_state = pre_states[vi];
                } else if (then_exits and !else_exits) {
                    // keep else branch states
                } else if (!then_exits and else_exits) {
                    for (0..saved_vc) |vi| {
                        self.vars[vi].res_state = then_states[vi];
                        self.vars[vi].has_deferred_free = then_defers[vi];
                    }
                } else {
                    for (0..saved_vc) |vi| {
                        self.vars[vi].res_state = mergeBranchResStates(then_states[vi], self.vars[vi].res_state);
                        self.vars[vi].has_deferred_free = then_defers[vi] or self.vars[vi].has_deferred_free;
                    }
                }
                if (then_ty != .unknown and else_ty != .unknown and !then_ty.compatibleWith(else_ty) and !else_ty.compatibleWith(then_ty)) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "if and else expression branches have incompatible types", .{});
                }
                if (then_ty == .never or then_ty == .null_t) break :blk else_ty;
                break :blk then_ty;
            },
            .tuple_lit => blk: {
                var td = parser_mod.TypeDesc{ .kind = .tuple };
                var elem = n.child0;
                while (elem != 0) : (elem = self.ast.nodes[elem].child1) {
                    const e = self.ast.nodes[elem].child0;
                    const ety = self.analyzeExpr(e);
                    self.markExprEscaped(e);
                    if (td.param_count < 8) {
                        const k = td.param_count;
                        const spec = toTypeSpec(ety);
                        td.param_tags[k] = spec.tag;
                        td.param_extras[k] = spec.extra;
                        td.param_elems[k] = spec.elem;
                        td.param_count += 1;
                    } else {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "tuples support at most 8 fields", .{});
                    }
                }
                if (self.info.tuple_desc_count < self.info.tuple_descs.len) {
                    const tid = self.info.tuple_desc_count;
                    self.info.tuple_descs[tid] = td;
                    self.info.tuple_desc_count += 1;
                    break :blk .{ .tuple_t = tid | 0x80000000 };
                }
                break :blk .{ .tuple_t = 0 };
            },
            .closure_expr => blk: {
                const cid: u32 = if (self.info.closure_count < self.info.closures.len) self.info.closure_count else 0;
                if (self.info.closure_count < self.info.closures.len) self.info.closure_count += 1;
                self.info.closures[cid] = .{ .node_idx = idx };
                self.info.closure_ids[idx] = @intCast(cid + 1);

                const saved_base = self.closure_var_base;
                const saved_cid = self.cur_closure_id;
                const saved_ret = self.cur_ret_type;
                const saved_has_ret = self.cur_has_explicit_ret;
                const saved_loop = self.loop_depth;
                const saved_defer = self.defer_depth;

                self.closure_var_base = self.var_count;
                self.cur_closure_id = @intCast(cid + 1);
                const ret_ty = if (n.type_tag == .none) .unknown else SemaType.fromTypeTag(n.type_tag, n.child1, n.elem_type);
                self.cur_ret_type = ret_ty;
                self.cur_has_explicit_ret = (n.type_tag != .none);
                self.loop_depth = 0;
                self.defer_depth = 0;

                self.pushScope();
                var p = n.child0;
                var pc: u8 = 0;
                while (p != 0) : (p = self.ast.nodes[p].child1) {
                    const pn = self.ast.nodes[p];
                    const pty = if (pn.type_tag == .none) SemaType.i64_t else SemaType.fromTypeTag(pn.type_tag, pn.child0, pn.elem_type);
                    if (pc < MAX_PARAMS) self.info.closures[cid].param_types[pc] = pty;
                    self.addVar(self.text(p), pty, false, pn.source_id, pn.line, pn.col);
                    pc += 1;
                }
                self.info.closures[cid].param_count = pc;
                var inferred_ret = if (ret_ty == .unknown) SemaType.i64_t else ret_ty;
                if (n.child2 != 0) {
                    const bnode = self.ast.nodes[n.child2];
                    if (bnode.kind == .block) {
                        self.analyzeBlock(n.child2, false, true);
                        var st = bnode.child0;
                        while (st != 0) {
                            const next = self.ast.stmt_chains[st];
                            const sn = self.ast.nodes[st];
                            if (sn.kind == .return_stmt and sn.child0 != 0) {
                                inferred_ret = self.info.node_types[sn.child0];
                            } else if (next == 0 and self.info.is_tail_expr[st]) {
                                inferred_ret = self.info.node_types[st];
                            }
                            st = next;
                        }
                    } else {
                        inferred_ret = self.analyzeExpr(n.child2);
                    }
                }
                self.popScope();

                self.closure_var_base = saved_base;
                self.cur_closure_id = saved_cid;
                self.cur_ret_type = saved_ret;
                self.cur_has_explicit_ret = saved_has_ret;
                self.loop_depth = saved_loop;
                self.defer_depth = saved_defer;

                if (ret_ty == .unknown) self.info.closures[cid].ret_type = inferred_ret else self.info.closures[cid].ret_type = ret_ty;
                break :blk .{ .fn_t = (cid + 1) | 0x40000000 };
            },
            .try_expr => blk: {
                const sub_ty = self.analyzeExpr(n.child0);
                if (sub_ty != .enum_t) {
                    if (sub_ty != .unknown) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "'?' operator requires an Option or Result enum value", .{});
                    }
                    break :blk SemaType.i64_t;
                }
                const ei = sub_ty.enum_t;
                self.info.enum_def_idx[idx] = @intCast(ei + 1);
                const ed = self.ast.enum_defs[ei];
                if (!ed.has_payloads or ed.variant_count < 2 or ed.variants[0].payload_count == 0) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "'?' operator requires a payload Option/Result enum", .{});
                    break :blk SemaType.i64_t;
                }
                if (!self.cur_has_explicit_ret or self.cur_ret_type != .enum_t) {
                    if (self.cur_ret_type != .unknown) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "'?' cannot propagate in function not returning Option or Result", .{});
                    }
                } else {
                    const ret_ed = self.ast.enum_defs[self.cur_ret_type.enum_t];
                    const sub_name = self.srcText(ed.name_start, ed.name_len, ed.source_id);
                    const ret_name = self.srcText(ret_ed.name_start, ret_ed.name_len, ret_ed.source_id);
                    const sub_is_opt = std.mem.startsWith(u8, sub_name, "Option__");
                    const ret_is_opt = std.mem.startsWith(u8, ret_name, "Option__");
                    const sub_is_res = std.mem.startsWith(u8, sub_name, "Result__");
                    const ret_is_res = std.mem.startsWith(u8, ret_name, "Result__");
                    if (!ret_ed.has_payloads or (sub_is_opt != ret_is_opt) or (sub_is_res != ret_is_res) or (!sub_is_opt and !sub_is_res and self.cur_ret_type.enum_t != ei)) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "'?' return type '{s}' is incompatible with '{s}'", .{ ret_name, sub_name });
                    }
                }
                const v0 = ed.variants[0];
                break :blk SemaType.fromTypeTag(v0.payload_tags[0], v0.payload_extras[0], v0.payload_elems[0]);
            },
            .coalesce_expr => blk: {
                const lhs_ty = self.analyzeExpr(n.child0);
                const rhs_ty = self.analyzeExpr(n.child1);
                if (lhs_ty == .enum_t) {
                    const ei = lhs_ty.enum_t;
                    self.info.enum_def_idx[idx] = @intCast(ei + 1);
                    const ed = self.ast.enum_defs[ei];
                    if (ed.variant_count > 0 and ed.variants[0].payload_count > 0) {
                        const v0 = ed.variants[0];
                        const inner = SemaType.fromTypeTag(v0.payload_tags[0], v0.payload_extras[0], v0.payload_elems[0]);
                        if (!inner.compatibleWith(rhs_ty)) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 2, "coalesce fallback type does not match Option inner type", .{});
                        }
                        break :blk inner;
                    }
                }
                break :blk if (rhs_ty != .unknown) rhs_ty else lhs_ty;
            },
            .map_lit => blk: {
                var flags: u32 = 0;
                var pair = n.child0;
                while (pair != 0) : (pair = self.ast.nodes[pair].child1) {
                    const pn = self.ast.nodes[pair];
                    const kt = self.analyzeExpr(pn.child0);
                    self.markExprEscaped(pn.child0);
                    if (kt == .string) flags |= 1;
                    const vt = self.analyzeExpr(pn.child2);
                    self.markExprEscaped(pn.child2);
                    if (vt == .string) flags |= 2 else if (vt == .float) flags |= 4;
                }
                break :blk .{ .map_t = flags };
            },
            .list_comp => blk: {
                _ = self.analyzeExpr(n.child1);
                if ((n.flags & 2) != 0 and n.extra != 0) {
                    _ = self.analyzeExpr(n.extra);
                }
                self.pushScope();
                self.addVar(self.text(idx), SemaType.i64_t, false, n.source_id, n.line, n.col);
                if (n.child2 != 0) _ = self.analyzeExpr(n.child2);
                _ = self.analyzeExpr(n.child0);
                self.popScope();
                break :blk SemaType.array_t;
            },
            .interp_string => blk: {
                var seg = n.child0;
                while (seg != 0) : (seg = self.ast.stmt_chains[seg]) {
                    _ = self.analyzeExpr(seg);
                }
                break :blk .string;
            },
            .spawn_expr => blk: {
                if (n.child0 != 0) {
                    const saved_in_spawn = self.in_spawn;
                    const saved_mtx_depth = self.spawn_mutex_depth;
                    const saved_cbase = self.closure_var_base;
                    self.in_spawn = true;
                    self.spawn_mutex_depth = 0;
                    if (self.ast.nodes[n.child0].kind != .closure_expr) {
                        self.closure_var_base = self.var_count;
                    }
                    _ = self.analyzeExpr(n.child0);
                    self.in_spawn = saved_in_spawn;
                    self.spawn_mutex_depth = saved_mtx_depth;
                    self.closure_var_base = saved_cbase;
                    const cid1 = self.info.closure_ids[n.child0];
                    if (cid1 > 0 and cid1 - 1 < self.info.closure_count and self.info.closures[cid1 - 1].captures_local_ref) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 5, "dangling reference: spawn closure cannot capture reference/pointer to local stack variable", .{});
                    }
                }
                break :blk SemaType.i64_t;
            },
            .comptime_expr => blk: {
                if (n.child0 != 0) {
                    break :blk self.analyzeExpr(n.child0);
                }
                break :blk SemaType.i64_t;
            },
            .addr_of => blk: {
                const sub = self.ast.nodes[n.child0];
                if (sub.kind != .identifier and sub.kind != .field_access and sub.kind != .index_expr and sub.kind != .deref) {
                    self.failAt(error.InvalidAddressOf, n.source_id, n.line, n.col, 1, "cannot take address of non-lvalue expression", .{});
                    break :blk .ptr;
                }
                const is_mut_borrow = (n.flags & 1) != 0;
                if (sub.kind == .identifier) {
                    const tname = self.text(n.child0);
                    if (self.lookupVarIdx(tname)) |tvi| {
                        const tv = self.vars[tvi];
                        if (self.in_spawn and tvi < self.closure_var_base) {
                            self.failAt(error.InvalidAddressOf, n.source_id, n.line, n.col, 1, "dangling reference: cannot take address of outer local variable '{s}' inside spawn", .{tname});
                        } else if (is_mut_borrow) {
                            if (tv.is_const or !tv.is_mut) {
                                self.failAt(error.InvalidAddressOf, n.source_id, n.line, n.col, 1, "cannot take mutable reference '&mut {s}' to immutable variable; declare with 'var' or 'let mut'", .{tname});
                            } else if (tv.mut_borrowed or tv.shared_borrows > 0) {
                                self.failAt(error.InvalidAddressOf, n.source_id, n.line, n.col, 1, "cannot mutably borrow '{s}' while it is already borrowed", .{tname});
                            }
                        } else if (tv.mut_borrowed) {
                            self.failAt(error.InvalidAddressOf, n.source_id, n.line, n.col, 1, "cannot immutably borrow '{s}' while it is mutably borrowed", .{tname});
                        }
                    }
                } else if (is_mut_borrow) {
                    if (self.extractLValueRootVar(n.child0)) |rvi| {
                        const rv = self.vars[rvi];
                        if (rv.is_ref_imm or (!rv.is_mut and (rv.ty == .struct_t or rv.ty == .fixed_array)) or (rv.borrow_target >= 0 and !rv.borrow_is_mut)) {
                            self.failAt(error.InvalidAddressOf, n.source_id, n.line, n.col, 1, "cannot take mutable reference through immutable value '{s}'", .{rv.name});
                        }
                    }
                }
                const sub_ty = self.analyzeExpr(n.child0);
                break :blk switch (sub_ty) {
                    .struct_t => |si| .{ .ptr_struct = si },
                    else => .ptr,
                };
            },
            .deref => blk: {
                const pty = self.analyzeExpr(n.child0);
                if (pty != .ptr and pty != .ptr_struct and pty != .unknown and pty != .never) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "cannot dereference non-pointer value", .{});
                }
                self.checkConstPtrValid(n.child0, false, "dereference");
                self.checkHeapBounds(n.child0, 8, idx);
                break :blk switch (pty) {
                    .ptr_struct => |si| .{ .struct_t = si },
                    else => SemaType.i64_t,
                };
            },
            .index_expr => blk: {
                const base_ty = self.analyzeExpr(n.child0);
                const idx_ty = self.analyzeExpr(n.child1);
                if (base_ty == .ptr or base_ty == .ptr_struct) {
                    self.checkConstPtrValid(n.child0, false, "indexed pointer");
                    if (self.evalConstExpr(n.child1)) |k| {
                        if (self.extractAllocVarAndOffset(n.child0)) |ref| {
                            const v = self.vars[ref.var_idx];
                            const byte_off = std.math.mul(i64, k, 8) catch std.math.maxInt(i64);
                            const start_off = std.math.add(i64, ref.off, byte_off) catch std.math.maxInt(i64);
                            const end_off = std.math.add(i64, start_off, 8) catch std.math.maxInt(i64);
                            if (start_off < 0 or end_off > v.heap_alloc_size) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "compile-time heap buffer overflow on '{s}': indexed access [{d}..{d}) exceeds @malloc({d}) bounds", .{ v.name, start_off, end_off, v.heap_alloc_size });
                            }
                        }
                    }
                }
                if (base_ty == .map_t) {
                    const mf = base_ty.map_t;
                    if ((mf & 2) != 0) break :blk .string;
                    if ((mf & 4) != 0) break :blk SemaType.f64_t;
                    break :blk SemaType.i64_t;
                }
                if (base_ty == .string) {
                    if (!idx_ty.isScalar()) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "string index must be an integer", .{});
                    }
                    if (self.ast.nodes[n.child0].kind == .string_literal) {
                        if (self.evalConstExpr(n.child1)) |k| {
                            const snode = self.ast.nodes[n.child0];
                            var dec_buf: [4096]u8 = undefined;
                            const slen = decodedStringLiteralBytes(self.srcText(snode.text_start, snode.text_len, snode.source_id), &dec_buf);
                            if (k < 0 or k >= @as(i64, @intCast(slen))) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "string index {d} out of bounds for literal of length {d}", .{ k, slen });
                            }
                        }
                    }
                    break :blk SemaType.i64_t;
                }
                if (base_ty != .ptr and base_ty != .ptr_struct and base_ty != .array and base_ty != .fixed_array and base_ty != .string and base_ty != .map_t and base_ty != .unknown and base_ty != .never) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "cannot index non-array/non-pointer value", .{});
                }
                if (idx_ty != .int and idx_ty != .unknown and idx_ty != .never) {
                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "array index must be an integer", .{});
                }
                if (base_ty == .fixed_array) {
                    if (self.evalConstExpr(n.child1)) |k| {
                        const flen: i64 = @intCast(base_ty.fixed_array.len);
                        if (k < 0 or k >= flen) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "array index {d} out of bounds for [0..{d})", .{ k, flen });
                        }
                    }
                }
                break :blk switch (base_ty) {
                    .array => |ea| if (ea != .none) SemaType.fromTypeTag(ea, 0, .none) else SemaType.i64_t,
                    .fixed_array => |fa| SemaType.fromTypeTag(fa.elem, 0, .none),
                    .string => .{ .int = .{ .bits = 8, .unsigned = true } },
                    else => SemaType.i64_t,
                };
            },
            .struct_init => blk: {
                const sname = self.text(idx);
                const si = self.ast.findStructBySlice(self.ast.sources[0], sname) orelse {
                    self.failAt(error.UndefinedStruct, n.source_id, n.line, n.col, n.text_len, "undefined struct '{s}'", .{sname});
                    var fi = n.child2;
                    while (fi != 0) : (fi = self.ast.nodes[fi].child1) {
                        _ = self.analyzeExpr(self.ast.nodes[fi].child0);
                    }
                    break :blk .unknown;
                };
                self.info.struct_indices[idx] = si;
                const sd = self.ast.struct_defs[si];
                const fc = @min(sd.field_count, @as(u32, @intCast(sd.fields.len)));
                var seen: [32]bool = .{false} ** 32;
                var init_field_count: u32 = 0;
                var fi = n.child2;
                while (fi != 0) : (fi = self.ast.nodes[fi].child1) {
                    const fn_node = self.ast.nodes[fi];
                    const fname = self.text(fi);
                    const val_ty = self.analyzeExpr(fn_node.child0);
                    self.markExprEscaped(fn_node.child0);
                    init_field_count += 1;
                    var found_idx: ?u32 = null;
                    for (0..fc) |k| {
                        const df = sd.fields[k];
                        const dfname = self.srcText(df.name_start, df.name_len, sd.source_id);
                        if (std.mem.eql(u8, dfname, fname)) {
                            found_idx = @intCast(k);
                            self.info.field_offsets[fi] = df.offset;
                            const expected_fty = SemaType.fromTypeTag(df.type_tag, df.extra, df.elem_type);
                            if (!self.isExprCompatible(expected_fty, val_ty, fn_node.child0)) {
                                self.failAt(error.TypeMismatch, fn_node.source_id, fn_node.line, fn_node.col, fn_node.text_len, "field '{s}' value type mismatches struct '{s}'", .{ fname, sname });
                            } else {
                                self.tagTraitImplIfDyn(expected_fty, val_ty, fn_node.child0);
                            }
                            break;
                        }
                    }
                    if (found_idx) |k| {
                        if (k < 32) {
                            if (seen[k]) {
                                self.failAt(error.DuplicateDeclaration, fn_node.source_id, fn_node.line, fn_node.col, fn_node.text_len, "duplicate field '{s}' in struct '{s}' initializer", .{ fname, sname });
                            }
                            seen[k] = true;
                        }
                    } else {
                        self.failAt(error.UnknownField, fn_node.source_id, fn_node.line, fn_node.col, fn_node.text_len, "struct '{s}' has no field '{s}'", .{ sname, fname });
                    }
                }
                if (sd.is_union) {
                    if (init_field_count != 1) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "union '{s}' initializer must specify exactly 1 field", .{sname});
                    }
                } else {
                    for (0..@min(fc, 32)) |k| {
                        if (!seen[k]) {
                            const df = sd.fields[k];
                            const dfname = self.srcText(df.name_start, df.name_len, sd.source_id);
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "missing field '{s}' in struct '{s}' initializer", .{ dfname, sname });
                            break;
                        }
                    }
                }
                break :blk .{ .struct_t = si };
            },
            .scoped_access => blk: {
                const base = self.ast.nodes[n.child0];
                const bname = self.text(n.child0);
                const mname = self.text(idx);
                if (n.flags == 1) {
                    // Type::fn(args) or Enum::Variant(payload_args)
                    var argc: u32 = 0;
                    var arg_types: [MAX_PARAMS]SemaType = undefined;
                    var arg_nodes: [MAX_PARAMS]u32 = .{0} ** MAX_PARAMS;
                    var ai = n.child2;
                    while (ai != 0) : (ai = self.ast.nodes[ai].child1) {
                        const ae = self.ast.nodes[ai].child0;
                        const aty = self.analyzeExpr(ae);
                        self.markExprEscaped(ae);
                        if (argc < MAX_PARAMS) {
                            arg_types[argc] = aty;
                            arg_nodes[argc] = ae;
                        }
                        argc += 1;
                    }
                    if (base.kind == .identifier) {
                        if (self.ast.findStructBySlice(self.ast.sources[0], bname)) |si| {
                            break :blk self.resolveStructMethod(si, mname, idx, argc, &arg_types, &arg_nodes, false, false, false, n.source_id, n.line, n.col, n.text_len);
                        }
                        if (self.ast.findEnumBySlice(self.ast.sources[0], bname)) |ei| {
                            const ed = self.ast.enum_defs[ei];
                            const vc = @min(ed.variant_count, @as(u32, @intCast(ed.variants.len)));
                            for (0..vc) |vi| {
                                const ev = ed.variants[vi];
                                if (std.mem.eql(u8, self.srcText(ev.name_start, ev.name_len, ed.source_id), mname)) {
                                    if (argc != ev.payload_count) {
                                        self.failAt(error.InvalidArgumentCount, n.source_id, n.line, n.col, n.text_len, "variant '{s}::{s}' expects {d} payload arguments, got {d}", .{ bname, mname, ev.payload_count, argc });
                                    } else {
                                        for (0..argc) |pk| {
                                            const expected_p = SemaType.fromTypeTag(ev.payload_tags[pk], ev.payload_extras[pk], ev.payload_elems[pk]);
                                            if (!self.isExprCompatible(expected_p, arg_types[pk], arg_nodes[pk])) {
                                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "payload argument {d} mismatches variant '{s}::{s}'", .{ pk + 1, bname, mname });
                                            } else {
                                                self.tagTraitImplIfDyn(expected_p, arg_types[pk], arg_nodes[pk]);
                                            }
                                        }
                                    }
                                    self.info.enum_def_idx[idx] = @intCast(ei + 1);
                                    self.info.enum_variant_idx[idx] = @intCast(vi);
                                    break :blk .{ .enum_t = ei };
                                }
                            }
                            self.failAt(error.UnknownField, n.source_id, n.line, n.col, n.text_len, "enum '{s}' has no variant '{s}'", .{ bname, mname });
                            break :blk .unknown;
                        }
                    }
                    self.failAt(error.UndefinedStruct, n.source_id, n.line, n.col, n.text_len, "unknown type '{s}' for scoped call '::{s}'", .{ bname, mname });
                    break :blk .unknown;
                } else {
                    // Enum::Variant
                    if (base.kind == .identifier) {
                        if (self.ast.findEnumBySlice(self.ast.sources[0], bname)) |ei| {
                            const ed = self.ast.enum_defs[ei];
                            const vc = @min(ed.variant_count, @as(u32, @intCast(ed.variants.len)));
                            for (0..vc) |vi| {
                                const ev = ed.variants[vi];
                                if (std.mem.eql(u8, self.srcText(ev.name_start, ev.name_len, ed.source_id), mname)) {
                                    if (!ed.has_payloads) {
                                        self.info.is_const_val[idx] = true;
                                        self.info.const_vals[idx] = ev.value;
                                    }
                                    self.info.enum_def_idx[idx] = @intCast(ei + 1);
                                    self.info.enum_variant_idx[idx] = @intCast(vi);
                                    break :blk .{ .enum_t = ei };
                                }
                            }
                            self.failAt(error.UnknownField, n.source_id, n.line, n.col, n.text_len, "enum '{s}' has no variant '{s}'", .{ bname, mname });
                            break :blk .unknown;
                        }
                    }
                    self.failAt(error.UndefinedStruct, n.source_id, n.line, n.col, n.text_len, "unknown enum '{s}'", .{bname});
                    break :blk .unknown;
                }
            },
            .method_call => blk: {
                const mname = self.text(idx);
                var argc: u32 = 0;
                var arg_types: [MAX_PARAMS]SemaType = undefined;
                var arg_nodes: [MAX_PARAMS]u32 = .{0} ** MAX_PARAMS;
                var ai = n.child2;
                while (ai != 0) : (ai = self.ast.nodes[ai].child1) {
                    const ae = self.ast.nodes[ai].child0;
                    const aty = self.analyzeExpr(ae);
                    self.markExprEscaped(ae);
                    if (argc < MAX_PARAMS) {
                        arg_types[argc] = aty;
                        arg_nodes[argc] = ae;
                    }
                    argc += 1;
                }
                const recv_node = self.ast.nodes[n.child0];
                if (recv_node.kind == .identifier and self.lookupVar(self.text(n.child0)) == null) {
                    const bname = self.text(n.child0);
                    if (self.ast.findStructBySlice(self.ast.sources[0], bname)) |si| {
                        break :blk self.resolveStructMethod(si, mname, idx, argc, &arg_types, &arg_nodes, false, false, false, n.source_id, n.line, n.col, n.text_len);
                    }
                }
                const recv_ty = self.analyzeExpr(n.child0);
                self.markExprEscaped(n.child0);
                const recv_is_mut = blk_rm: {
                    if (recv_node.kind == .identifier) {
                        if (self.lookupVar(self.text(n.child0))) |rve| {
                            if (rve.is_ref_imm) break :blk_rm false;
                            if (recv_ty == .ptr_struct or recv_ty == .ptr) {
                                if (rve.borrow_target >= 0 and !rve.borrow_is_mut) break :blk_rm false;
                                break :blk_rm true;
                            }
                            break :blk_rm rve.is_mut;
                        }
                    } else if (recv_node.kind == .deref or recv_node.kind == .field_access or recv_node.kind == .index_expr) {
                        if (self.extractLValueRootVar(n.child0)) |rvi| {
                            const rv = self.vars[rvi];
                            if (rv.is_ref_imm) break :blk_rm false;
                            if (rv.borrow_target >= 0 and !rv.borrow_is_mut) break :blk_rm false;
                            if (rv.ty == .struct_t or rv.ty == .fixed_array) break :blk_rm rv.is_mut;
                        }
                    }
                    break :blk_rm true;
                };
                switch (recv_ty) {
                    .struct_t => |si| break :blk self.resolveStructMethod(si, mname, idx, argc, &arg_types, &arg_nodes, true, false, recv_is_mut, n.source_id, n.line, n.col, n.text_len),
                    .ptr_struct => |si| break :blk self.resolveStructMethod(si, mname, idx, argc, &arg_types, &arg_nodes, true, true, recv_is_mut, n.source_id, n.line, n.col, n.text_len),
                    .dyn_trait => |ti| {
                        if (ti < self.ast.trait_count) {
                            const td = self.ast.trait_defs[ti];
                            for (0..td.method_count) |mi| {
                                const tm = td.methods[mi];
                                if (std.mem.eql(u8, self.srcText(tm.name.start, tm.name.len, tm.name.source_id), mname)) {
                                    const expected_argc: u32 = if (tm.param_count > 0) tm.param_count - 1 else 0;
                                    if (argc != expected_argc) {
                                        self.failAt(error.InvalidArgumentCount, n.source_id, n.line, n.col, n.text_len, "trait method '{s}' expects {d} arguments, got {d}", .{ mname, expected_argc, argc });
                                    } else {
                                        for (0..argc) |pk| {
                                            const pty = SemaType.fromTypeTag(tm.param_tags[pk + 1], tm.param_extras[pk + 1], tm.param_elems[pk + 1]);
                                            if (!self.isExprCompatible(pty, arg_types[pk], arg_nodes[pk])) {
                                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "argument {d} type mismatches trait method '{s}'", .{ pk + 1, mname });
                                            }
                                        }
                                    }
                                    self.info.field_offsets[idx] = @intCast(mi);
                                    self.info.trait_impl_idx[idx] = @intCast(ti + 1);
                                    break :blk SemaType.fromTypeTag(tm.ret_tag, tm.ret_extra, tm.ret_elem);
                                }
                            }
                        }
                        self.failAt(error.UndefinedFunctionCall, n.source_id, n.line, n.col, n.text_len, "trait has no method '{s}'", .{mname});
                        break :blk .unknown;
                    },
                    .array => {
                        if (std.mem.eql(u8, mname, "len")) break :blk SemaType.i64_t;
                        if (std.mem.eql(u8, mname, "push")) break :blk .void;
                        if (std.mem.eql(u8, mname, "pop")) break :blk SemaType.i64_t;
                        break :blk SemaType.i64_t;
                    },
                    .enum_t => |ei| {
                        const ed = self.ast.enum_defs[ei];
                        const ename = self.srcText(ed.name_start, ed.name_len, ed.source_id);
                        if (std.mem.startsWith(u8, ename, "Option__") or std.mem.startsWith(u8, ename, "Result__")) {
                            if (std.mem.eql(u8, mname, "is_some") or std.mem.eql(u8, mname, "is_none") or
                                std.mem.eql(u8, mname, "is_ok") or std.mem.eql(u8, mname, "is_err"))
                                break :blk .bool;
                            if ((std.mem.eql(u8, mname, "unwrap") or std.mem.eql(u8, mname, "unwrap_or")) and
                                ed.variant_count > 0 and ed.variants[0].payload_count > 0)
                            {
                                const v0 = ed.variants[0];
                                break :blk SemaType.fromTypeTag(v0.payload_tags[0], v0.payload_extras[0], v0.payload_elems[0]);
                            }
                        }
                        self.failAt(error.UndefinedFunctionCall, n.source_id, n.line, n.col, n.text_len, "cannot call method '{s}' on enum '{s}'", .{ mname, ename });
                        break :blk .unknown;
                    },
                    else => {
                        self.failAt(error.UndefinedFunctionCall, n.source_id, n.line, n.col, n.text_len, "cannot call method '{s}' on this type", .{mname});
                        break :blk .unknown;
                    },
                }
            },
            .field_access => blk: {
                const base_node = self.ast.nodes[n.child0];
                const fname = self.text(idx);
                if ((n.flags & 1) != 0) {
                    const base_ty = self.analyzeExpr(n.child0);
                    const tidx = n.int_val;
                    self.info.field_offsets[idx] = if (tidx >= 0) @intCast(tidx * 8) else 0;
                    if (base_ty == .tuple_t) {
                        if (self.getTupleDesc(base_ty.tuple_t)) |td| {
                            if (tidx >= 0 and tidx < td.param_count) {
                                const k: usize = @intCast(tidx);
                                break :blk SemaType.fromTypeTag(td.param_tags[k], td.param_extras[k], td.param_elems[k]);
                            }
                            self.failAt(error.UnknownField, n.source_id, n.line, n.col, 1, "tuple index {d} out of bounds for tuple of size {d}", .{ tidx, td.param_count });
                            break :blk .unknown;
                        }
                    }
                    break :blk SemaType.i64_t;
                }
                // Check Enum.Variant first when receiver is an enum type name
                if (base_node.kind == .identifier and self.lookupVar(self.text(n.child0)) == null) {
                    const ename = self.text(n.child0);
                    if (self.ast.findEnumBySlice(self.ast.sources[0], ename)) |ei| {
                        const ed = self.ast.enum_defs[ei];
                        const vc = @min(ed.variant_count, @as(u32, @intCast(ed.variants.len)));
                        for (0..vc) |vi| {
                            const ev = ed.variants[vi];
                            if (std.mem.eql(u8, self.srcText(ev.name_start, ev.name_len, ed.source_id), fname)) {
                                if (!ed.has_payloads) {
                                    self.info.is_const_val[idx] = true;
                                    self.info.const_vals[idx] = ev.value;
                                }
                                self.info.enum_def_idx[idx] = @intCast(ei + 1);
                                self.info.enum_variant_idx[idx] = @intCast(vi);
                                break :blk .{ .enum_t = ei };
                            }
                        }
                        self.failAt(error.UnknownField, n.source_id, n.line, n.col, n.text_len, "enum '{s}' has no variant '{s}'", .{ ename, fname });
                        break :blk .unknown;
                    }
                }
                const base_ty = self.analyzeExpr(n.child0);
                if (base_ty == .ptr or base_ty == .ptr_struct) {
                    self.checkConstPtrValid(n.child0, false, "struct field pointer");
                }
                if (std.mem.eql(u8, fname, "len")) {
                    if (base_ty == .string or base_ty == .array or base_ty == .map_t) {
                        self.info.is_len_prop[idx] = true;
                        break :blk SemaType.i64_t;
                    }
                    if (base_ty == .fixed_array) {
                        self.info.is_const_val[idx] = true;
                        self.info.const_vals[idx] = @intCast(base_ty.fixed_array.len);
                        break :blk SemaType.i64_t;
                    }
                }
                switch (base_ty) {
                    .struct_t, .ptr_struct => |si| {
                        const sd = self.ast.struct_defs[si];
                        const fc = @min(sd.field_count, @as(u32, @intCast(sd.fields.len)));
                        for (0..fc) |k| {
                            const df = sd.fields[k];
                            if (std.mem.eql(u8, self.srcText(df.name_start, df.name_len, sd.source_id), fname)) {
                                self.info.field_offsets[idx] = df.offset;
                                break :blk SemaType.fromTypeTag(df.type_tag, df.extra, df.elem_type);
                            }
                        }
                        self.failAt(error.UnknownField, n.source_id, n.line, n.col, n.text_len, "struct '{s}' has no field '{s}'", .{ self.srcText(sd.name_start, sd.name_len, sd.source_id), fname });
                        break :blk .unknown;
                    },
                    .ptr, .unknown => {
                        var match_count: u32 = 0;
                        var match_offset: u32 = 0;
                        var match_ty: SemaType = SemaType.i64_t;
                        const scount = @min(@as(u32, self.ast.struct_count), @as(u32, @intCast(self.ast.struct_defs.len)));
                        for (0..scount) |si| {
                            const sd = self.ast.struct_defs[si];
                            const fc = @min(sd.field_count, @as(u32, @intCast(sd.fields.len)));
                            for (0..fc) |k| {
                                const df = sd.fields[k];
                                if (std.mem.eql(u8, self.srcText(df.name_start, df.name_len, sd.source_id), fname)) {
                                    match_count += 1;
                                    match_offset = df.offset;
                                    match_ty = SemaType.fromTypeTag(df.type_tag, df.extra, df.elem_type);
                                }
                            }
                        }
                        if (match_count == 1) {
                            self.info.field_offsets[idx] = match_offset;
                            break :blk match_ty;
                        } else if (match_count > 1) {
                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "ambiguous field '{s}': annotate variable with its struct type", .{fname});
                        } else {
                            self.failAt(error.UnknownField, n.source_id, n.line, n.col, n.text_len, "unknown struct field '{s}'", .{fname});
                        }
                        break :blk .unknown;
                    },
                    else => {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, n.text_len, "cannot access field '{s}' on non-struct type", .{fname});
                        break :blk .unknown;
                    },
                }
            },
            .call_expr => blk: {
                const fn_node = self.ast.nodes[n.child0];
                const cname = self.text(n.child0);
                const is_free_fn = fn_node.kind == .identifier and
                    (std.mem.eql(u8, cname, "@free") or std.mem.eql(u8, cname, "@array_free") or std.mem.eql(u8, cname, "@map_free"));
                const is_close_fn = fn_node.kind == .identifier and std.mem.eql(u8, cname, "@close");
                var argc: u32 = 0;
                var arg_types: [MAX_PARAMS]SemaType = undefined;
                var arg_nodes: [MAX_PARAMS]u32 = undefined;
                var ai = n.child2;
                while (ai != 0) : (ai = self.ast.nodes[ai].child1) {
                    const arg_e = self.ast.nodes[ai].child0;
                    const saved_skip = self.skip_res_check_node;
                    if (argc == 0 and (is_free_fn or is_close_fn) and self.ast.nodes[arg_e].kind == .identifier) {
                        self.skip_res_check_node = arg_e;
                    }
                    const aty = self.analyzeExpr(arg_e);
                    self.skip_res_check_node = saved_skip;
                    if (argc < MAX_PARAMS) {
                        arg_types[argc] = aty;
                        arg_nodes[argc] = arg_e;
                    }
                    argc += 1;
                }

                if (fn_node.kind == .identifier) {
                    if (lookupBuiltin(cname)) |b| {
                        if (argc < b.min_args or argc > b.max_args) {
                            self.failAt(error.InvalidArgumentCount, fn_node.source_id, fn_node.line, fn_node.col, fn_node.text_len, "builtin '{s}' expects {d}..{d} arguments, got {d}", .{ cname, b.min_args, b.max_args, argc });
                        }
                        if (isIntegerIntrinsic(cname)) {
                            for (arg_types[0..@min(argc, MAX_PARAMS)], 0..) |aty, arg_i| {
                                if (!aty.eql(SemaType.i64_t) and aty != .never and aty != .unknown) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "{s} argument {d} must be i64 (cast explicitly for bit-pattern operations)", .{ cname, arg_i + 1 });
                                }
                            }
                        }
                        if (is_free_fn and argc >= 1) {
                            if (arg_types[0] != .ptr and arg_types[0] != .ptr_struct and arg_types[0] != .array and arg_types[0] != .map_t and arg_types[0] != .null_t and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "{s} expects a heap pointer or container", .{cname});
                            }
                            self.checkConstPtrValid(arg_nodes[0], true, cname);
                            if (self.ast.nodes[arg_nodes[0]].kind == .identifier) {
                                const vn = self.text(arg_nodes[0]);
                                if (self.lookupVarIdx(vn)) |vi| {
                                    if (self.vars[vi].thread_active) {
                                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "cannot free '{s}' while spawned thread may still be using it; call @thread_join first", .{vn});
                                    }
                                    var target_state = self.vars[vi].res_state;
                                    var target_defer = self.vars[vi].has_deferred_free;
                                    if (self.vars[vi].alias_root >= 0) {
                                        const avi: usize = @intCast(self.vars[vi].alias_root);
                                        if (avi < self.var_count) {
                                            if (self.vars[avi].thread_active) {
                                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "cannot free '{s}' while spawned thread may still be using '{s}'", .{ vn, self.vars[avi].name });
                                            }
                                            if (self.vars[avi].res_state == .freed or self.vars[avi].res_state == .maybe_freed) {
                                                target_state = self.vars[avi].res_state;
                                            }
                                            if (self.vars[avi].has_deferred_free) target_defer = true;
                                        }
                                    }
                                    if (self.defer_depth > 0) {
                                        if (target_state == .freed or target_state == .maybe_freed or target_defer) {
                                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time double-free via defer on '{s}'", .{vn});
                                        } else {
                                            self.vars[vi].has_deferred_free = true;
                                            if (self.vars[vi].alias_root >= 0) {
                                                const avi: usize = @intCast(self.vars[vi].alias_root);
                                                if (avi < self.var_count) self.vars[avi].has_deferred_free = true;
                                            }
                                        }
                                    } else {
                                        if (target_state == .freed) {
                                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time double-free detected on '{s}'", .{vn});
                                        } else if (target_state == .maybe_freed) {
                                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "potential double-free on '{s}' (already freed in conditional branch)", .{vn});
                                        } else if (target_defer) {
                                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time double-free on '{s}': already scheduled for deferred free", .{vn});
                                        } else {
                                            self.vars[vi].res_state = .freed;
                                            if (self.vars[vi].alias_root >= 0) {
                                                const avi: usize = @intCast(self.vars[vi].alias_root);
                                                if (avi < self.var_count) self.vars[avi].res_state = .freed;
                                            }
                                        }
                                    }
                                }
                            }
                        } else if (is_close_fn and argc >= 1) {
                            if (arg_types[0] != .int and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "@close expects an integer file descriptor", .{});
                            }
                            if (self.evalConstExpr(arg_nodes[0])) |fd_val| {
                                if (fd_val < 0) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time negative file descriptor {d} in @close", .{fd_val});
                                }
                            }
                            if (self.ast.nodes[arg_nodes[0]].kind == .identifier) {
                                const vn = self.text(arg_nodes[0]);
                                if (self.lookupVarIdx(vn)) |vi| {
                                    var target_state = self.vars[vi].res_state;
                                    var target_defer = self.vars[vi].has_deferred_free;
                                    if (self.vars[vi].alias_root >= 0) {
                                        const avi: usize = @intCast(self.vars[vi].alias_root);
                                        if (avi < self.var_count) {
                                            if (self.vars[avi].res_state == .fd_closed or self.vars[avi].res_state == .fd_maybe_closed) {
                                                target_state = self.vars[avi].res_state;
                                            }
                                            if (self.vars[avi].has_deferred_free) target_defer = true;
                                        }
                                    }
                                    if (self.defer_depth > 0) {
                                        if (target_state == .fd_closed or target_state == .fd_maybe_closed or target_defer) {
                                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time double-close via defer on file descriptor '{s}'", .{vn});
                                        } else {
                                            self.vars[vi].has_deferred_free = true;
                                            if (self.vars[vi].alias_root >= 0) {
                                                const avi: usize = @intCast(self.vars[vi].alias_root);
                                                if (avi < self.var_count) self.vars[avi].has_deferred_free = true;
                                            }
                                        }
                                    } else {
                                        if (target_state == .fd_closed) {
                                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time double-close detected on file descriptor '{s}'", .{vn});
                                        } else if (target_state == .fd_maybe_closed) {
                                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "potential double-close on file descriptor '{s}'", .{vn});
                                        } else if (target_defer) {
                                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time double-close on '{s}': already scheduled for deferred close", .{vn});
                                        } else {
                                            self.vars[vi].res_state = .fd_closed;
                                            if (self.vars[vi].alias_root >= 0) {
                                                const avi: usize = @intCast(self.vars[vi].alias_root);
                                                if (avi < self.var_count) self.vars[avi].res_state = .fd_closed;
                                            }
                                        }
                                    }
                                }
                            }
                        } else if ((std.mem.eql(u8, cname, "print") or std.mem.eql(u8, cname, "println") or
                            std.mem.eql(u8, cname, "@print") or std.mem.eql(u8, cname, "@println")) and argc >= 1)
                        {
                            if (arg_types[0] != .string and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "'{s}' expects a string argument; use printInt/printFloat for numbers", .{cname});
                            }
                        } else if (std.mem.eql(u8, cname, "printInt") and argc >= 1) {
                            if (arg_types[0] != .int and arg_types[0] != .bool and arg_types[0] != .enum_t and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "printInt expects an integer or bool argument", .{});
                            }
                        } else if ((std.mem.eql(u8, cname, "printFloat") or std.mem.eql(u8, cname, "printlnFloat") or
                            std.mem.eql(u8, cname, "@float_to_string") or std.mem.eql(u8, cname, "@sqrt") or
                            std.mem.eql(u8, cname, "@fabs") or std.mem.eql(u8, cname, "@floor") or
                            std.mem.eql(u8, cname, "@ceil") or std.mem.eql(u8, cname, "@round") or
                            std.mem.eql(u8, cname, "@sin") or std.mem.eql(u8, cname, "@cos")) and argc >= 1)
                        {
                            if (arg_types[0] != .float and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "'{s}' expects a float argument", .{cname});
                            }
                        } else if ((std.mem.eql(u8, cname, "exit") or std.mem.eql(u8, cname, "@exit") or
                            std.mem.eql(u8, cname, "@sleep_ms") or std.mem.eql(u8, cname, "@int_to_string")) and argc >= 1)
                        {
                            if (arg_types[0] != .int and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "'{s}' expects an integer argument", .{cname});
                            }
                        } else if ((std.mem.eql(u8, cname, "@string_len") or std.mem.eql(u8, cname, "@string_to_int") or
                            std.mem.eql(u8, cname, "@string_to_float") or std.mem.eql(u8, cname, "@getenv") or
                            std.mem.eql(u8, cname, "@unlink")) and argc >= 1)
                        {
                            if (arg_types[0] != .string and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "'{s}' expects a string argument", .{cname});
                            }
                        } else if ((std.mem.eql(u8, cname, "@string_concat") or std.mem.eql(u8, cname, "@string_eq") or
                            std.mem.eql(u8, cname, "@string_split")) and argc >= 2)
                        {
                            if ((arg_types[0] != .string and arg_types[0] != .unknown) or
                                (arg_types[1] != .string and arg_types[1] != .unknown))
                            {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "'{s}' expects two string arguments", .{cname});
                            }
                        } else if ((std.mem.eql(u8, cname, "@string_sub") or std.mem.eql(u8, cname, "@string_slice")) and argc >= 3) {
                            if ((arg_types[0] != .string and arg_types[0] != .unknown) or
                                (arg_types[1] != .int and arg_types[1] != .unknown) or
                                (arg_types[2] != .int and arg_types[2] != .unknown))
                            {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "'{s}' expects (string, int, int)", .{cname});
                            }
                        } else if (std.mem.eql(u8, cname, "@assert") and argc >= 1) {
                            if (arg_types[0] != .bool and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "@assert expects a bool argument", .{});
                            }
                        } else if (std.mem.eql(u8, cname, "@assert_eq") and argc >= 2) {
                            if (!self.isExprCompatible(arg_types[0], arg_types[1], arg_nodes[1]) and
                                !self.isExprCompatible(arg_types[1], arg_types[0], arg_nodes[0]))
                            {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "@assert_eq arguments have incompatible types", .{});
                            }
                        } else if ((std.mem.eql(u8, cname, "@malloc") or std.mem.eql(u8, cname, "@alloc")) and argc >= 1) {
                            if (arg_types[0] != .int and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "{s} expects an integer size", .{cname});
                            }
                            if (self.evalConstExpr(arg_nodes[0])) |sz| {
                                if (sz <= 0 or sz > 0x7FFF_FFFF) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time invalid allocation size {d} in {s}", .{ sz, cname });
                                }
                            }
                        } else if (std.mem.eql(u8, cname, "@array_new") and argc >= 1) {
                            if (self.evalConstExpr(arg_nodes[0])) |cap| {
                                if (cap < 0 or cap > (1 << 28)) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time invalid array capacity {d} in @array_new", .{cap});
                                }
                            }
                        } else if (std.mem.eql(u8, cname, "@chan_new") and argc >= 1) {
                            if (self.evalConstExpr(arg_nodes[0])) |cap| {
                                if (cap <= 0 or cap > (1 << 20)) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time invalid channel capacity {d} in @chan_new", .{cap});
                                }
                            }
                        } else if (std.mem.eql(u8, cname, "@checked_add") and argc >= 2) {
                            if (self.evalConstExpr(arg_nodes[0])) |va| {
                                if (self.evalConstExpr(arg_nodes[1])) |vb| {
                                    _ = std.math.add(i64, va, vb) catch {
                                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time signed integer overflow in @checked_add", .{});
                                    };
                                }
                            }
                        } else if (std.mem.eql(u8, cname, "@checked_sub") and argc >= 2) {
                            if (self.evalConstExpr(arg_nodes[0])) |va| {
                                if (self.evalConstExpr(arg_nodes[1])) |vb| {
                                    _ = std.math.sub(i64, va, vb) catch {
                                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time signed integer overflow in @checked_sub", .{});
                                    };
                                }
                            }
                        } else if (std.mem.eql(u8, cname, "@checked_mul") and argc >= 2) {
                            if (self.evalConstExpr(arg_nodes[0])) |va| {
                                if (self.evalConstExpr(arg_nodes[1])) |vb| {
                                    _ = std.math.mul(i64, va, vb) catch {
                                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time signed integer overflow in @checked_mul", .{});
                                    };
                                }
                            }
                        } else if ((std.mem.eql(u8, cname, "@read_byte") or std.mem.eql(u8, cname, "@read_u8") or
                            std.mem.eql(u8, cname, "@write_byte") or std.mem.eql(u8, cname, "@write_u8")) and argc >= 1)
                        {
                            if (arg_types[0] != .ptr and arg_types[0] != .ptr_struct and arg_types[0] != .null_t and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "'{s}' expects a pointer argument", .{cname});
                            }
                            self.checkConstPtrValid(arg_nodes[0], false, cname);
                            self.checkHeapBounds(arg_nodes[0], 1, idx);
                            if ((std.mem.eql(u8, cname, "@write_byte") or std.mem.eql(u8, cname, "@write_u8")) and self.in_spawn and self.spawn_mutex_depth == 0) {
                                if (self.extractPtrRootVar(arg_nodes[0])) |pvi| {
                                    if (pvi < self.closure_var_base) {
                                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "unsynchronized non-atomic write to shared pointer '{s}' inside spawn; use @atomic_add/@atomic_cas or mutex", .{self.vars[pvi].name});
                                    }
                                }
                            }
                        } else if ((std.mem.eql(u8, cname, "@read_u32") or std.mem.eql(u8, cname, "@write_u32")) and argc >= 1) {
                            if (arg_types[0] != .ptr and arg_types[0] != .ptr_struct and arg_types[0] != .null_t and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "'{s}' expects a pointer argument", .{cname});
                            }
                            self.checkConstPtrValid(arg_nodes[0], false, cname);
                            self.checkHeapBounds(arg_nodes[0], 4, idx);
                            if (std.mem.eql(u8, cname, "@write_u32") and self.in_spawn and self.spawn_mutex_depth == 0) {
                                if (self.extractPtrRootVar(arg_nodes[0])) |pvi| {
                                    if (pvi < self.closure_var_base) {
                                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "unsynchronized non-atomic write to shared pointer '{s}' inside spawn; use @atomic_add/@atomic_cas or mutex", .{self.vars[pvi].name});
                                    }
                                }
                            }
                        } else if ((std.mem.eql(u8, cname, "@read_u64") or std.mem.eql(u8, cname, "@write_u64")) and argc >= 1) {
                            if (arg_types[0] != .ptr and arg_types[0] != .ptr_struct and arg_types[0] != .null_t and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "'{s}' expects a pointer argument", .{cname});
                            }
                            self.checkConstPtrValid(arg_nodes[0], false, cname);
                            self.checkHeapBounds(arg_nodes[0], 8, idx);
                            if (std.mem.eql(u8, cname, "@write_u64")) {
                                if (self.in_spawn and self.spawn_mutex_depth == 0) {
                                    if (self.extractPtrRootVar(arg_nodes[0])) |pvi| {
                                        if (pvi < self.closure_var_base) {
                                            self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "unsynchronized non-atomic write to shared pointer '{s}' inside spawn; use @atomic_add/@atomic_cas or mutex", .{self.vars[pvi].name});
                                        }
                                    }
                                }
                                if (argc >= 2) self.markExprEscaped(arg_nodes[1]);
                            }
                        } else if ((std.mem.eql(u8, cname, "@memset") or std.mem.eql(u8, cname, "@secure_zero") or
                            std.mem.eql(u8, cname, "@random_bytes")) and argc >= 1)
                        {
                            self.checkConstPtrValid(arg_nodes[0], false, cname);
                            const len_idx: usize = if (std.mem.eql(u8, cname, "@memset")) 2 else 1;
                            if (argc > len_idx) {
                                if (self.evalConstExpr(arg_nodes[len_idx])) |blen| {
                                    if (blen < 0 or blen > 0x7FFF_FFFF) {
                                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time invalid length {d} in {s}", .{ blen, cname });
                                    } else {
                                        self.checkHeapBounds(arg_nodes[0], blen, idx);
                                    }
                                }
                            }
                        } else if ((std.mem.eql(u8, cname, "@memcpy") or std.mem.eql(u8, cname, "@const_time_eq")) and argc >= 3) {
                            self.checkConstPtrValid(arg_nodes[0], false, cname);
                            self.checkConstPtrValid(arg_nodes[1], false, cname);
                            if (self.evalConstExpr(arg_nodes[2])) |blen| {
                                if (blen < 0 or blen > 0x7FFF_FFFF) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time invalid length {d} in {s}", .{ blen, cname });
                                } else {
                                    self.checkHeapBounds(arg_nodes[0], blen, idx);
                                    self.checkHeapBounds(arg_nodes[1], blen, idx);
                                }
                            }
                        } else if (std.mem.eql(u8, cname, "@string_new") and argc >= 2) {
                            self.checkConstPtrValid(arg_nodes[0], false, cname);
                            if (self.evalConstExpr(arg_nodes[1])) |slen| {
                                if (slen < 0 or slen > 0x7FFF_FFFF) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time invalid string length {d} in @string_new", .{slen});
                                } else {
                                    self.checkHeapBounds(arg_nodes[0], slen, idx);
                                }
                            }
                        } else if (std.mem.eql(u8, cname, "@string_char_at") and argc >= 2) {
                            if (arg_types[0] != .string and arg_types[0] != .unknown) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "@string_char_at expects a string first argument", .{});
                            }
                            if (arg_types[1] != .int and arg_types[1] != .unknown) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "@string_char_at expects an integer index", .{});
                            }
                            if (self.evalConstExpr(arg_nodes[1])) |cidx| {
                                if (cidx < 0) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time negative string index {d} in @string_char_at", .{cidx});
                                } else if (self.ast.nodes[arg_nodes[0]].kind == .string_literal) {
                                    const snode = self.ast.nodes[arg_nodes[0]];
                                    var dec_buf: [4096]u8 = undefined;
                                    const slen = decodedStringLiteralBytes(self.srcText(snode.text_start, snode.text_len, snode.source_id), &dec_buf);
                                    if (cidx >= @as(i64, @intCast(slen))) {
                                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time string index {d} out of bounds for literal of length {d}", .{ cidx, slen });
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, cname, "@argv") and argc >= 1) {
                            if (self.evalConstExpr(arg_nodes[0])) |aidx| {
                                if (aidx < 0) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time negative @argv index {d}", .{aidx});
                                }
                            }
                        } else if ((std.mem.eql(u8, cname, "@read") or std.mem.eql(u8, cname, "@write")) and argc >= 3) {
                            if (self.evalConstExpr(arg_nodes[0])) |fdv| {
                                if (fdv < 0) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time negative file descriptor {d} in {s}", .{ fdv, cname });
                                }
                            }
                            self.checkConstPtrValid(arg_nodes[1], false, cname);
                            if (self.evalConstExpr(arg_nodes[2])) |rlen| {
                                if (rlen < 0 or rlen > 0x7FFF_FFFF) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time invalid I/O length {d} in {s}", .{ rlen, cname });
                                } else {
                                    self.checkHeapBounds(arg_nodes[1], rlen, idx);
                                }
                            }
                        } else if (std.mem.eql(u8, cname, "@ptr_add") and argc >= 2) {
                            if (arg_types[0] != .ptr and arg_types[0] != .ptr_struct and arg_types[0] != .string and arg_types[0] != .array and arg_types[0] != .unknown and arg_types[0] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "@ptr_add expects a pointer or string base", .{});
                            }
                            if (arg_types[1] != .int and arg_types[1] != .unknown and arg_types[1] != .never) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "@ptr_add expects an integer byte offset", .{});
                            }
                            self.checkConstPtrValid(arg_nodes[0], false, "@ptr_add");
                        } else if (std.mem.eql(u8, cname, "@panic") and argc >= 1) {
                            if (arg_types[0] != .string and arg_types[0] != .unknown) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "panic() expects a string message", .{});
                            }
                        } else if ((std.mem.eql(u8, cname, "@array_get") or std.mem.eql(u8, cname, "@array_set")) and argc >= 2) {
                            self.checkConstPtrValid(arg_nodes[0], false, cname);
                            if (self.evalConstExpr(arg_nodes[1])) |aidx| {
                                if (aidx < 0) {
                                    self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "compile-time negative array index {d} in {s}", .{ aidx, cname });
                                }
                            }
                            if (std.mem.eql(u8, cname, "@array_set") and argc >= 3) self.markExprEscaped(arg_nodes[2]);
                        } else if ((std.mem.eql(u8, cname, "@mutex_lock") or std.mem.eql(u8, cname, "@mutex_unlock") or
                            std.mem.eql(u8, cname, "@array_len") or std.mem.eql(u8, cname, "@array_push") or
                            std.mem.eql(u8, cname, "@map_len") or std.mem.eql(u8, cname, "@map_get") or
                            std.mem.eql(u8, cname, "@map_set") or std.mem.eql(u8, cname, "@map_has") or
                            std.mem.eql(u8, cname, "@map_del") or std.mem.eql(u8, cname, "@chan_send") or
                            std.mem.eql(u8, cname, "@chan_recv") or std.mem.eql(u8, cname, "@chan_close")) and argc >= 1)
                        {
                            self.checkConstPtrValid(arg_nodes[0], false, cname);
                            if (std.mem.eql(u8, cname, "@mutex_lock") and self.in_spawn) self.spawn_mutex_depth += 1;
                            if (std.mem.eql(u8, cname, "@mutex_unlock") and self.in_spawn and self.spawn_mutex_depth > 0) self.spawn_mutex_depth -= 1;
                            if (std.mem.eql(u8, cname, "@array_push") and argc >= 2) self.markExprEscaped(arg_nodes[1]);
                            if (std.mem.eql(u8, cname, "@map_set") and argc >= 3) self.markExprEscaped(arg_nodes[2]);
                            if (std.mem.eql(u8, cname, "@chan_send") and argc >= 2) self.markExprEscaped(arg_nodes[1]);
                        } else if (std.mem.eql(u8, cname, "@stat") and argc >= 2) {
                            self.checkConstPtrValid(arg_nodes[1], false, "@stat");
                        } else if (std.mem.eql(u8, cname, "@thread_create") and argc >= 2) {
                            if (self.ast.nodes[arg_nodes[0]].kind == .string_literal) {
                                const sn = self.ast.nodes[arg_nodes[0]];
                                var fn_buf: [256]u8 = undefined;
                                const flen = decodedStringLiteralBytes(self.srcText(sn.text_start, sn.text_len, sn.source_id), &fn_buf);
                                if (flen <= fn_buf.len and self.findFn(fn_buf[0..flen], 0) == null) {
                                    self.failAt(error.UndefinedFunctionCall, sn.source_id, sn.line, sn.col, sn.text_len, "unknown thread entry function '{s}' in @thread_create", .{fn_buf[0..flen]});
                                }
                            }
                            if (self.checkExprLocalRefOrigin(arg_nodes[1]) != 0) {
                                self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, fn_node.text_len, "dangling reference: cannot pass pointer to local stack variable to @thread_create", .{});
                            }
                            self.markExprEscaped(arg_nodes[1]);
                        } else if (std.mem.eql(u8, cname, "@thread_join") and argc >= 1) {
                            if (self.ast.nodes[arg_nodes[0]].kind == .identifier) {
                                if (self.lookupVarIdx(self.text(arg_nodes[0]))) |jvi| {
                                    for (0..self.var_count) |k| {
                                        if (self.vars[k].thread_handle_var == @as(i32, @intCast(jvi))) {
                                            self.vars[k].thread_active = false;
                                            self.vars[k].thread_handle_var = -1;
                                        }
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, cname, "@syscall") or std.mem.eql(u8, cname, "@array_map") or
                            std.mem.eql(u8, cname, "@array_filter") or std.mem.eql(u8, cname, "@array_reduce"))
                        {
                            for (0..@min(argc, MAX_PARAMS)) |k| self.markExprEscaped(arg_nodes[k]);
                        }

                        if (std.mem.eql(u8, cname, "@sqrt") or std.mem.eql(u8, cname, "@fabs") or
                            std.mem.eql(u8, cname, "@floor") or std.mem.eql(u8, cname, "@ceil") or
                            std.mem.eql(u8, cname, "@round") or std.mem.eql(u8, cname, "@sin") or
                            std.mem.eql(u8, cname, "@cos") or std.mem.eql(u8, cname, "printFloat") or
                            std.mem.eql(u8, cname, "printlnFloat") or std.mem.eql(u8, cname, "@float_to_string") or
                            std.mem.eql(u8, cname, "@string_to_float"))
                        {
                            self.info.is_float_op[idx] = true;
                        }
                        if (std.mem.eql(u8, cname, "@array_get") and argc >= 1 and arg_types[0] == .array and arg_types[0].array != .none) {
                            const elem_r = SemaType.fromTypeTag(arg_types[0].array, 0, .none);
                            if (elem_r == .float) self.info.is_float_op[idx] = true;
                            break :blk elem_r;
                        }
                        if (b.ret == .unknown and argc > 0) {
                            const r = if (std.mem.eql(u8, cname, "@array_reduce") and argc >= 2) arg_types[1] else arg_types[0];
                            if (r == .float) self.info.is_float_op[idx] = true;
                            break :blk r;
                        }
                        break :blk b.ret;
                    }

                    if (self.lookupVar(cname)) |ve| {
                        _ = self.analyzeExpr(n.child0);
                        for (0..@min(argc, MAX_PARAMS)) |k| self.markExprEscaped(arg_nodes[k]);
                        if (ve.ty == .fn_t) {
                            var fpc: u8 = 0;
                            var fpt: [MAX_PARAMS]SemaType = .{SemaType.i64_t} ** MAX_PARAMS;
                            var fret: SemaType = SemaType.i64_t;
                            if (self.fnSigFromType(ve.ty.fn_t, &fpc, &fpt, &fret)) {
                                if (argc != fpc) {
                                    self.failAt(error.InvalidArgumentCount, fn_node.source_id, fn_node.line, fn_node.col, fn_node.text_len, "function value '{s}' expects {d} arguments, got {d}", .{ cname, fpc, argc });
                                } else {
                                    for (0..argc) |k| {
                                        if (!self.isExprCompatible(fpt[k], arg_types[k], arg_nodes[k])) {
                                            self.failAt(error.TypeMismatch, fn_node.source_id, fn_node.line, fn_node.col, fn_node.text_len, "argument {d} type mismatches function value '{s}'", .{ k + 1, cname });
                                        }
                                    }
                                }
                                break :blk fret;
                            }
                            break :blk SemaType.i64_t;
                        }
                        if (ve.ty != .unknown and ve.ty != .never) {
                            self.failAt(error.TypeMismatch, fn_node.source_id, fn_node.line, fn_node.col, fn_node.text_len, "cannot call non-function variable '{s}'", .{cname});
                        }
                        break :blk .unknown;
                    }

                    if (self.findFn(cname, 0)) |sig| {
                        self.info.direct_call_fns[idx] = sig.node_idx;
                        var provided: [MAX_PARAMS]bool = .{false} ** MAX_PARAMS;
                        var named_seen = false;
                        var wrapper = n.child2;
                        var k: u32 = 0;
                        while (wrapper != 0 and k < MAX_PARAMS) : (k += 1) {
                            const wn = self.ast.nodes[wrapper];
                            var target: u32 = k;
                            if ((wn.flags & 128) != 0) {
                                named_seen = true;
                                target = sig.param_count;
                                for (sig.param_nodes[0..sig.param_count], 0..) |param, pi| {
                                    if (std.mem.eql(u8, self.text(param), self.text(wrapper))) {
                                        target = @intCast(pi);
                                        break;
                                    }
                                }
                                if (target == sig.param_count) self.failAt(error.InvalidArgumentCount, wn.source_id, wn.line, wn.col, wn.text_len, "unknown named argument '{s}'", .{self.text(wrapper)});
                            } else if (named_seen) {
                                self.failAt(error.InvalidArgumentCount, wn.source_id, wn.line, wn.col, 1, "positional argument cannot follow a named argument", .{});
                            }
                            if (target < sig.param_count) {
                                if (provided[target]) self.failAt(error.InvalidArgumentCount, wn.source_id, wn.line, wn.col, 1, "parameter '{s}' is supplied more than once", .{self.text(sig.param_nodes[target])});
                                provided[target] = true;
                                self.info.call_arg_targets[wrapper] = @intCast(target + 1);
                                if (!self.isExprCompatible(sig.param_types[target], arg_types[k], arg_nodes[k])) {
                                    self.failAt(error.TypeMismatch, wn.source_id, wn.line, wn.col, 1, "argument type mismatches parameter '{s}'", .{self.text(sig.param_nodes[target])});
                                } else self.tagTraitImplIfDyn(sig.param_types[target], arg_types[k], arg_nodes[k]);
                                self.markExprEscaped(arg_nodes[k]);
                            } else if ((wn.flags & 128) == 0) {
                                self.failAt(error.InvalidArgumentCount, n.source_id, n.line, n.col, 1, "too many arguments for function '{s}'", .{cname});
                            }
                            wrapper = wn.child1;
                        }
                        if (argc > MAX_PARAMS) self.failAt(error.TooManyArguments, n.source_id, n.line, n.col, 1, "call exceeds maximum of 8 arguments", .{});
                        for (sig.param_nodes[0..sig.param_count], 0..) |param, pi| {
                            if (!provided[pi] and self.ast.nodes[param].child2 == 0) self.failAt(error.InvalidArgumentCount, n.source_id, n.line, n.col, 1, "missing required argument '{s}'", .{self.text(param)});
                        }
                        break :blk if (sig.ret_type == .unknown) SemaType.i64_t else sig.ret_type;
                    }

                    self.failAt(error.UndefinedFunctionCall, fn_node.source_id, fn_node.line, fn_node.col, fn_node.text_len, "call to undefined function '{s}'", .{cname});
                    break :blk .unknown;
                } else {
                    // Indirect call expression e.g. get_fn()(x) or closure_arr[0](x)
                    const callee_ty = self.analyzeExpr(n.child0);
                    for (0..@min(argc, MAX_PARAMS)) |k| self.markExprEscaped(arg_nodes[k]);
                    if (callee_ty == .fn_t) {
                        var fpc: u8 = 0;
                        var fpt: [MAX_PARAMS]SemaType = .{SemaType.i64_t} ** MAX_PARAMS;
                        var fret: SemaType = SemaType.i64_t;
                        if (self.fnSigFromType(callee_ty.fn_t, &fpc, &fpt, &fret)) {
                            if (argc != fpc) {
                                self.failAt(error.InvalidArgumentCount, n.source_id, n.line, n.col, 1, "indirect call expects {d} arguments, got {d}", .{ fpc, argc });
                            } else {
                                for (0..argc) |k| {
                                    if (!self.isExprCompatible(fpt[k], arg_types[k], arg_nodes[k])) {
                                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "argument {d} type mismatches indirect callee parameter", .{k + 1});
                                    }
                                }
                            }
                            break :blk fret;
                        }
                        break :blk SemaType.i64_t;
                    }
                    if (callee_ty != .unknown and callee_ty != .never) {
                        self.failAt(error.TypeMismatch, n.source_id, n.line, n.col, 1, "cannot call non-function expression", .{});
                    }
                    break :blk .unknown;
                }
            },
            else => .unknown,
        };
        self.info.node_types[idx] = ty;
        return ty;
    }
};
