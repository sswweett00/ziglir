import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHost, runWasm} from '../runtime/browser/wasi.mjs';

// Exercise all seven imports and hostile pointers without relying on compiler output.
const output = [];
const host = createHost({args: ['app', 'çığ🙂'], stdin: 'ö', onOutput: (s, fd) => output.push([s, fd])});
const memory = new WebAssembly.Memory({initial: 3});
const v = new DataView(memory.buffer), b = new Uint8Array(memory.buffer);
const wasi = host.imports.wasi_snapshot_preview1;
assert.equal(host.start({exports: {memory, _start() {
  assert.equal(wasi.args_sizes_get(0, 4), 0);
  assert.equal(v.getUint32(0, true), 2);
  assert.equal(wasi.args_get(8, 100), 0);
  assert.equal(new TextDecoder().decode(b.subarray(104, 114)), 'çığ🙂');
  assert.equal(wasi.args_get(-1, 0), 21);
  v.setUint32(16, 200, true); v.setUint32(20, 2, true);
  assert.equal(wasi.fd_read(0, 16, 1, 24), 0);
  assert.equal(new TextDecoder().decode(b.subarray(200, 202)), 'ö');
  assert.equal(v.getUint32(24, true), 2);
  assert.equal(wasi.fd_read(0, 16, 1, 24), 0);
  assert.equal(v.getUint32(24, true), 0);
  b.set(new TextEncoder().encode('🙂'), 200);
  v.setUint32(20, 2, true);
  assert.equal(wasi.fd_write(1, 16, 1, 24), 0);
  v.setUint32(16, 202, true);
  assert.equal(wasi.fd_write(1, 16, 1, 24), 0);
  assert.deepEqual(output, [['🙂', 1]]);
  assert.equal(wasi.fd_write(3, 16, 1, 24), 8);
  assert.equal(wasi.fd_read(1, 16, 1, 24), 8);
  assert.equal(wasi.fd_write(1, -1, 1, 24), 21);
  assert.equal(wasi.fd_write(1, 16, -1, 24), 21);
  v.setUint32(16, memory.buffer.byteLength - 1, true);
  assert.equal(wasi.fd_write(1, 16, 1, 24), 21);
  assert.equal(wasi.args_sizes_get(-1, 4), 21);
  assert.equal(wasi.clock_time_get(0, 0n, 32), 0);
  assert.ok(v.getBigUint64(32, true) > 0n);
  assert.equal(wasi.clock_time_get(1, 0n, 32), 0);
  assert.equal(wasi.clock_time_get(7, 0n, 32), 28);
  assert.equal(wasi.clock_time_get(0, 0n, -1), 21);
  assert.equal(wasi.random_get(-1, 4), 21);
  assert.equal(wasi.random_get(1000, 70000), 0);
  assert.ok(b.subarray(1000, 71000).some(n => n !== 0));
  // Reacquire views after Wasm grows memory.
  memory.grow(1);
  assert.equal(wasi.args_sizes_get(0, 4), 0);
  wasi.proc_exit(7);
}}}), 7);
assert.throws(() => host.start({}), /single-use/);
assert.throws(() => createHost({args: ['bad\0arg']}), TypeError);
const trap = createHost();
assert.throws(() => trap.start({exports: {memory, _start() { throw new WebAssembly.RuntimeError('trap'); }}}), /trap/);

// Real compiler-generated Wasm, with independent expected outputs.
for (const file of process.argv.slice(2)) {
  const module = await WebAssembly.compile(await readFile(file));
  assert.deepEqual(WebAssembly.Module.imports(module).map(i => i.module), Array(7).fill('wasi_snapshot_preview1'));
  for (const count of [0, 1, 7, 100]) {
    let stdout = '';
    const code = await runWasm(module, {
      args: ['counter', ...Array(count).fill('click')],
      onOutput: (text, fd) => { assert.equal(fd, 1); stdout += text; },
    });
    assert.equal(code, 0);
    assert.equal(stdout, `${count}\n${count * count}\n`);
  }
}
console.log('Browser WASI host: all assertions passed');
