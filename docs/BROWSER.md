# Browser execution: first supported bridge

LIR's existing `wasm32-wasi` emitter can now run with the small browser host in
`runtime/browser/wasi.mjs`. This is a compatibility bridge, **not** a new compiler
target, JS code generator, full WASI implementation or direct DOM API.

## Run the example

From the repository root, with a built compiler:

```sh
./zig-out/bin/lir build examples/browser-counter/main.lir --target=wasm32-wasi \
  -o examples/browser-counter/app.wasm
python3 -m http.server 8000 --bind 0.0.0.0
```

Open `/examples/browser-counter/` on that server. Serve the repository root so
that the relative runtime module URL also resolves. Opening `index.html` using
`file://` is not supported. Do not use this development server in production.

The button listener is JavaScript. Each click passes arguments into a **fresh**
Wasm instance; the LIR program calculates the count and square. JavaScript writes
its stdout to DOM `textContent`, never `innerHTML`. Clicks are capped at 1000 to
bound the example's argument list. No application state survives in LIR memory
between calls. This demonstrates an event-to-LIR-to-DOM round trip, not a
persistent component/state system or an HTTP backend.

## Host API

```js
import {runWasm} from './runtime/browser/wasi.mjs';
const response = await fetch('./app.wasm');
if (!response.ok) throw new Error(`HTTP ${response.status}`);
const module = await WebAssembly.compile(await response.arrayBuffer());
const code = await runWasm(module, {
  args: ['app.wasm', 'argument'], // argv[0] is included; UTF-8, no embedded NUL
  stdin: 'optional input',
  onOutput(text, fd) { console.log(fd, text); }, // fd 1 stdout, fd 2 stderr
});
```

`runWasm` accepts compiled `WebAssembly.Module` or bytes. Compile once and reuse
the module to avoid repeated compilation; execution still instantiates anew.
`createHost(options)` exposes `{imports, start(instance)}` for manual
instantiation. A host is single-use. The instance must export `memory` and
`_start`. `proc_exit` becomes an unsigned exit code; real Wasm traps and host
callback errors propagate as exceptions, not successful exits.

Implemented imports under `wasi_snapshot_preview1`:

| Import | Contract |
| --- | --- |
| `fd_write` | stdout/stderr only; iovecs validated; streaming UTF-8 per fd |
| `fd_read` | stdin only, supplied UTF-8 bytes, EOF returns zero bytes |
| `args_sizes_get`, `args_get` | UTF-8 byte lengths, NUL-terminated arguments |
| `random_get` | Web Crypto only, chunked at 64 KiB; no weak random fallback |
| `clock_time_get` | realtime (0), monotonic (1); nanosecond units, host precision |
| `proc_exit` | terminates the current invocation with a code |

Invalid descriptors return BADF (8), out-of-memory-range pointers return FAULT
(21), unsupported clock IDs return INVAL (28), missing crypto returns NOSYS (52).
Views are reacquired after memory growth. No filesystem, environment variables,
sockets, DOM, `fetch`, arbitrary externs, or persistent storage are exposed to
Wasm. Use HTTPS or a browser-recognized local development origin for Web Crypto.

## Limits and security

Only run trusted code. Wasm bounds checking does not stop infinite loops or
unbounded memory growth. Execution is synchronous and can block the UI thread;
`runWasm` being async does not make `_start` asynchronous or cancellable. A future
worker-based execution layer must impose lifecycle/resource limits for untrusted
or long-running code. Output callbacks are trusted host code and must not mutate
Wasm memory or reenter execution. Imported APIs do not imply all standard-library
features work in the browser; validate each program's target capabilities.

## Verification and next work

`python3 tests/browser_test.py` requires Node 22+ and a built compiler. It tests
all seven imports, Unicode split across writes, input EOF, descriptor and pointer
errors, crypto requests above 64 KiB, memory growth, traps and exit status. It
also compiles and executes the real counter at O0/O1/O2 with independent expected
outputs. These host tests run in Node's WebAssembly engine without Node WASI;
they are **not** browser UI automation or a cross-browser compatibility claim.

Next distinct steps: worker lifecycle/timeouts; explicit typed JS/DOM bindings;
async/fetch contracts; HTTP backend and shared JSON/schema types. None is
implemented merely by adding this host. See PROJECTS.md for the broader roadmap.
