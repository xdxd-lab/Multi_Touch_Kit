#!/usr/bin/env python3
"""連線 mtk-server 的 WebSocket 並印出訊息（只用標準函式庫）。

用法：python3 ws_client.py [ws://127.0.0.1:7778] [秒數]
"""
import base64
import json
import os
import socket
import sys
import time
from urllib.parse import urlparse

# 每行立即輸出：被 timeout／管線強制結束時才不會遺失緩衝中的輸出
sys.stdout.reconfigure(line_buffering=True)

url = urlparse(sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:7778")
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 0
sock = socket.create_connection((url.hostname, url.port or 80))
key = base64.b64encode(os.urandom(16)).decode()
sock.sendall((f"GET {url.path or '/'} HTTP/1.1\r\nHost: {url.hostname}:{url.port}\r\n"
              f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
              "Sec-WebSocket-Version: 13\r\n\r\n").encode())
buffer = b""
while b"\r\n\r\n" not in buffer:
    buffer += sock.recv(4096)
header, buffer = buffer.split(b"\r\n\r\n", 1)
if b" 101 " not in header.split(b"\r\n")[0]:
    sys.exit(f"握手失敗：{header.decode(errors='replace')}")


def read(n):
    global buffer
    while len(buffer) < n:
        chunk = sock.recv(65536)
        if not chunk:
            raise ConnectionError("連線已關閉")
        buffer += chunk
    data, buffer = buffer[:n], buffer[n:]
    return data


end = time.time() + duration if duration else None
frames = 0
while end is None or time.time() < end:
    b0, b1 = read(2)
    length = b1 & 0x7F
    if length == 126:
        length = int.from_bytes(read(2), "big")
    elif length == 127:
        length = int.from_bytes(read(8), "big")
    payload = read(length)
    if b0 & 0x0F == 0x8:
        break
    if b0 & 0x0F != 0x1:
        continue
    msg = json.loads(payload)
    if msg["type"] == "frame":
        frames += 1
        began = [t["id"] for t in msg["touches"] if t["phase"] == "began"]
        if began:
            print(f'seq {msg["seq"]}: 按下 {began}，目前 {sum(t["phase"] not in ("ended", "cancelled") for t in msg["touches"])} 點')
    else:
        print(msg)
print(f"共收到 {frames} 個 frame")
