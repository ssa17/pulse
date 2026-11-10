#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

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
#define MAX_CPU_SENSORS 128

static void sample_and_print(IOHIDServiceClientRef *cpuServices, int cpuCount) {
    double sum = 0.0;
    double maxTemp = 0.0;
    int matched = 0;

    for (int i = 0; i < cpuCount; i++) {
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(cpuServices[i], kIOHIDEventTypeTemperature, 0, 0);
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

    if (matched > 0) {
        double avg = sum / matched;
        printf("{\"cpu\":%.1f,\"max\":%.1f}\n", avg, maxTemp);
    } else {
        printf("{}\n");
    }
    fflush(stdout);
}

int main(int argc, char *argv[]) {
    int watchMs = 0;
    if (argc >= 2 && strcmp(argv[1], "--watch") == 0) {
        watchMs = (argc >= 3) ? atoi(argv[2]) : 2500;
        if (watchMs < 500) watchMs = 500;
    }

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) {
        printf("{}\n");
        fflush(stdout);
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
        fflush(stdout);
        CFRelease(matching);
        CFRelease(pageNum);
        CFRelease(usageNum);
        CFRelease(client);
        return 0;
    }

    CFIndex count = CFArrayGetCount(services);
    IOHIDServiceClientRef cpuServices[MAX_CPU_SENSORS];
    int cpuCount = 0;

    for (CFIndex i = 0; i < count && cpuCount < MAX_CPU_SENSORS; i++) {
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
            cpuServices[cpuCount++] = service;
        }
    }

    if (!watchMs) {
        sample_and_print(cpuServices, cpuCount);
    } else {
        struct pollfd pfd;
        pfd.fd = STDIN_FILENO;
        pfd.events = POLLIN;
        for (;;) {
            sample_and_print(cpuServices, cpuCount);
            int r = poll(&pfd, 1, watchMs);
            if (r > 0) {
                char buf[16];
                if (read(STDIN_FILENO, buf, sizeof(buf)) <= 0) break;
            } else if (r < 0) {
                break;
            }
        }
    }

    CFRelease(services);
    CFRelease(matching);
    CFRelease(pageNum);
    CFRelease(usageNum);
    CFRelease(client);
    return 0;
}
