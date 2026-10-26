// Exercise the daemon's real event handlers with fake power sources and SMC writes.
// Every persisted file is redirected into the runner's temporary directory.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOMessage.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <utime.h>
#include <unistd.h>
#include "../smc.h"

#ifndef BATTERYD_TEST_DIR
#error "Run tests/test-daemon.sh to provide an isolated temporary directory"
#endif
#define CONFIG_DIR BATTERYD_TEST_DIR
#define CONFIG_FILE CONFIG_DIR "/config"
#define STATE_FILE CONFIG_DIR "/state"
#define STATUS_FILE CONFIG_DIR "/status.json"
#define FULL_FILE CONFIG_DIR "/fullcharge"
#define REACHED_FILE CONFIG_DIR "/reached"

static int fake_pct = 50;
static int fake_caps = 15;
static bool fake_adapter = true;
static bool fake_charging = true;
static bool fake_connected = true;
static bool fake_root_present = true;
static bool fake_caps_malformed;
static const char *fail_key;
static int acknowledgements;
static int writes;

static CFTypeRef test_power_info(void) {
    CFMutableDictionaryRef info = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int max = fake_pct < 0 ? 0 : 100;
    CFNumberRef pct = CFNumberCreate(NULL, kCFNumberIntType, &fake_pct);
    CFNumberRef capacity = CFNumberCreate(NULL, kCFNumberIntType, &max);
    CFDictionarySetValue(info, CFSTR(kIOPSTypeKey), CFSTR(kIOPSInternalBatteryType));
    CFDictionarySetValue(info, CFSTR(kIOPSCurrentCapacityKey), pct);
    CFDictionarySetValue(info, CFSTR(kIOPSMaxCapacityKey), capacity);
    CFDictionarySetValue(info, CFSTR(kIOPSPowerSourceStateKey),
        fake_adapter && fake_connected ? CFSTR(kIOPSACPowerValue) : CFSTR(kIOPSBatteryPowerValue));
    CFRelease(pct);
    CFRelease(capacity);
    return info;
}

static CFArrayRef test_power_list(CFTypeRef info) {
    return CFArrayCreate(NULL, &info, 1, &kCFTypeArrayCallBacks);
}

static CFDictionaryRef test_power_description(CFTypeRef info, CFTypeRef source) {
    (void)info;
    return (CFDictionaryRef)source;
}

static io_service_t test_matching_service(mach_port_t port, CFDictionaryRef matching) {
    (void)port;
    CFStringRef class = CFDictionaryGetValue(matching, CFSTR("IOProviderClass"));
    bool root = class && CFEqual(class, CFSTR("IOPMrootDomain"));
    CFRelease(matching);
    return root ? (fake_root_present ? 2 : 0) : 1;
}

static CFTypeRef test_property(io_registry_entry_t entry, CFStringRef key,
                              CFAllocatorRef allocator, IOOptionBits options) {
    (void)allocator; (void)options;
    if (entry == 2 && CFEqual(key, CFSTR("System Capabilities"))) {
        if (fake_caps_malformed) return CFRetain(CFSTR("invalid"));
        return fake_caps < 0 ? NULL : CFNumberCreate(NULL, kCFNumberIntType, &fake_caps);
    }
    if (entry == 1 && CFEqual(key, CFSTR("AdapterDetails"))) {
        int watts = fake_connected ? 60 : 0;
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &watts);
        const void *keys[] = { CFSTR("Watts") };
        const void *values[] = { number };
        CFDictionaryRef result = CFDictionaryCreate(NULL, keys, values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(number);
        return result;
    }
    return NULL;
}

static kern_return_t test_release(io_object_t object) {
    (void)object;
    return KERN_SUCCESS;
}

static IOReturn test_assertion_create(CFStringRef type, IOPMAssertionLevel level,
                                     CFStringRef name, IOPMAssertionID *id) {
    (void)type; (void)level; (void)name;
    *id = 42;
    return kIOReturnSuccess;
}

static IOReturn test_assertion_release(IOPMAssertionID id) {
    (void)id;
    return kIOReturnSuccess;
}

static IOReturn test_allow_power_change(io_connect_t connect, long token) {
    (void)connect;
    assert(token == 123);
    acknowledgements++;
    return kIOReturnSuccess;
}

#define IOPSCopyPowerSourcesInfo test_power_info
#define IOPSCopyPowerSourcesList test_power_list
#define IOPSGetPowerSourceDescription test_power_description
#define IOServiceGetMatchingService test_matching_service
#define IORegistryEntryCreateCFProperty test_property
#define IOObjectRelease test_release
#define IOPMAssertionCreateWithName test_assertion_create
#define IOPMAssertionRelease test_assertion_release
#define IOAllowPowerChange test_allow_power_change
#define main batteryd_main
#include "../main.c"
#undef main

kern_return_t smc_open(void) { return KERN_SUCCESS; }
void smc_close(void) {}
bool smc_key_exists(const char *key) { (void)key; return true; }
kern_return_t smc_read(const char *key, uint8_t *buf, uint32_t *size) {
    (void)key; (void)buf; (void)size;
    return kIOReturnUnsupported;
}

kern_return_t smc_write(const char *key, const uint8_t *buf, uint32_t size) {
    assert(size > 0);
    writes++;
    if (fail_key && strcmp(key, fail_key) == 0) return kIOReturnError;
    if (!strcmp(key, "CHTE") || !strcmp(key, "CH0B") || !strcmp(key, "CH0C")) {
        fake_charging = buf[0] == 0;
    } else if (!strcmp(key, "CHIE") || !strcmp(key, "CH0I")) {
        fake_adapter = buf[0] == 0;
    } else {
        assert(!"unexpected SMC key");
    }
    return KERN_SUCCESS;
}

static void write_config(bool active) {
    FILE *f = fopen(CONFIG_FILE, "w");
    assert(f);
    fprintf(f, "enabled=%d\nlow=10\nhigh=75\n", active);
    assert(fclose(f) == 0);
}

static void request_full(void) {
    FILE *f = fopen(FULL_FILE, "w");
    assert(f);
    assert(fclose(f) == 0);
}

static void reset_case(void) {
    unlink(FULL_FILE); unlink(STATE_FILE); unlink(STATUS_FILE); unlink(REACHED_FILE);
    enabled = true; low = 10; high = 75; mode = MODE_CHARGE;
    full_charge = false; reached_at = 0; reached_pct = 0;
    has_chte = true; has_chie = true; fault[0] = 0;
    awake_assertion = kIOPMNullAssertionID;
    system_sleeping = false;
    fake_pct = 50; fake_caps = 15; fake_adapter = true; fake_charging = true;
    fake_connected = true; fake_root_present = true; fake_caps_malformed = false;
    fail_key = NULL; acknowledgements = 0; writes = 0;
    write_config(true);
}

static void sleep_now(void) {
    power_cb(NULL, 0, kIOMessageSystemWillSleep, (void *)123);
    assert(system_sleeping);
    assert(acknowledgements == 1);
}

static void wake_now(void) {
    fake_caps = 15;
    power_cb(NULL, 0, kIOMessageSystemHasPoweredOn, NULL);
    assert(!system_sleeping);
}

static void assert_sleep_hold(void) {
    assert(fake_adapter);
    assert(!fake_charging);
    assert(fault[0] == 0);
}

static void assert_status_contains(const char *expected) {
    FILE *f = fopen(STATUS_FILE, "r");
    assert(f);
    char contents[1024];
    assert(fgets(contents, sizeof contents, f));
    fclose(f);
    assert(strstr(contents, expected));
}

static void test_overnight_sequence(void) {
    reset_case();
    fake_pct = 73;
    tick();
    assert(fake_charging);
    sleep_now();
    assert_sleep_hold();
    assert_status_contains("\"sleep_paused\":true");
    // No second WillSleep occurs between maintenance wakes. Their timer and
    // power-source callbacks must not start charging even below the low limit.
    fake_caps = 9;
    fake_pct = 10;
    for (int i = 0; i < 4; i++) {
        fake_charging = true;  // Model firmware restoring its charge key.
        tick();
        assert_sleep_hold();
        assert(system_sleeping);
    }
    // A stale fullwake property during the initial transition cannot unlock it.
    fake_caps = 15;
    tick();
    assert_sleep_hold();
    wake_now();
    assert(fake_adapter && fake_charging);
    assert(mode == MODE_CHARGE);
    assert_status_contains("\"sleep_paused\":false");
    fake_pct = 75;
    tick();
    assert(!fake_adapter && !fake_charging);
    assert(mode == MODE_DISCHARGE);
}

static void test_discharge_sleep_and_resume(void) {
    reset_case();
    mode = MODE_DISCHARGE;
    tick();
    assert(!fake_adapter && !fake_charging);
    sleep_now();
    assert_sleep_hold();
    assert(mode == MODE_DISCHARGE);
    wake_now();
    assert(!fake_adapter && !fake_charging);
    assert(mode == MODE_DISCHARGE);
}

static void test_explicit_full_and_cancel(void) {
    reset_case();
    sleep_now();
    request_full();
    tick();
    assert(full_charge && fake_charging && fake_adapter);
    assert_status_contains("\"sleep_paused\":false");
    unlink(FULL_FILE);
    tick();
    assert(!full_charge);
    assert_sleep_hold();
    assert_status_contains("\"sleep_paused\":true");
    wake_now();
    assert(fake_charging);
}

static void test_full_expiry_and_completion(void) {
    reset_case();
    sleep_now();
    request_full();
    tick();
    struct utimbuf old = { .actime = time(NULL) - FULL_EXPIRE_SECONDS - 10,
                          .modtime = time(NULL) - FULL_EXPIRE_SECONDS - 10 };
    assert(utime(FULL_FILE, &old) == 0);
    tick();
    assert(access(FULL_FILE, F_OK) != 0 && !full_charge);
    assert_sleep_hold();
    request_full();
    tick();
    fake_pct = 100;
    tick();
    assert(access(FULL_FILE, F_OK) != 0 && !full_charge);
    assert_sleep_hold();
    assert(mode == MODE_DISCHARGE && reached_pct == 100);
}

static void test_paused_cycle(void) {
    reset_case();
    sleep_now();
    write_config(false);
    tick();
    assert(!enabled && fake_adapter && fake_charging);
    write_config(true);
    tick();
    assert_sleep_hold();
}

static void test_unknown_battery_does_not_bypass_sleep(void) {
    reset_case();
    fake_pct = -1;
    sleep_now();
    assert(fake_adapter && !fake_charging);
    assert(strstr(fault, "读取电量失败"));
    fake_charging = true;
    tick();
    assert(fake_adapter && !fake_charging);
    assert(strstr(fault, "读取电量失败"));
    fake_pct = 50;
    tick();
    assert_sleep_hold();
}

static void test_unknown_battery_paused_at_sleep(void) {
    reset_case();
    mode = MODE_DISCHARGE;
    tick();
    assert(!fake_adapter && !fake_charging);
    fake_pct = -1;
    write_config(false);
    sleep_now();
    assert(!enabled && fake_adapter && fake_charging);
    assert(strstr(fault, "读取电量失败"));
    assert_status_contains("\"phase\":\"paused\"");
    assert_status_contains("\"sleep_paused\":false");
    fake_pct = 50;
    tick();
    assert(!enabled && fake_adapter && fake_charging && !fault[0]);
    write_config(true);
    tick();
    assert_sleep_hold();
    wake_now();
    assert(mode == MODE_DISCHARGE && !fake_adapter && !fake_charging);
}

static void test_unknown_battery_full_at_sleep(void) {
    reset_case();
    mode = MODE_DISCHARGE;
    tick();
    assert(!fake_adapter && !fake_charging);
    fake_pct = -1;
    request_full();
    sleep_now();
    assert(full_charge && fake_adapter && fake_charging);
    assert(strstr(fault, "读取电量失败"));
    assert_status_contains("\"phase\":\"full\"");
    assert_status_contains("\"sleep_paused\":false");
    fake_pct = 50;
    tick();
    assert(full_charge && fake_adapter && fake_charging && !fault[0]);
    fake_pct = 100;
    tick();
    assert(!full_charge && access(FULL_FILE, F_OK) != 0);
    assert(mode == MODE_DISCHARGE && reached_pct == 100);
    assert_sleep_hold();
}

static void test_unknown_battery_cancel_full(void) {
    for (int expires = 0; expires < 2; expires++) {
        reset_case();
        mode = MODE_DISCHARGE;
        sleep_now();
        request_full();
        tick();
        assert(full_charge && fake_charging);
        if (expires) {
            struct utimbuf old = { .actime = time(NULL) - FULL_EXPIRE_SECONDS - 10,
                                  .modtime = time(NULL) - FULL_EXPIRE_SECONDS - 10 };
            assert(utime(FULL_FILE, &old) == 0);
        } else {
            unlink(FULL_FILE);
        }
        fake_pct = -1;
        tick();
        assert(fake_adapter && !fake_charging);
        assert_status_contains("\"sleep_paused\":true");
        fake_pct = 50;
        tick();
        assert(!full_charge);
        assert_sleep_hold();
        // Once the percentage is known, cancellation still changes the old
        // discharge phase into a charge up to the configured ceiling.
        wake_now();
        assert(mode == MODE_CHARGE && fake_charging);
    }
}

static void test_original_low_battery_maintenance_wake(void) {
    reset_case();
    mode = MODE_DISCHARGE;
    fake_pct = 16;
    tick();
    sleep_now();
    assert_sleep_hold();
    fake_pct = 10;
    fake_caps = 9;
    tick();
    assert_sleep_hold();
    assert(mode == MODE_DISCHARGE); // Maintenance wake cannot advance the cycle.
    wake_now();
    assert(mode == MODE_CHARGE && fake_charging && fake_adapter);
}

static void test_startup_capabilities(void) {
    const int full_caps[] = { 15, 3, 5 }; // Graphics or audio is a full wake.
    for (unsigned i = 0; i < sizeof full_caps / sizeof *full_caps; i++) {
        reset_case();
        fake_caps = full_caps[i];
        initialize_sleep_state();
        assert(!system_sleeping);
        tick();
        assert(fake_charging);
    }
    const int sleep_caps[] = { 0, 1, 9, -1 };
    for (unsigned i = 0; i < sizeof sleep_caps / sizeof *sleep_caps; i++) {
        reset_case();
        fake_caps = sleep_caps[i];
        initialize_sleep_state();
        assert(system_sleeping);
        fake_pct = 10;
        tick();
        assert_sleep_hold();
    }
    reset_case(); fake_root_present = false;
    initialize_sleep_state();
    assert(system_sleeping);
    reset_case(); fake_caps_malformed = true;
    initialize_sleep_state();
    assert(system_sleeping);
}

static void test_faults_and_legacy_keys(void) {
    reset_case();
    fail_key = "CHTE";
    sleep_now();
    assert(fake_adapter);
    assert(strstr(fault, "CHTE"));
    fail_key = NULL;
    tick();
    assert_sleep_hold();
    reset_case();
    fail_key = "CHIE";
    sleep_now();
    assert(strstr(fault, "CHIE"));
    assert(writes >= 2); // Still attempts to inhibit charging if adapter write fails.
    reset_case();
    has_chte = false; has_chie = false;
    sleep_now();
    assert_sleep_hold();
    wake_now();
    assert(fake_adapter && fake_charging);
}

static void test_actual_reached_percentage(void) {
    reset_case();
    fake_pct = 86;
    tick();
    assert(mode == MODE_DISCHARGE && reached_pct == 86);
    FILE *f = fopen(REACHED_FILE, "r");
    assert(f);
    long when; int percentage;
    assert(fscanf(f, "%ld %d", &when, &percentage) == 2);
    fclose(f);
    assert(when > 0 && percentage == 86);
}

int main(void) {
    test_overnight_sequence();
    test_discharge_sleep_and_resume();
    test_explicit_full_and_cancel();
    test_full_expiry_and_completion();
    test_paused_cycle();
    test_unknown_battery_does_not_bypass_sleep();
    test_unknown_battery_paused_at_sleep();
    test_unknown_battery_full_at_sleep();
    test_unknown_battery_cancel_full();
    test_original_low_battery_maintenance_wake();
    test_startup_capabilities();
    test_faults_and_legacy_keys();
    test_actual_reached_percentage();
    puts("batteryd: 13 sleep/charge regression scenarios passed (no hardware writes)");
    return 0;
}
