using System;
using System.Collections.Generic;
using UnityEngine;
#if MTK_INPUT_SYSTEM
using UnityEngine.InputSystem;
#endif

namespace MultiTouchKit
{
    /// <summary>
    /// 場景中放一個即可：啟動觸控來源、每幀取出事件、換算螢幕座標，並發出 <see cref="TouchReceived"/>。
    /// 有安裝 Input System 時，也會把觸控送進一個虛擬 Touchscreen 裝置。
    /// </summary>
    [DefaultExecutionOrder(-1000)]
    [AddComponentMenu("MultiTouchKit/MultiTouchKit Manager")]
    public sealed class MultiTouchKitManager : MonoBehaviour
    {
        /// <summary>觸控資料的來源。</summary>
        public enum TransportMode
        {
            /// <summary>程序內直接讀取（最低延遲，只支援 macOS）</summary>
            Native,
            /// <summary>接收 mtk-server 的 UDP JSON</summary>
            Udp,
        }

        /// <summary>正規化座標換算成 Unity 螢幕座標的方式。</summary>
        public enum ScreenMappingMode
        {
            /// <summary>假設遊戲全螢幕顯示在觸控螢幕上：正規化座標直接乘上 Screen 尺寸</summary>
            FullScreen,
            /// <summary>依目前視窗位置換算（視窗模式時使用；需要原生外掛）</summary>
            KeyWindow,
        }

        /// <summary>觸控資料的來源；修改後呼叫 <see cref="Restart"/>。</summary>
        [Tooltip("Native：程序內直接讀取（最低延遲）；Udp：接收 mtk-server 的 UDP JSON")]
        public TransportMode transport = TransportMode.Native;
        /// <summary>Udp 模式監聽的埠（mtk-server 預設送到 7777）。</summary>
        [Tooltip("Udp 模式監聽的埠")]
        public int udpPort = 7777;
        /// <summary>Udp 模式監聽的位址；空白 = 127.0.0.1（只接收本機）。</summary>
        [Tooltip("Udp 模式監聽的位址。空白 = 127.0.0.1（只接收本機）；接收其他電腦的 mtk-server 時填 0.0.0.0")]
        public string udpBindAddress = "";
        /// <summary>Udp 模式：有觸點時超過此秒數沒有資料就全部 Cancelled；0 = 關閉。</summary>
        [Tooltip("Udp 模式：有觸點時超過此秒數沒有收到 mtk-server 的資料就全部 Cancelled（mtk-server 被強制結束等）；0 = 關閉")]
        public float udpTimeout = 0.5f;
        /// <summary>Native 模式：獨占觸控螢幕，系統游標不再跟著觸控移動。</summary>
        [Tooltip("獨占觸控螢幕，系統不再把觸控當成單點滑鼠")]
        public bool exclusive = true;
        /// <summary>Native 模式：只使用指定 Vendor ID 的裝置（0 = 不限）。</summary>
        [Tooltip("只使用指定的 Vendor ID（0 = 不限）")]
        public int vendorId;
        /// <summary>Native 模式：只使用指定 Product ID 的裝置（0 = 不限）。</summary>
        [Tooltip("只使用指定的 Product ID（0 = 不限）")]
        public int productId;
        /// <summary>換算 <see cref="MultiTouchTouch.ScreenPosition"/> 的方式。</summary>
        public ScreenMappingMode screenMapping = ScreenMappingMode.FullScreen;
        /// <summary>KeyWindow 模式：觸控螢幕所在的顯示器（格式見 docs/c-api.md）；空白 = 依面板尺寸自動挑選。</summary>
        [Tooltip("觸控螢幕所在的顯示器（KeyWindow 模式使用）。空白 = 自動依面板尺寸挑選；例：edid:6474:aa15、name:Sculptor,size:1920x1080")]
        public string displaySelector = "";
        /// <summary>KeyWindow 模式：直接指定 CGDirectDisplayID；非 0 時優先於 <see cref="displaySelector"/>。</summary>
        [Tooltip("直接指定 CGDirectDisplayID（非 0 時優先於 displaySelector；重新接線後可能改變）")]
        public uint displayId;
        /// <summary>Native 模式：觸點幾乎不動超過此秒數就以 Cancelled 取消（幽靈觸點）；0 = 關閉。</summary>
        [Tooltip("觸點幾乎不動超過此秒數就視為誤觸並以 Cancelled 取消（線材碰到面板等幽靈觸點）；0 = 關閉。" +
                 "長按音符超過 30 秒的遊戲請調大或關閉。Udp 模式由 mtk-server --stale-touch-timeout 決定")]
        public float staleTouchTimeout = 30f;
        /// <summary>安裝 Input System 時，把觸控送進虛擬的 Touchscreen 裝置。</summary>
        [Tooltip("把觸控送進 Input System 的 Touchscreen 裝置")]
        public bool feedInputSystem = true;
        /// <summary>把原生外掛的診斷訊息印到 Console。</summary>
        [Tooltip("把原生診斷訊息印到 Console")]
        public bool logNativeMessages = true;
        /// <summary>切換場景時保留這個 Manager（只在它是根物件時有效）。</summary>
        public bool dontDestroyOnLoad = true;
        /// <summary>Awake 時設定 Application.runInBackground，失去焦點時繼續接收觸控。</summary>
        [Tooltip("失去焦點時繼續執行（Application.runInBackground）。觸控螢幕通常是第二螢幕，使用者點主螢幕時遊戲仍要接收觸控；" +
                 "關閉時失焦期間的觸控會在回到前景時依目前狀態重新同步")]
        public bool runInBackground = true;

        /// <summary>目前作用中的 Manager（場景中第一個；其他的會被移除）；沒有時為 null。</summary>
        public static MultiTouchKitManager Instance { get; private set; }

        /// <summary>每個觸控事件（began／moved／ended／cancelled）在主執行緒上觸發一次。</summary>
        public static event Action<MultiTouchTouch> TouchReceived;

        /// <summary>
        /// 目前仍在螢幕上的觸點（key 為 Touch.Id）。查詢（<c>Count</c>、<c>TryGetValue</c>）不配置記憶體；
        /// 但透過這個介面 <c>foreach</c> 每次都會配置 enumerator，每幀列舉請改用 <see cref="GetActiveTouches"/>。
        /// </summary>
        public IReadOnlyDictionary<ulong, MultiTouchTouch> ActiveTouches => m_Active;

        /// <summary>
        /// 這一幀收到的所有事件，依時間順序。用 <c>for</c> 搭配索引讀取不配置記憶體（<c>foreach</c> 透過介面會配置）。
        /// </summary>
        public IReadOnlyList<MultiTouchTouch> TouchesThisFrame => m_ThisFrame;

        /// <summary>
        /// 把目前仍在螢幕上的觸點複製到 <paramref name="results"/>（先清空），依 Id 由小到大排序（先落下的在前），回傳數量。
        /// 重複使用同一個 List 時不配置記憶體，適合每幀呼叫。
        /// </summary>
        public int GetActiveTouches(List<MultiTouchTouch> results)
        {
            if (results == null) throw new ArgumentNullException(nameof(results));
            results.Clear();
            foreach (var touch in m_Active.Values) results.Add(touch);
            results.Sort(ByIdComparer.Instance);
            return results.Count;
        }

        // 用 IComparer 而不是 Comparison 委派：部分 Mono 版本的 List.Sort(Comparison) 每次都會包一個新的 comparer
        sealed class ByIdComparer : IComparer<MultiTouchTouch>
        {
            public static readonly ByIdComparer Instance = new ByIdComparer();
            public int Compare(MultiTouchTouch a, MultiTouchTouch b) => a.Id.CompareTo(b.Id);
        }

        /// <summary>觸控來源已成功啟動。</summary>
        public bool IsRunning => m_Transport != null;

        readonly Dictionary<ulong, MultiTouchTouch> m_Active = new Dictionary<ulong, MultiTouchTouch>();
        readonly List<MultiTouchTouch> m_ThisFrame = new List<MultiTouchTouch>();
        readonly List<MultiTouchTouch> m_Polled = new List<MultiTouchTouch>();
        IMultiTouchTransport m_Transport;
        int m_ThisFrameIndex = -1;
#if MTK_INPUT_SYSTEM
        // Input System 的虛擬裝置是靜態共用的：只由啟用它的 Manager 停用
        bool m_BridgeEnabled;
#endif

        void Awake()
        {
            if (Instance != null && Instance != this)
            {
                Debug.LogWarning("[MultiTouchKit] 場景中已有 MultiTouchKitManager，移除重複的元件");
                Destroy(this);
                return;
            }
            Instance = this;
            if (dontDestroyOnLoad && transform.parent == null) DontDestroyOnLoad(gameObject);
            if (runInBackground) Application.runInBackground = true;
        }

        void OnEnable()
        {
            if (Instance != this) return;
            StartTransport();
        }

        // 重複的 Manager（例如第二個場景也放了一個）被 Destroy 時也會收到 OnDisable，不可停掉正在使用的那個
        void OnDisable()
        {
            if (Instance == this) StopTransport();
        }

        void OnApplicationQuit()
        {
            if (Instance == this) StopTransport();
        }

        // 回到前景時與原生端對帳：失焦期間若 Update 暫停，可能錯過事件
        void OnApplicationFocus(bool hasFocus)
        {
            if (hasFocus) RequestResync();
        }

        void OnApplicationPause(bool paused)
        {
            if (!paused) RequestResync();
        }

        /// <summary>下一次取出觸控時先依原生端目前的狀態重新同步（Native 傳輸）。</summary>
        public void RequestResync()
        {
            if (m_Transport is NativeTransport native) native.RequestResync();
        }

        /// <summary>原生佇列溢位時丟棄的過時事件總數（Native 傳輸；溢位後會自動重新同步）。</summary>
        public ulong DroppedEventCount => m_Transport is NativeTransport native ? native.DroppedEventCount : 0;

        void OnDestroy()
        {
            if (Instance == this) Instance = null;
        }

        /// <summary>修改設定後重新啟動觸控來源。</summary>
        public void Restart()
        {
            StopTransport();
            StartTransport();
        }

        void StartTransport()
        {
            if (m_Transport != null) return;
            IMultiTouchTransport created = transport == TransportMode.Native
                ? new NativeTransport(exclusive, vendorId, productId, false, logNativeMessages, staleTouchTimeout)
                : (IMultiTouchTransport)new UdpTransport(udpPort, false, udpBindAddress, udpTimeout);
            if (!created.Start())
            {
                created.Dispose();
                return;
            }
            m_Transport = created;
            ApplyDisplaySelector();
            MultiTouchClock.Sample();
#if MTK_INPUT_SYSTEM
            if (feedInputSystem)
            {
                MultiTouchInputSystemBridge.Enable();
                m_BridgeEnabled = true;
                // 在 Input System 處理事件之前取出觸控，遊戲當幀就能讀到
                InputSystem.onBeforeUpdate += PollNow;
            }
#endif
        }

        void StopTransport()
        {
#if MTK_INPUT_SYSTEM
            InputSystem.onBeforeUpdate -= PollNow;
#endif
            if (m_Transport != null)
            {
                m_Transport.Dispose();
                m_Transport = null;
            }
            if (m_Active.Count > 0)
            {
                var remaining = new List<MultiTouchTouch>(m_Active.Values);
                m_Active.Clear();
                foreach (var touch in remaining)
                {
                    var cancelled = touch;
                    cancelled.Phase = MultiTouchPhase.Cancelled;
                    Dispatch(cancelled);
                }
            }
#if MTK_INPUT_SYSTEM
            if (m_BridgeEnabled)
            {
                MultiTouchInputSystemBridge.Disable();
                m_BridgeEnabled = false;
            }
#endif
        }

        void Update() => PollNow();

        /// <summary>立即取出目前所有觸控事件並發送；通常不需要手動呼叫。</summary>
        public void PollNow()
        {
            if (m_ThisFrameIndex != Time.frameCount)
            {
                m_ThisFrameIndex = Time.frameCount;
                m_ThisFrame.Clear();
            }
            if (m_Transport == null) return;
            MultiTouchClock.Sample();
#if MTK_INPUT_SYSTEM
            MultiTouchInputSystemBridge.SampleClock();
#endif
            m_Polled.Clear();
            m_Transport.Poll(m_Polled);
            for (int i = 0; i < m_Polled.Count; i++)
            {
                var touch = m_Polled[i];
                touch.ScreenPosition = ToScreen(touch.Normalized);
                if (touch.IsTerminal) m_Active.Remove(touch.Id);
                else m_Active[touch.Id] = touch;
                m_ThisFrame.Add(touch);
                Dispatch(touch);
            }
        }

        void ApplyDisplaySelector()
        {
            if (!MultiTouchKitNative.IsAvailable) return;
            if (MultiTouchKitNative.mtk_set_display(displaySelector) != MultiTouchKitNative.Ok)
                Debug.LogError($"[MultiTouchKit] displaySelector 格式錯誤：{displaySelector}");
        }

        /// <summary>目前對應到的顯示器 CGDirectDisplayID（0 = 找不到或不支援）。</summary>
        public uint TouchDisplayId => MultiTouchKitNative.IsAvailable
            ? (displayId != 0 ? displayId : MultiTouchKitNative.mtk_touch_display_id())
            : 0;

        /// <summary>面板正規化座標 → Unity 螢幕像素座標（原點左下）。</summary>
        public Vector2 ToScreen(Vector2 normalized)
        {
            if (screenMapping == ScreenMappingMode.KeyWindow && MultiTouchKitNative.IsAvailable &&
                MultiTouchKitNative.mtk_map_to_window(normalized.x, normalized.y, displayId, out float x, out float y) == MultiTouchKitNative.Ok)
            {
                return new Vector2(x, y);
            }
            return new Vector2(normalized.x * Screen.width, (1f - normalized.y) * Screen.height);
        }

        void Dispatch(in MultiTouchTouch touch)
        {
#if MTK_INPUT_SYSTEM
            if (feedInputSystem) MultiTouchInputSystemBridge.Queue(touch);
#endif
            var handler = TouchReceived;
            if (handler == null) return;
            try
            {
                handler(touch);
            }
            catch (Exception e)
            {
                Debug.LogException(e);
            }
        }
    }
}
