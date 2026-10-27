using System;
using System.Collections.Generic;

namespace MultiTouchKit
{
    /// <summary>觸控資料來源。Poll 在主執行緒呼叫，只需填入 Normalized 等原始欄位，ScreenPosition 由 Manager 計算。</summary>
    public interface IMultiTouchTransport : IDisposable
    {
        string Name { get; }
        bool Start();
        void Poll(List<MultiTouchTouch> output);
    }
}
