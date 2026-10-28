using System.Diagnostics;
using UnityEngine;

namespace MultiTouchKit
{
    /// <summary>
    /// 原生觸控時間（奈秒，mach_absolute_time）與 Unity 時鐘之間的換算。
    /// MultiTouchKitManager 每幀會呼叫 <see cref="Sample"/>；必須在主執行緒呼叫。
    /// </summary>
    public static class MultiTouchClock
    {
        // AudioSettings.dspTime 以音訊 buffer 為單位跳動：取最近 2 秒內 (dspTime - now) 的最大值，
        // 也就是 dspTime 剛更新時的對應關係，可去除 buffer 量化造成的誤差。
        const double DspWindowSeconds = 2.0;
        const int DspCapacity = 512;
        static readonly double[] s_DspOffsets = new double[DspCapacity];
        static readonly double[] s_DspTimes = new double[DspCapacity];
        static int s_DspHead;
        static int s_DspCount;
        static double s_DspOffset;
        static double s_RealtimeOffset;
        static readonly double s_StopwatchToNs = 1e9 / Stopwatch.Frequency;

        /// <summary>是否已有 dspTime 對應（音訊系統運作中才有）。</summary>
        public static bool HasDspMapping { get; private set; }

        /// <summary>與觸控時間戳記相同時基的目前時間（奈秒）。</summary>
        public static ulong NowNs =>
            MultiTouchKitNative.IsAvailable
                ? MultiTouchKitNative.mtk_now_ns()
                : (ulong)(Stopwatch.GetTimestamp() * s_StopwatchToNs);

        /// <summary>原生時間（奈秒）→ Time.realtimeSinceStartupAsDouble。</summary>
        public static double ToRealtime(ulong ns) => ns / 1e9 + s_RealtimeOffset;

        /// <summary>原生時間（奈秒）→ AudioSettings.dspTime（需要 <see cref="HasDspMapping"/>）。</summary>
        public static double ToDspTime(ulong ns) => ns / 1e9 + s_DspOffset;

        /// <summary>dspTime → 原生時間（奈秒），可用來把譜面時間換算成觸控時基。</summary>
        public static ulong DspTimeToNs(double dspTime) => (ulong)System.Math.Max(0, (dspTime - s_DspOffset) * 1e9);

        /// <summary>更新換算用的對應關係（Manager 每幀呼叫；自行使用時請在主執行緒每幀呼叫）。</summary>
        public static void Sample()
        {
            double now = NowNs / 1e9;
            s_RealtimeOffset = Time.realtimeSinceStartupAsDouble - now;

            double dsp = AudioSettings.dspTime;
            if (dsp <= 0) return;
            s_DspOffsets[s_DspHead] = dsp - now;
            s_DspTimes[s_DspHead] = now;
            s_DspHead = (s_DspHead + 1) % DspCapacity;
            if (s_DspCount < DspCapacity) s_DspCount++;

            double best = double.MinValue;
            for (int i = 0; i < s_DspCount; i++)
            {
                if (now - s_DspTimes[i] <= DspWindowSeconds && s_DspOffsets[i] > best) best = s_DspOffsets[i];
            }
            if (best > double.MinValue)
            {
                s_DspOffset = best;
                HasDspMapping = true;
            }
        }
    }
}
