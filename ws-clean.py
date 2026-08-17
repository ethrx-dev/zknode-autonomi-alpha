#!/usr/bin/env python3
import http.server
import urllib.request
import sys

TARGET = "http://127.0.0.1:9200"
PORT = 9250

class CleanProxy(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.forward()
    def do_POST(self):
        self.forward()
    def do_OPTIONS(self):
        self.send_response(200)

    def forward(self):
        body = None
        if self.headers.get('Content-Length'):
            length = int(self.headers['Content-Length'])
            body = self.rfile.read(length)
        url = TARGET + self.path
        req = urllib.request.Request(url, data=body, headers=dict(self.headers),
            method=self.command)
        try:
            resp = urllib.request.urlopen(req, timeout=60)
            data = resp.read()
            # Strip null bytes
            data = data.replace(b'\x00', b'')
            self.send_response(resp.status)
            for k, v in resp.headers.items():
                if k.lower() not in ('transfer-encoding', 'content-encoding', 'content-length'):
                    self.send_header(k, v)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except urllib.error.HTTPError as e:
            data = e.read()
            data = data.replace(b'\x00', b'')
            self.send_response(e.code)
            for k, v in e.headers.items():
                if k.lower() not in ('transfer-encoding', 'content-encoding'):
                    self.send_header(k, v)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_error(502, str(e))

http.server.HTTPServer(('127.0.0.1', PORT), CleanProxy).serve_forever()
