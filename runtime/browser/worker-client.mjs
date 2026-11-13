/** Run trusted LIR Wasm off the UI thread with termination and output limits.
 * This limits lifecycle/output, not Wasm memory use or all hostile-code risks.
 */
export function runInWorker(source, {
  args = ['app.wasm'], stdin = '', timeout = 5000, maxOutput = 1000000, signal,
} = {}) {
  if (!Number.isFinite(timeout) || timeout < 1 || timeout > 120000)
    return Promise.reject(new RangeError('timeout must be 1..120000 ms'));
  if (!Number.isInteger(maxOutput) || maxOutput < 1 || maxOutput > 10000000)
    return Promise.reject(new RangeError('maxOutput must be 1..10000000 characters'));
  if (signal?.aborted) return Promise.reject(new DOMException('Aborted', 'AbortError'));
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL('./worker.mjs', import.meta.url), {type: 'module'});
    let timer, settled = false;
    function finish(error, result) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      worker.terminate();
      if (error) reject(error); else resolve(result);
    }
    const abort = () => finish(new DOMException('Aborted', 'AbortError'));
    signal?.addEventListener('abort', abort, {once: true});
    timer = setTimeout(() => finish(new Error('LIR execution timed out')), timeout);
    worker.onmessage = ({data}) => {
      if (data.ok) finish(null, {code: data.code, output: data.output, stderr: data.stderr});
      else finish(new Error(data.error));
    };
    worker.onerror = event => { event.preventDefault(); finish(new Error(event.message || 'Worker failed')); };
    worker.onmessageerror = () => finish(new Error('Worker message could not be decoded'));
    try { worker.postMessage({source, args, stdin, maxOutput}); }
    catch (error) { finish(error); }
  });
}
