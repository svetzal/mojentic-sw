#!/usr/bin/env python3
"""Exercise the delivered RecoveryExample against scripted loopback HTTP only."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading

root = Path(__file__).resolve().parents[1]
credential = 'CREDENTIAL_SENTINEL_7d34'
private = 'PRIVATE_EVIDENCE_SENTINEL_8f21'
content = 'Recovered exactly: café 猫'
requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        requests.append((self.path, self.headers.get('Authorization'), body))
        status = 503 if len(requests) == 1 else 200
        response = ({'error': {'message': private, 'code': 'server_error'}}
                    if status == 503 else
                    {'id': 'fixture', 'model': 'scripted-model', 'choices': [
                        {'index': 0, 'message': {'role': 'assistant', 'content': content},
                         'finish_reason': 'stop'}]})
        encoded = json.dumps(response).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('X-Private-Evidence', private)
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def main():
    assert (root / 'Examples/RecoveryExample/main.swift').is_file(), 'missing delivered recovery executable'
    build = subprocess.run(['./scripts/with-gate-environment', 'swift', 'build', '-c', 'release',
                            '--product', 'RecoveryExample'], cwd=root)
    assert build.returncode == 0, 'example must be a registered, buildable SwiftPM product'
    location = subprocess.check_output(['./scripts/with-gate-environment', 'swift', 'build',
                                       '-c', 'release', '--show-bin-path'], cwd=root, text=True).strip()
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = dict(os.environ, RECOVERY_EXAMPLE_API_KEY=credential)
        result = subprocess.run([str(Path(location) / 'RecoveryExample'),
                                 f'http://127.0.0.1:{server.server_port}', '--admit-scripted-retry'],
                                cwd=root, env=env, capture_output=True, text=True, timeout=30)
        server.shutdown()
        thread.join()
    diagnostics = result.stdout + result.stderr
    print(diagnostics, end='')
    assert result.returncode == 0, f'executable failed: {result.returncode}'
    assert len(requests) == 2, f'expected exactly two completion requests, got {len(requests)}'
    assert all(path == '/v1/chat/completions' for path, _, _ in requests)
    assert all(auth == f'Bearer {credential}' for _, auth, _ in requests), 'credential sentinel must reach real HTTP'
    assert requests[0][2] == requests[1][2], 'admitted resend must preserve exact encoded bytes'
    payload = json.loads(requests[0][2])
    assert payload['model'] == 'scripted-model' and payload['stream'] is False
    assert payload['messages'] == [{'role': 'user', 'content': 'Demonstrate bounded recovery.'}]
    assert result.stdout.splitlines() == [
        'attemptFailed wire=1 status=503 eligible=true acceptance=unknown',
        'admission next=2 decision=allow', 'attemptSucceeded wire=2', content], 'exact public result and admission required'
    assert credential not in diagnostics and private not in diagnostics, 'sensitive evidence leaked'
    print('PASS: actual executable; eligible failure, explicit admission, exact content and byte-identical resend; safe diagnostics')


if __name__ == '__main__':
    main()
