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
#define USB_HEADER     12
#define CONTACT_SIZE   9
#define MAX_CONTACTS   16

/* Range fisico del sensore, in unita' del dispositivo. */
#define DEV_X_MIN      (-3678)
#define DEV_X_MAX      ( 3934)
#define DEV_Y_MIN      (-2478)
#define DEV_Y_MAX      ( 2587)

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
static const uint8_t ENABLE_USB[] = { 0x02, 0x01 };

/* ------------------------------------------------------------------ */
/* Opzioni                                                            */
/* ------------------------------------------------------------------ */

static struct {
    int    verbose;
    int    no_events;       /* solo decodifica, nessun CGEvent */
    int    natural_scroll;
    int    tap_to_click;
    int    edge_scroll;     /* scroll di bordo, per la modalita' a un contatto */
    int    diag;            /* riga di stato una volta al secondo */
    double pointer_speed;
    double scroll_speed;
} opt = { 0, 0, 1, 1, 1, 0, 1.0, 1.0 };

/* ------------------------------------------------------------------ */
/* Decodifica                                                         */
/* ------------------------------------------------------------------ */

typedef struct {
    int id;
    int x, y;               /* unita' dispositivo, y verso l'alto */
    int touch_major, touch_minor, size;
    int pressure;
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
    c->pressure    = t[7];
    /* Lo stato del contatto sta nei due bit alti di t[3], non in t[7]:
     * 0x80 = dito appoggiato. */
    c->down        = (t[3] & 0xC0) == 0x80;
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

/* Contatori per la diagnostica: servono a distinguere "non arrivano dati"
 * da "arrivano dati ma gli eventi non vengono consegnati a nessuno". */
static long g_events_posted = 0;
static long g_reports_seen  = 0;

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
    g_events_posted++;
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
    g_events_posted++;
}

static void post_button(CGEventType type, CGMouseButton button) {
    if (opt.no_events) return;
    if (!g_cursor_valid) cursor_sync();
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, g_cursor, button);
    if (!e) return;
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    g_events_posted++;
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

/*
 * Su Catalina il report descriptor puo' dichiarare una lunghezza sola,
 * mentre quella dei report multitouch varia col numero di dita (4 + 9n).
 * Dichiarando la misura di un contatto (13 byte) i report piu' lunghi
 * arrivano troncati: si vede sempre e solo il primo dito.
 *
 * Il bridge si adatta da solo. Se arriva un contatto solo usa le zone di
 * bordo per lo scroll e l'angolo per il click secondario; se ne arrivano
 * due o piu' — perche' il descriptor e' stato dichiarato piu' lungo, o
 * perche' un giorno il dispositivo verra' configurato per emettere report
 * a lunghezza fissa — usa le gesture vere.
 */

/*
 * Orientamento degli assi, verificato sul dispositivo: dopo la decodifica
 * x cresce verso destra e **y cresce verso il basso**, cioe' verso il bordo
 * vicino a chi lo usa — la stessa convenzione dello schermo.
 *
 * E' il punto in cui e' facile sbagliare: il driver Linux nega la y proprio
 * per ottenere questo, e chi copia la formula senza accorgersene finisce per
 * invertire tutto il verticale, puntatore e scroll compresi, e per mettere
 * le zone di bordo sul lato opposto del pad.
 */

/* Ampiezza delle zone di bordo, in unita' del dispositivo. */
#define EDGE_RIGHT_X   (DEV_X_MAX - 620)
#define EDGE_BOTTOM_Y  (DEV_Y_MAX - 520)
/* Angolo per il click secondario: piu' piccolo della zona di scroll. */
#define CORNER_X       (DEV_X_MAX - 1200)
#define CORNER_Y       (DEV_Y_MAX - 900)

typedef enum {
    G_IDLE = 0,
    G_POINTER,      /* un dito: muove il puntatore                     */
    G_EDGE_V,       /* un dito sul bordo destro: scroll verticale      */
    G_EDGE_H,       /* un dito sul bordo inferiore: scroll orizzontale */
    G_SCROLL,       /* due dita: scroll vero                           */
    G_SWIPE3,       /* tre dita                                        */
} Gesture;

static const char *gesture_name(Gesture g) {
    switch (g) {
    case G_POINTER: return "puntatore";
    case G_EDGE_V:  return "scroll bordo destro";
    case G_EDGE_H:  return "scroll bordo inferiore";
    case G_SCROLL:  return "scroll due dita";
    case G_SWIPE3:  return "swipe tre dita";
    default:        return "-";
    }
}

static struct {
    Gesture gesture;
    int     button_down;        /* pulsante fisico premuto */
    int     right_click_armed;  /* il click e' partito come secondario */
    int     max_contacts;       /* massimo visto in questa gesture */
    int     swipe_fired;

    int     anchor_id;          /* contatto che guida la gesture */
    double  last_x, last_y;
    double  scroll_x, scroll_y; /* baricentro, per lo scroll a due dita */
    double  travel;             /* distanza percorsa, per il tap */
    double  swipe_dx, swipe_dy;

    CFAbsoluteTime touch_start;
} st;

static void gesture_reset(void) {
    if (st.gesture == G_SCROLL || st.gesture == G_EDGE_V || st.gesture == G_EDGE_H)
        post_scroll(0, 0, PHASE_ENDED);
    memset(&st, 0, sizeof st);
}

static Contact *find_contact(Contact *c, int n, int id) {
    for (int i = 0; i < n; i++)
        if (c[i].down && c[i].id == id) return &c[i];
    return NULL;
}

static int in_corner(const Contact *c) {
    return c->x > CORNER_X && c->y > CORNER_Y;   /* y cresce verso il basso */
}

/* Quale gesture inizia un contatto solo, in base a dove si appoggia. */
static Gesture zone_of(const Contact *c) {
    if (!opt.edge_scroll)           return G_POINTER;
    if (c->x > EDGE_RIGHT_X)        return G_EDGE_V;
    if (c->y > EDGE_BOTTOM_Y)       return G_EDGE_H;
    return G_POINTER;
}

static void handle_contacts(Contact *all, int n_all, int button) {
    Contact active[MAX_CONTACTS];
    int n = 0;
    for (int i = 0; i < n_all; i++)
        if (all[i].down) active[n++] = all[i];

    if (opt.verbose) {
        printf("dita=%d button=%d %-22s", n, button, gesture_name(st.gesture));
        for (int i = 0; i < n; i++)
            printf("  [id%d %+5d %+5d s%d p%d]",
                   active[i].id, active[i].x, active[i].y,
                   active[i].size, active[i].pressure);
        printf("\n");
        fflush(stdout);
    }

    /* ---- pulsante fisico ---- */
    if (button && !st.button_down) {
        st.button_down = 1;
        /* due dita appoggiate, oppure un dito nell'angolo in basso a
         * destra: in entrambi i casi e' un click secondario. */
        st.right_click_armed = (n >= 2) || (n == 1 && in_corner(&active[0]));
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
            if (st.max_contacts == 1 && st.gesture == G_POINTER)
                post_click(kCGMouseButtonLeft);
            else if (st.max_contacts == 2)
                post_click(kCGMouseButtonRight);
        }
        gesture_reset();
        return;
    }

    /* ---- inizio di una nuova gesture ---- */
    if (st.gesture == G_IDLE) {
        st.touch_start  = CFAbsoluteTimeGetCurrent();
        st.max_contacts = n;
        st.travel       = 0;
        cursor_sync();

        if (n == 1) {
            st.gesture   = zone_of(&active[0]);
            st.anchor_id = active[0].id;
            st.last_x    = active[0].x;
            st.last_y    = active[0].y;
            if (st.gesture != G_POINTER)
                post_scroll(0, 0, PHASE_BEGAN);
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
    int one_finger = (st.gesture == G_POINTER || st.gesture == G_EDGE_V ||
                      st.gesture == G_EDGE_H);
    if ((one_finger            && n != 1) ||
        (st.gesture == G_SCROLL && n != 2) ||
        (st.gesture == G_SWIPE3 && n < 3)) {
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
        /* unita' dispositivo -> punti schermo: stesso verso su entrambi
         * gli assi, perche' la y decodificata cresce gia' verso il basso */
        double dx = (c->x - st.last_x) * 0.115;
        double dy = (c->y - st.last_y) * 0.115;
        st.last_x = c->x;
        st.last_y = c->y;
        st.travel += fabs(dx) + fabs(dy);
        post_move(dx, dy, st.button_down);
        break;
    }
    case G_EDGE_V:
    case G_EDGE_H: {
        Contact *c = find_contact(active, n, st.anchor_id);
        if (!c) break;
        double d = (st.gesture == G_EDGE_V)
                 ? -(c->y - st.last_y) * 0.115    /* bordo destro: usa y */
                 :  (c->x - st.last_x) * 0.115;   /* bordo inferiore: usa x */
        st.last_x = c->x;
        st.last_y = c->y;
        st.travel += fabs(d);
        if (st.gesture == G_EDGE_V) post_scroll(0, d, PHASE_CHANGED);
        else                        post_scroll(-d, 0, PHASE_CHANGED);
        break;
    }
    case G_SCROLL: {
        double cx = (active[0].x + active[1].x) / 2.0;
        double cy = (active[0].y + active[1].y) / 2.0;
        double dx = -(cx - st.scroll_x) * 0.115;
        double dy = -(cy - st.scroll_y) * 0.115;
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
            else if (st.swipe_dy < -900) { post_key(KEY_UP,    kCGEventFlagMaskControl); st.swipe_fired = 1; }
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
    g_reports_seen++;
    handle_contacts(contacts, count, button);

    if (opt.diag) {
        static CFAbsoluteTime last = 0;
        static long r0 = 0, e0 = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - last >= 1.0) {
            int down = 0;
            for (int i = 0; i < count; i++) if (contacts[i].down) down++;
            printf("  report/s %-4ld  dita %d  %-22s  eventi/s %-4ld  "
                   "accessibilita' %s\n",
                   g_reports_seen - r0, down, gesture_name(st.gesture),
                   g_events_posted - e0,
                   AXIsProcessTrusted() ? "ok" : "MANCANTE");
            fflush(stdout);
            last = now; r0 = g_reports_seen; e0 = g_events_posted;
        }
    }
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
    /* Su alcune interfacce la feature non passa: si ritenta sull'output. */
    if (r != kIOReturnSuccess)
        r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput,
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
"  -v, --verbose          stampa i contatti decodificati\n"
"      --no-events        decodifica soltanto, non genera eventi\n"
"      --classic-scroll   direzione di scroll classica (non naturale)\n"
"      --no-tap           disabilita il tap-to-click\n"
"      --no-edge-scroll   disabilita lo scroll lungo i bordi\n"
"      --diag             riga di stato al secondo, per capire dove si\n"
"                         perde il segnale\n"
"      --pointer N        velocita' del puntatore (default 1.0)\n"
"      --scroll N         velocita' dello scroll  (default 1.0)\n"
"  -h, --help             questo messaggio\n"
"\n"
"Con un contatto solo — cioe' quando il descriptor dichiara 13 byte e i\n"
"report piu' lunghi arrivano troncati:\n"
"\n"
"  un dito                    puntatore\n"
"  dito sul bordo destro      scroll verticale\n"
"  dito sul bordo inferiore   scroll orizzontale\n"
"  click                      click primario\n"
"  click in basso a destra    click secondario\n"
"  tap                        click primario     (--no-tap per disattivare)\n"
"\n"
"Se arrivano piu' contatti — descriptor dichiarato piu' lungo — il bridge\n"
"se ne accorge da solo e passa alle gesture vere:\n"
"\n"
"  due dita                   scroll con inerzia\n"
"  click o tap con due dita   click secondario\n"
"  swipe a tre dita           cambio spazio / Mission Control\n"
"\n", prog);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-v") || !strcmp(a, "--verbose")) opt.verbose = 1;
        else if (!strcmp(a, "--no-events"))      opt.no_events = 1;
        else if (!strcmp(a, "--classic-scroll")) opt.natural_scroll = 0;
        else if (!strcmp(a, "--no-tap"))         opt.tap_to_click = 0;
        else if (!strcmp(a, "--no-edge-scroll"))  opt.edge_scroll = 0;
        else if (!strcmp(a, "--diag"))            opt.diag = 1;
        else if (!strcmp(a, "--pointer") && i + 1 < argc) opt.pointer_speed = atof(argv[++i]);
        else if (!strcmp(a, "--scroll")  && i + 1 < argc) opt.scroll_speed  = atof(argv[++i]);
        else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(argv[0]); return 0; }
        else { fprintf(stderr, "opzione sconosciuta: %s\n", a); usage(argv[0]); return 2; }
    }

    if (!opt.no_events && !AXIsProcessTrusted()) {
        /* Chiedere il permesso apre direttamente il pannello di sistema:
         * molto meglio che limitarsi ad avvisare, perche' senza questo
         * permesso gli eventi vengono generati e buttati via in silenzio. */
        const void *keys[] = { kAXTrustedCheckOptionPrompt };
        const void *vals[] = { kCFBooleanTrue };
        CFDictionaryRef o = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1,
                                &kCFTypeDictionaryKeyCallBacks,
                                &kCFTypeDictionaryValueCallBacks);
        AXIsProcessTrustedWithOptions(o);
        if (o) CFRelease(o);

        fprintf(stderr,
            "\n**********************************************************\n"
            "  MANCA IL PERMESSO DI ACCESSIBILITA'\n"
            "\n"
            "  Senza, il bridge legge il trackpad e decodifica tutto, ma\n"
            "  gli eventi che genera non vengono consegnati a nessuno:\n"
            "  il puntatore resta fermo e sembra che non funzioni niente.\n"
            "\n"
            "  Preferenze di Sistema -> Sicurezza e Privacy -> Privacy\n"
            "  -> Accessibilita': aggiungi il Terminale e spunta la casella.\n"
            "  Poi CHIUDI E RIAPRI il Terminale, e rilancia il bridge.\n"
            "**********************************************************\n\n");
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
