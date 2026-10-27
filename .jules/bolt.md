# Bolt's Journal - Critical Learnings

## 2026-03-02 - Lexer keyword lookup and string equality
**Learning:** Linear array searches for keywords and manual byte-by-byte string equality loops in compiler hot paths add substantial unnecessary string comparison overhead for every parsed identifier.
**Action:** Use `std.StaticStringMap` for comptime O(1) keyword lookups and `std.mem.eql` for vectorized string equality.

## 2026-03-02 - Builtin IR dispatch and linear function/local symbol lookups
**Learning:** Sequential string equality cascades (`if (eql(name, "..."))`) for builtin dispatches and un-guarded string equality loops across symbol tables add unnecessary string comparisons during IR generation.
**Action:** Use `std.StaticStringMap` for builtin function lookups in IR lowering and pre-filter string comparisons with `len != name.len` in symbol table searches.
