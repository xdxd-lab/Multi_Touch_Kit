using System;
using System.Collections.Generic;

namespace MultiTouchKit
{
    /// <summary>觸控資料來源。Poll 在主執行緒呼叫，只需填入 Normalized 等原始欄位，ScreenPosition 由 Manager 計算。</summary>
    public interface IMultiTouchTransport : IDisposable
    {
        /// <summary>顯示用的名稱（例如 "Native"、"UDP 127.0.0.1:7777"）。</summary>
        string Name { get; }
        /// <summary>開始接收；失敗時回傳 false（原因已寫到 Console），Manager 會呼叫 Dispose。</summary>
        bool Start();
        /// <summary>把上次呼叫後收到的事件依時間順序附加到 <paramref name="output"/>（不清空）。每幀在主執行緒呼叫，不應配置記憶體。</summary>
        void Poll(List<MultiTouchTouch> output);
    }
}
