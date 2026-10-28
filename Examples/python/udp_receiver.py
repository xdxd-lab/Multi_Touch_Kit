#!/usr/bin/env python3
"""接收 mtk-server 的 UDP JSON 訊息（只用標準函式庫）。

用法：python3 udp_receiver.py [PORT]   預設 7777；先執行 mtk-server（或 mtk-server --simulate）
"""
import json
import socket
import sys

# 每行立即輸出：被 timeout／管線強制結束時才不會遺失緩衝中的輸出
sys.stdout.reconfigure(line_buffering=True)

port = int(sys.argv[1]) if len(sys.argv) > 1 else 7777
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", port))
print(f"等待 UDP 127.0.0.1:{port} …（Ctrl+C 離開）")
while True:
    data, _ = sock.recvfrom(65535)
    msg = json.loads(data)
    if msg["type"] == "frame":
        changes = [f'{t["id"]}:{t["phase"]}({t["x"]:.3f},{t["y"]:.3f})'
                   for t in msg["touches"] if t["phase"] != "stationary"]
        if changes:
            print(f'裝置 {msg["device"]} seq {msg["seq"]}: ' + " ".join(changes))
    else:
        print(msg)
