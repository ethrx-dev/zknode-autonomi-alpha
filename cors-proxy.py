#!/usr/bin/env python3
import http.server
import urllib.request
import json
import sys

TARGET = "http://127.0.0.1:9200"
PORT = 9250

class CorsProxy(http.server.BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_cors()
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        self.forward()

    def do_POST(self):
        self.forward()

    def send_cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Accept, Origin')

    def forward(self):
        body = None
        if self.headers.get('Content-Length'):
            try:
                length = int(self.headers['Content-Length'])
                body = self.rfile.read(length)
            except:
                pass
        url = TARGET + self.path
        try:
            req = urllib.request.Request(url, data=body,
                headers=dict(self.headers), method=self.command)
            resp = urllib.request.urlopen(req, timeout=120)
            data = resp.read()
            self.send_response(resp.status)
            self.send_cors()
            for k, v in resp.headers.items():
                kl = k.lower()
                if kl not in ('transfer-encoding', 'content-encoding', 'content-length',
                    'access-control-allow-origin', 'access-control-allow-methods',
                    'access-control-allow-headers'):
                    self.send_header(k, v)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            self.send_cors()
            for k, v in e.headers.items():
                kl = k.lower()
                if kl not in ('transfer-encoding', 'content-encoding', 'content-length',
                    'access-control-allow-origin', 'access-control-allow-methods',
                    'access-control-allow-headers'):
                    self.send_header(k, v)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_response(502)
            self.send_cors()
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(str(e).encode())

print(f"CORS proxy: {PORT} -> walletshield :9200")
http.server.HTTPServer(('0.0.0.0', PORT), CorsProxy).serve_forever()
