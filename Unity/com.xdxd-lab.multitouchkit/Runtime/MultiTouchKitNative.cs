using System;
using System.Runtime.InteropServices;
using System.Text;

namespace MultiTouchKit
{
    /// <summary>
    /// 原生外掛 MultiTouchKit.bundle 的 P/Invoke 宣告。
    /// 結構必須與 Sources/CMultiTouchKit/include/multitouchkit.h 完全一致（欄位順序、型別、大小）。
    /// </summary>
    public static class MultiTouchKitNative
    {
        public const string Library = "MultiTouchKit";
        public const int ExpectedApiVersion = 1;

        [StructLayout(LayoutKind.Sequential)]
        public struct Config
        {
            public int structSize;
            public int vendorId;
            public int productId;
            public int exclusive;
            public int initMultitouch;
            public int reportStationary;
            public int queueCapacity;
            public int reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct TouchEvent
        {
            public ulong touchId;
            public ulong timestampNs;
            public int deviceId;
            public int contactId;
            public int phase;
            public float x;
            public float y;
            public float pressure;
            public float width;
            public float height;
            public uint frameSeq;
            public uint flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DeviceInfo
        {
            public int deviceId;
            public int vendorId;
            public int productId;
            public int maxContacts;
            public int slotsPerReport;
            public int exclusive;
            public float physicalWidthMm;
            public float physicalHeightMm;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)] public byte[] manufacturer;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)] public byte[] product;

            public string Manufacturer => DecodeCString(manufacturer);
            public string Product => DecodeCString(product);
        }

        public const int Ok = 0;
        public const int ErrorNoWindow = -5;

        static bool? s_Available;

        /// <summary>原生外掛是否能載入（只有 macOS 編輯器與 macOS 執行檔支援）。</summary>
        public static bool IsAvailable
        {
            get
            {
                if (s_Available.HasValue) return s_Available.Value;
#if UNITY_EDITOR_OSX || UNITY_STANDALONE_OSX
                try
                {
                    int version = mtk_api_version();
                    s_Available = version == ExpectedApiVersion;
                    if (version != ExpectedApiVersion)
                        UnityEngine.Debug.LogError($"[MultiTouchKit] 原生外掛 API 版本 {version} 與 C# 端 {ExpectedApiVersion} 不符，請重新建置外掛");
                }
                catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException)
                {
                    UnityEngine.Debug.LogError($"[MultiTouchKit] 無法載入原生外掛：{e.Message}");
                    s_Available = false;
                }
#else
                s_Available = false;
#endif
                return s_Available.Value;
            }
        }

        public static string DecodeCString(byte[] bytes)
        {
            if (bytes == null) return string.Empty;
            int length = Array.IndexOf(bytes, (byte)0);
            return Encoding.UTF8.GetString(bytes, 0, length < 0 ? bytes.Length : length);
        }

        public static string Version => IsAvailable ? Marshal.PtrToStringAnsi(mtk_version()) : string.Empty;

#if UNITY_EDITOR_OSX || UNITY_STANDALONE_OSX
        [DllImport(Library)] public static extern int mtk_api_version();
        [DllImport(Library)] public static extern IntPtr mtk_version();
        [DllImport(Library)] public static extern void mtk_default_config(ref Config config);
        [DllImport(Library)] public static extern int mtk_start(ref Config config);
        [DllImport(Library)] public static extern void mtk_stop();
        [DllImport(Library)] public static extern int mtk_is_running();
        [DllImport(Library)] public static extern int mtk_poll_events([Out] TouchEvent[] buffer, int capacity);
        [DllImport(Library)] public static extern ulong mtk_dropped_event_count();
        [DllImport(Library)] public static extern int mtk_device_count();
        [DllImport(Library)] public static extern int mtk_get_device_info(int index, out DeviceInfo info);
        [DllImport(Library)] public static extern int mtk_poll_log([Out] byte[] buffer, int capacity);
        [DllImport(Library)] public static extern ulong mtk_now_ns();
        [DllImport(Library)] public static extern int mtk_map_to_window(float x, float y, uint displayId, out float outX, out float outY);
        // selector 為 UTF-8；見 docs/c-api.md。null 或 "" = 環境變數 MTK_DISPLAY 或自動
        [DllImport(Library)] public static extern int mtk_set_display([MarshalAs(UnmanagedType.LPUTF8Str)] string selector);
        [DllImport(Library)] public static extern uint mtk_touch_display_id();
#else
        // 其他平台沒有原生外掛：提供同名的空實作，讓專案在所有平台都能編譯
        public static int mtk_api_version() => 0;
        public static IntPtr mtk_version() => IntPtr.Zero;
        public static void mtk_default_config(ref Config config) { }
        public static int mtk_start(ref Config config) => -2;
        public static void mtk_stop() { }
        public static int mtk_is_running() => 0;
        public static int mtk_poll_events(TouchEvent[] buffer, int capacity) => 0;
        public static ulong mtk_dropped_event_count() => 0;
        public static int mtk_device_count() => 0;
        public static int mtk_get_device_info(int index, out DeviceInfo info) { info = default; return -4; }
        public static int mtk_poll_log(byte[] buffer, int capacity) => 0;
        public static ulong mtk_now_ns() => 0;
        public static int mtk_map_to_window(float x, float y, uint displayId, out float outX, out float outY) { outX = outY = 0; return ErrorNoWindow; }
        public static int mtk_set_display(string selector) => -1;
        public static uint mtk_touch_display_id() => 0;
#endif
    }
}
