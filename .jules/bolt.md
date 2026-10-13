# Bolt's Journal - Critical Learnings

## 2026-03-02 - Lexer keyword lookup and string equality
**Learning:** Linear array searches for keywords and manual byte-by-byte string equality loops in compiler hot paths add substantial unnecessary string comparison overhead for every parsed identifier.
**Action:** Use `std.StaticStringMap` for comptime O(1) keyword lookups and `std.mem.eql` for vectorized string equality.
