using UnityEngine;

namespace MultiTouchKit
{
    /// <summary>觸點階段；數值與原生 MTK_PHASE_* 相同。</summary>
    public enum MultiTouchPhase
    {
        Began = 0,
        Moved = 1,
        Stationary = 2,
        Ended = 3,
        Cancelled = 4,
    }

    /// <summary>一個觸控事件。</summary>
    public struct MultiTouchTouch
    {
        /// <summary>每次觸碰唯一的編號（從 1 開始）。</summary>
        public ulong Id;
        /// <summary>控制器的 Contact Identifier，放開後會被重複使用。</summary>
        public int ContactId;
        public int DeviceId;
        public MultiTouchPhase Phase;
        /// <summary>面板上的正規化座標 0..1，原點在左上角。</summary>
        public Vector2 Normalized;
        /// <summary>Unity 螢幕像素座標，原點在左下角（與 Input.mousePosition 相同）。</summary>
        public Vector2 ScreenPosition;
        /// <summary>收到觸控的原生時間（奈秒）；用 <see cref="DspTime"/> 或 <see cref="RealtimeSinceStartup"/> 換算。</summary>
        public ulong TimestampNs;
        /// <summary>0..1；裝置不支援時為 -1。</summary>
        public float Pressure;
        /// <summary>同一個掃描 frame 的事件數值相同。</summary>
        public uint FrameSequence;

        public bool IsTerminal => Phase == MultiTouchPhase.Ended || Phase == MultiTouchPhase.Cancelled;

        /// <summary>觸碰當下對應的 AudioSettings.dspTime，用於節奏遊戲判定。</summary>
        public double DspTime => MultiTouchClock.ToDspTime(TimestampNs);

        /// <summary>觸碰當下對應的 Time.realtimeSinceStartupAsDouble。</summary>
        public double RealtimeSinceStartup => MultiTouchClock.ToRealtime(TimestampNs);

        public override string ToString() =>
            $"Touch {Id} (cid {ContactId}) {Phase} {Normalized.x:F3},{Normalized.y:F3}";
    }
}
