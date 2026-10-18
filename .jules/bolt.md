# Bolt's Journal - Critical Learnings

## 2026-03-02 - Lexer keyword lookup and string equality
**Learning:** Linear array searches for keywords and manual byte-by-byte string equality loops in compiler hot paths add substantial unnecessary string comparison overhead for every parsed identifier.
**Action:** Use `std.StaticStringMap` for comptime O(1) keyword lookups and `std.mem.eql` for vectorized string equality.

## 2026-03-02 - Builtin IR op dispatch and string table hashing
**Learning:** Chaining 26+ sequential `if (eql(name, ...))` checks in IR lowering slows down call-expression lowering. Replacing manual byte loops in `stringHash` with `std.hash.Wyhash.hash` accelerates string interning.
**Action:** Use `std.StaticStringMap(IROp)` for $O(1)$ builtin opcode dispatches and `std.hash.Wyhash` for fast hash tables.
