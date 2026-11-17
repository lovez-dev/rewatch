"""End-to-end HTTP proxy checks. Run with: python tests/proxy_integration.py <app-executable>"""

from __future__ import annotations

import http.client
import gzip
import json
import os
from pathlib import Path
import signal
import socket
from socketserver import TCPServer
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FixtureServer(ThreadingHTTPServer):
    def server_bind(self) -> None:
        # Loopback fixtures must not depend on the runner's reverse DNS service.
        TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "proxy-fixture"

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_GET(self) -> None:
        if self.path == "/":
            body = b"<!doctype html><html><head><title>fixture</title><base href='https://example.invalid/assets/'></head><body>hello</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("ETag", '"fixture"')
            self.send_header("Content-Security-Policy", "default-src 'self'")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/windows-1252":
            body = b"<html><body>caf\xe9</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=windows-1252")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/utf16":
            body = "<html><body>wide</body></html>".encode("utf-16")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-16")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/partial":
            body = b"<html><body>partial representation</body></html>"[:18]
            self.send_response(206)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Range", f"bytes 0-{len(body) - 1}/49")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/binary":
            body = bytes(range(256)) + b"\x00\xff\x80"
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/cookies":
            body = b"cookies"
            self.send_response(200)
            self.send_header("Set-Cookie", "one=1; Path=/")
            self.send_header("Set-Cookie", "two=2; HttpOnly")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/chunked":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            for chunk in (b"chunk", b"ed"):
                self.wfile.write(f"{len(chunk):X}\r\n".encode("ascii") + chunk + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            return
        if self.path == "/compressed":
            body = gzip.compress(b"<html><body>compressed html</body></html>", mtime=0)
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/empty":
            self.send_response(204)
            self.send_header("X-Fixture", "empty")
            self.end_headers()
            return
        if self.path == "/not-modified":
            self.send_response(304)
            self.send_header("ETag", '"unchanged"')
            self.end_headers()
            return
        self._echo()

    def do_HEAD(self) -> None:
        body = b"head response body"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()

    def do_POST(self) -> None:
        self._echo()

    def _echo(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        response = json.dumps(
            {
                "method": self.command,
                "path": self.path,
                "body": body.decode("latin-1"),
                "content_type": self.headers.get("Content-Type"),
            },
            separators=(",", ":"),
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def request(address: str, method: str, path: str, body: bytes | None = None, headers=None):
    host, port_text = address.rsplit(":", 1)
    connection = http.client.HTTPConnection(host, int(port_text), timeout=2)
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        data = response.read()
        return response.status, response.getheaders(), data
    finally:
        connection.close()


def state(address: str) -> tuple[int, bool]:
    status, _headers, body = request(address, "GET", "/__rewatch/state")
    assert status == 200, (status, body)
    value = json.loads(body)
    assert isinstance(value.get("generation"), int), value
    assert isinstance(value.get("ready"), bool), value
    return value["generation"], value["ready"]


def wait_until(predicate, description: str, timeout: float = 8.0):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (OSError, http.client.HTTPException, AssertionError, ValueError) as error:
            last_error = error
        time.sleep(0.04)
    raise AssertionError(f"timed out waiting for {description}; last error: {last_error}")


def stop_process(process: subprocess.Popen, timeout: float = 8.0) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name == "nt":
            process.send_signal(signal.CTRL_BREAK_EVENT)
        else:
            process.send_signal(signal.SIGTERM)
        process.wait(timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        if process.poll() is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass
        process.wait(timeout=3)
        raise AssertionError("proxy supervisor did not exit after graceful shutdown") from error


def run(app: Path) -> None:
    app = app.resolve(strict=True)
    Path("out").mkdir(exist_ok=True)
    upstream_port = free_port()
    proxy_port = free_port()
    while proxy_port == upstream_port:
        proxy_port = free_port()

    with tempfile.TemporaryDirectory(prefix="proxy-", dir="out") as temporary:
        work = Path(temporary).resolve()
        watched = work / "watched"
        watched.mkdir()
        stdout_path = work / "stdout.log"
        stderr_path = work / "stderr.log"
        stdout_file = stdout_path.open("wb")
        stderr_file = stderr_path.open("wb")
        argv = [
            str(app),
            "--no-config",
            "--cwd",
            str(work),
            "--watch",
            str(watched),
            "--poll-interval",
            "30ms",
            "--debounce",
            "80ms",
            "--stop-timeout",
            "200ms",
            "--proxy-target",
            f"http://127.0.0.1:{upstream_port}",
            "--proxy-listen",
            f"127.0.0.1:{proxy_port}",
            "--",
            sys.executable,
            str(Path(__file__).resolve()),
            "--serve",
            str(upstream_port),
            str(work / "server-runs"),
        ]
        flags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
        process = subprocess.Popen(
            argv,
            cwd=work,
            stdin=subprocess.DEVNULL,
            stdout=stdout_file,
            stderr=stderr_file,
            creationflags=flags,
            start_new_session=os.name != "nt",
        )
        address = f"127.0.0.1:{proxy_port}"
        try:
            # The proxy listens during preparation, but must not claim readiness or
            # inject a script until a real upstream response below status 500 exists.
            wait_until(lambda: request(address, "GET", "/__rewatch/state")[0] == 200, "proxy state endpoint")
            generation, ready = state(address)
            assert not ready, (generation, ready)
            # Keep the application unavailable until the proxy reports not-ready.
            unavailable_status, _unavailable_headers, _unavailable_body = request(address, "GET", "/")
            assert unavailable_status == 502, unavailable_status
            work.joinpath("allow-listen").write_text("go", encoding="ascii")

            initial_html = wait_until(
                lambda: (result if (result := request(address, "GET", "/"))[0] == 200 else None),
                "upstream readiness",
            )
            status, headers, html = initial_html
            assert status == 200
            assert b"<title>fixture</title>" in html and b"hello" in html and b"</body>" in html
            assert b"/__rewatch/client.js?session=" in html, html
            header_values = dict((key.lower(), value) for key, value in headers)
            assert int(header_values["content-length"]) == len(html), (header_values, len(html))
            assert "etag" not in header_values
            assert header_values.get("cache-control", "").lower().find("no-store") >= 0
            assert header_values.get("content-security-policy") == "default-src 'self'"
            assert b"<base href='https://example.invalid/assets/'>" in html
            script = html.split(b"<script src=", 1)[1].split(b"></script>", 1)[0]
            assert b"/__rewatch/client.js?session=" in script
            generation, ready = wait_until(lambda: (s if (s := state(address))[1] else None), "first ready generation")
            assert ready and generation > 0, (generation, ready)

            session = json.loads(request(address, "GET", "/__rewatch/state")[2])["session"]
            script_status, script_headers, script = request(address, "GET", f"/__rewatch/client.js?session={session}")
            assert script_status == 200, (script_status, script)
            assert b"new URL('state',u)" in script and (b"location.reload" in script or b"location.replace" in script), script
            assert "javascript" in dict((k.lower(), v) for k, v in script_headers).get("content-type", "")
            assert b"new URL('state',u)" in script

            # Methods, target path/query and request body pass through unchanged.
            payload = b"payload\x00with-binary"
            echoed_status, _echo_headers, echoed = request(address, "POST", "/echo?q=a%2Fb&n=2", payload)
            assert echoed_status == 200
            echo = json.loads(echoed)
            assert echo == {
                "method": "POST",
                "path": "/echo?q=a%2Fb&n=2",
                "body": payload.decode("latin-1"),
                "content_type": None,
            }, echo

            binary_status, _binary_headers, binary = request(address, "GET", "/binary")
            assert binary_status == 200 and binary == bytes(range(256)) + b"\x00\xff\x80"
            cookie_status, cookie_headers, cookie_body = request(address, "GET", "/cookies")
            cookies = [value for key, value in cookie_headers if key.lower() == "set-cookie"]
            assert cookie_status == 200 and cookie_body == b"cookies" and cookies == ["one=1; Path=/", "two=2; HttpOnly"], (cookie_status, cookies)
            chunk_status, _chunk_headers, chunk = request(address, "GET", "/chunked")
            assert chunk_status == 200 and chunk == b"chunked"
            compressed_status, compressed_headers, compressed = request(address, "GET", "/compressed")
            assert compressed_status == 200
            assert dict((k.lower(), v) for k, v in compressed_headers).get("content-encoding") == "gzip"
            assert gzip.decompress(compressed) == b"<html><body>compressed html</body></html>"
            partial_status, partial_headers, partial = request(address, "GET", "/partial", headers={"Range": "bytes=0-17"})
            assert partial_status == 206 and partial == b"<html><body>partia", (partial_status, partial)
            assert "client.js" not in partial.decode("ascii")
            assert dict((k.lower(), v) for k, v in partial_headers).get("content-range", "").startswith("bytes 0-")
            utf16_status, utf16_headers, utf16 = request(address, "GET", "/utf16")
            assert utf16_status == 200 and utf16.startswith((b"\xff\xfe", b"\xfe\xff"))
            assert "client.js" not in dict((k.lower(), v) for k, v in utf16_headers).get("content-type", "")
            assert "client.js" not in utf16.decode("utf-16")
            latin_status, latin_headers, latin = request(address, "GET", "/windows-1252")
            assert latin_status == 200 and b"\xe9" in latin and b"client.js" in latin
            assert dict((k.lower(), v) for k, v in latin_headers).get("content-length") == str(len(latin))
            head_status, head_headers, head_body = request(address, "HEAD", "/head")
            assert head_status == 200 and head_body == b""
            assert dict((k.lower(), v) for k, v in head_headers).get("content-length") == str(len(b"head response body"))
            no_content = request(address, "GET", "/empty")
            assert no_content[0] == 204 and no_content[2] == b""
            not_modified = request(address, "GET", "/not-modified")
            assert not_modified[0] == 304 and not_modified[2] == b""
            unsupported_connect = request(address, "CONNECT", f"127.0.0.1:{upstream_port}")
            assert unsupported_connect[0] == 501
            unsupported_upgrade = request(address, "GET", "/", headers={"Connection": "Upgrade", "Upgrade": "websocket"})
            assert unsupported_upgrade[0] == 501

            # A watched edit invalidates the served generation immediately. Keep
            # readiness delayed so the false state is observable before it recovers.
            watched.joinpath("change.txt").write_text("restart", encoding="utf-8")
            wait_until(lambda: not state(address)[1], "proxy to become unready")
            time.sleep(0.1)
            assert not state(address)[1]
            next_generation, next_ready = wait_until(
                lambda: (s if (s := state(address))[1] and s[0] > generation else None),
                "next ready generation",
                timeout=10,
            )
            assert next_ready and next_generation > generation
            new_html_status, _new_html_headers, new_html = request(address, "GET", "/")
            assert new_html_status == 200 and f"data-generation=\"{next_generation}\"".encode() in new_html

            # Closing the supervisor closes its listener; further connections fail.
            stop_process(process)
            assert process.returncode == 0, process.returncode
            try:
                request(address, "GET", "/__rewatch/state")
            except OSError:
                pass
            else:
                raise AssertionError("proxy listener remained open after supervisor shutdown")

            # Failed preparation must leave the listener alive without publishing a
            # ready generation or starting the application process.
            runs = work.joinpath("server-runs").read_text(encoding="ascii")
            configuration = work / "failed-preparation.toml"
            configuration.write_text(
                "pre-command = "
                + json.dumps([[sys.executable, "-c", "raise SystemExit(7)"]])
                + "\ncommand = "
                + json.dumps([sys.executable, str(Path(__file__).resolve()), "--serve", str(upstream_port), str(work / "server-runs")])
                + "\nwatch = "
                + json.dumps([str(watched)])
                + "\nproxy-target = "
                + json.dumps(f"http://127.0.0.1:{upstream_port}")
                + "\nproxy-listen = "
                + json.dumps(address)
                + "\nstop-timeout = '200ms'\n",
                encoding="utf-8",
            )
            process = subprocess.Popen(
                [str(app), "--config", str(configuration)],
                cwd=work,
                stdin=subprocess.DEVNULL,
                stdout=stdout_file,
                stderr=stderr_file,
                creationflags=flags,
                start_new_session=os.name != "nt",
            )
            wait_until(lambda: request(address, "GET", "/__rewatch/state")[0] == 200, "failed-preparation proxy")
            time.sleep(0.4)
            failed_generation, failed_ready = state(address)
            assert failed_generation == 0 and not failed_ready, (failed_generation, failed_ready)
            assert work.joinpath("server-runs").read_text(encoding="ascii") == runs
            stop_process(process)
            assert process.returncode == 0
            print("proxy integration: HTML injection, HTTP forwarding, readiness, restart generation and shutdown passed")
        except BaseException:
            print(f"supervisor exit code: {process.poll()}", file=sys.stderr)
            marker = work / "server-runs"
            print(f"upstream starts: {marker.read_text(encoding='ascii') if marker.exists() else 'none'}", file=sys.stderr)
            for label, endpoint, path in (
                ("proxy state", address, "/__rewatch/state"),
                ("upstream", f"127.0.0.1:{upstream_port}", "/"),
            ):
                try:
                    print(f"{label}: {request(endpoint, 'GET', path)}", file=sys.stderr)
                except (OSError, http.client.HTTPException) as error:
                    print(f"{label}: {error!r}", file=sys.stderr)
            stderr_file.flush()
            print(stderr_path.read_text(encoding="utf-8", errors="replace"), file=sys.stderr)
            raise
        finally:
            try:
                if process.poll() is None:
                    stop_process(process)
            finally:
                stdout_file.close()
                stderr_file.close()


def serve(port: int, marker: Path) -> None:
    marker.parent.mkdir(parents=True, exist_ok=True)
    with marker.open("a", encoding="ascii") as output:
        output.write("run\n")
    def stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    if hasattr(signal, "SIGBREAK"):
        signal.signal(signal.SIGBREAK, stop)
    while not marker.parent.joinpath("allow-listen").exists():
        time.sleep(0.02)
    # Keep every new application unavailable long enough to exercise ready gating.
    time.sleep(0.7)
    server = FixtureServer(("127.0.0.1", port), Upstream)
    server.daemon_threads = True
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--serve":
        serve(int(sys.argv[2]), Path(sys.argv[3]))
    if len(sys.argv) != 2:
        raise SystemExit("usage: python tests/proxy_integration.py <app-executable>")
    run(Path(sys.argv[1]))
