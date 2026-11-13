# LIR performance benchmarks

Build the compiler in release mode first:

```sh
zig build -Doptimize=ReleaseFast
python3 bench/bench.py ./zig-out/bin/lir examples/features-demo.lir --repeats 25
```

The script measures end-to-end compile latency (including launching `lir`) and
runtime-plus-process-startup latency separately. It warms up the compiler,
uses a unique temporary directory, checks failures, and reports median/minimum
rather than a single noisy sample. Run on an idle machine; record CPU, OS,
Zig version, commit, optimization flags, and source size when publishing results.

## LIR vs Zig comparison

`compare_zig.py` compiles paired LIR and Zig implementations of an integer
recurrence, a branch/modulo workload, and recursive Fibonacci. It validates the
program outputs before timing, warms up, then measures repeated compilation and
repeated executions separately. Runtime includes process startup. The defaults
are nine measured samples and two warmups:

```sh
python3 bench/compare_zig.py --lir ./zig-out/bin/lir --zig zig
python3 bench/compare_zig.py --repeats 15 --warmups 3
```

Both compilers use release-oriented optimization (`lir -O2`, `zig -O
ReleaseFast`). On the 2-logical-CPU Xeon host used for this run, three samples
showed LIR runtime medians of 103.1 ms, 44.9 ms, and 160.6 ms for the workloads
above, versus Zig's 104.8 ms, 46.3 ms, and 76.6 ms. LIR was near parity on the
first two and slower on recursive Fibonacci (2.10x). LIR compile medians were
about 1.8–2.1 ms; Zig's were 4.6–4.8 s for these tiny programs. These are
end-to-end compiler measurements, not an isolated LLVM benchmark, and compile
times for different languages/toolchains are not directly comparable.

The workloads avoid I/O inside timed loops and use identical algorithms and
integer results. They do not cover every workload: optimizer behavior, safety
guarantees, target tuning, and process startup differ. Treat results as specific
to these programs, compiler versions, and hardware—not a general ranking of
languages. Record system details when sharing measurements.

The native x86-64 `printInt` decimal conversion has a focused workload:

```sh
python3 bench/bench.py ./zig-out/bin/lir bench/speed_compare/print_int_200k.lir --repeats 9
```

It formats 200,000 integers with stdout discarded to reduce terminal overhead.
This is a microbenchmark of formatting plus syscall/process overhead; the regular
test suite remains the correctness check.
