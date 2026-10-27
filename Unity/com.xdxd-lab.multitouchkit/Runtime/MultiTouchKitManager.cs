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
        public enum TransportMode
        {
            /// <summary>程序內直接讀取（最低延遲，只支援 macOS）</summary>
            Native,
            /// <summary>接收 mtk-server 的 UDP JSON</summary>
            Udp,
        }

        public enum ScreenMappingMode
        {
            /// <summary>假設遊戲全螢幕顯示在觸控螢幕上：正規化座標直接乘上 Screen 尺寸</summary>
            FullScreen,
            /// <summary>依目前視窗位置換算（視窗模式時使用；需要原生外掛）</summary>
            KeyWindow,
        }

        [Tooltip("Native：程序內直接讀取（最低延遲）；Udp：接收 mtk-server 的 UDP JSON")]
        public TransportMode transport = TransportMode.Native;
        [Tooltip("Udp 模式監聽的埠")]
        public int udpPort = 7777;
        [Tooltip("獨占觸控螢幕，系統不再把觸控當成單點滑鼠")]
        public bool exclusive = true;
        [Tooltip("只使用指定的 Vendor ID（0 = 不限）")]
        public int vendorId;
        [Tooltip("只使用指定的 Product ID（0 = 不限）")]
        public int productId;
        public ScreenMappingMode screenMapping = ScreenMappingMode.FullScreen;
        [Tooltip("KeyWindow 模式：觸控螢幕的 CGDirectDisplayID（0 = 主螢幕）")]
        public uint displayId;
        [Tooltip("把觸控送進 Input System 的 Touchscreen 裝置")]
        public bool feedInputSystem = true;
        [Tooltip("把原生診斷訊息印到 Console")]
        public bool logNativeMessages = true;
        public bool dontDestroyOnLoad = true;

        public static MultiTouchKitManager Instance { get; private set; }

        /// <summary>每個觸控事件（began／moved／ended／cancelled）在主執行緒上觸發一次。</summary>
        public static event Action<MultiTouchTouch> TouchReceived;

        /// <summary>目前仍在螢幕上的觸點（key 為 Touch.Id）。</summary>
        public IReadOnlyDictionary<ulong, MultiTouchTouch> ActiveTouches => m_Active;

        /// <summary>這一幀收到的所有事件，依時間順序。</summary>
        public IReadOnlyList<MultiTouchTouch> TouchesThisFrame => m_ThisFrame;

        public bool IsRunning => m_Transport != null;

        readonly Dictionary<ulong, MultiTouchTouch> m_Active = new Dictionary<ulong, MultiTouchTouch>();
        readonly List<MultiTouchTouch> m_ThisFrame = new List<MultiTouchTouch>();
        readonly List<MultiTouchTouch> m_Polled = new List<MultiTouchTouch>();
        IMultiTouchTransport m_Transport;
        int m_ThisFrameIndex = -1;

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
        }

        void OnEnable()
        {
            if (Instance != this) return;
            StartTransport();
        }

        void OnDisable() => StopTransport();

        void OnApplicationQuit() => StopTransport();

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
                ? new NativeTransport(exclusive, vendorId, productId, false, logNativeMessages)
                : (IMultiTouchTransport)new UdpTransport(udpPort);
            if (!created.Start())
            {
                created.Dispose();
                return;
            }
            m_Transport = created;
            MultiTouchClock.Sample();
#if MTK_INPUT_SYSTEM
            if (feedInputSystem)
            {
                MultiTouchInputSystemBridge.Enable();
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
            MultiTouchInputSystemBridge.Disable();
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
