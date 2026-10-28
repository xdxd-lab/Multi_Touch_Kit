using System.Collections.Generic;
using MultiTouchKit;
using UnityEngine;

/// <summary>
/// 加到場景中任一物件即可：沒有 MultiTouchKitManager 時會自動建立，並用 OnGUI 畫出每根手指與編號。
/// 請在 macOS 上以全螢幕執行（或 Game 視窗最大化），座標才會和手指位置對齊。
/// OnGUI 每幀會被呼叫好幾次（Layout、Repaint…）：字串只在內容改變時重建、觸點用 GetActiveTouches 取出，穩定狀態下不配置記憶體。
/// </summary>
public sealed class TouchVisualizerDemo : MonoBehaviour
{
    struct Ripple
    {
        public Vector2 Position;
        public float Start;
        public Color Color;
    }

    Texture2D m_Circle;
    GUIStyle m_LabelStyle;
    GUIStyle m_HudStyle;
    readonly List<Ripple> m_Ripples = new List<Ripple>();
    readonly List<MultiTouchTouch> m_Active = new List<MultiTouchTouch>(16);
    // 觸點編號的字串（放開時移除）
    readonly Dictionary<ulong, string> m_Labels = new Dictionary<ulong, string>();
    int m_MaxTouches;
    int m_Taps;
    string m_Hud;
    // m_Hud 對應的狀態；改變時才重建字串
    bool m_HudRunning;
    MultiTouchKitManager.TransportMode m_HudTransport;
    int m_HudCount = -1, m_HudMax = -1, m_HudTaps = -1;

    void Awake()
    {
        if (MultiTouchKitManager.Instance == null)
            new GameObject("MultiTouchKit").AddComponent<MultiTouchKitManager>();
        m_Circle = MakeCircle(128);
    }

    // 執行期間建立的 Texture2D 不會自動釋放；編輯器中每次 Play 都會累積
    void OnDestroy()
    {
        if (m_Circle != null) Destroy(m_Circle);
    }

    void OnEnable() => MultiTouchKitManager.TouchReceived += OnTouch;

    void OnDisable() => MultiTouchKitManager.TouchReceived -= OnTouch;

    void OnTouch(MultiTouchTouch touch)
    {
        if (touch.IsTerminal) m_Labels.Remove(touch.Id);
        if (touch.Phase != MultiTouchPhase.Began) return;
        m_Taps++;
        m_Ripples.Add(new Ripple { Position = touch.ScreenPosition, Start = Time.unscaledTime, Color = ColorFor(touch.Id) });
    }

    void OnGUI()
    {
        var manager = MultiTouchKitManager.Instance;
        if (manager == null) return;
        if (m_LabelStyle == null)
        {
            m_LabelStyle = new GUIStyle(GUI.skin.label) { alignment = TextAnchor.MiddleCenter, fontSize = 18, fontStyle = FontStyle.Bold };
            m_HudStyle = new GUIStyle(GUI.skin.label) { fontSize = 20 };
        }
        int count = manager.GetActiveTouches(m_Active);
        m_MaxTouches = Mathf.Max(m_MaxTouches, count);

        for (int i = m_Ripples.Count - 1; i >= 0; i--)
        {
            var r = m_Ripples[i];
            float progress = (Time.unscaledTime - r.Start) / 0.35f;
            if (progress >= 1)
            {
                m_Ripples.RemoveAt(i);
                continue;
            }
            float size = 80 + progress * 160;
            GUI.color = new Color(r.Color.r, r.Color.g, r.Color.b, 1 - progress);
            var p = ToGui(r.Position);
            GUI.DrawTexture(new Rect(p.x - size / 2, p.y - size / 2, size, size), m_Circle);
        }

        for (int i = 0; i < m_Active.Count; i++)
        {
            var touch = m_Active[i];
            var p = ToGui(touch.ScreenPosition);
            GUI.color = ColorFor(touch.Id);
            GUI.DrawTexture(new Rect(p.x - 45, p.y - 45, 90, 90), m_Circle);
            GUI.color = Color.white;
            GUI.Label(new Rect(p.x - 45, p.y - 45, 90, 90), Label(touch.Id), m_LabelStyle);
        }

        GUI.color = Color.white;
        GUI.Label(new Rect(16, 12, 900, 60), Hud(manager, count), m_HudStyle);
    }

    string Label(ulong id)
    {
        if (!m_Labels.TryGetValue(id, out var label))
        {
            label = id.ToString();
            m_Labels[id] = label;
        }
        return label;
    }

    string Hud(MultiTouchKitManager manager, int count)
    {
        bool running = manager.IsRunning;
        if (m_Hud == null || running != m_HudRunning || manager.transport != m_HudTransport || count != m_HudCount
            || m_MaxTouches != m_HudMax || m_Taps != m_HudTaps)
        {
            m_HudRunning = running;
            m_HudTransport = manager.transport;
            m_HudCount = count;
            m_HudMax = m_MaxTouches;
            m_HudTaps = m_Taps;
            string state = running ? manager.transport.ToString() : "未啟動（請看 Console）";
            m_Hud = $"MultiTouchKit {state}　觸點 {count}　最多 {m_MaxTouches}　按下 {m_Taps}";
        }
        return m_Hud;
    }

    static Vector2 ToGui(Vector2 screen) => new Vector2(screen.x, Screen.height - screen.y);

    static Color ColorFor(ulong id) => Color.HSVToRGB((id * 37 % 360) / 360f, 0.7f, 0.95f);

    static Texture2D MakeCircle(int size)
    {
        var texture = new Texture2D(size, size, TextureFormat.RGBA32, false);
        var pixels = new Color32[size * size];
        float radius = size / 2f;
        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                float d = Vector2.Distance(new Vector2(x + 0.5f, y + 0.5f), new Vector2(radius, radius));
                pixels[y * size + x] = new Color32(255, 255, 255, (byte)(Mathf.Clamp01(radius - d) * 255));
            }
        }
        texture.SetPixels32(pixels);
        texture.Apply();
        return texture;
    }
}
