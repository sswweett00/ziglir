#!/usr/bin/env python3
"""Reproducible, dependency-free LIR compile/startup microbenchmark.

Usage: python3 bench/bench.py ./zig-out/bin/lir examples/features-demo.lir
This reports measurements; it does not claim a universal ranking. Run on an
otherwise idle machine and compare identical source/flags/hardware/toolchains.
"""
from __future__ import annotations

import argparse
import os
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def timed(command: list[str], repeats: int, cwd: Path) -> list[float]:
    samples: list[float] = []
    for _ in range(repeats):
        start = time.perf_counter_ns()
        proc = subprocess.run(command, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        elapsed = (time.perf_counter_ns() - start) / 1e9
        if proc.returncode:
            raise RuntimeError(f"command failed ({proc.returncode}): {' '.join(command)}\n{proc.stderr.decode(errors='replace')}")
        samples.append(elapsed)
    return samples


def report(label: str, samples: list[float]) -> None:
    median = statistics.median(samples)
    print(f"{label:20} median={median * 1000:9.3f} ms  min={min(samples) * 1000:9.3f} ms  n={len(samples)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler", help="path to the LIR compiler executable")
    parser.add_argument("source", help="LIR source file to compile")
    parser.add_argument("-n", "--repeats", type=int, default=15)
    args = parser.parse_args()
    if args.repeats < 3:
        parser.error("--repeats must be at least 3")

    compiler = Path(args.compiler).resolve()
    source = Path(args.source).resolve()
    if not compiler.is_file() or not source.is_file():
        parser.error("compiler and source must be existing files")
    with tempfile.TemporaryDirectory(prefix="lir-bench-") as temp:
        work = Path(temp)
        output = work / "bench-program"
        command = [str(compiler), "build", str(source), "-o", str(output)]
        timed(command, 2, work)  # warm-up
        samples = timed(command, args.repeats, work)
        report("compile", samples)
        size = output.stat().st_size
        print(f"binary size          {size} bytes")

        # Runtime includes OS process startup, but excludes compilation.
        run_samples = timed([str(output)], args.repeats, work)
        report("runtime + startup", run_samples)
        lines = len(source.read_text(encoding="utf-8").splitlines())
        median = statistics.median(samples)
        if median > 0:
            print(f"source lines/sec     {lines / median:,.0f} (rough; includes compiler process startup)")


if __name__ == "__main__":
    main()
