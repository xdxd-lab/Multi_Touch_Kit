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
        /// <summary>DllImport 的程式庫名稱（Runtime/Plugins/macOS/MultiTouchKit.bundle）。</summary>
        public const string Library = "MultiTouchKit";
        /// <summary>這份 C# 宣告對應的 MTK_API_VERSION；與外掛不符時 <see cref="IsAvailable"/> 為 false。</summary>
        public const int ExpectedApiVersion = 1;

        /// <summary>MTKConfig（32 bytes）。先以 mtk_default_config 填入預設值再修改。</summary>
        [StructLayout(LayoutKind.Sequential)]
        public struct Config
        {
            /// <summary>= sizeof(MTKConfig)，由 mtk_default_config 填入。</summary>
            public int structSize;
            /// <summary>0 = 不限。</summary>
            public int vendorId;
            /// <summary>0 = 不限。</summary>
            public int productId;
            /// <summary>1 = 獨占裝置（預設）。</summary>
            public int exclusive;
            /// <summary>1 = 初始化多點模式（預設；ILITEK 必須）。</summary>
            public int initMultitouch;
            /// <summary>1 = 佇列也放入 stationary 事件（預設 0）。</summary>
            public int reportStationary;
            /// <summary>事件佇列容量；0 = 預設 4096。</summary>
            public int queueCapacity;
            /// <summary>0 = 預設 30000 ms、-1 = 關閉、&gt; 0 為毫秒（見 multitouchkit.h）</summary>
            public int staleTimeoutMs;
        }

        /// <summary>MTKTouchEvent（56 bytes）。</summary>
        [StructLayout(LayoutKind.Sequential)]
        public struct TouchEvent
        {
            /// <summary>每次觸碰唯一，從 1 開始。</summary>
            public ulong touchId;
            /// <summary>收到 HID 報告的時間（奈秒，mtk_now_ns 時基）。</summary>
            public ulong timestampNs;
            /// <summary>裝置編號（從 1 開始）。</summary>
            public int deviceId;
            /// <summary>控制器的 Contact Identifier，放開後會重複使用。</summary>
            public int contactId;
            /// <summary>MTK_PHASE_*，數值與 <see cref="MultiTouchPhase"/> 相同。</summary>
            public int phase;
            /// <summary>0..1，左 → 右。</summary>
            public float x;
            /// <summary>0..1，上 → 下。</summary>
            public float y;
            /// <summary>0..1；不支援時為 -1。</summary>
            public float pressure;
            /// <summary>正規化接觸寬度；不支援時為 -1。</summary>
            public float width;
            /// <summary>正規化接觸高度；不支援時為 -1。</summary>
            public float height;
            /// <summary>同一個 frame 的事件數值相同。</summary>
            public uint frameSeq;
            /// <summary>MTK_FLAG_*（0x1 有壓力、0x2 有尺寸、0x4 有 Confidence、0x8 低 Confidence）。</summary>
            public uint flags;
        }

        /// <summary>MTKDeviceInfo（160 bytes）。</summary>
        [StructLayout(LayoutKind.Sequential)]
        public struct DeviceInfo
        {
            /// <summary>裝置編號（從 1 開始）。</summary>
            public int deviceId;
            /// <summary>USB Vendor ID。</summary>
            public int vendorId;
            /// <summary>USB Product ID。</summary>
            public int productId;
            /// <summary>控制器宣告的最大同時觸點數。</summary>
            public int maxContacts;
            /// <summary>單一報告的觸點槽位數（小於 maxContacts 時為 hybrid mode）。</summary>
            public int slotsPerReport;
            /// <summary>1 = 已獨占。</summary>
            public int exclusive;
            /// <summary>觸控面板實體寬度（mm）；未知時為 0。</summary>
            public float physicalWidthMm;
            /// <summary>觸控面板實體高度（mm）；未知時為 0。</summary>
            public float physicalHeightMm;
            /// <summary>UTF-8，以 0 結尾；請用 <see cref="Manufacturer"/>。</summary>
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)] public byte[] manufacturer;
            /// <summary>UTF-8，以 0 結尾；請用 <see cref="Product"/>。</summary>
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)] public byte[] product;

            /// <summary>廠商名稱。</summary>
            public string Manufacturer => DecodeCString(manufacturer);
            /// <summary>產品名稱。</summary>
            public string Product => DecodeCString(product);
        }

        /// <summary>MTK_OK。</summary>
        public const int Ok = 0;
        /// <summary>MTK_ERR_NO_WINDOW：mtk_map_to_window 找不到視窗。</summary>
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

        /// <summary>以 0 結尾的 UTF-8 位元組 → 字串（沒有 0 時取整個陣列）。</summary>
        public static string DecodeCString(byte[] bytes)
        {
            if (bytes == null) return string.Empty;
            int length = Array.IndexOf(bytes, (byte)0);
            return Encoding.UTF8.GetString(bytes, 0, length < 0 ? bytes.Length : length);
        }

        /// <summary>原生外掛的版本（mtk_version）；外掛無法載入時為空字串。</summary>
        public static string Version => IsAvailable ? Marshal.PtrToStringAnsi(mtk_version()) : string.Empty;

        // 以下與 multitouchkit.h 一一對應，詳細說明（執行緒、回傳值、擁有權）以 header 為準
#if UNITY_EDITOR_OSX || UNITY_STANDALONE_OSX
        /// <summary>MTK_API_VERSION。</summary>
        [DllImport(Library)] public static extern int mtk_api_version();
        /// <summary>程式庫版本（靜態的 UTF-8 字串，不要釋放）。</summary>
        [DllImport(Library)] public static extern IntPtr mtk_version();
        /// <summary>填入預設設定（含 structSize）。</summary>
        [DllImport(Library)] public static extern void mtk_default_config(ref Config config);
        /// <summary>開始偵測與讀取；已在執行時先停止再以新設定開始。不可在回呼內呼叫。</summary>
        [DllImport(Library)] public static extern int mtk_start(ref Config config);
        /// <summary>停止並釋放裝置；仍在螢幕上的觸點以 cancelled 放入佇列。</summary>
        [DllImport(Library)] public static extern void mtk_stop();
        /// <summary>1 = 執行中。</summary>
        [DllImport(Library)] public static extern int mtk_is_running();
        /// <summary>依時間順序取出最多 capacity 個事件，回傳數量；任何執行緒皆可呼叫。</summary>
        [DllImport(Library)] public static extern int mtk_poll_events([Out] TouchEvent[] buffer, int capacity);
        /// <summary>佇列溢位（或重新同步）時丟棄的過時事件總數；溢位後下一次取出會先重新同步。</summary>
        [DllImport(Library)] public static extern ulong mtk_dropped_event_count();
        /// <summary>要求下一次 mtk_poll_events 先依目前觸點狀態重新同步。</summary>
        [DllImport(Library)] public static extern void mtk_request_resync();
        /// <summary>目前開啟的裝置數。</summary>
        [DllImport(Library)] public static extern int mtk_device_count();
        /// <summary>第 index 個裝置的資訊；超出範圍回傳 MTK_ERR_OUT_OF_RANGE。</summary>
        [DllImport(Library)] public static extern int mtk_get_device_info(int index, out DeviceInfo info);
        /// <summary>取出一則診斷訊息（UTF-8），回傳位元組數；沒有訊息時回傳 0。</summary>
        [DllImport(Library)] public static extern int mtk_poll_log([Out] byte[] buffer, int capacity);
        /// <summary>與 timestampNs 相同時基的目前時間（奈秒）。</summary>
        [DllImport(Library)] public static extern ulong mtk_now_ns();
        /// <summary>正規化座標 → 目前 key window 內容區的像素座標（原點左下）；必須在主執行緒呼叫。</summary>
        [DllImport(Library)] public static extern int mtk_map_to_window(float x, float y, uint displayId, out float outX, out float outY);
        /// <summary>選擇觸控螢幕所在的顯示器（UTF-8，格式見 docs/c-api.md）；null 或 "" = 環境變數 MTK_DISPLAY 或自動。</summary>
        [DllImport(Library)] public static extern int mtk_set_display([MarshalAs(UnmanagedType.LPUTF8Str)] string selector);
        /// <summary>目前選到的顯示器 CGDirectDisplayID；找不到時為 0。必須在主執行緒呼叫。</summary>
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
        public static void mtk_request_resync() { }
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
