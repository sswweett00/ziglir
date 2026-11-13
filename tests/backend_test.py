#!/usr/bin/env python3
"""Differential execution tests with independent expected outputs (Linux x86-64).

Requires a host C compiler for --backend=c and Node 22+ or Wasmtime for Wasm. Uses no third-party Python packages.
Every subprocess has a timeout; all generated artifacts live in temporary dirs.
"""
import pathlib
import subprocess
import sys
import tempfile
import unittest

COMPILER = pathlib.Path(sys.argv.pop(1) if len(sys.argv) > 1 else "zig-out/bin/lir").resolve()
BACKENDS = ("native", "vm", "c", "wasm")
LEVELS = ("-O0", "-O1", "-O2")
CASES = (
    ("recursion", '''
fn fib(n: i64) -> i64 {
    if n <= 1 { return n }
    return fib(n - 1) + fib(n - 2)
}
fn main() -> i64 { printInt(fib(10)) return 7 }
''', "55\n", 7),
    ("signed_arithmetic", '''
fn calc(a: i64, b: i64) -> i64 {
    printInt(a / b)
    printInt(a % b)
    printInt(a >> 2)
    printInt((b << 3) | 1)
    return 0
}
fn main() -> i64 { return calc(-37, 5) }
''', "-7\n-2\n-10\n41\n", 0),
    ("loop_and_branch", '''
fn sum(n: i64) -> i64 {
    let mut i = 0
    let mut total = 0
    while i < n {
        if i % 2 == 0 { total = total + i } else { total = total - 1 }
        i = i + 1
    }
    return total
}
fn main() -> i64 { printInt(sum(10)) return 0 }
''', "15\n", 0),
    ("strings_and_arrays", '''
fn main() -> i64 {
    let values = [4, 8, 15, 16]
    printInt(values[0] + values[3])
    let a = "hello"
    let b = " world"
    println(a + b)
    return 0
}
''', "20\nhello world\n", 0),
)


# Keep executable examples under the same cross-backend regression gates.
EXAMPLES = pathlib.Path(__file__).resolve().parents[1] / "examples"
CASES += (
    ("integer_intrinsics", (EXAMPLES / "integer-intrinsics.lir").read_text(),
     "-9223372036854775808\n-9223372036854775808\n123\n2\n"
     "-9223372036854775808\n12345\n-1\n0\n1\n"
     "-9223372036854775808\n9223372036854775807\n-2\npower\nzero\nnegative\nnot power\n", 0),
    ("integer_power", (EXAMPLES / "integer-power.lir").read_text(),
     "512\n-4\n-8\n19\n81\n1\n1\n-9223372036854775808\n0\n-1\n", 0),
    ("loop_control", (EXAMPLES / "loop-control.lir").read_text(),
     "13\nleaving loop\n3\n-7\n12\n1.5", 0),
    ("intrinsic_evaluation_order", '''
fn next(p: *i64) -> i64 { *p = *p + 1 return *p }
fn main() -> i64 {
    let mut n = 0
    printInt(@wrapping_sub(next(&n), next(&n)))
    printInt(n)
    printInt(@rotl(next(&n), next(&n)))
    printInt(n)
    return 0
}
''', "-1\n2\n48\n4\n", 0),
)


def integer_edge_case():
    """Expected bit patterns come from Python, not a second LIR backend."""
    mask = (1 << 64) - 1
    def signed(value):
        value &= mask
        return value if value < (1 << 63) else value - (1 << 64)
    source = ["fn reverse(x: i64) -> i64 { return @bit_reverse(x) }",
              "fn rotate(x: i64, n: i64) -> i64 { return @rotl(x, n) }",
              "fn main() -> i64 {"]
    expected = []
    values = [0, 1, -1, 123456789, -123456789, (1 << 63) - 1, -(1 << 63)]
    for value in values:
        # Spell MIN_I64 using a valid positive literal followed by subtraction.
        literal = str(value) if value != -(1 << 63) else "(-9223372036854775807 - 1)"
        source.append(f"printInt(reverse({literal}))")
        expected.append(signed(int(f"{value & mask:064b}"[::-1], 2)))
        for count in [-65, -1, 0, 1, 63, 64, 65]:
            n = count & 63
            bits = value & mask
            expected.append(signed((bits << n) | (bits >> ((-n) & 63))))
            source.append(f"printInt(rotate({literal}, {count}))")
    source.append("return 0 }")
    return ("integer_edges", "\n".join(source),
            "".join(f"{value}\n" for value in expected), 0)


CASES += (integer_edge_case(),)


class BackendTests(unittest.TestCase):
    def test_execution_matrix(self):
        with tempfile.TemporaryDirectory(prefix="lir-backends-") as temp:
            cwd = pathlib.Path(temp)
            for name, source, expected, exit_code in CASES:
                path = cwd / (name + ".lir")
                path.write_text(source)
                for backend in BACKENDS:
                    for level in LEVELS:
                        with self.subTest(case=name, backend=backend, level=level):
                            result = subprocess.run(
                                [str(COMPILER), "run", str(path), "--backend=" + backend, level]
                                + (["--target=wasm32-wasi"] if backend == "wasm" else []),
                                cwd=cwd, capture_output=True, text=True, timeout=30)
                            self.assertEqual(result.returncode, exit_code, result.stderr)
                            self.assertEqual(result.stdout, expected, result.stderr)

    def test_negative_runtime_exponent_traps(self):
        with tempfile.TemporaryDirectory(prefix="lir-power-trap-") as temp:
            cwd = pathlib.Path(temp)
            path = cwd / "main.lir"
            path.write_text("fn power(x: i64, n: i64) -> i64 { return x ** n }\n"
                            "fn main() -> i64 { printInt(power(2, -1)) return 0 }")
            check = subprocess.run([str(COMPILER), "check", str(path)],
                                   capture_output=True, text=True, timeout=30)
            self.assertEqual(check.returncode, 0, check.stderr)
            for backend in BACKENDS:
                for level in LEVELS:
                    with self.subTest(backend=backend, level=level):
                        args = [str(COMPILER), "run", str(path), "--backend=" + backend, level]
                        if backend == "wasm":
                            args.append("--target=wasm32-wasi")
                        result = subprocess.run(args, cwd=cwd, capture_output=True,
                                                text=True, timeout=30)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(result.stdout, "")

    def test_language_feature_diagnostics(self):
        invalid = [
            ('+"text"', "numeric"),
            ('2 ** -1', "nonnegative"),
            ('2.0 ** 3.0', "i64"),
            ('true ** 3', "i64"),
            ('(2 as u64) ** 3', "i64"),
            ('@rotl(1)', "arguments"),
            ('@rotr(1, 2, 3)', "arguments"),
            ('@bit_reverse(1.5)', "i64"),
            ('@signum(true)', "i64"),
            ('@is_power_of_two("8")', "i64"),
            ('@wrapping_add(1, false)', "i64"),
            ('@wrapping_sub(1 as u64, 1)', "i64"),
            ('@wrapping_mul(1 as i32, 2)', "i64"),
        ]
        with tempfile.TemporaryDirectory(prefix="lir-invalid-features-") as temp:
            cwd = pathlib.Path(temp)
            for expression, message in invalid:
                with self.subTest(expression=expression):
                    path = cwd / "bad.lir"
                    path.write_text(f"fn main() -> i64 {{ let value = {expression} return 0 }}")
                    result = subprocess.run([str(COMPILER), "check", str(path)],
                                            capture_output=True, text=True, timeout=30)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
            path.write_text("fn main() -> i64 { loop return 0 }")
            result = subprocess.run([str(COMPILER), "check", str(path)],
                                    capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)

    def test_o0_build_ir_matches_unoptimized_ir_command(self):
        # This specifically detects silent CLI -O0 -> -O2 promotion, rather than
        # only checking output parity (which an optimizing compiler can pass).
        with tempfile.TemporaryDirectory(prefix="lir-opt-") as temp:
            cwd = pathlib.Path(temp)
            path = cwd / "main.lir"
            path.write_text('fn main() -> i64 { let a = 6 let b = 7 printInt(a * b) return 0 }')
            def invoke(*args):
                result = subprocess.run([str(COMPILER), *args], cwd=cwd,
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout
            ir = invoke("ir", str(path), "-O0")
            optimized = invoke("ir", str(path), "-O2")
            self.assertNotEqual(ir, optimized, "fixture must distinguish optimization levels")
            build = invoke("build", str(path), "-O0", "--emit-ir", "-o", "program")
            # Build appends its artifact-size status line after the IR dump.
            self.assertIn(ir, build)
            self.assertNotIn(optimized, build)


if __name__ == "__main__":
    unittest.main()
