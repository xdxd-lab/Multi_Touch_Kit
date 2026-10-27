using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using UnityEngine;

namespace MultiTouchKit
{
    /// <summary>
    /// 接收 mtk-server 的 UDP JSON（見 docs/server-protocol.md）。適合多個程式共用觸控，
    /// 或在沒有觸控螢幕時搭配 `mtk-server --simulate` 開發。同一台 Mac 上時間戳記與原生時鐘相同。
    /// </summary>
    public sealed class UdpTransport : IMultiTouchTransport
    {
        [Serializable]
        sealed class FrameMessage
        {
            public string type;
            public int device;
            public long seq;
            public long t;
            public TouchMessage[] touches;
        }

        [Serializable]
        sealed class TouchMessage
        {
            public long id;
            public int cid;
            public string phase;
            public float x;
            public float y;
            public float p = -1;
        }

        readonly int m_Port;
        readonly bool m_ReportStationary;
        readonly ConcurrentQueue<string> m_Queue = new ConcurrentQueue<string>();
        UdpClient m_Client;
        Thread m_Thread;
        volatile bool m_Running;

        public UdpTransport(int port = 7777, bool reportStationary = false)
        {
            m_Port = port;
            m_ReportStationary = reportStationary;
        }

        public string Name => $"UDP {m_Port}";

        public bool Start()
        {
            try
            {
                m_Client = new UdpClient(new IPEndPoint(IPAddress.Loopback, m_Port));
            }
            catch (SocketException e)
            {
                Debug.LogError($"[MultiTouchKit] 無法監聽 UDP {m_Port}：{e.Message}");
                return false;
            }
            m_Running = true;
            m_Thread = new Thread(ReceiveLoop) { IsBackground = true, Name = "MultiTouchKit UDP" };
            m_Thread.Start();
            Debug.Log($"[MultiTouchKit] 等待 mtk-server 的 UDP 資料（127.0.0.1:{m_Port}）");
            return true;
        }

        void ReceiveLoop()
        {
            var remote = new IPEndPoint(IPAddress.Any, 0);
            while (m_Running)
            {
                try
                {
                    byte[] data = m_Client.Receive(ref remote);
                    m_Queue.Enqueue(Encoding.UTF8.GetString(data));
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
            while (m_Queue.TryDequeue(out string json))
            {
                if (json.IndexOf("\"type\":\"frame\"", StringComparison.Ordinal) < 0) continue;
                FrameMessage frame;
                try
                {
                    frame = JsonUtility.FromJson<FrameMessage>(json);
                }
                catch (ArgumentException)
                {
                    continue;
                }
                if (frame?.touches == null) continue;
                foreach (var t in frame.touches)
                {
                    var phase = ParsePhase(t.phase);
                    if (phase == MultiTouchPhase.Stationary && !m_ReportStationary) continue;
                    output.Add(new MultiTouchTouch
                    {
                        Id = (ulong)t.id,
                        ContactId = t.cid,
                        DeviceId = frame.device,
                        Phase = phase,
                        Normalized = new Vector2(t.x, t.y),
                        TimestampNs = (ulong)frame.t,
                        Pressure = t.p,
                        FrameSequence = (uint)frame.seq,
                    });
                }
            }
        }

        static MultiTouchPhase ParsePhase(string phase)
        {
            switch (phase)
            {
                case "began": return MultiTouchPhase.Began;
                case "moved": return MultiTouchPhase.Moved;
                case "stationary": return MultiTouchPhase.Stationary;
                case "ended": return MultiTouchPhase.Ended;
                default: return MultiTouchPhase.Cancelled;
            }
        }

        public void Dispose()
        {
            m_Running = false;
            m_Client?.Close();
            m_Thread?.Join(200);
            m_Client = null;
            m_Thread = null;
        }
    }
}
