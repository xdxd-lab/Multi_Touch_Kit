// UdpTransport 與 TouchFrameJsonParser 的離線測試（由 scripts/test-unity-offline.sh 執行，不需要開啟 Unity Editor）：
// 1. UDP 傳輸的行為：began／ended、began 遺失、逾時取消、溢位對帳
// 2. 解析器與 System.Text.Json 的差分測試：實際 mtk-server 輸出、隨機欄位順序／空白／多餘欄位／跳脫字元／指數、
//    截斷與損壞的輸入（必須與標準 JSON 解析器的接受／拒絕一致，接受時內容一致）
// 3. 穩定狀態的配置量必須為 0（GC.GetTotalAllocatedBytes，涵蓋接收執行緒）
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using MultiTouchKit;

static class UnityOfflineTests
{
    static int s_Fails;

    static int Main(string[] args)
    {
        string fixture = args.Length > 0 ? args[0] : "mtk-server-frames.jsonl";
        TransportBehavior();
        ParserDifferential(fixture);
        Allocation(3);
        Allocation(10);
        Console.WriteLine(s_Fails == 0 ? "ALL PASS" : $"{s_Fails} FAIL");
        return s_Fails == 0 ? 0 : 1;
    }

    static void Expect(string name, string got, string want)
    {
        bool ok = got == want;
        if (!ok) s_Fails++;
        Console.WriteLine($"{(ok ? "OK" : "NG")}  {name}: got [{got}] want [{want}]");
    }

    // MARK: - 1. 傳輸行為

    const int BehaviorPort = 7790;
    static readonly UdpClient s_Sender = new UdpClient();

    static void Send(int device, long seq, params (long id, string phase)[] touches)
    {
        var body = string.Join(",", touches.Select(t => $"{{\"id\":{t.id},\"cid\":0,\"phase\":\"{t.phase}\",\"x\":0.5,\"y\":0.5}}"));
        var bytes = Encoding.UTF8.GetBytes($"{{\"type\":\"frame\",\"v\":1,\"device\":{device},\"seq\":{seq},\"t\":{seq},\"touches\":[{body}]}}");
        s_Sender.Send(bytes, bytes.Length, "127.0.0.1", BehaviorPort);
    }

    /// <summary>等封包到達後取出，格式為「Id＋階段首字」，例如 "1B 2M"。</summary>
    static string Poll(UdpTransport transport)
    {
        Thread.Sleep(60);
        var output = new List<MultiTouchTouch>();
        transport.Poll(output);
        return string.Join(" ", output.Select(t => $"{t.Id}{t.Phase.ToString()[0]}"));
    }

    static void TransportBehavior()
    {
        var transport = new UdpTransport(BehaviorPort, false, null, 0.5f);
        if (!transport.Start())
        {
            Console.WriteLine(string.Join("\n", UnityEngine.Debug.Lines));
            s_Fails++;
            return;
        }
        Send(1, 1, (1, "began"));
        Send(1, 2, (1, "moved"));
        Send(1, 3, (1, "stationary"));
        Expect("began／moved（不含 stationary）", Poll(transport), "1B 1M");
        Send(1, 4, (1, "ended"));
        Expect("ended", Poll(transport), "1E");
        Send(1, 5, (2, "moved"));
        Expect("began 遺失 → Began", Poll(transport), "2B");
        Thread.Sleep(700);
        Expect("逾時取消", Poll(transport), "2C");
        Expect("逾時記錄", UnityEngine.Debug.Lines.Any(l => l.Contains("沒有收到")) ? "y" : "n", "y");
        Send(1, 6, (2, "ended"));
        Expect("取消後收到的 ended 略過", Poll(transport), "");

        // 溢位：3 與 4 已交給使用者，之後送 1100 個只含 4、5 的 frame（3 的 ended 被淹沒）
        Send(1, 10, (3, "began"), (4, "began"));
        Expect("兩個 began", Poll(transport), "3B 4B");
        Send(1, 11, (3, "ended"), (4, "moved"));
        for (int i = 0; i < 1100; i++) Send(1, 12 + i, (4, "moved"), (5, i == 0 ? "began" : "moved"));
        Thread.Sleep(300);
        var output = new List<MultiTouchTouch>();
        transport.Poll(output);
        // 每個觸點的階段序列，連續的 Moved 合併成一個
        var phases = output.GroupBy(t => t.Id).OrderBy(g => g.Key).Select(g =>
        {
            var sequence = new StringBuilder();
            foreach (var t in g)
            {
                char c = t.Phase.ToString()[0];
                if (sequence.Length == 0 || sequence[sequence.Length - 1] != c || c != 'M') sequence.Append(c);
            }
            return $"{g.Key}:{sequence}";
        });
        Expect("溢位對帳", string.Join(" ", phases), "3:C 4:M 5:BM");
        Expect("溢位記錄", UnityEngine.Debug.Lines.Any(l => l.Contains("佇列超過")) ? "y" : "n", "y");
        transport.Dispose();
    }

    // MARK: - 2. 解析器差分測試

    static int s_Checks;
    static int s_Mismatches;

    /// <summary>以 System.Text.Json 解析並輸出 UdpTransport 需要的欄位（與 Mine 相同格式）；不是 frame 或格式錯誤為 REJECT。</summary>
    static string Reference(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("type", out var type)
                || type.ValueKind != JsonValueKind.String || type.GetString() != "frame")
            {
                return "REJECT";
            }
            int device = root.TryGetProperty("device", out var d) ? (int)d.GetDouble() : 0;
            ulong time = root.TryGetProperty("t", out var t) ? t.GetUInt64() : 0;
            long seq = root.TryGetProperty("seq", out var s) ? s.GetInt64() : 0;
            var text = new StringBuilder($"dev={device} ");
            if (root.TryGetProperty("touches", out var touches))
            {
                foreach (var x in touches.EnumerateArray())
                {
                    string name = x.TryGetProperty("phase", out var p) ? p.GetString() : "";
                    string phase = name == "began" ? "Began" : name == "moved" ? "Moved" : name == "stationary" ? "Stationary"
                        : name == "ended" ? "Ended" : "Cancelled";
                    ulong id = x.TryGetProperty("id", out var i) ? i.GetUInt64() : 0;
                    int cid = x.TryGetProperty("cid", out var c) ? (int)c.GetDouble() : 0;
                    float px = (float)(x.TryGetProperty("x", out var xv) ? xv.GetDouble() : 0);
                    float py = (float)(x.TryGetProperty("y", out var yv) ? yv.GetDouble() : 0);
                    float pressure = (float)(x.TryGetProperty("p", out var pv) ? pv.GetDouble() : -1);
                    text.Append($"[{id} {cid} {phase} {px:R} {py:R} {pressure:R} {device} {time} {(uint)seq}]");
                }
            }
            return text.ToString();
        }
        catch (JsonException)
        {
            return "REJECT";
        }
    }

    static string Mine(string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        var touches = new List<MultiTouchTouch>();
        if (!TouchFrameJsonParser.TryParse(bytes, bytes.Length, touches, out int device))
        {
            return touches.Count != 0 ? "LEFTOVER" : "REJECT";
        }
        var text = new StringBuilder($"dev={device} ");
        foreach (var x in touches)
        {
            text.Append($"[{x.Id} {x.ContactId} {x.Phase} {x.Normalized.x:R} {x.Normalized.y:R} {x.Pressure:R} {x.DeviceId} {x.TimestampNs} {x.FrameSequence}]");
        }
        return text.ToString();
    }

    static void Check(string json, bool mustAccept = false)
    {
        s_Checks++;
        string expected = Reference(json), actual = Mine(json);
        if (expected == actual && !(mustAccept && actual == "REJECT")) return;
        s_Mismatches++;
        if (s_Mismatches <= 5) Console.WriteLine($"   json={json}\n   ref ={expected}\n   mine={actual}");
    }

    static void ParserDifferential(string fixture)
    {
        foreach (var json in File.ReadAllLines(fixture)) Check(json, true);

        var rng = new Random(42);
        string[] phases = { "began", "moved", "stationary", "ended", "cancelled", "unknown" };
        string Space() => rng.Next(4) == 0 ? new[] { " ", "\n", "\t ", "\r\n" }[rng.Next(4)] : "";
        string Number() => rng.Next(6) switch
        {
            0 => rng.NextDouble().ToString("R"),
            1 => rng.NextDouble().ToString("F5"),
            2 => (rng.NextDouble() * 1e-3).ToString("E3"),
            3 => "1",
            4 => "0",
            _ => rng.NextDouble().ToString("F9"),
        };
        for (int n = 0; n < 20000; n++)
        {
            var touches = new List<string>();
            for (int k = rng.Next(0, 12); k > 0; k--)
            {
                ulong id = (ulong)rng.NextInt64(0, long.MaxValue) / (ulong)(rng.Next(3) == 0 ? 1 : 1_000_000);
                var fields = new List<string>
                {
                    $"\"id\":{Space()}{id}", $"\"cid\":{rng.Next(0, 64)}", $"\"phase\":\"{phases[rng.Next(phases.Length)]}\"",
                    $"\"x\":{Number()}", $"\"y\":{Space()}{Number()}",
                };
                if (rng.Next(2) == 0) fields.Add($"\"p\":{Number()}");
                if (rng.Next(3) == 0) fields.Add($"\"rx\":{rng.Next(10000)}");
                if (rng.Next(4) == 0) fields.Add($"\"conf\":{(rng.Next(2) == 0 ? "true" : "false")}");
                if (rng.Next(6) == 0) fields.Add("\"extra\":{\"a\":[1,{\"b\":\"x]}\\\"\"}],\"c\":null}");
                if (rng.Next(6) == 0) fields.Add("\"note\":\"引號\\\"與\\\\斜線\\u00e9\"");
                fields = fields.OrderBy(_ => rng.Next(3) == 0 ? rng.Next() : 0).ToList();
                touches.Add("{" + Space() + string.Join("," + Space(), fields) + Space() + "}");
            }
            var top = new List<string>
            {
                "\"type\":\"frame\"", "\"v\":1", $"\"device\":{rng.Next(0, 5)}", $"\"seq\":{rng.Next()}",
                $"\"t\":{(ulong)rng.NextInt64()}", $"\"touches\":[{string.Join(",", touches)}]",
            };
            if (rng.Next(3) == 0) top.Add($"\"scan\":{rng.Next(65536)}");
            if (rng.Next(5) == 0) top = top.OrderBy(_ => rng.Next()).ToList();
            string json = Space() + "{" + string.Join("," + Space(), top) + "}" + Space();
            Check(json, true);
            // 截斷與破壞：不可丟出例外、不可留下觸點；接受時內容必須與參考相同
            if (n % 4 == 0) Check(json.Substring(0, rng.Next(json.Length)));
            if (n % 4 == 1)
            {
                var chars = json.ToCharArray();
                chars[rng.Next(chars.Length)] = "{}[],:\"x\\"[rng.Next(9)];
                Check(new string(chars));
            }
        }
        foreach (var json in new[]
        {
            "", "{}", "[]", "null", "{\"type\":\"device\",\"device\":{\"id\":1}}", "{\"type\":\"hello\",\"devices\":[]}",
            "{\"type\":\"frame\"}", "{\"type\":\"frame\",\"touches\":[]}", "{\"type\":\"frame\",\"touches\":[]}x",
            "{\"touches\":[{\"id\":1}],\"type\":\"frame\",\"device\":3,\"t\":5,\"seq\":2}",
        })
        {
            Check(json);
        }
        Expect("解析器差分", $"{s_Mismatches} 不一致／{s_Checks}", $"0 不一致／{s_Checks}");
    }

    // MARK: - 3. 配置量

    const int AllocationPort = 7798;

    static byte[] Frame(long seq, int fingers)
    {
        var text = new StringBuilder($"{{\"type\":\"frame\",\"v\":1,\"device\":1,\"seq\":{seq},\"t\":{seq * 8000000},\"touches\":[");
        for (int i = 0; i < fingers; i++)
        {
            if (i > 0) text.Append(',');
            text.Append($"{{\"id\":{i + 1},\"cid\":{i},\"phase\":\"{(seq == 0 ? "began" : "moved")}\",\"x\":0.{10000 + seq % 9000:D5},\"y\":0.50000,\"rx\":{1000 + i},\"ry\":2000}}");
        }
        return Encoding.UTF8.GetBytes(text.Append("]}").ToString());
    }

    /// <summary>每 4 個封包取出一次（約 125 Hz 對 30 fps），第二輪（容量已長好）的配置量必須為 0。</summary>
    static void Allocation(int fingers)
    {
        var transport = new UdpTransport(AllocationPort, false, null, 0f);
        if (!transport.Start())
        {
            s_Fails++;
            return;
        }
        var sender = new UdpClient();
        sender.Connect("127.0.0.1", AllocationPort);
        var output = new List<MultiTouchTouch>(256);
        var packets = Enumerable.Range(0, 3000).Select(i => Frame(i, fingers)).ToArray();
        int received = 0;
        for (int round = 0; round < 2; round++)
        {
            long before = GC.GetTotalAllocatedBytes(true);
            for (int i = 0; i < 1500; i++)
            {
                var packet = packets[round * 1500 + i];
                sender.Send(packet, packet.Length);
                if (i % 4 == 3)
                {
                    Thread.Sleep(1);
                    output.Clear();
                    transport.Poll(output);
                    received += output.Count;
                }
            }
            Thread.Sleep(50);
            output.Clear();
            transport.Poll(output);
            received += output.Count;
            long allocated = GC.GetTotalAllocatedBytes(true) - before;
            if (round == 1) Expect($"配置量 {fingers} 指（收到 {received} 筆）", $"{allocated / 1500.0:F0} B/封包", "0 B/封包");
        }
        sender.Dispose();
        transport.Dispose();
    }
}
