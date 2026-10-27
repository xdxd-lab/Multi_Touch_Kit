#!/usr/bin/env python3
"""用 ctypes 直接呼叫 MultiTouchKit C API（不需要 mtk-server）。

用法：python3 native_ctypes.py [秒數] [程式庫路徑]
程式庫預設依序尋找：.build/release/libMultiTouchKitC.dylib、Unity 套件內的 MultiTouchKit.bundle。
結構定義必須與 Sources/CMultiTouchKit/include/multitouchkit.h 一致。
"""
import ctypes
import pathlib
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
CANDIDATES = [
    ROOT / ".build/release/libMultiTouchKitC.dylib",
    ROOT / "Unity/com.xdxd-lab.multitouchkit/Runtime/Plugins/macOS/MultiTouchKit.bundle/Contents/MacOS/MultiTouchKit",
]


class Config(ctypes.Structure):
    _fields_ = [(name, ctypes.c_int32) for name in (
        "struct_size", "vendor_id", "product_id", "exclusive",
        "init_multitouch", "report_stationary", "queue_capacity", "reserved")]


class TouchEvent(ctypes.Structure):
    _fields_ = [
        ("touch_id", ctypes.c_uint64), ("timestamp_ns", ctypes.c_uint64),
        ("device_id", ctypes.c_int32), ("contact_id", ctypes.c_int32), ("phase", ctypes.c_int32),
        ("x", ctypes.c_float), ("y", ctypes.c_float), ("pressure", ctypes.c_float),
        ("width", ctypes.c_float), ("height", ctypes.c_float),
        ("frame_seq", ctypes.c_uint32), ("flags", ctypes.c_uint32),
    ]


class DeviceInfo(ctypes.Structure):
    _fields_ = [
        ("device_id", ctypes.c_int32), ("vendor_id", ctypes.c_int32), ("product_id", ctypes.c_int32),
        ("max_contacts", ctypes.c_int32), ("slots_per_report", ctypes.c_int32), ("exclusive", ctypes.c_int32),
        ("physical_width_mm", ctypes.c_float), ("physical_height_mm", ctypes.c_float),
        ("manufacturer", ctypes.c_char * 64), ("product", ctypes.c_char * 64),
    ]


PHASES = ["began", "moved", "stationary", "ended", "cancelled"]
seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 10
path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else next((p for p in CANDIDATES if p.exists()), None)
if path is None:
    sys.exit("找不到程式庫，請先執行 swift build -c release 或 scripts/build-unity-plugin.sh")

lib = ctypes.CDLL(str(path))
lib.mtk_version.restype = ctypes.c_char_p
lib.mtk_now_ns.restype = ctypes.c_uint64
lib.mtk_poll_events.argtypes = [ctypes.POINTER(TouchEvent), ctypes.c_int32]
lib.mtk_poll_log.argtypes = [ctypes.c_char_p, ctypes.c_int32]
lib.mtk_get_device_info.argtypes = [ctypes.c_int32, ctypes.POINTER(DeviceInfo)]
assert ctypes.sizeof(Config) == 32 and ctypes.sizeof(TouchEvent) == 56 and ctypes.sizeof(DeviceInfo) == 160

log = ctypes.create_string_buffer(512)


def drain_logs():
    while lib.mtk_poll_log(log, len(log)) > 0:
        print(log.value.decode())


print(f"MultiTouchKit {lib.mtk_version().decode()}（API {lib.mtk_api_version()}）：{path.name}")
config = Config()
lib.mtk_default_config(ctypes.byref(config))
if lib.mtk_start(ctypes.byref(config)) != 0:
    drain_logs()
    sys.exit("mtk_start 失敗")
drain_logs()
for i in range(lib.mtk_device_count()):
    info = DeviceInfo()
    lib.mtk_get_device_info(i, ctypes.byref(info))
    print(f"裝置 #{info.device_id} {info.manufacturer.decode()} {info.product.decode()}：最多 {info.max_contacts} 點")

events = (TouchEvent * 256)()
end = time.time() + seconds
began = 0
try:
    while time.time() < end:
        n = lib.mtk_poll_events(events, 256)
        for e in events[:n]:
            began += e.phase == 0
            print(f"touch {e.touch_id} (cid {e.contact_id}) {PHASES[e.phase]:<10} x={e.x:.4f} y={e.y:.4f}")
        drain_logs()
        time.sleep(0.002)
finally:
    lib.mtk_stop()
print(f"共 {began} 次按下")
