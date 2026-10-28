/*
 * MultiTouchKit C API
 *
 * 讓 Unity（DllImport "MultiTouchKit"）、C/C++、Python ctypes、Godot GDExtension、Rust 等
 * 在 macOS 上讀取 HID 多點觸控螢幕的 10 點資料。
 *
 * ABI 規則：
 *   - 結構欄位只能附加在尾端，不可重排或刪除；改動後要同步更新 MTK_API_VERSION、
 *     Unity 套件的 MultiTouchKitNative.cs 與 docs/c-api.md。
 *   - 座標為 0...1 的正規化值，原點在觸控面板左上角。
 *   - 時間戳記單位為奈秒，時基與 mtk_now_ns() 相同（mach_absolute_time）。
 */
#ifndef MULTITOUCHKIT_H
#define MULTITOUCHKIT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MTK_API_VERSION 1

/* 回傳碼 */
#define MTK_OK 0
#define MTK_ERR_INVALID_ARGUMENT (-1)
#define MTK_ERR_START_FAILED (-2)
#define MTK_ERR_NOT_RUNNING (-3)
#define MTK_ERR_OUT_OF_RANGE (-4)
#define MTK_ERR_NO_WINDOW (-5)

/* 觸點階段（MTKTouchEvent.phase） */
#define MTK_PHASE_BEGAN 0
#define MTK_PHASE_MOVED 1
#define MTK_PHASE_STATIONARY 2
#define MTK_PHASE_ENDED 3
#define MTK_PHASE_CANCELLED 4

/* MTKTouchEvent.flags */
#define MTK_FLAG_HAS_PRESSURE 0x1u
#define MTK_FLAG_HAS_SIZE 0x2u
#define MTK_FLAG_HAS_CONFIDENCE 0x4u
#define MTK_FLAG_LOW_CONFIDENCE 0x8u /* 控制器判斷不是有意的觸碰（例如手掌） */

typedef struct MTKConfig {
    int32_t struct_size;       /* = sizeof(MTKConfig)，由 mtk_default_config 填入 */
    int32_t vendor_id;         /* 0 = 不限 */
    int32_t product_id;        /* 0 = 不限 */
    int32_t exclusive;         /* 1 = 獨占裝置（預設），系統不再把觸控當成單點滑鼠 */
    int32_t init_multitouch;   /* 1 = 依 Windows 流程初始化多點模式（預設） */
    int32_t report_stationary; /* 0 = 事件佇列不放入 stationary 事件（預設） */
    int32_t queue_capacity;    /* 事件佇列容量，0 = 預設 4096；滿了會丟棄最舊的事件 */
    int32_t stale_timeout_ms;  /* 觸點幾乎不動超過此時間就視為誤觸並取消（線材等幽靈觸點）。
                                  0 = 預設 30000、-1 = 關閉、> 0 為毫秒。原為 reserved：舊程式送 0，會得到預設開啟 */
} MTKConfig; /* 32 bytes */

typedef struct MTKTouchEvent {
    uint64_t touch_id;     /* 每次觸碰唯一，從 1 開始 */
    uint64_t timestamp_ns; /* 收到 HID 報告的時間 */
    int32_t device_id;
    int32_t contact_id;    /* 控制器的 Contact Identifier，放開後會重複使用 */
    int32_t phase;         /* MTK_PHASE_* */
    float x;               /* 0...1，左 → 右 */
    float y;               /* 0...1，上 → 下 */
    float pressure;        /* 0...1；不支援時為 -1 */
    float width;           /* 正規化接觸寬度；不支援時為 -1 */
    float height;          /* 正規化接觸高度；不支援時為 -1 */
    uint32_t frame_seq;    /* 同一個 frame 的事件數值相同 */
    uint32_t flags;        /* MTK_FLAG_* */
} MTKTouchEvent; /* 56 bytes */

typedef struct MTKDeviceInfo {
    int32_t device_id;
    int32_t vendor_id;
    int32_t product_id;
    int32_t max_contacts;
    int32_t slots_per_report;
    int32_t exclusive;
    float physical_width_mm;  /* 未知時為 0 */
    float physical_height_mm; /* 未知時為 0 */
    char manufacturer[64];    /* UTF-8，以 0 結尾 */
    char product[64];
} MTKDeviceInfo; /* 160 bytes */

/* 在 HID 執行緒上呼叫；請盡快返回。events 只在回呼期間有效。
 * 回呼內可以呼叫 mtk_set_event_callback（立即生效），但不可呼叫 mtk_start／mtk_stop（可能死結）。 */
typedef void (*MTKEventCallback)(const MTKTouchEvent *events, int32_t count, void *user_data);

int32_t mtk_api_version(void);
const char *mtk_version(void);

void mtk_default_config(MTKConfig *config);

/* 開始偵測與讀取。已在執行時會先停止再以新設定重新開始。config 為 NULL 時使用預設值；
 * config->struct_size 小於本版本的 sizeof(MTKConfig) 時回傳 MTK_ERR_INVALID_ARGUMENT。
 * mtk_start／mtk_stop 可從任何執行緒呼叫，彼此會序列化。 */
int32_t mtk_start(const MTKConfig *config);
void mtk_stop(void);
int32_t mtk_is_running(void);

/* 取出佇列中的事件（依時間順序），回傳取出的數量；可在任何執行緒呼叫。 */
int32_t mtk_poll_events(MTKTouchEvent *buffer, int32_t capacity);
/* 佇列溢位（或重新同步）時丟棄的過時事件總數。溢位不會遺失觸點狀態：下一次 mtk_poll_events
 * 會先送出重新同步事件（已離開的觸點 cancelled、仍在螢幕上的 began／moved），並在 mtk_poll_log 留下訊息。 */
uint64_t mtk_dropped_event_count(void);

/* 要求下一次 mtk_poll_events 先依目前觸點狀態重新同步（例如 App 從背景回到前景時對帳）。任何執行緒皆可呼叫。 */
void mtk_request_resync(void);

/* 設定即時回呼（NULL 取消）。設定回呼不影響佇列：每個事件都會傳給回呼，也會放進 mtk_poll_events 的佇列。
 * 從其他執行緒呼叫時，會等進行中的回呼結束才返回；返回後保證不會再以舊的 callback／user_data 呼叫，
 * 可以立即釋放舊的 user_data。 */
void mtk_set_event_callback(MTKEventCallback callback, void *user_data);

int32_t mtk_device_count(void);
int32_t mtk_get_device_info(int32_t index, MTKDeviceInfo *info);

/* 取出一則診斷訊息（UTF-8），回傳寫入的位元組數（不含結尾 0），沒有訊息時回傳 0。 */
int32_t mtk_poll_log(char *buffer, int32_t capacity);

/* 與 timestamp_ns 相同時基的目前時間 */
uint64_t mtk_now_ns(void);

/*
 * 把正規化觸控座標換算成目前程式 key window（沒有則 main window）內容區的像素座標，
 * 原點在左下角（與 Unity 的 Screen 座標相同）。
 * display_id = 0 代表觸控螢幕所在的顯示器（由 mtk_set_display 選擇，預設自動）；其他值為 CGDirectDisplayID。
 * 必須在主執行緒呼叫。成功回傳 MTK_OK，沒有視窗回傳 MTK_ERR_NO_WINDOW。
 */
int32_t mtk_map_to_window(float x, float y, uint32_t display_id, float *out_x, float *out_y);

/*
 * 選擇觸控螢幕對應的顯示器（UTF-8 文字，格式見 docs/c-api.md）。NULL 或 "" = 環境變數 MTK_DISPLAY，
 * 沒有設定時為 "auto"（依觸控面板實體尺寸挑選）。例："edid:6474:aa15"、"name:Sculptor,size:1920x1080"。
 * 可在 mtk_start 前後呼叫。格式錯誤回傳 MTK_ERR_INVALID_ARGUMENT（設定不變）。
 * 從主執行緒以外呼叫時會非同步套用（排到主執行緒），緊接著的 mtk_touch_display_id 可能仍是舊結果。
 */
int32_t mtk_set_display(const char *selector);

/* 目前選到的顯示器 CGDirectDisplayID，找不到時回傳 0。必須在主執行緒呼叫。 */
uint32_t mtk_touch_display_id(void);

#ifdef __cplusplus
}
#endif

#endif /* MULTITOUCHKIT_H */
