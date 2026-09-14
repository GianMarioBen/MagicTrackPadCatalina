/*
 * mt_enable — mette la Magic Trackpad USB-C in modalita' multitouch.
 *
 * Versione diagnostica del comando che il bridge invia da solo.
 * Riconosce il transport e manda la sequenza giusta:
 *
 *   Bluetooth : feature report 0xF1  ->  F1 02 01
 *   USB       : feature report 0x02  ->  02 01 00 00 00 00 00 00 00
 *
 *   clang -framework IOKit -framework CoreFoundation -o mt_enable mt_enable.c
 *   ./mt_enable            # abilita e poi ascolta i report per 10 secondi
 *   ./mt_enable --quiet    # abilita e basta
 *
 * Serve il permesso "Monitoraggio Input" per il Terminale.
 *
 * ATTESO: dopo l'abilitazione il puntatore smette di muoversi. E' corretto:
 * il dispositivo ha lasciato la modalita' mouse di compatibilita'.
 * Per tornare indietro basta spegnere e riaccendere il trackpad.
 */
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

#define MT_VENDOR_ID  0x004C
#define MT_PRODUCT_ID 0x0324

static const uint8_t ENABLE_BT[]  = { 0xF1, 0x02, 0x01 };
static const uint8_t ENABLE_USB[] = { 0x02, 0x01, 0x00, 0x00, 0x00,
                                      0x00, 0x00, 0x00, 0x00 };

static int g_quiet = 0;
static int g_reports = 0;
static uint8_t g_buf[1024];

static int is_bluetooth(IOHIDDeviceRef dev) {
    CFTypeRef v = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDTransportKey));
    if (!v || CFGetTypeID(v) != CFStringGetTypeID()) return 1; /* default BT */
    return CFStringFind((CFStringRef)v, CFSTR("USB"),
                        kCFCompareCaseInsensitive).location == kCFNotFound;
}

static void on_report(void *ctx, IOReturn res, void *sender,
                      IOHIDReportType type, uint32_t reportID,
                      uint8_t *report, CFIndex len) {
    (void)ctx; (void)res; (void)sender; (void)type;
    g_reports++;
    if (g_quiet) return;
    printf("report id=0x%02X len=%ld : ", reportID, (long)len);
    for (CFIndex i = 0; i < len && i < 40; i++) printf("%02X ", report[i]);
    printf("\n");
    fflush(stdout);
}

static void on_match(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;

    int bt = is_bluetooth(dev);
    const uint8_t *cmd = bt ? ENABLE_BT : ENABLE_USB;
    size_t cmd_len     = bt ? sizeof ENABLE_BT : sizeof ENABLE_USB;

    printf("Trovato trackpad su %s\n", bt ? "Bluetooth" : "USB");

    IOReturn ok = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    printf("  IOHIDDeviceOpen      : 0x%08X\n", ok);

    ok = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature,
                              cmd[0], cmd, (CFIndex)cmd_len);
    printf("  SetReport 0x%02X       : 0x%08X %s\n", cmd[0], ok,
           ok == kIOReturnSuccess ? "OK" : "FALLITO");

    if (ok != kIOReturnSuccess) return;

    if (!g_quiet) {
        IOHIDDeviceRegisterInputReportCallback(dev, g_buf, sizeof g_buf,
                                               on_report, NULL);
        printf("\nIn ascolto per 10 secondi — muovi le dita sul trackpad.\n\n");
    }
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--quiet")) g_quiet = 1;

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                             kIOHIDOptionsTypeNone);

    CFMutableDictionaryRef m = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    int vid = MT_VENDOR_ID, pid = MT_PRODUCT_ID;
    CFNumberRef nv = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    CFNumberRef np = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kIOHIDVendorIDKey), nv);
    CFDictionarySetValue(m, CFSTR(kIOHIDProductIDKey), np);
    IOHIDManagerSetDeviceMatching(mgr, m);
    CFRelease(nv); CFRelease(np); CFRelease(m);

    IOHIDManagerRegisterDeviceMatchingCallback(mgr, on_match, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(),
                                    kCFRunLoopDefaultMode);

    IOReturn ok = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (ok != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDManagerOpen: 0x%08X "
                        "(manca il permesso Monitoraggio Input?)\n", ok);
        return 1;
    }

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, g_quiet ? 1.5 : 11.0, false);

    if (!g_quiet) {
        printf("\nReport ricevuti: %d\n", g_reports);
        if (g_reports == 0)
            printf("Zero report = il kernel li sta scartando.\n"
                   "Controlla MaxInputReportSize con tools/triage.sh:\n"
                   "se vale 8, serve la patch del descriptor (docs/02-analisi.md).\n");
    }
    return 0;
}
