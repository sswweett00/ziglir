#!/usr/bin/env python3
"""Paired LIR-vs-Zig microbenchmarks with correctness checks and repeated runs.

Examples:
  python3 bench/compare_zig.py --lir ./zig-out/bin/lir --zig zig
  python3 bench/compare_zig.py --repeats 7 --warmups 2

Compilation and execution are timed separately. Runtime numbers include process
startup. Outputs must match before measurements are reported. Results are
workload- and machine-specific, not a general language ranking.
"""
from __future__ import annotations

import argparse
import os
import platform
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKLOAD_DIR = Path(__file__).resolve().parent / "speed_compare"
WORKLOADS = (
    ("fib_recursive_38", "fib_recursive_38.lir", "fib_recursive_38.zig"),
    ("fib_mod_30m", "fib_mod_30m.lir", "fib_mod_30m.zig"),
    ("branch_mix_30m", "branch_mix_30m.lir", "branch_mix_30m.zig"),
    ("collatz_sequence_1m", "collatz_sequence_1m.lir", "collatz_sequence_1m.zig"),
    ("prime_count_500k", "prime_count_500k.lir", "prime_count_500k.zig"),
    ("mandelbrot_fixed_2d", "mandelbrot_fixed_2d.lir", "mandelbrot_fixed_2d.zig"),
    ("bitwise_hash_20m", "bitwise_hash_20m.lir", "bitwise_hash_20m.zig"),
    ("nested_matrix_loop_4m", "nested_matrix_loop_4m.lir", "nested_matrix_loop_4m.zig"),
    ("tak_recursive_27", "tak_recursive_27.lir", "tak_recursive_27.zig"),
)


def timed(command: list[str], cwd: Path) -> tuple[float, subprocess.CompletedProcess[bytes]]:
    start = time.perf_counter_ns()
    proc = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    elapsed = (time.perf_counter_ns() - start) / 1e9
    if proc.returncode:
        raise RuntimeError(
            f"command failed ({proc.returncode}): {' '.join(command)}\n"
            f"{proc.stderr.decode(errors='replace')}"
        )
    return elapsed, proc


def samples(values: list[float]) -> str:
    return (
        f"median {statistics.median(values) * 1000:.3f} ms; "
        f"min {min(values) * 1000:.3f}; max {max(values) * 1000:.3f}"
    )


def cpu_description() -> str:
    if platform.processor():
        return platform.processor()
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.lower().startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return "unknown"


def output(proc: subprocess.CompletedProcess[bytes]) -> str:
    # LIR writes println to stdout; std.debug.print writes to stderr.
    return (proc.stdout + proc.stderr).decode(errors="replace").strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lir", default="./zig-out/bin/lir", help="built LIR compiler")
    parser.add_argument("--zig", default="zig", help="Zig compiler executable")
    parser.add_argument("--repeats", type=int, default=7, help="measured executions per workload")
    parser.add_argument("--warmups", type=int, default=2, help="unmeasured warmup executions")
    parser.add_argument("--compile-repeats", type=int, default=3, help="measured compilation runs per workload")
    args = parser.parse_args()
    if args.repeats < 3 or args.warmups < 0:
        parser.error("--repeats must be at least 3 and --warmups cannot be negative")

    lir = shutil.which(args.lir) if not Path(args.lir).is_file() else str(Path(args.lir).resolve())
    zig = shutil.which(args.zig) if not Path(args.zig).is_file() else str(Path(args.zig).resolve())
    if not lir or not zig:
        parser.error("could not find both compiler executables")
    zig_version = subprocess.check_output([zig, "version"], text=True).strip()
    print(f"LIR -O2 vs Zig {zig_version} -O ReleaseFast")
    print(f"system: {platform.platform()} | CPU: {cpu_description()} | logical CPUs: {os.cpu_count()}")
    print(f"measured execution samples: {args.repeats}; warmups: {args.warmups}; compile samples: {args.compile_repeats}")

    with tempfile.TemporaryDirectory(prefix="lir-zig-compare-") as temp:
        work = Path(temp)
        for name, lir_name, zig_name in WORKLOADS:
            lir_source = WORKLOAD_DIR / lir_name
            zig_source = WORKLOAD_DIR / zig_name
            lir_binary = work / f"{name}-lir"
            zig_binary = work / f"{name}-zig"
            lir_cmd = [lir, "build", str(lir_source), "-O2", "-o", str(lir_binary)]
            zig_cmd = [zig, "build-exe", str(zig_source), "-O", "ReleaseFast", f"-femit-bin={zig_binary}"]

            lir_compiles: list[float] = []
            zig_compiles: list[float] = []
            for index in range(1 + args.compile_repeats):
                elapsed, _ = timed(lir_cmd, work)
                if index >= 1:
                    lir_compiles.append(elapsed)
                elapsed, _ = timed(zig_cmd, work)
                if index >= 1:
                    zig_compiles.append(elapsed)

            _, lir_check = timed([str(lir_binary)], work)
            _, zig_check = timed([str(zig_binary)], work)
            expected = output(lir_check)
            actual = output(zig_check)
            if expected != actual:
                raise RuntimeError(f"{name}: result mismatch: LIR={expected!r}, Zig={actual!r}")

            lir_runs: list[float] = []
            zig_runs: list[float] = []
            for index in range(args.warmups + args.repeats):
                lir_elapsed, lir_proc = timed([str(lir_binary)], work)
                zig_elapsed, zig_proc = timed([str(zig_binary)], work)
                if output(lir_proc) != expected or output(zig_proc) != expected:
                    raise RuntimeError(f"{name}: unstable output during repeated execution")
                if index >= args.warmups:
                    lir_runs.append(lir_elapsed)
                    zig_runs.append(zig_elapsed)

            lir_median = statistics.median(lir_runs)
            zig_median = statistics.median(zig_runs)
            lir_compile_med = statistics.median(lir_compiles)
            zig_compile_med = statistics.median(zig_compiles)
            print(f"\n{name}: validated result {expected}")
            print("  runtime + process startup")
            print("    LIR " + samples(lir_runs))
            print("    Zig " + samples(zig_runs))
            print(f"    median ratio LIR/Zig runtime: {lir_median / zig_median:.2f}x ({'LIR is ' + f'{zig_median/lir_median:.2f}x faster' if lir_median < zig_median else 'Zig is ' + f'{lir_median/zig_median:.2f}x faster'})")
            print("  compilation")
            print("    LIR " + samples(lir_compiles))
            print("    Zig " + samples(zig_compiles))
            print(f"    compile speedup: LIR compiles {zig_compile_med / lir_compile_med:.1f}x faster than Zig")
            print(f"  binary sizes: LIR {lir_binary.stat().st_size} B; Zig {zig_binary.stat().st_size} B (LIR is {zig_binary.stat().st_size / lir_binary.stat().st_size:.1f}x smaller)")


if __name__ == "__main__":
    main()
