using System;
using System.Collections.Generic;
using MultiTouchKit;
using UnityEngine;

/// <summary>
/// 節奏遊戲延遲校正：跟著節拍器點擊螢幕任意位置，計算點擊相對節拍的誤差。
/// 誤差中位數 = 觸控延遲 + 音訊輸出延遲 + 個人習慣，可直接當作遊戲的「判定偏移」。
/// 判定用的是觸控時間戳記換算成的 dspTime（MultiTouchTouch.DspTime），不受畫面幀率影響。
/// 統計與顯示用的字串只在新的點擊（或 BPM 改變）時更新，OnGUI 不配置記憶體。
/// </summary>
public sealed class LatencyCalibrationDemo : MonoBehaviour
{
    [Range(60, 240)] public float bpm = 120;
    [Tooltip("用最近幾次點擊計算")]
    public int sampleCount = 32;
    [Tooltip("校正後誤差在此範圍內為 Perfect（毫秒）")]
    public double perfectWindowMs = 35;
    [Tooltip("校正後誤差在此範圍內為 Good（毫秒）")]
    public double goodWindowMs = 80;

    AudioSource[] m_Sources;
    AudioClip m_Click;
    int m_NextSource;
    double m_StartDsp;
    double m_NextBeatDsp;
    readonly List<double> m_Offsets = new List<double>();
    readonly List<double> m_Sorted = new List<double>();
    string m_LastJudge = "";
    string m_LastLine = "";
    string m_StatsLine;
    string m_HintLine;
    float m_HintBpm = -1;
    GUIStyle m_Big;
    GUIStyle m_Normal;

    double Interval => 60.0 / bpm;

    void Awake()
    {
        if (MultiTouchKitManager.Instance == null)
            new GameObject("MultiTouchKit").AddComponent<MultiTouchKitManager>();
        var click = m_Click = MakeClick();
        m_Sources = new AudioSource[4];
        for (int i = 0; i < m_Sources.Length; i++)
        {
            m_Sources[i] = gameObject.AddComponent<AudioSource>();
            m_Sources[i].playOnAwake = false;
            m_Sources[i].clip = click;
        }
    }

    // 執行期間建立的 AudioClip 不會自動釋放；編輯器中每次 Play 都會累積
    void OnDestroy()
    {
        if (m_Click != null) Destroy(m_Click);
    }

    void OnEnable() => MultiTouchKitManager.TouchReceived += OnTouch;

    void OnDisable() => MultiTouchKitManager.TouchReceived -= OnTouch;

    void Start()
    {
        m_StartDsp = AudioSettings.dspTime + 0.5;
        m_NextBeatDsp = m_StartDsp;
    }

    void Update()
    {
        // 提前排程節拍聲，確保準時
        double dsp = AudioSettings.dspTime;
        while (m_NextBeatDsp < dsp + 0.25)
        {
            m_Sources[m_NextSource].PlayScheduled(m_NextBeatDsp);
            m_NextSource = (m_NextSource + 1) % m_Sources.Length;
            m_NextBeatDsp += Interval;
        }
    }

    void OnTouch(MultiTouchTouch touch)
    {
        if (touch.Phase != MultiTouchPhase.Began || !MultiTouchClock.HasDspMapping) return;
        double beats = (touch.DspTime - m_StartDsp) / Interval;
        double offsetMs = (beats - Math.Round(beats)) * Interval * 1000; // 正值 = 比節拍晚
        m_Offsets.Add(offsetMs);
        if (m_Offsets.Count > sampleCount) m_Offsets.RemoveAt(0);

        double median = Median();
        double corrected = Math.Abs(offsetMs - median);
        m_LastJudge = corrected <= perfectWindowMs ? "Perfect" : corrected <= goodWindowMs ? "Good" : "Miss";
        m_LastLine = $"這次 {offsetMs:+0.0;-0.0} ms";
        m_StatsLine = null; // 下次 OnGUI 重建
    }

    double Median()
    {
        if (m_Offsets.Count == 0) return 0;
        m_Sorted.Clear();
        for (int i = 0; i < m_Offsets.Count; i++) m_Sorted.Add(m_Offsets[i]);
        m_Sorted.Sort();
        int mid = m_Sorted.Count / 2;
        return m_Sorted.Count % 2 == 1 ? m_Sorted[mid] : (m_Sorted[mid - 1] + m_Sorted[mid]) / 2;
    }

    double StandardDeviation()
    {
        if (m_Offsets.Count < 2) return 0;
        double mean = 0;
        foreach (var o in m_Offsets) mean += o;
        mean /= m_Offsets.Count;
        double sum = 0;
        foreach (var o in m_Offsets) sum += (o - mean) * (o - mean);
        return Math.Sqrt(sum / (m_Offsets.Count - 1));
    }

    void OnGUI()
    {
        if (m_Big == null)
        {
            m_Big = new GUIStyle(GUI.skin.label) { fontSize = 48, fontStyle = FontStyle.Bold, alignment = TextAnchor.MiddleCenter };
            m_Normal = new GUIStyle(GUI.skin.label) { fontSize = 22, alignment = TextAnchor.MiddleCenter };
        }
        float w = Screen.width;
        float h = Screen.height;
        if (m_HintLine == null || bpm != m_HintBpm)
        {
            m_HintBpm = bpm;
            m_HintLine = $"跟著節拍（{bpm:F0} BPM）點擊螢幕任意位置，累積 16 次以上";
        }
        if (m_StatsLine == null)
        {
            m_StatsLine = $"建議判定偏移：{Median():+0.0;-0.0} ms　穩定度（標準差）：{StandardDeviation():0.0} ms　樣本 {m_Offsets.Count}";
        }
        GUI.Label(new Rect(0, h * 0.18f, w, 40), m_HintLine, m_Normal);
        GUI.Label(new Rect(0, h * 0.32f, w, 70), m_LastJudge, m_Big);
        GUI.Label(new Rect(0, h * 0.42f, w, 40), m_LastLine, m_Normal);
        GUI.Label(new Rect(0, h * 0.55f, w, 40), m_StatsLine, m_Normal);
        if (!MultiTouchClock.HasDspMapping)
            GUI.Label(new Rect(0, h * 0.65f, w, 40), "等待音訊系統啟動…", m_Normal);
    }

    static AudioClip MakeClick()
    {
        int rate = AudioSettings.outputSampleRate;
        int length = rate * 30 / 1000;
        var data = new float[length];
        for (int i = 0; i < length; i++)
        {
            float envelope = Mathf.Exp(-i / (rate * 0.005f));
            data[i] = Mathf.Sin(2 * Mathf.PI * 1500 * i / rate) * envelope * 0.8f;
        }
        var clip = AudioClip.Create("MultiTouchKit Click", length, 1, rate, false);
        clip.SetData(data, 0);
        return clip;
    }
}
