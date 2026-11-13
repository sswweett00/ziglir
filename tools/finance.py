#!/usr/bin/env python3
"""Build and serve only LIR Finance's public files, never repository internals."""
import argparse
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / 'apps/finance/web'
PUBLIC = {f'/apps/finance/web/{name}': WEB / name for name in
          ['index.html', 'app.mjs', 'model.mjs', 'style.css', 'finance.wasm']}
PUBLIC.update({f'/runtime/browser/{name}': ROOT / 'runtime/browser' / name for name in
               ['wasi.mjs', 'worker-client.mjs', 'worker.mjs']})
PUBLIC['/apps/finance/web/'] = WEB / 'index.html'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/':
            self.send_response(302)
            self.send_header('Location', '/apps/finance/web/')
            self.end_headers()
            return
        file = PUBLIC.get(path)
        if file is None or not file.is_file():
            self.send_error(404)
            return
        content = file.read_bytes()
        mime = 'text/javascript' if file.suffix == '.mjs' else mimetypes.guess_type(file)[0] or 'application/octet-stream'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(content)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; worker-src 'self'; object-src 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(content)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8000)
    parser.add_argument('--compiler', type=Path, default=ROOT / 'zig-out/bin/lir')
    parser.add_argument('--no-build', action='store_true')
    args = parser.parse_args()
    if not args.no_build:
        subprocess.run([str(args.compiler.resolve()), 'build', str(ROOT / 'apps/finance'),
                        '--target=wasm32-wasi', '-o', str(WEB / 'finance.wasm')], check=True, timeout=60)
    print(f'LIR Finance: http://0.0.0.0:{args.port}', flush=True)
    ThreadingHTTPServer(('0.0.0.0', args.port), Handler).serve_forever()
