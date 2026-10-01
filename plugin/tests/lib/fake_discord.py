#!/usr/bin/env python3
"""테스트용 가짜 Discord REST — marina session 이 쓰는 4개 호출만.
사용: python3 fake_discord.py <dir>  → <dir>/port 에 포트를 쓰고, 받은 요청을 <dir>/log.jsonl 에 남긴다.
스위치: <dir>/fail_post 가 '403' 이면 POST 를 403 으로, '429once' 면 첫 POST 만 429."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

state = Path(sys.argv[1]); state.mkdir(parents=True, exist_ok=True)
TOKEN = "Bot test-token"
channels = {}
next_id = [1000]
lock = threading.Lock()


def log(entry):
    with lock, open(state / "log.jsonl", "a") as f:
        f.write(json.dumps(entry) + "\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        if self.headers.get("Authorization") != TOKEN:
            self._send(401, {"message": "401: Unauthorized"})
            return False
        return True

    def _parts(self):
        return self.path.strip("/").split("/")

    def do_GET(self):
        log({"m": "GET", "p": self.path})
        if not self._auth():
            return
        p = self._parts()
        if len(p) == 3 and p[0] == "guilds" and p[2] == "channels":
            with lock:
                self._send(200, list(channels.values()))
            return
        self._send(404, {"message": "404"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}") if n else {}
        log({"m": "POST", "p": self.path, "b": body})
        if not self._auth():
            return
        fp = state / "fail_post"
        mode = fp.read_text().strip() if fp.exists() else ""
        if mode == "403":
            self._send(403, {"message": "Missing Permissions"}); return
        if mode == "429once":
            fp.unlink(); self._send(429, {"message": "rate limited", "retry_after": 0.05}); return
        p = self._parts()
        if len(p) == 3 and p[0] == "channels" and p[2] == "messages":
            self._send(200, {"id": "m-sent", "content": body.get("content")}); return
        if len(p) == 3 and p[0] == "guilds" and p[2] == "channels":
            with lock:
                next_id[0] += 1
                ch = {"id": str(next_id[0]), "name": body.get("name"), "type": body.get("type", 0),
                      "parent_id": body.get("parent_id"), "guild_id": p[1]}
                channels[ch["id"]] = ch
            self._send(201, ch); return
        self._send(404, {"message": "404"})

    def do_DELETE(self):
        log({"m": "DELETE", "p": self.path})
        if not self._auth():
            return
        p = self._parts()
        if len(p) >= 4 and p[0] == "channels" and p[2] == "messages":
            self._send(204); return
        if len(p) == 2 and p[0] == "channels":
            with lock:
                ch = channels.pop(p[1], None)
            if ch is None:
                self._send(404, {"message": "Unknown Channel"}); return
            self._send(200, ch); return
        self._send(404, {"message": "404"})


    def do_PUT(self):
        log({"m": "PUT", "p": self.path})
        if not self._auth():
            return
        self._send(204)

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
(state / "port").write_text(str(srv.server_address[1]))
srv.serve_forever()
