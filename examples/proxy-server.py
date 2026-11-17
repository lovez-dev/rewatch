"""Minimal local HTTP app for the reload proxy example."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer


class LocalServer(ThreadingHTTPServer):
    def server_bind(self):
        # This loopback example needs no reverse DNS lookup during startup.
        TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><html><body><h1>Edit this example to reload</h1></body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    LocalServer(("127.0.0.1", 8080), Handler).serve_forever()
