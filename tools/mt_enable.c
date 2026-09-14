/*
 * mt_enable — sonda TUTTE le interfacce HID della Magic Trackpad USB-C,
 * prova ad accendere il multitouch su ciascuna e ascolta cosa arriva.
 *
 * Il dispositivo espone piu' interfacce con lo stesso VID/PID: una di
 * compatibilita' mouse (UsagePage 0x01) e una o piu' vendor-defined Apple
 * (UsagePage 0xFF00). Il comando di abilitazione va mandato a quella giusta,
 * e a seconda del transport va mandato come feature report oppure come
 * output report. Questo tool le prova tutte e dice cosa risponde ognuna.
 *
 *   clang -framework IOKit -framework CoreFoundation -o mt_enable mt_enable.c
 *
 *   ./mt_enable              # sonda, abilita, ascolta 12 secondi
 *   ./mt_enable --listen     # ascolta soltanto, non manda nulla
 *   ./mt_enable --desc       # in piu' stampa i report descriptor
 *   ./mt_enable --secs 30    # ascolta piu' a lungo
 *
 * Serve il permesso "Monitoraggio Input" per il Terminale.
 */
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Il vendor ID cambia col transport: 0x05AC e' il vendor USB di Apple,
 * 0x004C e' il company identifier Bluetooth. Stesso dispositivo, numeri
 * diversi — quindi si fa il matching sul solo ProductID e si verifica
 * il vendor dopo. */
#define MT_VENDOR_USB  0x05AC
#define MT_VENDOR_BT   0x004C
#define MT_PRODUCT_ID  0x0324
#define MAX_IFACES     32
#define BUF_SIZE       4096

/* Bluetooth: feature report 0xF1. USB: report 0x02. */
/* Sequenze prese da hid-magicmouse.c (magicmouse_enable_multitouch).
 * Su USB il payload e' di DUE byte: il primo e' il report ID. */
static const uint8_t ENABLE_BT[]  = { 0xF1, 0x02, 0x01 };
static const uint8_t ENABLE_USB[] = { 0x02, 0x01 };

typedef struct {
    IOHIDDeviceRef dev;
    long   usage_page, usage;
    long   max_in, max_out, max_feat;
    int    bluetooth;
    int    opened;
    int    reports;
    int    multitouch_reports;
    uint8_t buf[BUF_SIZE];
} Iface;

static Iface g_if[MAX_IFACES];
static int   g_nif = 0;

static int opt_listen_only = 0;
static int opt_desc = 0;
static double opt_secs = 12.0;

/* ------------------------------------------------------------------ */

static long int_prop(IOHIDDeviceRef d, CFStringRef key) {
    CFTypeRef v = IOHIDDeviceGetProperty(d, key);
    long out = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &out);
    return out;
}

/* Accetta il dispositivo solo se il vendor e' quello USB o quello Bluetooth
 * di Apple: il matching e' sul ProductID, che da solo non basta. */
static int is_magic_trackpad(IOHIDDeviceRef dev) {
    long vid = int_prop(dev, CFSTR(kIOHIDVendorIDKey));
    return vid == MT_VENDOR_USB || vid == MT_VENDOR_BT;
}

static int is_bluetooth(IOHIDDeviceRef dev) {
    CFTypeRef v = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDTransportKey));
    if (!v || CFGetTypeID(v) != CFStringGetTypeID()) return 1;
    return CFStringFind((CFStringRef)v, CFSTR("USB"),
                        kCFCompareCaseInsensitive).location == kCFNotFound;
}

static const char *ret_name(IOReturn r) {
    switch (r) {
    case kIOReturnSuccess:        return "OK";
    case kIOReturnUnsupported:    return "non supportato";
    case kIOReturnBadArgument:    return "argomento non valido (dimensione?)";
    case kIOReturnNotOpen:        return "device non aperto";
    case kIOReturnNotPermitted:   return "non permesso (Monitoraggio Input?)";
    case kIOReturnNoDevice:       return "device sparito";
    case kIOReturnExclusiveAccess:return "gia' in uso in modo esclusivo";
    case kIOReturnTimeout:        return "timeout";
    case kIOReturnAborted:        return "annullato";
    default:                      return "?";
    }
}

static void dump_descriptor(IOHIDDeviceRef dev) {
    CFTypeRef rd = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDReportDescriptorKey));
    if (!rd || CFGetTypeID(rd) != CFDataGetTypeID()) {
        printf("      report descriptor: non disponibile\n");
        return;
    }
    CFDataRef data = (CFDataRef)rd;
    const UInt8 *p = CFDataGetBytePtr(data);
    CFIndex len = CFDataGetLength(data);
    printf("      report descriptor: %ld byte\n      ", (long)len);
    for (CFIndex i = 0; i < len; i++) {
        printf("%02X", p[i]);
        if ((i % 16) == 15 && i + 1 < len) printf("\n      ");
        else if (i + 1 < len) printf(" ");
    }
    printf("\n");
}

/* ------------------------------------------------------------------ */

static void on_report(void *ctx, IOReturn res, void *sender,
                      IOHIDReportType type, uint32_t reportID,
                      uint8_t *report, CFIndex len) {
    (void)sender; (void)type;
    if (res != kIOReturnSuccess || len <= 0) return;

    Iface *f = (Iface *)ctx;
    f->reports++;

    /* Lunghezza del report compreso il byte di report ID. */
    size_t n = (size_t)len + ((uint32_t)report[0] == reportID ? 0 : 1);

    /* Multitouch: 4 + 9n su Bluetooth (report 0x31), 12 + 9n su USB
     * (report 0x02, lo stesso id del mouse di compatibilita': si
     * distinguono solo dalla lunghezza). */
    int fingers = -1;
    if (reportID == 0x31 && n >= 4 && (n - 4) % 9 == 0)
        fingers = (int)((n - 4) / 9);
    else if (reportID == 0x02 && n >= 12 && (n - 12) % 9 == 0)
        fingers = (int)((n - 12) / 9);

    int mt = fingers >= 0;
    if (mt) f->multitouch_reports++;

    char tag[24];
    if (mt) snprintf(tag, sizeof tag, " MT %dd", fingers);
    else    snprintf(tag, sizeof tag, "      ");

    printf("  [if %d] id=0x%02X len=%2ld%s : ",
           (int)(f - g_if), reportID, (long)len, tag);
    for (CFIndex i = 0; i < len && i < 34; i++) printf("%02X ", report[i]);
    if (len > 34) printf("...");
    printf("\n");
    fflush(stdout);
}

static void on_match(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;
    if (g_nif >= MAX_IFACES) return;
    if (!is_magic_trackpad(dev)) return;

    Iface *f = &g_if[g_nif];
    memset(f, 0, sizeof *f);
    f->dev        = dev;
    f->usage_page = int_prop(dev, CFSTR(kIOHIDPrimaryUsagePageKey));
    f->usage      = int_prop(dev, CFSTR(kIOHIDPrimaryUsageKey));
    f->max_in     = int_prop(dev, CFSTR(kIOHIDMaxInputReportSizeKey));
    f->max_out    = int_prop(dev, CFSTR(kIOHIDMaxOutputReportSizeKey));
    f->max_feat   = int_prop(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey));
    f->bluetooth  = is_bluetooth(dev);
    g_nif++;
}

/* ------------------------------------------------------------------ */

static void try_enable(Iface *f, int idx) {
    const uint8_t *cmd = f->bluetooth ? ENABLE_BT : ENABLE_USB;
    size_t len         = f->bluetooth ? sizeof ENABLE_BT : sizeof ENABLE_USB;

    printf("  [if %d] UsagePage 0x%04lX Usage 0x%02lX — invio %02X…(%zu byte)\n",
           idx, f->usage_page, f->usage, cmd[0], len);

    IOReturn r = IOHIDDeviceSetReport(f->dev, kIOHIDReportTypeFeature,
                                      cmd[0], cmd, (CFIndex)len);
    printf("      feature : 0x%08X  %s\n", r, ret_name(r));

    /* Con MaxFeatureReportSize = 1 la feature non passa: su USB il comando
     * va allora mandato sull'endpoint di output, che qui e' da 64 byte. */
    if (r != kIOReturnSuccess && f->max_out > (long)len) {
        IOReturn r2 = IOHIDDeviceSetReport(f->dev, kIOHIDReportTypeOutput,
                                           cmd[0], cmd, (CFIndex)len);
        printf("      output  : 0x%08X  %s\n", r2, ret_name(r2));
    }
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--listen")) opt_listen_only = 1;
        else if (!strcmp(argv[i], "--desc")) opt_desc = 1;
        else if (!strcmp(argv[i], "--secs") && i + 1 < argc) opt_secs = atof(argv[++i]);
        else { fprintf(stderr, "opzione sconosciuta: %s\n", argv[i]); return 2; }
    }

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                             kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef m = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    int pid = MT_PRODUCT_ID;
    CFNumberRef np = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kIOHIDProductIDKey), np);
    IOHIDManagerSetDeviceMatching(mgr, m);
    CFRelease(np); CFRelease(m);

    IOHIDManagerRegisterDeviceMatchingCallback(mgr, on_match, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(),
                                    kCFRunLoopDefaultMode);

    IOReturn ok = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (ok != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDManagerOpen: 0x%08X — manca il permesso "
                        "Monitoraggio Input per il Terminale?\n", ok);
        return 1;
    }

    /* Fase 1: raccolta delle interfacce. */
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);

    if (g_nif == 0) {
        printf("Nessuna interfaccia trovata per PID 0x%04X "
               "(vendor atteso 0x%04X su USB, 0x%04X su Bluetooth).\n",
               MT_PRODUCT_ID, MT_VENDOR_USB, MT_VENDOR_BT);
        return 1;
    }

    printf("=== Interfacce trovate: %d ===\n\n", g_nif);
    for (int i = 0; i < g_nif; i++) {
        Iface *f = &g_if[i];
        const char *kind =
            (f->usage_page == 0x01 && f->usage == 0x02) ? "mouse di compatibilita'" :
            (f->usage_page == 0xFF00)                   ? "vendor Apple" : "altro";
        printf("  [%d] %s — UsagePage 0x%04lX Usage 0x%02lX (%s)\n",
               i, f->bluetooth ? "Bluetooth" : "USB",
               f->usage_page, f->usage, kind);
        printf("      MaxInput %ld  MaxOutput %ld  MaxFeature %ld\n",
               f->max_in, f->max_out, f->max_feat);
        if (opt_desc) dump_descriptor(f->dev);
    }
    printf("\n");

    /* Fase 2: apertura e ascolto. */
    printf("=== Apertura ===\n");
    for (int i = 0; i < g_nif; i++) {
        Iface *f = &g_if[i];
        IOReturn r = IOHIDDeviceOpen(f->dev, kIOHIDOptionsTypeNone);
        f->opened = (r == kIOReturnSuccess);
        printf("  [%d] open: 0x%08X %s\n", i, r, ret_name(r));
        if (f->opened)
            IOHIDDeviceRegisterInputReportCallback(f->dev, f->buf, BUF_SIZE,
                                                   on_report, f);
    }
    printf("\n");

    /* Fase 3: abilitazione. */
    if (!opt_listen_only) {
        printf("=== Abilitazione multitouch ===\n");
        for (int i = 0; i < g_nif; i++)
            if (g_if[i].opened) try_enable(&g_if[i], i);
        printf("\n");
    }

    printf("=== Ascolto per %.0f secondi — muovi le dita sul trackpad ===\n\n",
           opt_secs);
    fflush(stdout);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, opt_secs, false);

    printf("\n=== Riepilogo ===\n");
    int total = 0, total_mt = 0;
    for (int i = 0; i < g_nif; i++) {
        printf("  [%d] UsagePage 0x%04lX Usage 0x%02lX : %d report, "
               "di cui %d multitouch\n",
               i, g_if[i].usage_page, g_if[i].usage,
               g_if[i].reports, g_if[i].multitouch_reports);
        total    += g_if[i].reports;
        total_mt += g_if[i].multitouch_reports;
    }
    printf("\n  totale: %d report, %d multitouch\n", total, total_mt);

    if (total == 0)
        printf("\n  Zero report ovunque: o il kernel li scarta, o un altro\n"
               "  driver tiene le interfacce in accesso esclusivo.\n");
    else if (total_mt == 0)
        printf("\n  Arrivano report ma nessuno ha la forma multitouch:\n"
               "  l'abilitazione non ha preso, oppure il formato e' diverso\n"
               "  da quello atteso. Manda a Camilla le righe qui sopra.\n");
    else
        printf("\n  Multitouch confermato su USB.\n");

    return 0;
}
