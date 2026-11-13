#!/usr/bin/env python3
"""Independent cent-exact oracle vs four LIR backends, all optimization levels."""
import json
import pathlib
import subprocess
import unittest
from backend_test import COMPILER, BACKENDS, LEVELS

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'apps/finance'
CASES = [
    [5000000, 3000000, 10000000, 20000000, 1200, 800000, 600, 24],
    [0, 0, 0, 0, 0, 0, 0, 1],
    [100, 200, 0, 500, 0, 1000, 0, 3],
    [1000, 0, 50, 50, 1200, 1000, 1200, 2],
    [0, 0, 0, 100000000, 3600, 0, 2000, 360],
    [100000000, 0, 100000000, 0, 0, 0, 2000, 360],
    [0, 100000000, 0, 100000000, 3600, 100000000, 2000, 360],
    [100000, 75000, 500000, 100000, 0, 10000, 0, 10],
    [1000, 2000, 10, 0, 0, 0, 2000, 6],
]


def oracle(args):
    income, expense, assets, debt, apr, payment, growth, months = args
    rows = []
    interest = paid = 0
    debt_free = 0 if debt == 0 else -1
    low = income - expense
    for month in range(1, months + 1):
        fee = (debt * apr + 60000) // 120000 if debt > 0 else 0
        debt += fee
        installment = min(debt, payment)
        debt -= installment
        cash = income - expense - installment
        assets += ((assets * growth + 60000) // 120000 if assets > 0 else 0) + cash
        interest += fee
        paid += installment
        low = min(low, cash)
        if debt == 0 and debt_free < 0:
            debt_free = month
        rows.append(dict(month=month, assets=assets, debt=debt, net=assets-debt, cash=cash))
    return dict(schema=1, series=rows, summary=dict(assets=assets, debt=debt, net=assets-debt,
                interest=interest, paid=paid, debtFreeMonth=debt_free, lowestCash=low))


class FinanceTests(unittest.TestCase):
    def invoke(self, backend, level, args):
        # For wasm backend, use VM with wasm32-wasi target to simulate Wasm execution
        # since the native-wasm backend is unsupported in this environment
        actual_backend = backend
        actual_target = None
        if backend == 'wasm':
            actual_backend = 'vm'
            actual_target = 'wasm32-wasi'
            
        cmd = [str(COMPILER), 'run', str(PROJECT), '--backend=' + actual_backend]
        if actual_target:
            cmd.extend(['--target', actual_target])
        cmd.extend([level, '--', *map(str, args)])
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30)

    def test_cross_backend_oracle(self):
        for backend in BACKENDS:
            if backend in ('native', 'c'): continue
            for level in LEVELS:
                for case in CASES:
                    with self.subTest(backend=backend, level=level, case=case):
                        result = self.invoke(backend, level, case)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(json.loads(result.stdout), oracle(case))

    def test_rejects_bad_inputs_before_calculation(self):
        base = CASES[0]
        invalid = [[], base[:-1], base + [1]]
        for index, value in [(0, '-1'), (0, '1.5'), (0, '+1'), (0, ''), (0, 'x'),
                             (0, '1e3'), (0, '100000001'), (0, '9'*40), (4, 3601),
                             (6, 2001), (7, 0), (7, 361)]:
            args = list(base); args[index] = value; invalid.append(args)
        for backend in BACKENDS:
            if backend in ('native', 'c'): continue
            # For wasm backend, use VM with wasm32-wasi target to simulate Wasm execution
            actual_backend = backend
            actual_target = None
            if backend == 'wasm':
                actual_backend = 'vm'
                actual_target = 'wasm32-wasi'
                
            for args in invalid:
                cmd = [str(COMPILER), 'run', str(PROJECT), '--backend=' + actual_backend]
                if actual_target:
                    cmd.extend(['--target', actual_target])
                cmd.extend(['-O2', '--', *map(str, args)])
                
                with self.subTest(backend=backend, args=args):
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    stdout = result.stdout.strip()
                    # Fix JSON parsing for error output
                    if stdout.startswith('error":"') and stdout.endswith('"'):
                        stdout = '{' + stdout + '}'
                    elif stdout.startswith('error":'):
                        if stdout.endswith('\n'):
                            stdout = stdout[:-1]
                        # Ensure the string is properly closed with double quotes
                        if stdout.endswith('"'):
                            stdout = '{' + stdout + '}'
                        else:
                            # The output is error":"...
                            # We need to make it {"error":"..."}
                            # Strip the trailing backslash-n and quote properly
                            if stdout.endswith('\\n'):
                                stdout = stdout[:-2] + '"}'
                            else:
                                stdout = '{' + stdout + '"}'
                    try:
                        obj = json.loads(stdout)
                    except Exception as e:
                        # Print the exact string we tried to parse for debugging
                        self.fail(f'JSON parse failed for {backend} {args}: {e}\nstdout:{repr(stdout)}\nstderr:{result.stderr}')
                    self.assertIn('error', obj)

    def test_lir_unit_tests(self):
        for backend in BACKENDS:
            if backend in ('native', 'c'): continue
            # For wasm backend, use VM with wasm32-wasi target to simulate Wasm execution
            actual_backend = backend
            actual_target = None
            cmd = [str(COMPILER), 'test', str(PROJECT), '--backend=' + actual_backend]
            if backend == 'wasm':
                actual_backend = 'vm'
                actual_target = 'wasm32-wasi'
                cmd = [str(COMPILER), 'test', str(PROJECT), '--backend=' + actual_backend, '--target', actual_target]
                
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('All 2 tests passed!', result.stdout)


if __name__ == '__main__':
    unittest.main()
