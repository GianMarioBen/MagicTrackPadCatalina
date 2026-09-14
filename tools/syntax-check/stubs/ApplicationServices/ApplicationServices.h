#ifndef STUB_APPLICATIONSERVICES_H
#define STUB_APPLICATIONSERVICES_H
#include <CoreFoundation/CoreFoundation.h>

typedef struct { double x, y; } CGPoint;
typedef struct { double width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
typedef struct __CGEvent       *CGEventRef;
typedef struct __CGEventSource *CGEventSourceRef;
typedef uint32_t CGDirectDisplayID;
typedef uint16_t CGKeyCode;
typedef uint64_t CGEventFlags;
typedef int CGError;
typedef enum { kCGMouseButtonLeft, kCGMouseButtonRight, kCGMouseButtonCenter } CGMouseButton;
typedef enum { kCGScrollEventUnitPixel, kCGScrollEventUnitLine } CGScrollEventUnit;
typedef enum {
    kCGEventMouseMoved = 5, kCGEventLeftMouseDown = 1, kCGEventLeftMouseUp = 2,
    kCGEventRightMouseDown = 3, kCGEventRightMouseUp = 4,
    kCGEventLeftMouseDragged = 6
} CGEventType;
typedef enum {
    kCGMouseEventDeltaX = 4, kCGMouseEventDeltaY = 5,
    kCGScrollWheelEventIsContinuous = 88,
    kCGScrollWheelEventScrollPhase = 99,
    kCGScrollWheelEventMomentumPhase = 123
} CGEventField;

#define kCGHIDEventTap ((void *)0)
#define kCGEventFlagMaskControl 0x040000
#define kCGErrorSuccess 0

CGRect CGRectMake(double, double, double, double);
CGRect CGRectUnion(CGRect, CGRect);
double CGRectGetMinX(CGRect); double CGRectGetMinY(CGRect);
double CGRectGetMaxX(CGRect); double CGRectGetMaxY(CGRect);
CGRect CGDisplayBounds(CGDirectDisplayID);
CGError CGGetActiveDisplayList(uint32_t, CGDirectDisplayID *, uint32_t *);
CGEventRef CGEventCreate(CGEventSourceRef);
CGPoint CGEventGetLocation(CGEventRef);
CGEventRef CGEventCreateMouseEvent(CGEventSourceRef, CGEventType, CGPoint, CGMouseButton);
CGEventRef CGEventCreateScrollWheelEvent2(CGEventSourceRef, CGScrollEventUnit,
                                          uint32_t, int32_t, int32_t, int32_t);
CGEventRef CGEventCreateKeyboardEvent(CGEventSourceRef, CGKeyCode, Boolean);
void CGEventSetDoubleValueField(CGEventRef, CGEventField, double);
void CGEventSetIntegerValueField(CGEventRef, CGEventField, int64_t);
void CGEventSetFlags(CGEventRef, CGEventFlags);
void CGEventPost(void *, CGEventRef);
Boolean AXIsProcessTrusted(void);
#endif
