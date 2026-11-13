import {runWasm} from './wasi.mjs';
// A fresh worker and Wasm instance per request. Only cloned data crosses the boundary.
self.onmessage = async ({data}) => {
  try {
    let output = '', stderr = '';
    const code = await runWasm(data.source, {
      args: data.args,
      stdin: data.stdin,
      onOutput(text, fd) {
        if (output.length + stderr.length + text.length > data.maxOutput)
          throw new Error('Output limit exceeded');
        if (fd === 1) output += text; else stderr += text;
      },
    });
    self.postMessage({ok: true, code, output, stderr});
  } catch (error) {
    self.postMessage({ok: false, error: String(error)});
  }
};
