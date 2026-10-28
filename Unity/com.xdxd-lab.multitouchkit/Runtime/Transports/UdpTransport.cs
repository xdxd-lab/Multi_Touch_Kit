using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using UnityEngine;
using Debug = UnityEngine.Debug;

namespace MultiTouchKit
{
    /// <summary>
    /// 接收 mtk-server 的 UDP JSON（見 docs/server-protocol.md）。適合多個程式共用觸控，
    /// 或在沒有觸控螢幕時搭配 `mtk-server --simulate` 開發。同一台 Mac 上時間戳記與原生時鐘相同。
    /// </summary>
    /// <remarks>
    /// UDP 可能遺失最後的 ended（mtk-server 被強制結束、重新啟動、接收緩衝區滿），所以：
    /// <list type="bullet">
    /// <item>有觸點時超過 <c>timeout</c> 秒沒有收到任何封包（mtk-server 按住時以約 125 Hz 送出），仍在的觸點全部 Cancelled。</item>
    /// <item>主執行緒停止取出（例如失焦且未開 runInBackground）時，佇列最多保留 <see cref="MaxQueuedPackets"/> 個封包；
    /// 溢位時丟棄並在下一個 frame 對帳。每個 frame 都列出該裝置所有仍在螢幕上的觸點，
    /// 所以不在其中的觸點以 Cancelled 結束，新的觸點以 Began 開始。</item>
    /// </list>
    /// 穩定狀態下不配置記憶體：接收執行緒用固定的緩衝區接收、以 <see cref="TouchFrameJsonParser"/> 直接解析位元組，
    /// 兩個執行緒之間以兩組 List 交換（容量長到需要的大小後就不再配置）。
    /// </remarks>
    public sealed class UdpTransport : IMultiTouchTransport
    {
        /// <summary>佇列上限（約 8 秒的 125 Hz 封包）。</summary>
        public const int MaxQueuedPackets = 1024;
        const int ReceivePollMilliseconds = 100;
        /// <summary>UDP 封包的最大長度</summary>
        const int MaxPacketBytes = 65536;

        /// <summary>一個 frame 在觸點清單中的範圍</summary>
        struct FrameRange
        {
            public int Device;
            public int Start;
            public int Count;
        }

        /// <summary>接收執行緒解析好、等待主執行緒取出的 frame（兩組輪流使用）</summary>
        sealed class Batch
        {
            public readonly List<FrameRange> Frames = new List<FrameRange>(64);
            public readonly List<MultiTouchTouch> Touches = new List<MultiTouchTouch>(256);

            public void Clear()
            {
                Frames.Clear();
                Touches.Clear();
            }
        }

        readonly int m_Port;
        readonly string m_BindText;
        readonly IPAddress m_BindAddress;
        readonly bool m_ReportStationary;
        readonly double m_Timeout;
        // m_Lock 保護 m_Incoming 與 m_Overflowed；主執行緒取出時與 m_Polling 交換
        readonly object m_Lock = new object();
        Batch m_Incoming = new Batch();
        Batch m_Polling = new Batch();
        bool m_Overflowed;
        long m_LastPacketTimestamp;
        // 以下只在接收執行緒存取
        readonly byte[] m_ReceiveBuffer = new byte[MaxPacketBytes];
        readonly List<MultiTouchTouch> m_Parsed = new List<MultiTouchTouch>(64);
        UdpClient m_Client;
        Thread m_Thread;
        volatile bool m_Running;

        // 以下只在主執行緒（Poll）存取：已交給使用者、尚未結束的觸點
        readonly Dictionary<ulong, MultiTouchTouch> m_Active = new Dictionary<ulong, MultiTouchTouch>();
        readonly HashSet<int> m_ResyncDevices = new HashSet<int>();
        bool m_ResyncAll;
        readonly HashSet<ulong> m_SeenInFrame = new HashSet<ulong>();
        readonly List<ulong> m_Ended = new List<ulong>();

        /// <param name="port">監聽的埠</param>
        /// <param name="reportStationary">是否送出 Stationary 事件</param>
        /// <param name="bindAddress">監聽的位址；null 或空白 = 127.0.0.1（只接收本機）。接收其他電腦的 mtk-server 時用 "0.0.0.0"</param>
        /// <param name="timeout">有觸點時超過此秒數沒有封包就全部取消；0 = 關閉</param>
        public UdpTransport(int port = 7777, bool reportStationary = false, string bindAddress = null, float timeout = 0.5f)
        {
            m_Port = port;
            m_ReportStationary = reportStationary;
            m_Timeout = timeout;
            m_BindText = string.IsNullOrWhiteSpace(bindAddress) ? "127.0.0.1" : bindAddress.Trim();
            // 格式錯誤時為 null，Start 會回報錯誤
            m_BindAddress = IPAddress.TryParse(m_BindText, out var address) ? address : null;
        }

        public string Name => $"UDP {m_BindText}:{m_Port}";

        public bool Start()
        {
            if (m_BindAddress == null)
            {
                Debug.LogError($"[MultiTouchKit] UDP 監聽位址格式錯誤：{m_BindText}");
                return false;
            }
            try
            {
                m_Client = new UdpClient(new IPEndPoint(m_BindAddress, m_Port));
                // 接收執行緒定期醒來檢查 m_Running：關閉一個正被其他執行緒阻塞在 Receive 的 socket，
                // 在部分執行環境（.NET on macOS）會一直等待，所以 Dispose 先讓執行緒自己結束再關閉
                m_Client.Client.ReceiveTimeout = ReceivePollMilliseconds;
            }
            catch (SocketException e)
            {
                Debug.LogError($"[MultiTouchKit] 無法監聽 UDP {m_BindAddress}:{m_Port}：{e.Message}");
                return false;
            }
            Interlocked.Exchange(ref m_LastPacketTimestamp, Stopwatch.GetTimestamp());
            m_Running = true;
            m_Thread = new Thread(ReceiveLoop) { IsBackground = true, Name = "MultiTouchKit UDP" };
            m_Thread.Start();
            Debug.Log($"[MultiTouchKit] 等待 mtk-server 的 UDP 資料（{m_BindAddress}:{m_Port}）");
            return true;
        }

        void ReceiveLoop()
        {
            var socket = m_Client.Client;
            while (m_Running)
            {
                try
                {
                    // Socket.Receive(byte[])：不配置（UdpClient.Receive 每個封包都會配置新的 byte[]，ReceiveFrom 會配置來源位址）
                    int length = socket.Receive(m_ReceiveBuffer);
                    Interlocked.Exchange(ref m_LastPacketTimestamp, Stopwatch.GetTimestamp());
                    m_Parsed.Clear();
                    if (!TouchFrameJsonParser.TryParse(m_ReceiveBuffer, length, m_Parsed, out int device)) continue;
                    lock (m_Lock)
                    {
                        if (m_Incoming.Frames.Count >= MaxQueuedPackets)
                        {
                            // 主執行緒沒有在取出：丟棄所有舊 frame，下一次 Poll 對帳
                            m_Incoming.Clear();
                            m_Overflowed = true;
                        }
                        m_Incoming.Frames.Add(new FrameRange { Device = device, Start = m_Incoming.Touches.Count, Count = m_Parsed.Count });
                        // AddRange(IEnumerable) 在部分 Mono 版本會配置，逐一加入
                        for (int k = 0; k < m_Parsed.Count; k++) m_Incoming.Touches.Add(m_Parsed[k]);
                    }
                }
                catch (SocketException e) when (e.SocketErrorCode == SocketError.TimedOut || e.SocketErrorCode == SocketError.WouldBlock)
                {
                    // ReceiveTimeout：回到迴圈檢查 m_Running
                }
                catch (SocketException)
                {
                    if (!m_Running) break;
                }
                catch (ObjectDisposedException)
                {
                    break;
                }
            }
        }

        public void Poll(List<MultiTouchTouch> output)
        {
            bool overflowed;
            lock (m_Lock)
            {
                var batch = m_Incoming;
                m_Incoming = m_Polling;
                m_Polling = batch;
                overflowed = m_Overflowed;
                m_Overflowed = false;
            }
            if (overflowed)
            {
                Debug.LogWarning($"[MultiTouchKit] UDP 佇列超過 {MaxQueuedPackets} 個封包（Update 暫停？），已丟棄舊資料並依下一個 frame 重新同步");
                m_ResyncAll = true;
            }
            var frames = m_Polling.Frames;
            var parsed = m_Polling.Touches;
            for (int f = 0; f < frames.Count; f++)
            {
                var frame = frames[f];
                bool resync = m_ResyncAll || m_ResyncDevices.Contains(frame.Device);
                if (m_ResyncAll)
                {
                    // 其他裝置在收到各自的下一個 frame 時對帳
                    m_ResyncAll = false;
                    foreach (var touch in m_Active.Values) m_ResyncDevices.Add(touch.DeviceId);
                }
                if (resync) m_SeenInFrame.Clear();
                for (int k = frame.Start; k < frame.Start + frame.Count; k++)
                {
                    var touch = parsed[k];
                    if (resync) m_SeenInFrame.Add(touch.Id);
                    bool known = m_Active.ContainsKey(touch.Id);
                    if (touch.IsTerminal)
                    {
                        if (!known) continue; // 對帳後才收到的 ended：使用者不知道這個觸點
                        m_Active.Remove(touch.Id);
                    }
                    else
                    {
                        // 使用者還不知道的觸點（對帳後、或 began 遺失）一律以 Began 開始
                        if (!known) touch.Phase = MultiTouchPhase.Began;
                        m_Active[touch.Id] = touch;
                    }
                    if (touch.Phase == MultiTouchPhase.Stationary && !m_ReportStationary) continue;
                    output.Add(touch);
                }
                if (resync)
                {
                    m_ResyncDevices.Remove(frame.Device);
                    CancelWhere(output, frame.Device, true);
                }
            }
            m_Polling.Clear();
            CheckTimeout(output);
        }

        /// <summary>有觸點、卻超過 timeout 沒有封包：mtk-server 可能已結束，取消所有觸點。</summary>
        void CheckTimeout(List<MultiTouchTouch> output)
        {
            if (m_Timeout <= 0 || m_Active.Count == 0) return;
            double silence = (Stopwatch.GetTimestamp() - Interlocked.Read(ref m_LastPacketTimestamp)) / (double)Stopwatch.Frequency;
            if (silence <= m_Timeout) return;
            Debug.LogWarning($"[MultiTouchKit] 已 {silence:F1} 秒沒有收到 mtk-server 的 UDP 資料，取消仍在螢幕上的 {m_Active.Count} 個觸點");
            CancelWhere(output, 0, false);
            m_ResyncDevices.Clear();
        }

        /// <param name="onlyUnseen">true：只取消該裝置這個 frame 沒有列出的觸點；false：取消全部</param>
        void CancelWhere(List<MultiTouchTouch> output, int device, bool onlyUnseen)
        {
            m_Ended.Clear();
            foreach (var pair in m_Active)
            {
                if (onlyUnseen && (pair.Value.DeviceId != device || m_SeenInFrame.Contains(pair.Key))) continue;
                m_Ended.Add(pair.Key);
            }
            foreach (ulong id in m_Ended)
            {
                var touch = m_Active[id];
                touch.Phase = MultiTouchPhase.Cancelled;
                m_Active.Remove(id);
                output.Add(touch);
            }
        }

        public void Dispose()
        {
            m_Running = false;
            // 最多等一個 ReceiveTimeout 週期；逾時（極少見）才直接關閉
            m_Thread?.Join(ReceivePollMilliseconds * 3);
            m_Client?.Close();
            m_Client = null;
            m_Thread = null;
            m_Active.Clear();
        }
    }
}
