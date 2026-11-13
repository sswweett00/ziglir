/** Minimal browser host for LIR's seven WASI preview1 imports.
 * No filesystem, network, environment, or DOM access is granted to Wasm.
 * Synchronous execution is NOT a sandbox against infinite loops/memory growth.
 */
export function createHost({args = ['app.wasm'], stdin = '', onOutput = () => {}} = {}) {
  const encoder = new TextEncoder();
  if (!Array.isArray(args) || args.some(a => typeof a !== 'string' || a.includes('\0')))
    throw new TypeError('args must be NUL-free strings');
  const argv = args.map(a => encoder.encode(a + '\0'));
  const input = encoder.encode(stdin);
  let cursor = 0, memory, started = false;
  const exit = {};
  let exitCode;
  const decoders = {1: new TextDecoder(), 2: new TextDecoder()};
  const view = () => new DataView(memory.buffer);
  const valid = (p, n) => Number.isInteger(p) && Number.isInteger(n) && p >= 0 && n >= 0 && p <= memory.buffer.byteLength && n <= memory.buffer.byteLength - p;
  const bytes = (p, n) => new Uint8Array(memory.buffer, p, n);
  function vectors(ptr, count, result) {
    ptr >>>= 0; count >>>= 0; result >>>= 0;
    if (!valid(ptr, count * 8) || !valid(result, 4)) return null;
    const entries = [];
    for (let i = 0; i < count; i++) {
      const p = view().getUint32(ptr + i * 8, true), n = view().getUint32(ptr + i * 8 + 4, true);
      if (!valid(p, n)) return null;
      entries.push([p, n]);
    }
    return entries;
  }
  const imports = {wasi_snapshot_preview1: {
    fd_write(fd, ptr, count, result) {
      if (fd !== 1 && fd !== 2) return 8; // BADF
      const entries = vectors(ptr, count, result);
      if (!entries) return 21; // FAULT
      let written = 0;
      for (const [p, n] of entries) {
        const text = decoders[fd].decode(bytes(p, n), {stream: true});
        written += n;
        if (text) onOutput(text, fd);
      }
      view().setUint32(result >>> 0, written, true);
      return 0;
    },
    fd_read(fd, ptr, count, result) {
      if (fd !== 0) return 8;
      const entries = vectors(ptr, count, result);
      if (!entries) return 21;
      let read = 0;
      for (const [p, n] of entries) {
        const size = Math.min(n, input.length - cursor);
        bytes(p, size).set(input.subarray(cursor, cursor + size));
        cursor += size; read += size;
      }
      view().setUint32(result >>> 0, read, true);
      return 0;
    },
    proc_exit(code) { exitCode = code >>> 0; throw exit; },
    random_get(p, n) {
      p >>>= 0; n >>>= 0;
      if (!valid(p, n)) return 21;
      if (!globalThis.crypto?.getRandomValues) return 52; // NOSYS, no weak fallback
      for (let offset = 0; offset < n; offset += 65536)
        globalThis.crypto.getRandomValues(bytes(p + offset, Math.min(65536, n - offset)));
      return 0;
    },
    clock_time_get(id, precision, p) {
      p >>>= 0;
      if (!valid(p, 8)) return 21;
      if (id !== 0 && id !== 1) return 28; // INVAL
      const ns = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.floor(performance.now() * 1e6));
      view().setBigUint64(p, ns, true);
      return 0;
    },
    args_sizes_get(count, size) {
      count >>>= 0; size >>>= 0;
      if (!valid(count, 4) || !valid(size, 4)) return 21;
      view().setUint32(count, argv.length, true);
      view().setUint32(size, argv.reduce((n, a) => n + a.length, 0), true);
      return 0;
    },
    args_get(ptr, buffer) {
      ptr >>>= 0; buffer >>>= 0;
      const total = argv.reduce((n, a) => n + a.length, 0);
      if (!valid(ptr, argv.length * 4) || !valid(buffer, total)) return 21;
      for (let i = 0; i < argv.length; i++) {
        view().setUint32(ptr + i * 4, buffer, true);
        bytes(buffer, argv[i].length).set(argv[i]); buffer += argv[i].length;
      }
      return 0;
    },
  }};
  return {
    imports,
    start(instance) {
      if (started) throw new Error('host instances are single-use');
      started = true;
      memory = instance.exports.memory;
      if (!(memory instanceof WebAssembly.Memory) || typeof instance.exports._start !== 'function')
        throw new TypeError('expected exported memory and _start');
      try { instance.exports._start(); }
      catch (error) { if (error !== exit) throw error; }
      finally {
        for (const fd of [1, 2]) {
          const text = decoders[fd].decode();
          if (text) onOutput(text, fd);
        }
      }
      return exitCode ?? 0;
    },
  };
}

/** Compile/instantiate afresh per invocation: no persistent LIR state. */
export async function runWasm(source, options) {
  const host = createHost(options);
  const module = source instanceof WebAssembly.Module ? source : await WebAssembly.compile(source);
  const instance = await WebAssembly.instantiate(module, host.imports);
  return host.start(instance);
}
