#!/usr/bin/env python3
"""Browser host conformance plus real LIR Wasm at all optimization levels (Node 22+)."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
compiler = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else root / 'zig-out/bin/lir').resolve()
with tempfile.TemporaryDirectory(prefix='lir-browser-') as temp:
    outputs = []
    for level in range(3):
        output = pathlib.Path(temp) / f'counter-O{level}.wasm'
        subprocess.run([str(compiler), 'build', str(root / 'examples/browser-counter/main.lir'),
                        '--target=wasm32-wasi', f'-O{level}', '-o', str(output)], check=True, timeout=30)
        outputs.append(str(output))
    subprocess.run(['node', str(root / 'tests/browser_runtime_test.mjs'), *outputs], check=True, timeout=30)
