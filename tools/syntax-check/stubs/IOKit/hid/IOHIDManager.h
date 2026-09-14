#ifndef STUB_IOHIDMANAGER_H
#define STUB_IOHIDMANAGER_H
#include <CoreFoundation/CoreFoundation.h>

typedef int IOReturn;
typedef struct __IOHIDManager *IOHIDManagerRef;
typedef struct __IOHIDDevice  *IOHIDDeviceRef;
typedef enum { kIOHIDReportTypeInput, kIOHIDReportTypeOutput,
               kIOHIDReportTypeFeature } IOHIDReportType;
typedef uint32_t IOOptionBits;

#define kIOHIDOptionsTypeNone        0x00
#define kIOHIDOptionsTypeSeizeDevice 0x01

#define kIOReturnSuccess        0
#define kIOReturnNoDevice       0xE00002C0
#define kIOReturnNotPermitted   0xE00002E2
#define kIOReturnBadArgument    0xE00002C2
#define kIOReturnUnsupported    0xE00002C7
#define kIOReturnNotOpen        0xE00002CD
#define kIOReturnExclusiveAccess 0xE00002C5
#define kIOReturnTimeout        0xE00002D6
#define kIOReturnAborted        0xE00002EB

#define kIOHIDVendorIDKey            "VendorID"
#define kIOHIDProductIDKey           "ProductID"
#define kIOHIDProductKey             "Product"
#define kIOHIDTransportKey           "Transport"
#define kIOHIDPrimaryUsageKey        "PrimaryUsage"
#define kIOHIDPrimaryUsagePageKey    "PrimaryUsagePage"
#define kIOHIDMaxInputReportSizeKey  "MaxInputReportSize"
#define kIOHIDMaxOutputReportSizeKey "MaxOutputReportSize"
#define kIOHIDMaxFeatureReportSizeKey "MaxFeatureReportSize"
#define kIOHIDReportDescriptorKey    "ReportDescriptor"

typedef void (*IOHIDDeviceCallback)(void *, IOReturn, void *, IOHIDDeviceRef);
typedef void (*IOHIDReportCallback)(void *, IOReturn, void *, IOHIDReportType,
                                    uint32_t, uint8_t *, CFIndex);

IOHIDManagerRef IOHIDManagerCreate(CFAllocatorRef, IOOptionBits);
void IOHIDManagerSetDeviceMatching(IOHIDManagerRef, CFMutableDictionaryRef);
void IOHIDManagerRegisterDeviceMatchingCallback(IOHIDManagerRef, IOHIDDeviceCallback, void *);
void IOHIDManagerRegisterDeviceRemovalCallback(IOHIDManagerRef, IOHIDDeviceCallback, void *);
void IOHIDManagerScheduleWithRunLoop(IOHIDManagerRef, CFRunLoopRef, CFStringRef);
IOReturn IOHIDManagerOpen(IOHIDManagerRef, IOOptionBits);
IOReturn IOHIDDeviceOpen(IOHIDDeviceRef, IOOptionBits);
CFTypeRef IOHIDDeviceGetProperty(IOHIDDeviceRef, CFStringRef);
IOReturn IOHIDDeviceSetReport(IOHIDDeviceRef, IOHIDReportType, CFIndex,
                              const uint8_t *, CFIndex);
void IOHIDDeviceRegisterInputReportCallback(IOHIDDeviceRef, uint8_t *, CFIndex,
                                            IOHIDReportCallback, void *);
#endif
