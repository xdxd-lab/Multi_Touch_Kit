#if MTK_INPUT_SYSTEM
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;
using InputTouchPhase = UnityEngine.InputSystem.TouchPhase;

namespace MultiTouchKit
{
    /// <summary>
    /// 把觸控送進 Input System 的 Touchscreen 裝置。遊戲可直接用 Touchscreen.current、
    /// EnhancedTouch（UnityEngine.InputSystem.EnhancedTouch.Touch.activeTouches）與 UI，
    /// 程式寫法和 iOS／Android 版相同。只在專案安裝 Input System 套件時編譯。
    /// </summary>
    public static class MultiTouchInputSystemBridge
    {
        static Touchscreen s_Device;
        static double s_InputTimeOffset;

        /// <summary>虛擬的 Touchscreen 裝置；尚未啟用時為 null。</summary>
        public static Touchscreen Device => s_Device;

        /// <summary>新增虛擬的 Touchscreen 裝置（已存在時不做任何事）。</summary>
        public static void Enable()
        {
            if (s_Device != null && s_Device.added) return;
            s_Device = InputSystem.AddDevice<Touchscreen>("MultiTouchKit Touchscreen");
        }

        /// <summary>移除虛擬的 Touchscreen 裝置。</summary>
        public static void Disable()
        {
            if (s_Device != null && s_Device.added) InputSystem.RemoveDevice(s_Device);
            s_Device = null;
        }

        /// <summary>校正原生時間 → Input System 時間（InputState.currentTime）。每次送事件前呼叫。</summary>
        public static void SampleClock()
        {
            s_InputTimeOffset = InputState.currentTime - MultiTouchClock.NowNs / 1e9;
        }

        /// <summary>把一個觸控事件排入 Input System（時間換算成 Input System 時間）。</summary>
        public static void Queue(in MultiTouchTouch touch)
        {
            if (s_Device == null || !s_Device.added) return;
            int touchId = (int)(touch.Id & 0x7FFFFFFF);
            var state = new TouchState
            {
                touchId = touchId == 0 ? 1 : touchId,
                phase = ToInputPhase(touch.Phase),
                position = touch.ScreenPosition,
                pressure = touch.Pressure >= 0 ? touch.Pressure : 1f,
            };
            InputSystem.QueueStateEvent(s_Device, state, touch.TimestampNs / 1e9 + s_InputTimeOffset);
        }

        static InputTouchPhase ToInputPhase(MultiTouchPhase phase)
        {
            switch (phase)
            {
                case MultiTouchPhase.Began: return InputTouchPhase.Began;
                case MultiTouchPhase.Moved: return InputTouchPhase.Moved;
                case MultiTouchPhase.Stationary: return InputTouchPhase.Stationary;
                case MultiTouchPhase.Ended: return InputTouchPhase.Ended;
                default: return InputTouchPhase.Canceled;
            }
        }
    }
}
#endif
