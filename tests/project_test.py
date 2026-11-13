#!/usr/bin/env python3
"""Project-manifest integration tests. All generated files stay in temp dirs."""
import json
import pathlib
import subprocess
import tempfile
import unittest
from backend_test import COMPILER, BACKENDS


class ProjectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lir-project-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)

    def invoke(self, *args, cwd=None, ok=True):
        result = subprocess.run([str(COMPILER), *args], cwd=cwd or self.root,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, ok, result.stderr + result.stdout)
        return result

    def test_generated_project_workflow(self):
        self.invoke('init', 'demo')
        project = self.root / 'demo'
        for path in ['project.manifest', 'src/main.lir', 'src/lib.lir', 'src/tests.lir', '.gitignore']:
            self.assertTrue((project / path).is_file(), path)
        self.invoke('check', cwd=project)
        self.invoke('ir', '-O0', cwd=project)
        self.invoke('build', cwd=project)
        self.assertTrue((project / 'demo.out').exists())
        for backend in BACKENDS:
            flags = ['--backend=' + backend]
            if backend == 'wasm':
                flags.append('--target=wasm32-wasi')
            with self.subTest(backend=backend):
                self.assertEqual(self.invoke('run', 'demo', *flags).stdout, 'Hello from LIR!\n')
                self.assertIn('All 1 tests passed!', self.invoke('test', *flags, cwd=project).stdout)
        self.invoke('build', 'demo', '--emit-c')
        self.assertTrue((project / 'demo.c').exists())
        self.invoke('build', 'demo', '-o', 'custom')
        self.assertTrue((self.root / 'custom').exists())
        self.invoke('build', 'demo', '--target=wasm32-wasi')
        self.assertEqual((project / 'demo.out.wasm').read_bytes()[:4], b'\x00asm')

    def test_custom_entry_paths_and_runtime_arguments(self):
        project = self.root / 'project with spaces'
        (project / 'code/nested').mkdir(parents=True)
        (project / 'code/helper.lir').write_text('fn answer() -> i64 { return 42 }')
        (project / 'code/nested/app.lir').write_text('import "../helper.lir"\nfn main() -> i64 { printInt(answer()) printInt(@argc()) return 0 }')
        (project / 'code/nested/spec.lir').write_text('import "../helper.lir"\n#[test]\nfn answer_test() { @assert_eq(answer(),42) }')
        (project / 'project.manifest').write_text(json.dumps(dict(name='custom', source_dir='code', entry='nested/app.lir', test_entry='nested/spec.lir')))
        self.assertEqual(self.invoke('run', str(project), '--backend=vm', '--', 'hello').stdout, '42\n2\n')
        self.assertIn('PASS: answer_test', self.invoke('test', str(project), '--backend=vm').stdout)
        self.invoke('check', str(project))

    def test_manifest_validation_and_output_preservation(self):
        self.invoke('init', 'demo')
        project = self.root / 'demo'
        manifest = project / 'project.manifest'
        valid = json.loads(manifest.read_text())
        invalid = ['{', '[]', '{}', '{"name":"a","name":"b"}']
        for field, value in [('name', '..'), ('entry', '../escape.lir'), ('source_dir', '/tmp'),
                             ('test_entry', 'a/../../escape'), ('entry', 'C:/escape'),
                             ('entry', 'a\\escape'), ('entry', ''), ('entry', 12),
                             ('source_dri', 'wrong'), ('dependencies', {})]:
            item = dict(valid)
            item[field] = value
            invalid.append(json.dumps(item))
        artifact = project / 'demo.out'
        artifact.write_bytes(b'previous artifact')
        for text in invalid:
            with self.subTest(manifest=text):
                manifest.write_text(text)
                self.invoke('build', 'demo', ok=False)
                self.assertEqual(artifact.read_bytes(), b'previous artifact')
        manifest.write_text(json.dumps(valid))
        self.invoke('check', 'demo')
        self.assertFalse(list(project.glob('*.lir_tmp_*')))

    def test_explicit_file_bypasses_manifest_and_missing_project_fails(self):
        (self.root / 'project.manifest').write_text('invalid json')
        (self.root / 'single.lir').write_text('fn main() -> i64 { return 0 }')
        self.invoke('check', 'single.lir')
        self.invoke('check', ok=False)
        (self.root / 'project.manifest').unlink()
        for command in ['build', 'run', 'check', 'ir', 'test']:
            self.invoke(command, ok=False)

    def test_absent_tests_do_not_silently_run_application(self):
        self.invoke('init', 'demo')
        project = self.root / 'demo'
        manifest = project / 'project.manifest'
        value = json.loads(manifest.read_text())
        del value['test_entry']
        manifest.write_text(json.dumps(value))
        self.invoke('test', 'demo', '--backend=vm')
        (project / 'src/tests.lir').unlink()
        self.assertIn('MissingTestEntry', self.invoke('test', 'demo', ok=False).stderr)


if __name__ == '__main__':
    unittest.main()
