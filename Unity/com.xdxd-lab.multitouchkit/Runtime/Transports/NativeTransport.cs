using System.Collections.Generic;
using System.Text;
using UnityEngine;

namespace MultiTouchKit
{
    /// <summary>在 Unity 程序內直接讀取觸控（最低延遲）。同一時間只有一個程式能獨占裝置，執行 mtk-server 時請改用 UdpTransport。</summary>
    public sealed class NativeTransport : IMultiTouchTransport
    {
        readonly MultiTouchKitNative.TouchEvent[] m_Buffer = new MultiTouchKitNative.TouchEvent[256];
        readonly byte[] m_LogBuffer = new byte[1024];
        readonly bool m_Exclusive;
        readonly int m_VendorId;
        readonly int m_ProductId;
        readonly bool m_ReportStationary;
        readonly bool m_Log;
        readonly float m_StaleTouchTimeout;
        readonly bool m_ApplyCalibration;
        bool m_Started;
        ulong m_LastDropped;

        /// <summary>原生佇列溢位時丟棄的過時事件總數（溢位後會自動重新同步，觸點狀態不會遺失）。</summary>
        public ulong DroppedEventCount => m_Started ? MultiTouchKitNative.mtk_dropped_event_count() : 0;

        /// <param name="exclusive">獨占觸控螢幕（系統游標不再跟著觸控移動）</param>
        /// <param name="vendorId">只使用指定 Vendor ID 的裝置；0 = 不限</param>
        /// <param name="productId">只使用指定 Product ID 的裝置；0 = 不限</param>
        /// <param name="reportStationary">也送出 Stationary 事件</param>
        /// <param name="log">把原生診斷訊息印到 Console</param>
        /// <param name="staleTouchTimeout">觸點幾乎不動超過此秒數就視為誤觸並取消（線材等幽靈觸點）；0 = 關閉</param>
        /// <param name="applyCalibration">套用 mtk-viewer --calibrate 建立的觸控校正（有該裝置的校正時）</param>
        public NativeTransport(bool exclusive = true, int vendorId = 0, int productId = 0,
                               bool reportStationary = false, bool log = true, float staleTouchTimeout = 30f,
                               bool applyCalibration = true)
        {
            m_ApplyCalibration = applyCalibration;
            m_StaleTouchTimeout = staleTouchTimeout;
            m_Exclusive = exclusive;
            m_VendorId = vendorId;
            m_ProductId = productId;
            m_ReportStationary = reportStationary;
            m_Log = log;
        }

        /// <inheritdoc/>
        public string Name => "Native";

        /// <inheritdoc/>
        public bool Start()
        {
            if (!MultiTouchKitNative.IsAvailable)
            {
                Debug.LogWarning("[MultiTouchKit] 原生外掛只支援 macOS（編輯器與執行檔）");
                return false;
            }
            var config = new MultiTouchKitNative.Config();
            MultiTouchKitNative.mtk_default_config(ref config);
            config.exclusive = m_Exclusive ? 1 : 0;
            config.staleTimeoutMs = m_StaleTouchTimeout > 0 ? Mathf.Max(1, Mathf.RoundToInt(m_StaleTouchTimeout * 1000)) : -1;
            config.vendorId = m_VendorId;
            config.productId = m_ProductId;
            config.reportStationary = m_ReportStationary ? 1 : 0;
            MultiTouchKitNative.mtk_set_calibration_enabled(m_ApplyCalibration ? 1 : 0);
            int result = MultiTouchKitNative.mtk_start(ref config);
            DrainLogs();
            if (result != MultiTouchKitNative.Ok)
            {
                Debug.LogError($"[MultiTouchKit] mtk_start 失敗：{result}");
                return false;
            }
            m_Started = true;
            m_LastDropped = MultiTouchKitNative.mtk_dropped_event_count();
            return true;
        }

        /// <inheritdoc/>
        public void Poll(List<MultiTouchTouch> output)
        {
            if (!m_Started) return;
            int count;
            do
            {
                count = MultiTouchKitNative.mtk_poll_events(m_Buffer, m_Buffer.Length);
                for (int i = 0; i < count; i++)
                {
                    var e = m_Buffer[i];
                    output.Add(new MultiTouchTouch
                    {
                        Id = e.touchId,
                        ContactId = e.contactId,
                        DeviceId = e.deviceId,
                        Phase = (MultiTouchPhase)e.phase,
                        Normalized = new Vector2(e.x, e.y),
                        TimestampNs = e.timestampNs,
                        Pressure = e.pressure,
                        FrameSequence = e.frameSeq,
                    });
                }
            } while (count == m_Buffer.Length);
            ulong dropped = MultiTouchKitNative.mtk_dropped_event_count();
            if (dropped != m_LastDropped)
            {
                Debug.LogWarning($"[MultiTouchKit] 原生事件佇列溢位，已丟棄 {dropped - m_LastDropped} 筆過時事件並依目前觸點狀態重新同步" +
                                 "（通常是 Update 暫停，例如編輯器失去焦點；可開啟 MultiTouchKitManager.runInBackground）");
                m_LastDropped = dropped;
            }
            DrainLogs();
        }

        /// <summary>下一次 Poll 先依原生端目前的觸點狀態重新同步（App 回到前景時呼叫）。</summary>
        public void RequestResync()
        {
            if (m_Started) MultiTouchKitNative.mtk_request_resync();
        }

        /// <summary>停止接收並釋放資源；可重複呼叫。</summary>
        public void Dispose()
        {
            if (!m_Started) return;
            MultiTouchKitNative.mtk_stop();
            m_Started = false;
            DrainLogs();
        }

        void DrainLogs()
        {
            int length;
            while ((length = MultiTouchKitNative.mtk_poll_log(m_LogBuffer, m_LogBuffer.Length)) > 0)
            {
                if (m_Log) Debug.Log(Encoding.UTF8.GetString(m_LogBuffer, 0, length));
            }
        }
    }
}
