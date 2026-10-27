// MultiTouchKit C API 範例：列出裝置、印出 10 秒內的觸控事件。
// 編譯：scripts/build-c-example.sh（或參考 docs/c-api.md）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "multitouchkit.h"

static const char *phase_name(int32_t phase) {
    switch (phase) {
    case MTK_PHASE_BEGAN: return "began";
    case MTK_PHASE_MOVED: return "moved";
    case MTK_PHASE_STATIONARY: return "stationary";
    case MTK_PHASE_ENDED: return "ended";
    default: return "cancelled";
    }
}

static void drain_logs(void) {
    char line[512];
    while (mtk_poll_log(line, sizeof line) > 0) printf("%s\n", line);
}

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 10;
    printf("MultiTouchKit %s（API %d）\n", mtk_version(), mtk_api_version());
    printf("sizeof: MTKConfig=%zu MTKTouchEvent=%zu MTKDeviceInfo=%zu\n",
           sizeof(MTKConfig), sizeof(MTKTouchEvent), sizeof(MTKDeviceInfo));

    MTKConfig config;
    mtk_default_config(&config);
    int32_t result = mtk_start(&config);
    if (result != MTK_OK) {
        drain_logs();
        fprintf(stderr, "mtk_start 失敗：%d\n", result);
        return 1;
    }
    drain_logs();
    for (int32_t i = 0; i < mtk_device_count(); i++) {
        MTKDeviceInfo info;
        if (mtk_get_device_info(i, &info) == MTK_OK) {
            printf("裝置 #%d %s %s：最多 %d 點，%.1f × %.1f mm\n", info.device_id, info.manufacturer,
                   info.product, info.max_contacts, info.physical_width_mm, info.physical_height_mm);
        }
    }

    MTKTouchEvent events[256];
    uint64_t end = mtk_now_ns() + (uint64_t)seconds * 1000000000ull;
    while (mtk_now_ns() < end) {
        int32_t n = mtk_poll_events(events, 256);
        for (int32_t i = 0; i < n; i++) {
            const MTKTouchEvent *e = &events[i];
            printf("%.3f ms  touch %llu (cid %d) %-10s x=%.4f y=%.4f\n",
                   (double)(mtk_now_ns() - e->timestamp_ns) / 1e6, (unsigned long long)e->touch_id,
                   e->contact_id, phase_name(e->phase), e->x, e->y);
        }
        drain_logs();
        usleep(2000);
    }
    mtk_stop();
    drain_logs();
    return 0;
}
