using System;
using System.Collections.Generic;
using UnityEngine;

namespace MultiTouchKit
{
    /// <summary>
    /// mtk-server frame 訊息（docs/server-protocol.md）的專用 JSON 解析器：直接讀 UTF-8 位元組，不配置字串或物件。
    /// 125 Hz 下 JsonUtility＋Encoding.GetString 每個封包配置 2–5 KB，會讓 Unity 定期 GC 而掉幀。
    /// 只取 UdpTransport 需要的欄位，其他欄位（scan、rx、w、conf、未來新增的欄位）一律略過；格式錯誤時回傳 false。
    /// </summary>
    internal static class TouchFrameJsonParser
    {
        /// <summary>解析一個 frame 訊息，觸點附加到 <paramref name="touches"/>。不是 frame（device、hello）或格式錯誤時回傳 false，且不留下任何觸點。</summary>
        public static bool TryParse(byte[] data, int length, List<MultiTouchTouch> touches, out int device)
        {
            int start = touches.Count;
            device = 0;
            bool isFrame = false;
            long seq = 0;
            ulong time = 0;
            int i = 0;
            try
            {
                if (!Expect(data, length, ref i, (byte)'{')) return Fail(touches, start);
                if (Peek(data, length, ref i) == '}') return Fail(touches, start);
                while (true)
                {
                    if (!ReadKey(data, length, ref i, out int keyStart, out int keyLength)) return Fail(touches, start);
                    if (KeyIs(data, keyStart, keyLength, "type"))
                    {
                        if (!ReadStringSpan(data, length, ref i, out int s, out int n)) return Fail(touches, start);
                        isFrame = KeyIs(data, s, n, "frame");
                        if (!isFrame) return Fail(touches, start);
                    }
                    else if (KeyIs(data, keyStart, keyLength, "device"))
                    {
                        if (!ReadNumber(data, length, ref i, out double v)) return Fail(touches, start);
                        device = (int)v;
                    }
                    else if (KeyIs(data, keyStart, keyLength, "seq"))
                    {
                        if (!ReadInteger(data, length, ref i, out ulong v)) return Fail(touches, start);
                        seq = (long)v;
                    }
                    else if (KeyIs(data, keyStart, keyLength, "t"))
                    {
                        if (!ReadInteger(data, length, ref i, out time)) return Fail(touches, start);
                    }
                    else if (KeyIs(data, keyStart, keyLength, "touches"))
                    {
                        if (!ReadTouches(data, length, ref i, touches)) return Fail(touches, start);
                    }
                    else if (!SkipValue(data, length, ref i))
                    {
                        return Fail(touches, start);
                    }
                    byte next = Peek(data, length, ref i);
                    i++;
                    if (next == '}') break;
                    if (next != ',') return Fail(touches, start);
                }
            }
            catch (IndexOutOfRangeException)
            {
                return Fail(touches, start);
            }
            // 結尾只能有空白
            if (!isFrame || Peek(data, length, ref i) != 0 || i != length) return Fail(touches, start);
            // device／seq／t 可能出現在 touches 之後：最後再填入
            for (int k = start; k < touches.Count; k++)
            {
                var t = touches[k];
                t.DeviceId = device;
                t.TimestampNs = time;
                t.FrameSequence = (uint)seq;
                touches[k] = t;
            }
            return true;
        }

        static bool Fail(List<MultiTouchTouch> touches, int start)
        {
            touches.RemoveRange(start, touches.Count - start);
            return false;
        }

        static bool ReadTouches(byte[] d, int length, ref int i, List<MultiTouchTouch> touches)
        {
            if (!Expect(d, length, ref i, (byte)'[')) return false;
            if (Peek(d, length, ref i) == ']')
            {
                i++;
                return true;
            }
            while (true)
            {
                if (!ReadTouch(d, length, ref i, out var touch)) return false;
                touches.Add(touch);
                byte next = Peek(d, length, ref i);
                i++;
                if (next == ']') return true;
                if (next != ',') return false;
            }
        }

        static bool ReadTouch(byte[] d, int length, ref int i, out MultiTouchTouch touch)
        {
            touch = new MultiTouchTouch { Pressure = -1, Phase = MultiTouchPhase.Cancelled };
            double x = 0, y = 0;
            if (!Expect(d, length, ref i, (byte)'{')) return false;
            if (Peek(d, length, ref i) == '}')
            {
                i++;
                return true;
            }
            while (true)
            {
                if (!ReadKey(d, length, ref i, out int ks, out int kn)) return false;
                if (KeyIs(d, ks, kn, "id"))
                {
                    if (!ReadInteger(d, length, ref i, out ulong v)) return false;
                    touch.Id = v;
                }
                else if (KeyIs(d, ks, kn, "cid"))
                {
                    if (!ReadNumber(d, length, ref i, out double v)) return false;
                    touch.ContactId = (int)v;
                }
                else if (KeyIs(d, ks, kn, "phase"))
                {
                    if (!ReadStringSpan(d, length, ref i, out int s, out int n)) return false;
                    touch.Phase = ParsePhase(d, s, n);
                }
                else if (KeyIs(d, ks, kn, "x"))
                {
                    if (!ReadNumber(d, length, ref i, out x)) return false;
                }
                else if (KeyIs(d, ks, kn, "y"))
                {
                    if (!ReadNumber(d, length, ref i, out y)) return false;
                }
                else if (KeyIs(d, ks, kn, "p"))
                {
                    if (!ReadNumber(d, length, ref i, out double p)) return false;
                    touch.Pressure = (float)p;
                }
                else if (!SkipValue(d, length, ref i))
                {
                    return false;
                }
                byte next = Peek(d, length, ref i);
                i++;
                if (next == '}') break;
                if (next != ',') return false;
            }
            touch.Normalized = new Vector2((float)x, (float)y);
            return true;
        }

        // 不認得的值（未來新增的階段、損毀的封包）視為 Cancelled：寧可提早結束觸點，也不要讓它卡在螢幕上
        static MultiTouchPhase ParsePhase(byte[] d, int s, int n)
        {
            if (KeyIs(d, s, n, "began")) return MultiTouchPhase.Began;
            if (KeyIs(d, s, n, "moved")) return MultiTouchPhase.Moved;
            if (KeyIs(d, s, n, "stationary")) return MultiTouchPhase.Stationary;
            if (KeyIs(d, s, n, "ended")) return MultiTouchPhase.Ended;
            return MultiTouchPhase.Cancelled;
        }

        // MARK: - 詞法

        static void SkipWhitespace(byte[] d, int length, ref int i)
        {
            while (i < length && (d[i] == ' ' || d[i] == '\t' || d[i] == '\n' || d[i] == '\r')) i++;
        }

        /// <summary>略過空白後的下一個位元組（不前進）；已到結尾時回傳 0。</summary>
        static byte Peek(byte[] d, int length, ref int i)
        {
            SkipWhitespace(d, length, ref i);
            return i < length ? d[i] : (byte)0;
        }

        static bool Expect(byte[] d, int length, ref int i, byte c)
        {
            if (Peek(d, length, ref i) != c) return false;
            i++;
            return true;
        }

        static bool ReadKey(byte[] d, int length, ref int i, out int start, out int count)
        {
            if (!ReadStringSpan(d, length, ref i, out start, out count)) return false;
            return Expect(d, length, ref i, (byte)':');
        }

        /// <summary>字串內容的位元組範圍（不解碼跳脫字元；含跳脫字元的字串只會被當成「不符合」）。</summary>
        static bool ReadStringSpan(byte[] d, int length, ref int i, out int start, out int count)
        {
            start = count = 0;
            if (!Expect(d, length, ref i, (byte)'"')) return false;
            start = i;
            while (i < length)
            {
                byte c = d[i];
                if (c == '\\')
                {
                    if (i + 1 >= length) return false;
                    byte e = d[i + 1];
                    if (e == 'u')
                    {
                        if (i + 6 > length) return false;
                        for (int k = i + 2; k < i + 6; k++)
                        {
                            byte h = d[k];
                            if (!((h >= '0' && h <= '9') || (h >= 'a' && h <= 'f') || (h >= 'A' && h <= 'F'))) return false;
                        }
                        i += 6;
                        continue;
                    }
                    if (e != '"' && e != '\\' && e != '/' && e != 'b' && e != 'f' && e != 'n' && e != 'r' && e != 't') return false;
                    i += 2;
                    continue;
                }
                if (c < 0x20) return false; // JSON 字串內不能有控制字元
                if (c == '"')
                {
                    count = i - start;
                    i++;
                    return true;
                }
                i++;
            }
            return false;
        }

        static bool KeyIs(byte[] d, int start, int count, string ascii)
        {
            if (count != ascii.Length) return false;
            for (int k = 0; k < count; k++)
            {
                if (d[start + k] != ascii[k]) return false;
            }
            return true;
        }

        /// <summary>非負整數（id、seq、t 為 uint64，不能經過 double）。</summary>
        static bool ReadInteger(byte[] d, int length, ref int i, out ulong value)
        {
            value = 0;
            SkipWhitespace(d, length, ref i);
            int begin = i;
            while (i < length && d[i] >= '0' && d[i] <= '9')
            {
                value = unchecked(value * 10 + (ulong)(d[i] - '0'));
                i++;
            }
            if (i == begin) return false;
            // 帶小數或指數的「整數」：其餘部分略過
            if (i < length && (d[i] == '.' || d[i] == 'e' || d[i] == 'E'))
            {
                return ReadNumber(d, length, ref i, out _);
            }
            return true;
        }

        static readonly double[] s_PowersOf10 =
        {
            1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18,
            1e19, 1e20, 1e21, 1e22,
        };

        /// <summary>
        /// JSON 數字。mtk-server 的座標固定 5 位小數：整數部分×10^k＋小數部分組成一個不超過 2^53 的整數，
        /// 再除以 10^k（兩者都能精確表示）。結果與 double.Parse 相同（正確捨入）。位數過多或有指數時以 Math.Pow 近似。
        /// </summary>
        static bool ReadNumber(byte[] d, int length, ref int i, out double value)
        {
            value = 0;
            SkipWhitespace(d, length, ref i);
            bool negative = false;
            if (i < length && d[i] == '-')
            {
                negative = true;
                i++;
            }
            long mantissa = 0;
            int digits = 0;
            int scale = 0;
            int begin = i;
            while (i < length && d[i] >= '0' && d[i] <= '9')
            {
                if (digits < 18)
                {
                    mantissa = mantissa * 10 + (d[i] - '0');
                    if (mantissa != 0) digits++;
                }
                else
                {
                    scale--; // 超過 18 位的整數位數：以指數補上
                }
                i++;
            }
            if (i == begin) return false;
            if (i < length && d[i] == '.')
            {
                i++;
                int fractionBegin = i;
                while (i < length && d[i] >= '0' && d[i] <= '9')
                {
                    if (digits < 18)
                    {
                        mantissa = mantissa * 10 + (d[i] - '0');
                        if (mantissa != 0) digits++;
                        scale++;
                    }
                    i++;
                }
                if (i == fractionBegin) return false;
            }
            int exponent = 0;
            if (i < length && (d[i] == 'e' || d[i] == 'E'))
            {
                i++;
                bool negativeExponent = false;
                if (i < length && (d[i] == '+' || d[i] == '-'))
                {
                    negativeExponent = d[i] == '-';
                    i++;
                }
                int exponentBegin = i;
                while (i < length && d[i] >= '0' && d[i] <= '9')
                {
                    if (exponent < 10000) exponent = exponent * 10 + (d[i] - '0');
                    i++;
                }
                if (i == exponentBegin) return false;
                if (negativeExponent) exponent = -exponent;
            }
            int power = exponent - scale;
            double m = mantissa;
            if (power == 0) value = m;
            else if (power < 0 && -power < s_PowersOf10.Length) value = m / s_PowersOf10[-power];
            else if (power > 0 && power < s_PowersOf10.Length) value = m * s_PowersOf10[power];
            else value = m * Math.Pow(10, power);
            if (negative) value = -value;
            return true;
        }

        const int MaxDepth = 32;

        /// <summary>略過任意 JSON 值（字串、數字、true／false／null、物件、陣列），並檢查語法：格式錯誤的封包整個丟棄。</summary>
        static bool SkipValue(byte[] d, int length, ref int i, int depth = 0)
        {
            if (depth > MaxDepth) return false;
            byte c = Peek(d, length, ref i);
            switch (c)
            {
                case (byte)'"':
                    return ReadStringSpan(d, length, ref i, out _, out _);
                case (byte)'{':
                    i++;
                    if (Peek(d, length, ref i) == '}')
                    {
                        i++;
                        return true;
                    }
                    while (true)
                    {
                        if (!ReadKey(d, length, ref i, out _, out _) || !SkipValue(d, length, ref i, depth + 1)) return false;
                        byte next = Peek(d, length, ref i);
                        i++;
                        if (next == '}') return true;
                        if (next != ',') return false;
                    }
                case (byte)'[':
                    i++;
                    if (Peek(d, length, ref i) == ']')
                    {
                        i++;
                        return true;
                    }
                    while (true)
                    {
                        if (!SkipValue(d, length, ref i, depth + 1)) return false;
                        byte next = Peek(d, length, ref i);
                        i++;
                        if (next == ']') return true;
                        if (next != ',') return false;
                    }
                case (byte)'t':
                    return SkipLiteral(d, length, ref i, "true");
                case (byte)'f':
                    return SkipLiteral(d, length, ref i, "false");
                case (byte)'n':
                    return SkipLiteral(d, length, ref i, "null");
                default:
                    return ReadNumber(d, length, ref i, out _);
            }
        }

        static bool SkipLiteral(byte[] d, int length, ref int i, string literal)
        {
            if (i + literal.Length > length || !KeyIs(d, i, literal.Length, literal)) return false;
            i += literal.Length;
            return true;
        }
    }
}
