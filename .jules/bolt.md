# Bolt's Journal - Critical Learnings

## 2026-03-02 - Lexer keyword lookup and string equality
**Learning:** Linear array searches for keywords and manual byte-by-byte string equality loops in compiler hot paths add substantial unnecessary string comparison overhead for every parsed identifier.
**Action:** Use `std.StaticStringMap` for comptime O(1) keyword lookups and `std.mem.eql` for vectorized string equality.

## 2026-03-02 - String slice bounds and fast length comparisons
**Learning:** Comparing pointer offsets across arbitrary string slice allocations can lead to false positive string matches if not strictly bounds-checked against source buffer limits. Plain string length checks (`len != len`) are 100% safe and eliminate string comparison calls without pointer math risks.
**Action:** Use early length checks (`len != len`) and prefix character dispatch (`name[0] == '@'`) to skip non-matching string comparisons safely.
