/*
 * mt_desc_dump — dump del report descriptor HID di un dispositivo.
 *
 * Da eseguire sul Mac MODERNO dove la Magic Trackpad USB-C funziona
 * nativamente: serve a catturare il descriptor vero, quello che poi
 * inietteremo nella cache SDP di Catalina con sdp_patch.py.
 *
 *   clang -framework IOKit -framework CoreFoundation -o mt_desc_dump mt_desc_dump.c
 *   ./mt_desc_dump                 # solo la Magic Trackpad USB-C
 *   ./mt_desc_dump --all           # tutti gli HID (per capire cosa c'e')
 *   ./mt_desc_dump --hex > desc.txt
 *
 * Serve il permesso "Monitoraggio Input" per il Terminale.
 */
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

#define MT_VENDOR_ID  0x004C
#define MT_PRODUCT_ID 0x0324

static int g_all = 0, g_hex_only = 0;

static long int_prop(IOHIDDeviceRef d, CFStringRef key) {
    CFTypeRef v = IOHIDDeviceGetProperty(d, key);
    long out = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberLongType, &out);
    return out;
}

static void str_prop(IOHIDDeviceRef d, CFStringRef key, char *buf, size_t n) {
    CFTypeRef v = IOHIDDeviceGetProperty(d, key);
    buf[0] = '\0';
    if (v && CFGetTypeID(v) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)v, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

static void dump_device(IOHIDDeviceRef dev) {
    long vid = int_prop(dev, CFSTR(kIOHIDVendorIDKey));
    long pid = int_prop(dev, CFSTR(kIOHIDProductIDKey));

    if (!g_all && !(vid == MT_VENDOR_ID && pid == MT_PRODUCT_ID)) return;

    char product[256], transport[64];
    str_prop(dev, CFSTR(kIOHIDProductKey), product, sizeof product);
    str_prop(dev, CFSTR(kIOHIDTransportKey), transport, sizeof transport);

    CFTypeRef rd = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDReportDescriptorKey));

    if (!g_hex_only) {
        printf("\n--- %s ---\n", product[0] ? product : "(senza nome)");
        printf("  VendorID            0x%04lX\n", vid);
        printf("  ProductID           0x%04lX\n", pid);
        printf("  Transport           %s\n", transport);
        printf("  MaxInputReportSize  %ld\n",
               int_prop(dev, CFSTR(kIOHIDMaxInputReportSizeKey)));
        printf("  MaxFeatureReportSize %ld\n",
               int_prop(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey)));
    }

    if (!rd || CFGetTypeID(rd) != CFDataGetTypeID()) {
        if (!g_hex_only)
            printf("  ReportDescriptor    NON DISPONIBILE\n");
        return;
    }

    CFDataRef data = (CFDataRef)rd;
    const UInt8 *p = CFDataGetBytePtr(data);
    CFIndex len = CFDataGetLength(data);

    if (!g_hex_only) printf("  ReportDescriptor    %ld byte\n\n", (long)len);

    for (CFIndex i = 0; i < len; i++) {
        printf("%02X", p[i]);
        if ((i % 16) == 15) printf("\n");
        else if (i + 1 < len) printf(" ");
    }
    if (len % 16) printf("\n");
}

static void on_match(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;
    dump_device(dev);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--all"))  g_all = 1;
        if (!strcmp(argv[i], "--hex"))  g_hex_only = 1;
    }

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                             kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(mgr, NULL);   /* tutti, filtriamo noi */
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, on_match, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(),
                                    kCFRunLoopDefaultMode);

    IOReturn ok = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (ok != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDManagerOpen: 0x%08X "
                        "(manca il permesso Monitoraggio Input?)\n", ok);
        return 1;
    }

    /* Un giro di run loop basta: i device gia' presenti arrivano subito. */
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);

    if (!g_hex_only) printf("\n");
    return 0;
}
