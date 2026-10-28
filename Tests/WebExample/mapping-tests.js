// Examples/web/index.html 座標換算的測試（scripts/test-web-example.sh 以 macOS 內建的 jsc 執行）。
// MAPPING 由執行腳本從 index.html 的「座標換算」區段取出後放在這個檔案之前。
let failures = 0;
function expect(name, actual, expected) {
  const ok = Math.abs(actual - expected) < 1e-6;
  if (!ok) failures++;
  print(`${ok ? "OK" : "NG"}  ${name}: ${actual} (預期 ${expected})`);
}

// MF156LR 在主螢幕右側：全域座標 [1920, 0, 1920, 1080]
const panel = [1920, 0, 1920, 1080];

// 1. Safari 全螢幕（綠色按鈕）且工具列仍顯示：內容區比螢幕矮 52 點、與螢幕底部對齊
{
  const win = { fullscreen: false, screenX: 1920, screenY: 0, outerWidth: 1920, outerHeight: 1080, innerWidth: 1920, innerHeight: 1028 };
  const bottom = mapTouch({ x: 0.5, y: 1 }, win, panel);
  const middle = mapTouch({ x: 0.1, y: 0.5 }, win, panel);
  expect("Safari 工具列：底部 y", bottom.y, 1028);
  expect("Safari 工具列：中間 y（螢幕 540 − 工具列 52）", middle.y, 488);
  expect("Safari 工具列：左側 x 不偏移", middle.x, 192);
  // 舊版的算法（y × innerHeight）：螢幕上顯示的位置 = 內容區頂端 + y × innerHeight，手指在 y × 1080。
  // 誤差 = 52 × (1 − y)：底部 0、中間 26、頂部 52 點，正是回報的「底部最準、越往上越偏下」
  const oldError = (y) => viewportOnScreen(win).top + y * win.innerHeight - y * 1080;
  expect("舊算法誤差：底部", oldError(1), 0);
  expect("舊算法誤差：中間", oldError(0.5), 26);
  expect("舊算法誤差：頂部", oldError(0), 52);
}

// 2. 一般視窗：在觸控螢幕上的 (2100, 100)，標題列＋工具列 80 點
{
  const win = { fullscreen: false, screenX: 2100, screenY: 100, outerWidth: 1000, outerHeight: 800, innerWidth: 1000, innerHeight: 720 };
  const p = mapTouch({ x: 0.25, y: 0.5 }, win, panel);
  expect("視窗模式 x（1920+480−2100）", p.x, 300);
  expect("視窗模式 y（540−100−80）", p.y, 360);
}

// 3. 換算後加上內容區位置，必須等於手指的全域位置（隨機幾何）
{
  let seed = 7;
  const rand = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  let worst = 0;
  for (let i = 0; i < 1000; i++) {
    const outerWidth = 400 + rand() * 1600, outerHeight = 300 + rand() * 900, toolbar = rand() * 120;
    const win = { fullscreen: false, screenX: rand() * 4000 - 500, screenY: rand() * 1500, outerWidth, outerHeight,
                  innerWidth: outerWidth, innerHeight: outerHeight - toolbar };
    const bounds = [rand() * 4000 - 1000, rand() * 2000 - 500, 800 + rand() * 2000, 600 + rand() * 1500];
    const t = { x: rand(), y: rand() };
    const p = mapTouch(t, win, bounds), v = viewportOnScreen(win);
    worst = Math.max(worst, Math.abs(v.left + p.x - (bounds[0] + t.x * bounds[2])), Math.abs(v.top + p.y - (bounds[1] + t.y * bounds[3])));
  }
  expect("隨機幾何：最大誤差（點）", worst, 0);
}

// 4. Fullscreen API 全螢幕、沒有顯示器資訊：內容區即面板
{
  const win = { fullscreen: true, screenX: 1920, screenY: 0, outerWidth: 1920, outerHeight: 1080, innerWidth: 1920, innerHeight: 1080 };
  const p = mapTouch({ x: 0.3, y: 0.7 }, win, panel);
  expect("全螢幕 x", p.x, 576);
  expect("全螢幕 y", p.y, 756);
  expect("全螢幕模式名稱", p.mode === "fullscreen" ? 1 : 0, 1);
  const q = mapTouch({ x: 0.5, y: 0.5 }, { ...win, fullscreen: false }, null);
  expect("沒有 bounds：x × innerWidth", q.x, 960);
}

// 5. 警告
{
  const full = { fullscreen: true, screenX: 0, screenY: 0, outerWidth: 1920, outerHeight: 1080, innerWidth: 1920, innerHeight: 1080 };
  expect("全螢幕在不同大小的螢幕上 → 警告", geometryWarning(full, panel, { width: 2560, height: 1440 }) ? 1 : 0, 1);
  expect("全螢幕在觸控螢幕上 → 無警告", geometryWarning(full, panel, { width: 1920, height: 1080 }) ? 1 : 0, 0);
  const zoomed = { fullscreen: false, screenX: 0, screenY: 0, outerWidth: 1920, outerHeight: 1080, innerWidth: 1745, innerHeight: 900 };
  expect("頁面縮放 → 警告", geometryWarning(zoomed, panel, { width: 1920, height: 1080 }) ? 1 : 0, 1);
  expect("沒有 bounds → 警告", geometryWarning(full, null, { width: 1920, height: 1080 }) ? 1 : 0, 1);
}

print(failures === 0 ? "ALL PASS" : `${failures} FAIL`);
if (failures) throw new Error(`${failures} 項失敗`);
