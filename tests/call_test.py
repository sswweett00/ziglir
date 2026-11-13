#!/usr/bin/env python3
"""Named/optional free-function call regressions, not a C# compatibility suite."""
import pathlib
import subprocess
import tempfile
import unittest
from backend_test import COMPILER, BACKENDS, LEVELS, EXAMPLES


class CallTests(unittest.TestCase):
    def invoke(self, cwd, *args):
        return subprocess.run([str(COMPILER), *args], cwd=cwd,
                              capture_output=True, text=True, timeout=30)

    def execute_matrix(self, cwd, path, expected):
        for backend in BACKENDS:
            for level in LEVELS:
                with self.subTest(backend=backend, level=level):
                    args = ['run', str(path), level, '--backend=' + backend]
                    if backend == 'wasm':
                        args.append('--target=wasm32-wasi')
                    result = self.invoke(cwd, *args)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, expected)

    def test_named_and_optional_calls(self):
        with tempfile.TemporaryDirectory(prefix='lir-calls-') as temp:
            self.execute_matrix(temp, EXAMPLES / 'named-arguments.lir',
                                '183\n289\n285\n231\n3\nhello\ngeneric\n1.5\n')

    def test_imported_defaults_do_not_capture_caller_variables(self):
        with tempfile.TemporaryDirectory(prefix='lir-import-calls-') as temp:
            cwd = pathlib.Path(temp)
            (cwd / 'helper.lir').write_text('const BASE = 6\nfn add(x: i64, step: i64 = BASE * 2) -> i64 { return x + step }')
            path = cwd / 'main.lir'
            path.write_text('import "helper.lir"\nfn main() -> i64 { let BASE = 100 printInt(add(x: 3)) printInt(add(step: 5, x: 2)) return 0 }')
            self.execute_matrix(cwd, path, '15\n7\n')

    def test_call_diagnostics(self):
        cases = (
            ('unknown', 'fn f(x:i64)->i64{return x} fn main()->i64{return f(y:1)}', 'unknown named'),
            ('duplicate', 'fn f(x:i64)->i64{return x} fn main()->i64{return f(x:1,x:2)}', 'more than once'),
            ('duplicate_position', 'fn f(x:i64)->i64{return x} fn main()->i64{return f(1,x:2)}', 'more than once'),
            ('positional_order', 'fn f(x:i64,y:i64)->i64{return x+y} fn main()->i64{return f(y:1,2)}', 'cannot follow'),
            ('missing', 'fn f(x:i64,y:i64=2)->i64{return x+y} fn main()->i64{return f(y:3)}', 'missing required'),
            ('too_many', 'fn f(x:i64)->i64{return x} fn main()->i64{return f(1,2)}', 'too many arguments'),
            ('named_type', 'fn f(x:i64)->i64{return x} fn main()->i64{return f(x:"bad")}', 'type mismatches'),
            ('default_type', 'fn f(x:i64="bad")->i64{return x} fn main()->i64{return 0}', 'default argument type'),
            ('default_reference', 'fn f(x:i64,y:i64=x)->i64{return y} fn main()->i64{return 0}', 'compile-time constant'),
            ('default_call', 'fn g()->i64{return 1} fn f(x:i64=g())->i64{return x} fn main()->i64{return 0}', 'compile-time constant'),
            ('required_after_default', 'fn f(x:i64=1,y:i64)->i64{return x+y} fn main()->i64{return 0}', 'required parameter'),
            ('builtin', 'fn main()->i64{printInt(value:1) return 0}', 'direct free-function'),
            ('function_value', 'fn f(x:i64)->i64{return x} fn main()->i64{let g=f return g(x:1)}', 'direct free-function'),
            ('enum', 'enum E{A(i64)} fn main()->i64{let e=E::A(value:1) return 0}', 'direct free-function'),
            ('method', 'struct S{n:i64, fn f(&self,x:i64)->i64{return x}} fn main()->i64{let s=S{n:1} return s.f(x:1)}', 'direct free-function'),
            ('method_default', 'struct S{n:i64, fn f(&self,x:i64=2)->i64{return x}} fn main()->i64{return 0}', 'free function'),
            ('main_default', 'fn main(x:i64=1)->i64{return x}', 'entry-point'),
            ('comptime_named', 'fn f(x:i64)->i64{return x} fn main()->i64{let x=comptime f(x:1) return x}', 'compile-time evaluation'),
            ('const_default', 'fn f(x:i64=2)->i64{return x} const X=f() fn main()->i64{return X}', 'compile-time evaluation'),
            ('narrow_default', 'fn f(x:u8=300)->i64{return x as i64} fn main()->i64{return 0}', 'default argument type'),
        )
        with tempfile.TemporaryDirectory(prefix='lir-invalid-calls-') as temp:
            path = pathlib.Path(temp) / 'bad.lir'
            for name, source, diagnostic in cases:
                with self.subTest(case=name):
                    path.write_text(source)
                    result = self.invoke(temp, 'check', str(path))
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn(diagnostic, result.stderr)


if __name__ == '__main__':
    unittest.main()
