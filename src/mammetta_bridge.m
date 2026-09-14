/*
 * mammetta_bridge — Magic Trackpad USB-C come vero trackpad su Catalina.
 *
 * Legge i report multitouch del dispositivo tramite IOHIDManager e li traduce
 * in CGEvent: puntatore, scroll a due dita con fasi (quindi con inerzia e
 * rubber-banding veri), click, click destro, tap-to-click, swipe a tre dita.
 *
 *   clang -fobjc-arc -framework IOKit -framework CoreFoundation \
 *         -framework ApplicationServices -o mammetta_bridge mammetta_bridge.m
 *
 * Permessi richiesti dal Terminale (Preferenze di Sistema → Sicurezza e
 * Privacy → Privacy):
 *   - Monitoraggio Input   (per leggere il trackpad)
 *   - Accessibilita'       (per generare eventi)
 *
 * PREREQUISITO: il kernel deve consegnarci i report. Se
 * MaxInputReportSize vale 8 i report vengono scartati prima di arrivare qui:
 * vedi docs/02-analisi.md. Il bridge te lo dice all'avvio.
 */

#import <IOKit/hid/IOHIDManager.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#include <math.h>
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

#define BT_REPORT_ID   0x31
#define BT_HEADER      4
#define USB_REPORT_ID  0x02
#define USB_HEADER     6
#define CONTACT_SIZE   9
#define MAX_CONTACTS   16

/* Range fisico del sensore, in unita' del dispositivo. */
#define DEV_X_SPAN     7612.0   /* da -3678 a +3934 */
#define DEV_Y_SPAN     5065.0   /* da -2478 a +2587 */

/* Su SDK vecchi queste costanti possono mancare. */
#ifndef kCGScrollWheelEventScrollPhase
#define kCGScrollWheelEventScrollPhase 99
#endif
#ifndef kCGScrollWheelEventMomentumPhase
#define kCGScrollWheelEventMomentumPhase 123
#endif
#ifndef kCGScrollWheelEventIsContinuous
#define kCGScrollWheelEventIsContinuous 88
#endif

#define PHASE_NONE    0
#define PHASE_BEGAN   1
#define PHASE_CHANGED 2
#define PHASE_ENDED   4

static const uint8_t ENABLE_BT[]  = { 0xF1, 0x02, 0x01 };
static const uint8_t ENABLE_USB[] = { 0x02, 0x01, 0x00, 0x00, 0x00,
                                      0x00, 0x00, 0x00, 0x00 };

/* ------------------------------------------------------------------ */
/* Opzioni                                                            */
/* ------------------------------------------------------------------ */

static struct {
    int    verbose;
    int    no_events;       /* solo decodifica, nessun CGEvent */
    int    natural_scroll;
    int    tap_to_click;
    double pointer_speed;
    double scroll_speed;
} opt = { 0, 0, 1, 1, 1.0, 1.0 };

/* ------------------------------------------------------------------ */
/* Decodifica                                                         */
/* ------------------------------------------------------------------ */

typedef struct {
    int id;
    int x, y;               /* unita' dispositivo, y verso l'alto */
    int touch_major, touch_minor, size;
    int down;
} Contact;

static int sign_extend(int value, int bits) {
    int mask = 1 << (bits - 1);
    return (value & (mask - 1)) - (value & mask);
}

static void decode_contact(const uint8_t *t, Contact *c) {
    int ux = ((t[1] << 8) | t[0]) & 0x1FFF;
    int uy = (((t[3] << 16) | (t[2] << 8) | t[1]) >> 5) & 0x1FFF;
    c->x           = sign_extend(ux, 13);
    c->y           = -sign_extend(uy, 13);
    c->touch_major = t[4];
    c->touch_minor = t[5];
    c->size        = t[6];
    c->down        = (t[7] & 0xF0) != 0;
    c->id          = t[8] & 0x0F;
}

/* Restituisce il numero di contatti, -1 se il report non e' multitouch. */
static int decode_report(const uint8_t *data, size_t len,
                         Contact *out, int *button) {
    if (len < 2) return -1;

    size_t header;
    if (data[0] == BT_REPORT_ID)       header = BT_HEADER;
    else if (data[0] == USB_REPORT_ID) header = USB_HEADER;
    else return -1;

    if (len < header) return -1;
    size_t body = len - header;
    if (body % CONTACT_SIZE) return -1;

    int n = (int)(body / CONTACT_SIZE);
    if (n > MAX_CONTACTS) n = MAX_CONTACTS;

    *button = (data[1] & 1) != 0;
    for (int i = 0; i < n; i++)
        decode_contact(data + header + i * CONTACT_SIZE, &out[i]);
    return n;
}

/* ------------------------------------------------------------------ */
/* Generazione eventi                                                 */
/* ------------------------------------------------------------------ */

static CGPoint g_cursor;
static int     g_cursor_valid = 0;

static CGRect desktop_bounds(void) {
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, ids, &count) != kCGErrorSuccess || !count)
        return CGRectMake(0, 0, 1440, 900);

    CGRect r = CGDisplayBounds(ids[0]);
    for (uint32_t i = 1; i < count; i++)
        r = CGRectUnion(r, CGDisplayBounds(ids[i]));
    return r;
}

static void cursor_sync(void) {
    CGEventRef probe = CGEventCreate(NULL);
    if (probe) {
        g_cursor = CGEventGetLocation(probe);
        CFRelease(probe);
        g_cursor_valid = 1;
    }
}

/* Curva di accelerazione: lenta quando muovi piano, veloce quando corri. */
static double accel(double speed) {
    double a = 0.55 + 0.030 * speed;
    return a > 3.2 ? 3.2 : a;
}

static void post_move(double dx, double dy, int dragging) {
    if (opt.no_events) return;
    if (!g_cursor_valid) cursor_sync();

    double speed = sqrt(dx * dx + dy * dy);
    double gain  = accel(speed) * opt.pointer_speed;
    double mx = dx * gain, my = dy * gain;

    CGRect b = desktop_bounds();
    g_cursor.x += mx;
    g_cursor.y += my;
    if (g_cursor.x < CGRectGetMinX(b)) g_cursor.x = CGRectGetMinX(b);
    if (g_cursor.y < CGRectGetMinY(b)) g_cursor.y = CGRectGetMinY(b);
    if (g_cursor.x > CGRectGetMaxX(b) - 1) g_cursor.x = CGRectGetMaxX(b) - 1;
    if (g_cursor.y > CGRectGetMaxY(b) - 1) g_cursor.y = CGRectGetMaxY(b) - 1;

    CGEventType type = dragging ? kCGEventLeftMouseDragged : kCGEventMouseMoved;
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, g_cursor,
                                           kCGMouseButtonLeft);
    if (!e) return;
    CGEventSetDoubleValueField(e, kCGMouseEventDeltaX, mx);
    CGEventSetDoubleValueField(e, kCGMouseEventDeltaY, my);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

static void post_scroll(double dx, double dy, int phase) {
    if (opt.no_events) return;

    double sign = opt.natural_scroll ? 1.0 : -1.0;
    int32_t sy = (int32_t)lround(dy * 1.4 * opt.scroll_speed * sign);
    int32_t sx = (int32_t)lround(dx * 1.4 * opt.scroll_speed * sign);

    if (phase == PHASE_CHANGED && sx == 0 && sy == 0) return;

    CGEventRef e = CGEventCreateScrollWheelEvent2(
        NULL, kCGScrollEventUnitPixel, 2, sy, sx, 0);
    if (!e) return;
    /* Senza queste due righe macOS lo tratta come una rotella: niente
     * inerzia, niente elastico, scatti. */
    CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventScrollPhase, phase);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

static void post_button(CGEventType type, CGMouseButton button) {
    if (opt.no_events) return;
    if (!g_cursor_valid) cursor_sync();
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, g_cursor, button);
    if (!e) return;
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

static void post_click(CGMouseButton button) {
    post_button(button == kCGMouseButtonRight ? kCGEventRightMouseDown
                                              : kCGEventLeftMouseDown, button);
    post_button(button == kCGMouseButtonRight ? kCGEventRightMouseUp
                                              : kCGEventLeftMouseUp, button);
}

/* Swipe a tre dita → Control+Freccia (spazi) e Control+Su (Mission Control).
 * Passare per i tasti e' molto piu' affidabile che simulare gesture NSEvent,
 * che da user space richiederebbero API private. */
static void post_key(CGKeyCode key, CGEventFlags flags) {
    if (opt.no_events) return;
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, key, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(NULL, key, false);
    if (down) { CGEventSetFlags(down, flags); CGEventPost(kCGHIDEventTap, down); CFRelease(down); }
    if (up)   { CGEventSetFlags(up, flags);   CGEventPost(kCGHIDEventTap, up);   CFRelease(up); }
}

#define KEY_LEFT  0x7B
#define KEY_RIGHT 0x7C
#define KEY_UP    0x7E

/* ------------------------------------------------------------------ */
/* Macchina a stati delle gesture                                     */
/* ------------------------------------------------------------------ */

typedef enum {
    G_IDLE = 0,
    G_POINTER,
    G_SCROLL,
    G_SWIPE3,
} Gesture;

static struct {
    Gesture gesture;
    int     button_down;        /* pulsante fisico premuto */
    int     right_click_armed;  /* click partito con due dita */
    int     n_at_start;         /* dita al momento del tocco iniziale */
    int     max_contacts;       /* massimo visto in questa gesture */
    int     swipe_fired;

    int     anchor_id;          /* dito che guida il puntatore */
    double  last_x, last_y;
    double  scroll_x, scroll_y; /* baricentro delle due dita */
    double  travel;             /* distanza percorsa, per il tap */
    double  swipe_dx, swipe_dy;

    CFAbsoluteTime touch_start;
} st;

static void gesture_reset(void) {
    if (st.gesture == G_SCROLL)
        post_scroll(0, 0, PHASE_ENDED);
    memset(&st, 0, sizeof st);
}

static Contact *find_contact(Contact *c, int n, int id) {
    for (int i = 0; i < n; i++)
        if (c[i].down && c[i].id == id) return &c[i];
    return NULL;
}

static void handle_contacts(Contact *all, int n_all, int button) {
    Contact active[MAX_CONTACTS];
    int n = 0;
    for (int i = 0; i < n_all; i++)
        if (all[i].down) active[n++] = all[i];

    if (opt.verbose) {
        printf("dita=%d button=%d", n, button);
        for (int i = 0; i < n; i++)
            printf("  [id%d %+5d %+5d s%d]",
                   active[i].id, active[i].x, active[i].y, active[i].size);
        printf("\n");
        fflush(stdout);
    }

    /* ---- pulsante fisico ---- */
    if (button && !st.button_down) {
        st.button_down = 1;
        /* due dita appoggiate mentre si preme = click secondario */
        st.right_click_armed = (n >= 2);
        post_button(st.right_click_armed ? kCGEventRightMouseDown
                                         : kCGEventLeftMouseDown,
                    st.right_click_armed ? kCGMouseButtonRight
                                         : kCGMouseButtonLeft);
    } else if (!button && st.button_down) {
        post_button(st.right_click_armed ? kCGEventRightMouseUp
                                         : kCGEventLeftMouseUp,
                    st.right_click_armed ? kCGMouseButtonRight
                                         : kCGMouseButtonLeft);
        st.button_down = 0;
        st.right_click_armed = 0;
    }

    /* ---- tutte le dita sollevate: fine gesture ---- */
    if (n == 0) {
        if (opt.tap_to_click && !st.button_down &&
            st.gesture != G_SWIPE3 && st.travel < 18.0 &&
            (CFAbsoluteTimeGetCurrent() - st.touch_start) < 0.25) {
            if (st.max_contacts == 1)      post_click(kCGMouseButtonLeft);
            else if (st.max_contacts == 2) post_click(kCGMouseButtonRight);
        }
        gesture_reset();
        return;
    }

    /* ---- inizio di una nuova gesture ---- */
    if (st.gesture == G_IDLE) {
        st.touch_start  = CFAbsoluteTimeGetCurrent();
        st.n_at_start   = n;
        st.max_contacts = n;
        st.travel       = 0;
        cursor_sync();

        if (n == 1) {
            st.gesture   = G_POINTER;
            st.anchor_id = active[0].id;
            st.last_x    = active[0].x;
            st.last_y    = active[0].y;
        } else if (n == 2) {
            st.gesture  = G_SCROLL;
            st.scroll_x = (active[0].x + active[1].x) / 2.0;
            st.scroll_y = (active[0].y + active[1].y) / 2.0;
            post_scroll(0, 0, PHASE_BEGAN);
        } else {
            st.gesture   = G_SWIPE3;
            st.swipe_dx  = st.swipe_dy = 0;
            st.anchor_id = active[0].id;
            st.last_x    = active[0].x;
            st.last_y    = active[0].y;
        }
        return;
    }

    if (n > st.max_contacts) st.max_contacts = n;

    /* Cambio del numero di dita a meta' gesture: si ricomincia, cosi'
     * appoggiare un secondo dito passa da puntatore a scroll senza scatti. */
    if ((st.gesture == G_POINTER && n != 1) ||
        (st.gesture == G_SCROLL  && n != 2) ||
        (st.gesture == G_SWIPE3  && n < 3)) {
        int keep = st.max_contacts;
        int btn  = st.button_down;
        int rca  = st.right_click_armed;
        CFAbsoluteTime t0 = st.touch_start;
        gesture_reset();
        st.max_contacts      = keep;
        st.button_down       = btn;
        st.right_click_armed = rca;
        st.touch_start       = t0;
        handle_contacts(all, n_all, button);
        return;
    }

    switch (st.gesture) {
    case G_POINTER: {
        Contact *c = find_contact(active, n, st.anchor_id);
        if (!c) { st.anchor_id = active[0].id;
                  st.last_x = active[0].x; st.last_y = active[0].y; break; }
        /* unita' dispositivo -> punti schermo, y invertito */
        double dx = (c->x - st.last_x) * 0.115;
        double dy = -(c->y - st.last_y) * 0.115;
        st.last_x = c->x;
        st.last_y = c->y;
        st.travel += fabs(dx) + fabs(dy);
        post_move(dx, dy, st.button_down);
        break;
    }
    case G_SCROLL: {
        double cx = (active[0].x + active[1].x) / 2.0;
        double cy = (active[0].y + active[1].y) / 2.0;
        double dx = -(cx - st.scroll_x) * 0.115;
        double dy =  (cy - st.scroll_y) * 0.115;
        st.scroll_x = cx;
        st.scroll_y = cy;
        st.travel += fabs(dx) + fabs(dy);
        post_scroll(dx, dy, PHASE_CHANGED);
        break;
    }
    case G_SWIPE3: {
        Contact *c = find_contact(active, n, st.anchor_id);
        if (!c) break;
        st.swipe_dx += c->x - st.last_x;
        st.swipe_dy += c->y - st.last_y;
        st.last_x = c->x;
        st.last_y = c->y;

        if (!st.swipe_fired) {
            if (st.swipe_dx >  900) { post_key(KEY_LEFT,  kCGEventFlagMaskControl); st.swipe_fired = 1; }
            else if (st.swipe_dx < -900) { post_key(KEY_RIGHT, kCGEventFlagMaskControl); st.swipe_fired = 1; }
            else if (st.swipe_dy >  900) { post_key(KEY_UP,    kCGEventFlagMaskControl); st.swipe_fired = 1; }
        }
        break;
    }
    default:
        break;
    }
}

/* ------------------------------------------------------------------ */
/* IOHID                                                              */
/* ------------------------------------------------------------------ */

static uint8_t g_report_buf[2048];
static int     g_seen_multitouch = 0;
static int     g_seen_any = 0;

static void on_report(void *ctx, IOReturn res, void *sender,
                      IOHIDReportType type, uint32_t reportID,
                      uint8_t *report, CFIndex len) {
    (void)ctx; (void)sender; (void)type;
    if (res != kIOReturnSuccess || len <= 0) return;

    g_seen_any++;

    /* A seconda del transport il buffer puo' includere o meno il report ID
     * in testa: normalizziamo. */
    uint8_t stack[2048];
    const uint8_t *data;
    size_t n;

    if ((uint32_t)report[0] == reportID) {
        data = report;
        n = (size_t)len;
    } else {
        if ((size_t)len + 1 > sizeof stack) return;
        stack[0] = (uint8_t)reportID;
        memcpy(stack + 1, report, (size_t)len);
        data = stack;
        n = (size_t)len + 1;
    }

    Contact contacts[MAX_CONTACTS];
    int button = 0;
    int count = decode_report(data, n, contacts, &button);
    if (count < 0) return;

    if (!g_seen_multitouch) {
        g_seen_multitouch = 1;
        printf("Report multitouch in arrivo. Il bridge e' operativo.\n\n");
        fflush(stdout);
    }
    handle_contacts(contacts, count, button);
}

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

static void enable_multitouch(IOHIDDeviceRef dev) {
    int bt = is_bluetooth(dev);
    const uint8_t *cmd = bt ? ENABLE_BT : ENABLE_USB;
    size_t len         = bt ? sizeof ENABLE_BT : sizeof ENABLE_USB;

    IOReturn r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature,
                                      cmd[0], cmd, (CFIndex)len);
    printf("  abilitazione multitouch (%s): %s\n",
           bt ? "Bluetooth" : "USB",
           r == kIOReturnSuccess ? "OK" : "FALLITA");
    if (r != kIOReturnSuccess)
        printf("  IOHIDDeviceSetReport ha restituito 0x%08X\n", r);
}

static void on_match(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;
    if (!is_magic_trackpad(dev)) return;

    long maxIn = int_prop(dev, CFSTR(kIOHIDMaxInputReportSizeKey));
    printf("Trackpad collegato (%s)\n", is_bluetooth(dev) ? "Bluetooth" : "USB");
    printf("  MaxInputReportSize: %ld\n", maxIn);

    if (maxIn > 0 && maxIn < 13) {
        printf("\n  ATTENZIONE: con MaxInputReportSize = %ld il kernel scarta\n"
               "  i report multitouch prima che arrivino qui. Serve la patch\n"
               "  del report descriptor — vedi docs/02-analisi.md §4, traccia B.\n"
               "  (Su USB questo problema non dovrebbe presentarsi.)\n\n", maxIn);
    }

    IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    IOHIDDeviceRegisterInputReportCallback(dev, g_report_buf,
                                           sizeof g_report_buf,
                                           on_report, NULL);
    enable_multitouch(dev);
    printf("\n");
    fflush(stdout);
}

static void on_remove(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender; (void)dev;
    printf("Trackpad scollegato. In attesa che torni.\n");
    gesture_reset();
    g_seen_multitouch = 0;
    fflush(stdout);
}

/* ------------------------------------------------------------------ */

static void usage(const char *prog) {
    printf(
"uso: %s [opzioni]\n"
"\n"
"  -v, --verbose         stampa i contatti decodificati\n"
"      --no-events       decodifica soltanto, non genera eventi\n"
"      --classic-scroll  direzione di scroll classica (non naturale)\n"
"      --no-tap          disabilita il tap-to-click\n"
"      --pointer N       velocita' del puntatore (default 1.0)\n"
"      --scroll N        velocita' dello scroll  (default 1.0)\n"
"  -h, --help            questo messaggio\n"
"\n"
"Gesture:\n"
"  1 dito                puntatore\n"
"  2 dita                scroll con inerzia\n"
"  click                 click primario\n"
"  click con 2 dita      click secondario\n"
"  tap                   click primario     (--no-tap per disattivare)\n"
"  tap con 2 dita        click secondario\n"
"  swipe 3 dita          cambio spazio / Mission Control\n"
"\n", prog);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-v") || !strcmp(a, "--verbose")) opt.verbose = 1;
        else if (!strcmp(a, "--no-events"))      opt.no_events = 1;
        else if (!strcmp(a, "--classic-scroll")) opt.natural_scroll = 0;
        else if (!strcmp(a, "--no-tap"))         opt.tap_to_click = 0;
        else if (!strcmp(a, "--pointer") && i + 1 < argc) opt.pointer_speed = atof(argv[++i]);
        else if (!strcmp(a, "--scroll")  && i + 1 < argc) opt.scroll_speed  = atof(argv[++i]);
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(argv[0]); return 0; }
        else { fprintf(stderr, "opzione sconosciuta: %s\n", a); usage(argv[0]); return 2; }
    }

    if (!opt.no_events && !AXIsProcessTrusted()) {
        fprintf(stderr,
            "Il processo non e' abilitato all'Accessibilita'.\n"
            "Preferenze di Sistema -> Sicurezza e Privacy -> Privacy ->\n"
            "Accessibilita': aggiungi il Terminale (o questo binario).\n"
            "Senza, gli eventi vengono generati ma non consegnati.\n\n");
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
    IOHIDManagerRegisterDeviceRemovalCallback(mgr, on_remove, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(),
                                    kCFRunLoopDefaultMode);

    IOReturn ok = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (ok != kIOReturnSuccess) {
        fprintf(stderr,
            "IOHIDManagerOpen: 0x%08X\n"
            "Manca il permesso Monitoraggio Input per il Terminale.\n", ok);
        return 1;
    }

    cursor_sync();
    printf("mammetta_bridge — in attesa della Magic Trackpad USB-C "
           "(PID 0x%04X)\n", MT_PRODUCT_ID);
    printf("Ctrl-C per uscire.\n\n");
    fflush(stdout);

    CFRunLoopRun();
    return 0;
}
