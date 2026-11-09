#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <stdio.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t param);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);

#define IOHIDEventFieldBase(type) ((type) << 16)
#define kIOHIDEventTypeTemperature 15

int main(int argc, char *argv[]) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) {
        printf("{}\n");
        return 0;
    }

    int page = 0xff00;
    int usage = 5;
    CFNumberRef pageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);

    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { pageNum, usageNum };
    CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                  &kCFTypeDictionaryKeyCallBacks,
                                                  &kCFTypeDictionaryValueCallBacks);

    IOHIDEventSystemClientSetMatching(client, matching);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) {
        printf("{}\n");
        CFRelease(matching);
        CFRelease(pageNum);
        CFRelease(usageNum);
        CFRelease(client);
        return 0;
    }

    CFIndex count = CFArrayGetCount(services);
    double sum = 0.0;
    double maxTemp = 0.0;
    int matched = 0;

    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFStringRef product = (CFStringRef)IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (!product) continue;

        char name[128] = {0};
        CFStringGetCString(product, name, sizeof(name), kCFStringEncodingUTF8);
        CFRelease(product);

        // Filter for CPU / SoC die sensors:
        // Match "tdie", "pACC", "eACC" but exclude "tcal" (calibration/test offset)
        if ((strstr(name, "tdie") || strstr(name, "pACC") || strstr(name, "eACC")) &&
            !strstr(name, "tcal")) {
            IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
            if (event) {
                double temp = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
                if (temp > 0.0 && temp < 150.0) {
                    sum += temp;
                    if (temp > maxTemp) maxTemp = temp;
                    matched++;
                }
                CFRelease(event);
            }
        }
    }

    if (matched > 0) {
        double avg = sum / matched;
        printf("{\"cpu\":%.1f,\"max\":%.1f}\n", avg, maxTemp);
    } else {
        printf("{}\n");
    }

    CFRelease(services);
    CFRelease(matching);
    CFRelease(pageNum);
    CFRelease(usageNum);
    CFRelease(client);
    return 0;
}
