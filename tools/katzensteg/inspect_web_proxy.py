#!/usr/bin/env -S uv run --script
import argparse
import http.client
import http.server
import json
import os
import socket
import socketserver
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "inspector-web"


class UDSHTTPConnection(http.client.HTTPConnection):
    def __init__(self, unix_socket_path: str):
        super().__init__("localhost")
        self.unix_socket_path = unix_socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.unix_socket_path)


class Handler(http.server.SimpleHTTPRequestHandler):
    server_version = "KatzenstegInspect/0.1"

    def __init__(self, *args, directory=None, uds_path=None, **kwargs):
        self._uds_path = uds_path
        super().__init__(*args, directory=directory, **kwargs)

    def do_GET(self):
        if self.path.startswith("/inspect/"):
            self._proxy("GET")
            return
        if self.path == "/":
            self.path = "/index.html"
        return super().do_GET()

    def do_POST(self):
        if self.path.startswith("/inspect/"):
            self._proxy("POST")
            return
        self.send_error(405, "Method not allowed")

    def _proxy(self, method: str):
        target_path = self.path[len("/inspect") :]
        if not target_path:
            target_path = "/"
        body = None
        if "Content-Length" in self.headers:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length) if length > 0 else None
        conn = UDSHTTPConnection(self._uds_path)
        try:
            conn.request(method, target_path, body=body, headers={"Host": "localhost"})
            resp = conn.getresponse()
            payload = resp.read()
            self.send_response(resp.status)
            for key, value in resp.getheaders():
                if key.lower() == "transfer-encoding":
                    continue
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(payload)
        except FileNotFoundError:
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "uds_not_found", "path": self._uds_path}).encode())
        except ConnectionRefusedError:
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "uds_connection_refused", "path": self._uds_path}).encode())
        finally:
            conn.close()

    def log_message(self, fmt, *args):
        sys.stderr.write("inspect-web: " + fmt % args + "\n")


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser(description="Serve Katzensteg inspector web UI and proxy to UDS")
    parser.add_argument("--uds", default=os.environ.get("KATZENSTEG_INSPECT_SOCKET", "/tmp/katzensteg-inspect.sock"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8024)
    args = parser.parse_args()

    if not ROOT.exists():
        raise SystemExit(f"missing web root: {ROOT}")

    def handler(*h_args, **h_kwargs):
        return Handler(*h_args, directory=str(ROOT), uds_path=args.uds, **h_kwargs)

    server = ThreadingHTTPServer((args.host, args.port), handler)
    print(f"inspect-web: serving http://{args.host}:{args.port} -> uds {args.uds}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
