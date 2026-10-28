// 以 DOM／WebSocket 替身執行 Examples/web/index.html 的整個 <script>（scripts/test-web-example.sh 先載入本檔，再載入頁面腳本與 page-tests-run.js）：
// 確認語法正確，以及 hello／display／frame 訊息 → 畫出的圓點位置。
var arcs = [];
var hudText = "";
var rafCallbacks = [];
function element(id) {
  return {
    id, clientWidth: 1920, clientHeight: 1028, width: 0, height: 0, dataset: {},
    set textContent(v) { if (id === "hud") hudText = v; }, get textContent() { return id === "hud" ? hudText : ""; },
    addEventListener() {},
    getContext() {
      return {
        setTransform() {}, fillRect() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {}, fill() {}, fillText() {},
        arc(x, y, r) { arcs.push({ x, y, r }); },
      };
    },
  };
}
var elements = { view: element("view"), hud: element("hud"), panel: element("panel"), fullscreen: element("fullscreen") };
var document = { getElementById: (id) => elements[id], documentElement: {}, fullscreenElement: null };
var location = { search: "" };
function URLSearchParams(search) { this.search = search; }
URLSearchParams.prototype.get = function () { return null; };
URLSearchParams.prototype.has = function () { return false; };
var devicePixelRatio = 1;
// Safari 綠色按鈕全螢幕、工具列 52 點，觸控螢幕在主螢幕右側
var screenX = 1920, screenY = 0, outerWidth = 1920, outerHeight = 1080, innerWidth = 1920, innerHeight = 1028;
var screen = { width: 1920, height: 1080 };
var performance = { now: () => 0 };
function addEventListener() {}
function requestAnimationFrame(callback) { rafCallbacks.push(callback); }
function setTimeout() {}
var sockets = [];
function WebSocket(url) { this.url = url; sockets.push(this); }
