// 離線測試用的最小 UnityEngine 替身：只提供 Runtime/Transports 用到的型別，讓傳輸程式碼能在 Unity 內建的 dotnet 上執行。
// 不是 Unity 的實作；Unity 內的行為仍需在 Editor 中確認（見 scripts/test-unity-offline.sh）。
using System.Collections.Generic;

namespace UnityEngine
{
    public struct Vector2
    {
        public float x, y;
        public Vector2(float x, float y) { this.x = x; this.y = y; }
    }

    public static class Debug
    {
        public static readonly List<string> Lines = new List<string>();
        public static void Log(object message) => Lines.Add("I " + message);
        public static void LogWarning(object message) => Lines.Add("W " + message);
        public static void LogError(object message) => Lines.Add("E " + message);
    }
}

namespace MultiTouchKit
{
    // MultiTouchTouch 的換算屬性用到；離線測試不需要真正的時鐘
    public static class MultiTouchClock
    {
        public static double ToDspTime(ulong ns) => 0;
        public static double ToRealtime(ulong ns) => 0;
    }
}
