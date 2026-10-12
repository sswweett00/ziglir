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

For fair comparisons with other compilers, use equivalent programs and compiler
optimization settings, measure both cold and warm builds separately, and compare
multiple workload sizes. This is a measurement harness, not evidence that LIR is
the world's fastest language. No cross-language ranking is valid without
reproducible comparative data.
