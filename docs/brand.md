# 品牌資產（v1 定版）

MultiTouchKit 的品牌資產自 2026-10-29 起為 **v1 定版**。除非另有決定，請不要再調整外觀；
所有素材都由 `Sources/MultiTouchKitArt` 以程式產生，執行 `./scripts/generate-art.sh` 可逐位元重現。

## 設計

- **五指色**：mtk-viewer 的觸點色相（觸點 id × 37°，取 id 1、3、5、7、9）——拇指橘、食指綠、中指青、無名指紫、小指粉。
- **字標**：MultiTouch 10 個字母代表 10 根手指，左右鏡像配色（小指、無名指、中指、食指、拇指 | 拇指、食指、中指、無名指、小指）；
  右手食指的 o 帶點擊光暈。Kit 是暖色魔法漸層（琥珀金 → 珊瑚 → 洋紅 → 紫），i 是魔法棒：棒身加上尖端的虹彩光球與星芒。
- **色階**：深色底用鮮豔色階、白底用較深的色階，對各自背景都 ≥ 4.5:1（`mtk-art` 會輸出完整的對比表）。

## 素材

| 檔案 | 用途 |
|---|---|
| `Assets/Brand/MultiTouchKit.icns`、`MultiTouchKit.iconset/` | App 圖示；16、32 pt（含 @2x）是 5 點小尺寸專屬版，128 pt 以上帶食指點擊光圈 |
| `Assets/Brand/MultiTouchKit-1024.png`、`MultiTouchKit.svg` | 圖示原圖 |
| `Assets/Brand/banner.svg` | README 頂部 banner：自帶圓角深色底板，在 GitHub 的任何主題下都完整呈現 |
| `Examples/web/favicon.svg`、`favicon-16.png`、`favicon-32.png`、`apple-touch-icon.png` | 網頁範例的圖示 |
| `Examples/web/brand.css` | 網頁用的品牌色 CSS 變數（依深淺色主題切換） |
| `Unity/com.xdxd-lab.multitouchkit/Editor/Icons/MultiTouchKitManager.png` | Unity 元件圖示 |
