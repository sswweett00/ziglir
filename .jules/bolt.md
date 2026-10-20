# Bolt's Journal - Critical Learnings

## 2026-03-02 - Lexer keyword lookup and string equality
**Learning:** Linear array searches for keywords and manual byte-by-byte string equality loops in compiler hot paths add substantial unnecessary string comparison overhead for every parsed identifier.
**Action:** Use `std.StaticStringMap` for comptime O(1) keyword lookups and `std.mem.eql` for vectorized string equality.

## 2026-03-02 - Builtin function lookup in IR generator
**Learning:** Linear `if (eql(name, ...))` chains in IR generation (`ir_gen.zig`) for builtins cause up to 27 string equality checks for every function call.
**Action:** Use `std.StaticStringMap(IROp)` in `genCall` for comptime O(1) builtin lookup.
