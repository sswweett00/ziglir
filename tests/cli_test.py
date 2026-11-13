#!/usr/bin/env python3
"""Dependency-free CLI regression tests; all outputs stay in a temp directory."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

COMPILER = pathlib.Path(sys.argv.pop(1) if len(sys.argv) > 1 else "zig-out/bin/lir").resolve()


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="lir-cli-")
        self.addCleanup(self.temp.cleanup)
        self.cwd = pathlib.Path(self.temp.name)
        (self.cwd / "main.lir").write_text('fn main() -> i64 { println("42") 0 }\n')

    def run_cli(self, *args, ok=True):
        result = subprocess.run([str(COMPILER), *args], cwd=self.cwd,
                                capture_output=True, text=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("Error:", result.stderr)
        return result

    def test_metadata(self):
        self.assertIn("lir ", self.run_cli("version").stdout)
        self.assertIn("Usage:", self.run_cli("help").stdout)
        self.assertIn("wasm32-wasi", self.run_cli("targets").stdout)

    def test_extra_arguments_are_rejected(self):
        for command in ("build", "check", "ir", "test"):
            with self.subTest(command=command):
                self.run_cli(command, "main.lir", "extra.lir", ok=False)
        self.run_cli("init", "demo", "extra", ok=False)

    def test_unknown_options_are_rejected(self):
        for command in ("build", "check", "ir", "test"):
            with self.subTest(command=command):
                self.run_cli(command, "main.lir", "--typo", ok=False)

    def test_missing_flag_values(self):
        for command in ("build", "check", "ir", "test"):
            self.run_cli(command, "main.lir", "--target", ok=False)
        self.run_cli("build", "main.lir", "-o", ok=False)

    def test_init_is_non_destructive_and_buildable(self):
        self.run_cli("init", "demo")
        source = self.cwd / "demo/src/main.lir"
        before = source.read_bytes()
        self.run_cli("init", "demo", ok=False)
        self.assertEqual(source.read_bytes(), before)
        self.assertFalse((self.cwd / "project.manifest").exists())
        self.run_cli("check", "demo/src/main.lir")
        for name in (".", "..", "../escape", "bad/name"):
            self.run_cli("init", name, ok=False)

    def test_build_check_vm_and_c_emission(self):
        self.run_cli("check", "main.lir")
        self.assertIn("42", self.run_cli("run", "main.lir", "--backend=vm").stdout)
        self.run_cli("build", "main.lir", "-o", "program")
        self.assertTrue((self.cwd / "program").is_file())
        self.run_cli("build", "main.lir", "--emit-c", "-o", "program.c")
        self.assertIn("#include", (self.cwd / "program.c").read_text())

    def test_failed_build_preserves_existing_output(self):
        (self.cwd / "program").write_bytes(b"existing artifact")
        (self.cwd / "bad.lir").write_text('fn main() { let x = "unterminated }')
        result = subprocess.run([str(COMPILER), "build", "bad.lir", "-o", "program"],
                                cwd=self.cwd, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.cwd / "program").read_bytes(), b"existing artifact")
        self.assertFalse(list(self.cwd.glob("*.lir_tmp_*")))


if __name__ == "__main__":
    unittest.main()
