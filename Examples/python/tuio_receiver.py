#!/usr/bin/env python3
"""接收 mtk-server 的 TUIO 1.1（/tuio/2Dcur）並印出（只用標準函式庫，內含極簡 OSC 解碼）。

用法：python3 tuio_receiver.py [PORT] [秒數]   預設 3333
"""
import socket
import struct
import sys
import time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 3333
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 0


def osc_string(data, i):
    end = data.index(b"\0", i)
    return data[i:end].decode(), (end + 4) & ~3


def osc_message(data):
    address, i = osc_string(data, 0)
    tags, i = osc_string(data, i)
    args = []
    for tag in tags[1:]:
        if tag == "i":
            args.append(struct.unpack(">i", data[i:i + 4])[0]); i += 4
        elif tag == "f":
            args.append(struct.unpack(">f", data[i:i + 4])[0]); i += 4
        elif tag == "s":
            value, i = osc_string(data, i); args.append(value)
    return address, args


def osc_packet(data):
    if not data.startswith(b"#bundle\0"):
        return [osc_message(data)]
    i, out = 16, []
    while i < len(data):
        size = struct.unpack(">i", data[i:i + 4])[0]
        out += osc_packet(data[i + 4:i + 4 + size])
        i += 4 + size
    return out


sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", port))
sock.settimeout(0.5)
print(f"等待 TUIO 127.0.0.1:{port} …")
end = time.time() + duration if duration else None
bundles = 0
alive_max = 0
while end is None or time.time() < end:
    try:
        data, _ = sock.recvfrom(65535)
    except socket.timeout:
        continue
    bundles += 1
    for address, args in osc_packet(data):
        if args and args[0] == "alive":
            alive_max = max(alive_max, len(args) - 1)
            if duration == 0:
                print(f"alive {args[1:]}")
        elif args and args[0] == "set" and duration == 0:
            print(f"  set s_id={args[1]} x={args[2]:.3f} y={args[3]:.3f}")
print(f"共收到 {bundles} 個 bundle，最多同時 {alive_max} 個 cursor")
