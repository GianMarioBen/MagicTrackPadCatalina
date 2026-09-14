/* Stub minimale: serve solo a far analizzare i sorgenti macOS a un
 * compilatore Linux, per intercettare errori di sintassi e identificatori
 * non dichiarati. Non produce un binario funzionante. */
#ifndef STUB_COREFOUNDATION_H
#define STUB_COREFOUNDATION_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>   /* i veri header CoreFoundation lo tirano dentro */

typedef unsigned char   UInt8;
typedef unsigned char   Boolean;
typedef long            CFIndex;
typedef double          CFAbsoluteTime;
typedef double          CFTimeInterval;
typedef unsigned long   CFTypeID;
typedef const void     *CFTypeRef;
typedef const struct __CFString     *CFStringRef;
typedef const struct __CFData       *CFDataRef;
typedef const struct __CFNumber     *CFNumberRef;
typedef const struct __CFAllocator  *CFAllocatorRef;
typedef struct __CFDictionary       *CFMutableDictionaryRef;
typedef struct __CFRunLoop          *CFRunLoopRef;
typedef const struct __CFDictionary  *CFDictionaryRef;
typedef const struct __CFBoolean     *CFBooleanRef;

typedef struct { CFIndex location, length; } CFRange;
typedef struct { CFIndex version; void *retain, *release, *copyDescription, *equal, *hash; } CFDictionaryKeyCallBacks;
typedef struct { CFIndex version; void *retain, *release, *copyDescription, *equal; } CFDictionaryValueCallBacks;

typedef enum { kCFNumberIntType = 9, kCFNumberLongType = 10 } CFNumberType;
typedef enum { kCFCompareCaseInsensitive = 1 } CFStringCompareFlags;
typedef enum { kCFStringEncodingUTF8 = 0x08000100 } CFStringEncoding;

#define CFSTR(s) ((CFStringRef)(s))
#define kCFNotFound ((CFIndex)-1)

extern const CFAllocatorRef kCFAllocatorDefault;
extern const CFStringRef    kCFRunLoopDefaultMode;
extern const CFDictionaryKeyCallBacks   kCFTypeDictionaryKeyCallBacks;
extern const CFDictionaryValueCallBacks kCFTypeDictionaryValueCallBacks;

CFTypeID CFGetTypeID(CFTypeRef);
CFTypeID CFNumberGetTypeID(void);
CFTypeID CFStringGetTypeID(void);
CFTypeID CFDataGetTypeID(void);
Boolean  CFNumberGetValue(CFNumberRef, CFNumberType, void *);
CFNumberRef CFNumberCreate(CFAllocatorRef, CFNumberType, const void *);
CFRange  CFStringFind(CFStringRef, CFStringRef, CFStringCompareFlags);
Boolean  CFStringGetCString(CFStringRef, char *, CFIndex, CFStringEncoding);
const UInt8 *CFDataGetBytePtr(CFDataRef);
CFIndex  CFDataGetLength(CFDataRef);
CFMutableDictionaryRef CFDictionaryCreateMutable(CFAllocatorRef, CFIndex,
    const CFDictionaryKeyCallBacks *, const CFDictionaryValueCallBacks *);
void CFDictionarySetValue(CFMutableDictionaryRef, const void *, const void *);
void CFRelease(CFTypeRef);
extern const CFBooleanRef kCFBooleanTrue;
CFDictionaryRef CFDictionaryCreate(CFAllocatorRef, const void **, const void **,
    CFIndex, const CFDictionaryKeyCallBacks *, const CFDictionaryValueCallBacks *);
CFRunLoopRef CFRunLoopGetCurrent(void);
void CFRunLoopRun(void);
int  CFRunLoopRunInMode(CFStringRef, CFTimeInterval, Boolean);
CFAbsoluteTime CFAbsoluteTimeGetCurrent(void);
#endif
