using System.Collections.Generic;
using MultiTouchKit;
using UnityEngine;

/// <summary>
/// 加到場景中任一物件即可：沒有 MultiTouchKitManager 時會自動建立，並用 OnGUI 畫出每根手指與編號。
/// 請在 macOS 上以全螢幕執行（或 Game 視窗最大化），座標才會和手指位置對齊。
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
    int m_MaxTouches;
    int m_Taps;

    void Awake()
    {
        if (MultiTouchKitManager.Instance == null)
            new GameObject("MultiTouchKit").AddComponent<MultiTouchKitManager>();
        m_Circle = MakeCircle(128);
    }

    void OnEnable() => MultiTouchKitManager.TouchReceived += OnTouch;

    void OnDisable() => MultiTouchKitManager.TouchReceived -= OnTouch;

    void OnTouch(MultiTouchTouch touch)
    {
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
        m_MaxTouches = Mathf.Max(m_MaxTouches, manager.ActiveTouches.Count);

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

        foreach (var touch in manager.ActiveTouches.Values)
        {
            var p = ToGui(touch.ScreenPosition);
            GUI.color = ColorFor(touch.Id);
            GUI.DrawTexture(new Rect(p.x - 45, p.y - 45, 90, 90), m_Circle);
            GUI.color = Color.white;
            GUI.Label(new Rect(p.x - 45, p.y - 45, 90, 90), touch.Id.ToString(), m_LabelStyle);
        }

        GUI.color = Color.white;
        string state = manager.IsRunning ? manager.transport.ToString() : "未啟動（請看 Console）";
        GUI.Label(new Rect(16, 12, 900, 60),
            $"MultiTouchKit {state}　觸點 {manager.ActiveTouches.Count}　最多 {m_MaxTouches}　按下 {m_Taps}", m_HudStyle);
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
