/*
 * mt_sweep — cerca per tentativi il comando che accende il multitouch.
 *
 * I report descriptor dicono che la Magic Trackpad USB-C ha, sull'interfaccia
 * vendor 0xFF00/0x0D, un canale dati (input report 0x3F, 16 byte) e un canale
 * comandi (output report 0x53, 64 byte). Quale sia il comando, pero', non e'
 * documentato: il Magic Trackpad 2 usa F1 02 01 su Bluetooth e 02 01 00... su
 * USB, ma questo modello ha un transport diverso.
 *
 * Il tool prova una matrice di candidati: per ogni interfaccia, per ogni
 * report ID plausibile, per ogni payload, in versione corta e riempita alla
 * lunghezza dichiarata. Dopo ogni invio ascolta un attimo e guarda se sono
 * comparsi report diversi dal solito 0x02 del mouse.
 *
 *   clang -framework IOKit -framework CoreFoundation -o mt_sweep mt_sweep.c
 *
 *   ./mt_sweep                 # sweep completo
 *   ./mt_sweep --dwell 1.5     # ascolta piu' a lungo dopo ogni comando
 *   ./mt_sweep --seize         # apre le interfacce in modo esclusivo
 *
 * IMPORTANTE: durante lo sweep tieni un dito appoggiato sul trackpad e
 * muovilo di continuo, altrimenti il dispositivo non ha nulla da trasmettere
 * e un comando che ha funzionato sembra non aver fatto niente.
 *
 * Serve il permesso "Monitoraggio Input" per il Terminale.
 */
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MT_VENDOR_USB  0x05AC
#define MT_VENDOR_BT   0x004C
#define MT_PRODUCT_ID  0x0324
#define MAX_IFACES     8
#define BUF_SIZE       4096
#define MOUSE_REPORT   0x02   /* quello che gia' arriva: non e' una novita' */

typedef struct {
    IOHIDDeviceRef dev;
    long usage_page, usage, max_in, max_out;
    int  opened;
    int  novel;              /* report diversi da 0x02 visti dall'ultimo reset */
    uint8_t first[64];       /* il primo report nuovo, per mostrarlo */
    int  first_len, first_id;
    uint8_t buf[BUF_SIZE];
} Iface;

static Iface g_if[MAX_IFACES];
static int   g_nif = 0;
static double opt_dwell = 0.9;
static int    opt_seize = 0;

/* --- payload candidati ------------------------------------------------ */

typedef struct { const char *name; const uint8_t *data; size_t len; } Payload;

static const uint8_t P_BT[]    = { 0xF1, 0x02, 0x01 };
static const uint8_t P_USB[]   = { 0x02, 0x01, 0x00, 0x00, 0x00,
                                   0x00, 0x00, 0x00, 0x00 };
static const uint8_t P_ON[]    = { 0x01 };
static const uint8_t P_MT[]    = { 0x02, 0x01 };
static const uint8_t P_WRAP[]  = { 0xF1, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };

static const Payload PAYLOADS[] = {
    { "F1 02 01 (Bluetooth MT2)",  P_BT,   sizeof P_BT   },
    { "02 01 00.. (USB MT2)",      P_USB,  sizeof P_USB  },
    { "02 01",                     P_MT,   sizeof P_MT   },
    { "01",                        P_ON,   sizeof P_ON   },
    { "F1 02 01 + zeri",           P_WRAP, sizeof P_WRAP },
};
#define N_PAYLOADS (int)(sizeof PAYLOADS / sizeof PAYLOADS[0])

/* Il primo e' quello dichiarato dal descriptor: va provato per primo. */
static const uint8_t OUT_IDS[]  = { 0x53, 0x02, 0x3F, 0xF1 };
static const uint8_t FEAT_IDS[] = { 0xF1, 0x02, 0x53 };

/* --------------------------------------------------------------------- */

static long int_prop(IOHIDDeviceRef d, CFStringRef key) {
    CFTypeRef v = IOHIDDeviceGetProperty(d, key);
    long out = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &out);
    return out;
}

static void on_report(void *ctx, IOReturn res, void *sender,
                      IOHIDReportType type, uint32_t reportID,
                      uint8_t *report, CFIndex len) {
    (void)sender; (void)type;
    if (res != kIOReturnSuccess || len <= 0) return;
    if (reportID == MOUSE_REPORT) return;         /* gia' noto */

    Iface *f = (Iface *)ctx;
    if (f->novel == 0) {
        f->first_id  = (int)reportID;
        f->first_len = (int)(len < 64 ? len : 64);
        memcpy(f->first, report, (size_t)f->first_len);
    }
    f->novel++;
}

static void on_match(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;
    if (g_nif >= MAX_IFACES) return;
    long vid = int_prop(dev, CFSTR(kIOHIDVendorIDKey));
    if (vid != MT_VENDOR_USB && vid != MT_VENDOR_BT) return;

    Iface *f = &g_if[g_nif++];
    memset(f, 0, sizeof *f);
    f->dev        = dev;
    f->usage_page = int_prop(dev, CFSTR(kIOHIDPrimaryUsagePageKey));
    f->usage      = int_prop(dev, CFSTR(kIOHIDPrimaryUsageKey));
    f->max_in     = int_prop(dev, CFSTR(kIOHIDMaxInputReportSizeKey));
    f->max_out    = int_prop(dev, CFSTR(kIOHIDMaxOutputReportSizeKey));
}

static void reset_counters(void) {
    for (int i = 0; i < g_nif; i++) g_if[i].novel = 0;
}

/* Restituisce l'indice dell'interfaccia su cui sono arrivati report nuovi. */
static int listen_and_check(void) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, opt_dwell, false);
    for (int i = 0; i < g_nif; i++)
        if (g_if[i].novel > 0) return i;
    return -1;
}

static void show_hit(int idx, const char *how) {
    Iface *f = &g_if[idx];
    printf("\n"
           "  ############################################################\n"
           "  #  TROVATO                                                 #\n"
           "  ############################################################\n\n");
    printf("  Comando      : %s\n", how);
    printf("  Interfaccia  : [%d] UsagePage 0x%04lX Usage 0x%02lX\n",
           idx, f->usage_page, f->usage);
    printf("  Report nuovi : %d\n", f->novel);
    printf("  Primo report : id=0x%02X len=%d : ", f->first_id, f->first_len);
    for (int i = 0; i < f->first_len; i++) printf("%02X ", f->first[i]);
    printf("\n\n");
}

static int attempt(Iface *f, int idx, IOHIDReportType type,
                   uint8_t rid, const Payload *p, int padded) {
    uint8_t body[128];
    size_t len = p->len;

    if (padded) {
        long want = (type == kIOHIDReportTypeOutput) ? f->max_out - 1 : 0;
        if (want <= (long)p->len || want > (long)sizeof body) return 0;
        memset(body, 0, (size_t)want);
        memcpy(body, p->data, p->len);
        len = (size_t)want;
    } else {
        if (p->len > sizeof body) return 0;
        memcpy(body, p->data, p->len);
    }

    const char *tname = (type == kIOHIDReportTypeOutput) ? "output" : "feature";
    char how[160];
    snprintf(how, sizeof how, "if[%d] %s id=0x%02X payload \"%s\"%s",
             idx, tname, rid, p->name, padded ? " (riempito)" : "");

    reset_counters();
    IOReturn r = IOHIDDeviceSetReport(f->dev, type, rid, body, (CFIndex)len);
    printf("  %-62s -> 0x%08X%s\n", how, r,
           r == kIOReturnSuccess ? "" : "  (rifiutato)");
    fflush(stdout);

    if (r != kIOReturnSuccess) return 0;

    int hit = listen_and_check();
    if (hit >= 0) { show_hit(hit, how); return 1; }
    return 0;
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dwell") && i + 1 < argc) opt_dwell = atof(argv[++i]);
        else if (!strcmp(argv[i], "--seize")) opt_seize = 1;
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

    if (IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDManagerOpen fallita — permesso Monitoraggio "
                        "Input per il Terminale?\n");
        return 1;
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);

    if (g_nif == 0) { printf("Trackpad non trovato.\n"); return 1; }

    printf("=== %d interfacce ===\n", g_nif);
    for (int i = 0; i < g_nif; i++) {
        Iface *f = &g_if[i];
        IOReturn r = IOHIDDeviceOpen(f->dev, opt_seize
                                     ? kIOHIDOptionsTypeSeizeDevice
                                     : kIOHIDOptionsTypeNone);
        f->opened = (r == kIOReturnSuccess);
        printf("  [%d] UsagePage 0x%04lX Usage 0x%02lX  MaxIn %ld MaxOut %ld  "
               "open %s\n", i, f->usage_page, f->usage, f->max_in, f->max_out,
               f->opened ? "OK" : "FALLITA");
        if (f->opened)
            IOHIDDeviceRegisterInputReportCallback(f->dev, f->buf, BUF_SIZE,
                                                   on_report, f);
    }

    printf("\n  >>> TIENI UN DITO SUL TRACKPAD E MUOVILO PER TUTTO LO SWEEP <<<\n"
           "      (senza dati da trasmettere, un comando riuscito sembra "
           "fallito)\n\n");
    printf("=== Sweep (%.1fs per tentativo) ===\n\n", opt_dwell);

    /* Prima gli output report, che sono la strada indicata dal descriptor. */
    for (int i = 0; i < g_nif; i++) {
        Iface *f = &g_if[i];
        if (!f->opened || f->max_out <= 1) continue;
        for (size_t k = 0; k < sizeof OUT_IDS; k++)
            for (int p = 0; p < N_PAYLOADS; p++)
                for (int pad = 0; pad < 2; pad++)
                    if (attempt(f, i, kIOHIDReportTypeOutput,
                                OUT_IDS[k], &PAYLOADS[p], pad))
                        return 0;
    }

    /* Poi le feature, per scrupolo: il descriptor non ne dichiara. */
    for (int i = 0; i < g_nif; i++) {
        Iface *f = &g_if[i];
        if (!f->opened) continue;
        for (size_t k = 0; k < sizeof FEAT_IDS; k++)
            for (int p = 0; p < N_PAYLOADS; p++)
                if (attempt(f, i, kIOHIDReportTypeFeature,
                            FEAT_IDS[k], &PAYLOADS[p], 0))
                    return 0;
    }

    printf("\n=== Nessun candidato ha prodotto report nuovi ===\n\n"
           "  Il comando di questo modello non e' nessuno di quelli provati.\n"
           "  A questo punto conviene catturare la sequenza vera invece di\n"
           "  indovinarla: vedi docs/04-usb.md.\n");
    return 1;
}
