let pageFailures = 0;
function check(name, ok, detail) { if (!ok) pageFailures++; print(`${ok ? "OK" : "NG"}  ${name}${detail ? "：" + detail : ""}`); }
function send(message) { sockets[0].onmessage({ data: JSON.stringify(message) }); }
function render() { arcs = []; const callbacks = rafCallbacks; rafCallbacks = []; callbacks.forEach((cb) => cb(1000)); }
const mainDisplay = { id: 1, bounds: [0, 0, 1920, 1080] }, panelDisplay = { id: 2, bounds: [1920, 0, 1920, 1080] };

check("連線到預設網址", sockets.length === 1 && sockets[0].url === "ws://127.0.0.1:7778");
sockets[0].onopen();
render();
check("狀態燈：已連線", elements.panel.dataset.connected === "true");
// hello 時觸控螢幕尚未接上：auto 退回主螢幕
send({ type: "hello", devices: [], display: mainDisplay });
send({ type: "frame", touches: [{ id: 1, phase: "moved", x: 0.25, y: 0.5 }] });
render();
const dot = arcs.find((a) => a.r === 45);
check("主螢幕 bounds：觸點不在這個視窗內（x < 0）", dot && dot.x < 0, dot && `x=${dot.x}`);
// 之後觸控螢幕接上，server 送出 display
send({ type: "display", display: panelDisplay });
render();
const moved = arcs.find((a) => a.r === 45);
check("display 更新後：x = 0.25 × 1920", moved && Math.abs(moved.x - 480) < 1e-9, moved && `x=${moved.x}`);
check("display 更新後：y = 540 − 工具列 52", moved && Math.abs(moved.y - 488) < 1e-9, moved && `y=${moved.y}`);
send({ type: "display", display: null });
render();
check("display 為 null：退回內容區＝面板並警告", hudText.includes("沒有提供觸控螢幕位置"));
send({ type: "frame", touches: [{ id: 1, phase: "ended", x: 0.25, y: 0.5 }] });
render();
check("ended 後不再畫觸點", !arcs.some((a) => a.r === 45));
// 斷線：清除觸點並顯示狀態（不能被下一幀覆蓋）
send({ type: "frame", touches: [{ id: 2, phase: "began", x: 0.5, y: 0.5 }] });
render();
check("斷線前有觸點", arcs.some((a) => a.r === 45));
sockets[0].onclose();
render();
check("斷線後清除觸點（不留幽靈圓點）", !arcs.some((a) => a.r === 45));
render();
check("斷線狀態不會被下一幀覆蓋", hudText.startsWith("連線中斷"), hudText.split("\n")[0]);
check("狀態燈：斷線", elements.panel.dataset.connected === "false");
// D 模式：面板移位並顯示校正狀態
debug = true;
send({ type: "hello", devices: [{ id: 1, product: "ILITEK-TP", maxContacts: 10, calibrated: true }], display: panelDisplay });
sockets[0].onopen();
render();
check("D 模式面板移位", elements.panel.dataset.debug === "true");
check("D 模式顯示已套用校正", hudText.includes("觸控校正：已套用"));
print(pageFailures === 0 ? "PAGE ALL PASS" : `${pageFailures} PAGE FAIL`);
if (pageFailures) throw new Error(`${pageFailures} 項失敗`);
