#!/usr/bin/env python3
"""테스트용 가짜 Discord REST — marina session 이 쓰는 호출만(채널·메시지·반응·역할·봇 자신).
사용: python3 fake_discord.py <dir>  → <dir>/port 에 포트를 쓰고, 받은 요청을 <dir>/log.jsonl 에 남긴다.
스위치: <dir>/fail_post 가 '403' 이면 POST 를 403 으로, '429once' 면 첫 POST 만 429. <dir>/no_chat_role 이면 chat 역할 없음."""
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
        if p == ["users", "@me"]:
            self._send(200, {"id": "BOT1", "bot": True}); return
        if len(p) == 3 and p[0] == "guilds" and p[2] == "roles":
            roles = [{"id": p[1], "name": "@everyone"}]
            if not (state / "no_chat_role").exists():
                roles.append({"id": "R-chat", "name": "chat"})
            self._send(200, roles); return
        self._send(404, {"message": "404"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        ctype = self.headers.get("Content-Type") or ""
        if ctype.startswith("multipart/form-data"):
            # 첨부 업로드 — payload_json 과 파일 이름·크기만 남긴다
            from email.parser import BytesParser
            from email.policy import default as dpol
            msg = BytesParser(policy=dpol).parsebytes(b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + raw)
            body = {"files": []}
            for part in msg.iter_parts():
                name = part.get_param("name", header="content-disposition")
                if name == "payload_json":
                    body["payload"] = json.loads(part.get_content())
                else:
                    body["files"].append({"field": name, "filename": part.get_filename(),
                                          "size": len(part.get_payload(decode=True) or b"")})
        else:
            body = json.loads(raw or b"{}") if raw else {}
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
                      "parent_id": body.get("parent_id"), "guild_id": p[1],
                      "permission_overwrites": body.get("permission_overwrites") or []}
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
