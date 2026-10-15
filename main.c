// batteryd：插着电也让电池在 [low, high] 之间循环
//   电量 >= high：停止充电并断开适配器供电，由电池放电
//   电量 <= low ：恢复适配器并开始充电
// 设置读取自 CONFIG_FILE（菜单栏 App 写入），状态写到 STATUS_FILE 供 App 显示
// FULL_FILE 存在时临时充到 100%，充满后删除它并回到循环
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOMessage.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "smc.h"

#define CONFIG_DIR   "/Library/Application Support/batteryd"
#define CONFIG_FILE  CONFIG_DIR "/config"
#define STATE_FILE   "/var/db/batteryd.state"
#define STATUS_FILE  "/var/run/batteryd.json"
#define FULL_FILE    CONFIG_DIR "/fullcharge"
#define REACHED_FILE "/var/db/batteryd.reached"
#define POLL_SECONDS 30
#define FULL_EXPIRE_SECONDS (12 * 3600)  // 充满请求超过这么久还没完成就作废

typedef enum { MODE_CHARGE, MODE_DISCHARGE } Mode;

static bool enabled = true;
static int low = 10, high = 75;
static Mode mode;
static bool full_charge;  // 正在一次性充满到 100%
static long reached_at;   // 上次充到上限（或充满）的时间，0 表示还没有
static int reached_pct;   // 当时的上限值，充满时为 100
static bool has_chte, has_chie;  // 新固件（macOS 15+）的 key
static char fault[96];           // 当前故障原因（SMC 写入失败、读不到电量），空串表示正常

static io_connect_t pm_root;
static IONotificationPortRef pm_port;
static io_object_t pm_notifier;

static void logf_(const char *fmt, ...) {
    char ts[32];
    time_t now = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&now));
    printf("[%s] ", ts);
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
    fflush(stdout);
}

// ---------- 电池信息 ----------

static int battery_percent(bool *on_ac) {
    int pct = -1;
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    CFArrayRef list = info ? IOPSCopyPowerSourcesList(info) : NULL;
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef ps = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
        if (!ps) continue;
        CFStringRef type = CFDictionaryGetValue(ps, CFSTR(kIOPSTypeKey));
        if (!type || !CFEqual(type, CFSTR(kIOPSInternalBatteryType))) continue;

        CFNumberRef cur_ref = CFDictionaryGetValue(ps, CFSTR(kIOPSCurrentCapacityKey));
        CFNumberRef max_ref = CFDictionaryGetValue(ps, CFSTR(kIOPSMaxCapacityKey));
        int cur = 0, max = 0;
        if (cur_ref) CFNumberGetValue(cur_ref, kCFNumberIntType, &cur);
        if (max_ref) CFNumberGetValue(max_ref, kCFNumberIntType, &max);
        if (max > 0) pct = cur * 100 / max;

        if (on_ac) {
            CFStringRef st = CFDictionaryGetValue(ps, CFSTR(kIOPSPowerSourceStateKey));
            *on_ac = st && CFEqual(st, CFSTR(kIOPSACPowerValue));
        }
        break;
    }
    if (list) CFRelease(list);
    if (info) CFRelease(info);
    return pct;
}

// ---------- SMC 控制 ----------

// 写入失败时把第一个失败的 key 记进 fault，供状态文件和日志使用
static bool smc_set(const char *key, const uint8_t *v, uint32_t n) {
    kern_return_t kr = smc_write(key, v, n);
    if (kr != KERN_SUCCESS && !fault[0])
        snprintf(fault, sizeof fault, "写入 SMC %s 失败（0x%x）", key, (unsigned)kr);
    return kr == KERN_SUCCESS;
}

static bool set_charging(bool enable) {
    if (has_chte) {
        uint8_t v[4] = { enable ? 0x00 : 0x01, 0, 0, 0 };
        return smc_set("CHTE", v, sizeof v);
    }
    uint8_t v = enable ? 0x00 : 0x02;
    return smc_set("CH0B", &v, 1) && smc_set("CH0C", &v, 1);
}

static bool set_adapter(bool enable) {
    if (has_chie) {
        uint8_t v = enable ? 0x00 : 0x08;
        return smc_set("CHIE", &v, 1);
    }
    uint8_t v = enable ? 0x00 : 0x01;
    return smc_set("CH0I", &v, 1);
}

// 故障原因变化时才写日志，避免每 30 秒刷一条
static void report_fault(void) {
    static char logged[sizeof fault];
    if (strcmp(fault, logged) == 0) return;
    if (fault[0]) logf_("故障：%s", fault);
    else logf_("故障已恢复");
    strcpy(logged, fault);
}

static void apply(Mode m) {
    fault[0] = 0;
    // 先接通适配器再允许充电；放电时先停充电再断适配器，前一步失败就不做后一步
    if (m == MODE_CHARGE) {
        if (set_adapter(true)) set_charging(true);
    } else {
        if (set_charging(false)) set_adapter(false);
    }
    report_fault();
}

static void restore_defaults(void) {
    fault[0] = 0;
    set_adapter(true);
    set_charging(true);
    report_fault();
}

// ---------- 配置 / 状态文件 ----------

static void load_config(void) {
    FILE *f = fopen(CONFIG_FILE, "r");
    if (!f) return;
    int e = enabled, l = low, h = high;
    char line[64];
    while (fgets(line, sizeof line, f)) {
        sscanf(line, "enabled=%d", &e);
        sscanf(line, "low=%d", &l);
        sscanf(line, "high=%d", &h);
    }
    fclose(f);
    enabled = e != 0;
    if (l >= 5 && h <= 100 && l < h) {
        low = l;
        high = h;
    }
}

static void write_status(int pct, bool on_ac) {
    const char *phase = full_charge ? "full"
                      : !enabled ? "paused" : (mode == MODE_CHARGE ? "charge" : "discharge");
    FILE *f = fopen(STATUS_FILE ".tmp", "w");
    if (!f) return;
    fprintf(f, "{\"pct\":%d,\"ac\":%s,\"phase\":\"%s\",\"enabled\":%s,\"low\":%d,\"high\":%d,\"updated\":%ld,"
               "\"reached_at\":%ld,\"reached_pct\":%d,\"fault\":\"%s\",\"keys\":\"%s %s\"}\n",
            pct, on_ac ? "true" : "false", phase, enabled ? "true" : "false", low, high, (long)time(NULL),
            reached_at, reached_pct, fault,
            has_chte ? "CHTE" : "CH0B/CH0C", has_chie ? "CHIE" : "CH0I");
    fclose(f);
    rename(STATUS_FILE ".tmp", STATUS_FILE);
}

static void save_reached(int pct) {
    reached_at = (long)time(NULL);
    reached_pct = pct;
    FILE *f = fopen(REACHED_FILE, "w");
    if (!f) return;
    fprintf(f, "%ld %d\n", reached_at, reached_pct);
    fclose(f);
}

static void load_reached(void) {
    FILE *f = fopen(REACHED_FILE, "r");
    if (!f) return;
    long t;
    int p;
    if (fscanf(f, "%ld %d", &t, &p) == 2) {
        reached_at = t;
        reached_pct = p;
    }
    fclose(f);
}

static void save_state(void) {
    FILE *f = fopen(STATE_FILE, "w");
    if (!f) return;
    fputs(mode == MODE_DISCHARGE ? "discharge\n" : "charge\n", f);
    fclose(f);
}

static bool load_state(Mode *out) {
    char buf[16] = {0};
    FILE *f = fopen(STATE_FILE, "r");
    if (!f) return false;
    bool ok = fgets(buf, sizeof buf, f) != NULL;
    fclose(f);
    if (!ok) return false;
    if (strncmp(buf, "discharge", 9) == 0) { *out = MODE_DISCHARGE; return true; }
    if (strncmp(buf, "charge", 6) == 0)    { *out = MODE_CHARGE;    return true; }
    return false;
}

// ---------- 主循环 ----------

static void tick(void) {
    bool was_enabled = enabled;
    int old_low = low, old_high = high;
    load_config();
    if (enabled != was_enabled)
        logf_("%s", enabled ? "已启用循环" : "已暂停，恢复默认充电");
    if (low != old_low || high != old_high)
        logf_("区间改为 %d%%–%d%%", low, high);

    bool on_ac = false;
    int pct = battery_percent(&on_ac);
    if (pct < 0) {
        // 照常写状态，App 马上能看到原因，而不是等状态过期
        snprintf(fault, sizeof fault, "读取电量失败");
        report_fault();
        write_status(pct, on_ac);
        return;
    }

    // 充满一次：不管循环设置，充到 100% 为止；App 删除 FULL_FILE 即取消。
    // 请求时间就是文件的修改时间，太久没完成（一直没插电、系统卡在 80%）就作废，
    // 免得几天后插上电突然充到 100%
    struct stat st;
    bool want_full = stat(FULL_FILE, &st) == 0;
    if (want_full && time(NULL) - st.st_mtime > FULL_EXPIRE_SECONDS) {
        unlink(FULL_FILE);
        want_full = false;
        logf_("充满请求超过 %d 小时未完成，自动取消", FULL_EXPIRE_SECONDS / 3600);
    }
    if (want_full && pct >= 100) {
        unlink(FULL_FILE);
        want_full = false;
        // 直接进入放电阶段，免得下面的切换再把记录改成上限值
        mode = MODE_DISCHARGE;
        save_state();
        save_reached(100);
        logf_("已充满到 %d%%，恢复循环", pct);
    } else if (want_full && !full_charge) {
        logf_("开始充满到 100%%");
    } else if (!want_full && full_charge) {
        // 取消：已超过上限就从这里开始放电，并把当前电量记为「上次充到」；否则继续充到上限
        mode = pct >= high ? MODE_DISCHARGE : MODE_CHARGE;
        save_state();
        if (mode == MODE_DISCHARGE) save_reached(pct);
        logf_("已取消充满（电量 %d%%），恢复循环", pct);
    }
    full_charge = want_full;
    if (full_charge) {
        apply(MODE_CHARGE);
        write_status(pct, on_ac);
        return;
    }

    if (!enabled) {
        restore_defaults();
        write_status(pct, on_ac);
        return;
    }

    Mode next = mode;
    if (pct <= low)  next = MODE_CHARGE;
    if (pct >= high) next = MODE_DISCHARGE;
    if (next != mode) {
        mode = next;
        save_state();
        if (mode == MODE_DISCHARGE) save_reached(high);
        logf_("电量 %d%%，切换到 %s", pct, mode == MODE_CHARGE ? "充电" : "放电");
    }
    // 每次都重新写入：睡眠/唤醒或系统可能会重置这些 key
    apply(mode);
    write_status(pct, on_ac);
}

static void power_cb(void *ref, io_service_t svc, natural_t msg, void *arg) {
    (void)ref; (void)svc;
    switch (msg) {
    case kIOMessageCanSystemSleep:
        IOAllowPowerChange(pm_root, (long)arg);
        break;
    case kIOMessageSystemWillSleep:
        // 睡眠期间进程不运行，恢复适配器供电，避免睡眠中电池被放空；
        // 放电阶段仍保持不充电，电量停在当前值
        set_adapter(true);
        IOAllowPowerChange(pm_root, (long)arg);
        break;
    case kIOMessageSystemHasPoweredOn:
        tick();
        break;
    }
}

static void on_signal(void) {
    logf_("收到退出信号，恢复默认充电行为");
    restore_defaults();
    unlink(STATUS_FILE);
    smc_close();
    exit(0);
}

static void watch_signal(int sig) {
    signal(sig, SIG_IGN);
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, ^{ on_signal(); });
    dispatch_resume(s);
}

// App 修改设置时（写临时文件后 rename 进目录）立即生效，不用等下一次轮询
static void watch_config(void) {
    int fd = open(CONFIG_DIR, O_EVTONLY);
    if (fd < 0) {
        logf_("警告：无法监听 %s，设置将在 %d 秒内生效", CONFIG_DIR, POLL_SECONDS);
        return;
    }
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd, DISPATCH_VNODE_WRITE,
                                                 dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, ^{ tick(); });
    dispatch_source_set_cancel_handler(s, ^{ close(fd); });
    dispatch_resume(s);
}

static int run(void) {
    load_config();
    load_reached();
    if (!load_state(&mode)) {
        int pct = battery_percent(NULL);
        mode = (pct >= high) ? MODE_DISCHARGE : MODE_CHARGE;
        save_state();
    }
    logf_("启动：区间 %d%%–%d%%，%s，当前阶段 %s，key: %s / %s",
          low, high, enabled ? "已启用" : "已暂停", mode == MODE_CHARGE ? "充电" : "放电",
          has_chte ? "CHTE" : "CH0B/CH0C", has_chie ? "CHIE" : "CH0I");

    watch_signal(SIGTERM);
    watch_signal(SIGINT);
    watch_signal(SIGHUP);
    watch_config();

    pm_root = IORegisterForSystemPower(NULL, &pm_port, power_cb, &pm_notifier);
    if (pm_root) IONotificationPortSetDispatchQueue(pm_port, dispatch_get_main_queue());
    else logf_("警告：无法注册睡眠通知");

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              POLL_SECONDS * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ tick(); });
    dispatch_resume(timer);

    dispatch_main();
}

// ---------- 命令行 ----------

static void print_key(const char *key) {
    uint8_t buf[32];
    uint32_t n = sizeof buf;
    if (smc_read(key, buf, &n) != KERN_SUCCESS) {
        printf("  %s: 不存在\n", key);
        return;
    }
    printf("  %s: ", key);
    for (uint32_t i = 0; i < n; i++) printf("%02x", buf[i]);
    putchar('\n');
}

static int status(void) {
    bool on_ac = false;
    int pct = battery_percent(&on_ac);
    load_config();
    printf("电量: %d%%  电源: %s\n", pct, on_ac ? "适配器" : "电池");
    printf("设置: %s，区间 %d%%–%d%%\n", enabled ? "已启用" : "已暂停", low, high);
    Mode m;
    if (load_state(&m)) printf("当前阶段: %s\n", m == MODE_CHARGE ? "充电" : "放电");
    if (access(FULL_FILE, F_OK) == 0) printf("正在充满到 100%%\n");
    printf("SMC keys:\n");
    print_key("CHTE"); print_key("CH0B"); print_key("CH0C");
    print_key("CHIE"); print_key("CH0I");
    return 0;
}

static void usage(void) {
    fprintf(stderr,
        "用法:\n"
        "  batteryd run        运行（设置读取自 " CONFIG_FILE "）\n"
        "  batteryd status     查看电量和 SMC 状态\n"
        "  batteryd restore    恢复系统默认充电\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 1; }
    const char *cmd = argv[1];

    if (smc_open() != KERN_SUCCESS) {
        fprintf(stderr, "无法打开 AppleSMC\n");
        return 1;
    }
    has_chte = smc_key_exists("CHTE");
    has_chie = smc_key_exists("CHIE");

    if (strcmp(cmd, "status") == 0) return status();

    if (geteuid() != 0) {
        fprintf(stderr, "需要 root 权限，请用 sudo 运行\n");
        return 1;
    }
    if (!has_chte && !(smc_key_exists("CH0B") && smc_key_exists("CH0C"))) {
        fprintf(stderr, "此机型不支持充电控制（找不到 CHTE 或 CH0B/CH0C）\n");
        return 1;
    }
    if (!has_chie && !smc_key_exists("CH0I")) {
        fprintf(stderr, "此机型不支持插电放电（找不到 CHIE/CH0I）\n");
        return 1;
    }

    if (strcmp(cmd, "restore") == 0) {
        restore_defaults();
        unlink(STATE_FILE);
        printf("已恢复默认充电\n");
        return 0;
    }
    if (strcmp(cmd, "run") == 0) return run();

    usage();
    return 1;
}
