#include "Telemetry.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <string.h>
#include <time.h>

extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef,
                                                          CFStringRef, uint64_t,
                                                          uint64_t, uint64_t);
extern void IOReportMergeChannels(CFMutableDictionaryRef, CFDictionaryRef,
                                  CFTypeRef);
extern CFTypeRef IOReportCreateSubscription(void *, CFMutableDictionaryRef,
                                            CFMutableDictionaryRef *, uint64_t,
                                            CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(CFTypeRef, CFMutableDictionaryRef,
                                             CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef,
                                                  CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int);
extern int IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int);

typedef struct {
  double ghz[64];
  int count;
} Table;
static CFMutableDictionaryRef channels;
static CFTypeRef sub;
static CFDictionaryRef last;
static double stamp;
static bool initialized;
static Table tables[3];
static bool eq(CFStringRef a, CFStringRef b) { return a && CFEqual(a, b); }
static void frequencies(void) {
  io_iterator_t it;
  if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                   IOServiceMatching("AppleARMIODevice"),
                                   &it) != KERN_SUCCESS)
    return;
  io_object_t dev;
  while ((dev = IOIteratorNext(it))) {
    io_name_t name;
    if (IORegistryEntryGetName(dev, name) == KERN_SUCCESS &&
        !strcmp(name, "pmgr")) {
      CFStringRef keys[] = {CFSTR("voltage-states5-sram"),
                            CFSTR("voltage-states1-sram"),
                            CFSTR("voltage-states9")};
      for (int j = 0; j < 3; j++) {
        CFDataRef data = IORegistryEntryCreateCFProperty(
            dev, keys[j], kCFAllocatorDefault, 0);
        if (!data)
          continue;
        if (CFGetTypeID(data) == CFDataGetTypeID()) {
          int len = (int)CFDataGetLength(data);
          const UInt8 *p = CFDataGetBytePtr(data);
          for (int k = 0; k + 8 <= len && tables[j].count < 64; k += 8) {
            uint32_t raw;
            memcpy(&raw, p + k, 4);
            // M4 CPU tables are in kHz; GPU tables in Hz. Ignore off states.
            double ghz = raw >= 100000000 ? raw / 1e9 : raw / 1e6;
            if (ghz >= 0.1 && ghz <= 8)
              tables[j].ghz[tables[j].count++] = ghz;
          }
        }
        CFRelease(data);
      }
      IOObjectRelease(dev);
      break;
    }
    IOObjectRelease(dev);
  }
  IOObjectRelease(it);
}
static void setup(void) {
  frequencies();
  CFStringRef groups[] = {CFSTR("Energy Model"), CFSTR("CPU Stats"),
                          CFSTR("GPU Stats")};
  for (int i = 0; i < 3; i++) {
    CFMutableDictionaryRef group =
        IOReportCopyChannelsInGroup(groups[i], NULL, 0, 0, 0);
    if (!group)
      continue;
    if (!channels)
      channels = CFDictionaryCreateMutableCopy(NULL, 0, group);
    else
      IOReportMergeChannels(channels, group, NULL);
    CFRelease(group);
  }
  if (channels) {
    CFMutableDictionaryRef subscribed = NULL;
    sub = IOReportCreateSubscription(NULL, channels, &subscribed, 0, NULL);
    if (subscribed)
      CFRelease(subscribed);
  }
}
void sb_energy(SBSensors *s) {
  if (!initialized) {
    initialized = true;
    setup();
  }
  if (!sub)
    return;
  CFDictionaryRef next = IOReportCreateSamples(sub, channels, NULL);
  if (!next)
    return;
  double now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9, dt = now - stamp;
  CFDictionaryRef delta =
      last ? IOReportCreateSamplesDelta(last, next, NULL) : NULL;
  if (last)
    CFRelease(last);
  last = next;
  stamp = now;
  if (!delta)
    return;
  CFArrayRef items = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
  double sum[3] = {0}, weights[3] = {0};
  for (CFIndex i = 0; items && dt > 0 && i < CFArrayGetCount(items); i++) {
    CFDictionaryRef c = CFArrayGetValueAtIndex(items, i);
    CFStringRef name = IOReportChannelGetChannelName(c),
                group = IOReportChannelGetSubGroup(c);
    if (!name)
      continue;
    bool cpu = eq(name, CFSTR("CPU Energy")),
         gpu = eq(name, CFSTR("GPU Energy"));
    if (cpu || gpu) {
      CFStringRef u = IOReportChannelGetUnitLabel(c);
      double scale = eq(u, CFSTR("mJ"))   ? 1e-3
                     : eq(u, CFSTR("uJ")) ? 1e-6
                     : eq(u, CFSTR("nJ")) ? 1e-9
                     : eq(u, CFSTR("J"))  ? 1
                                          : NAN;
      double watts = IOReportSimpleGetIntegerValue(c, 0) * scale / dt;
      if (watts >= 0) {
        if (cpu)
          s->cpuWatts = watts;
        else
          s->gpuWatts = watts;
      }
    }
    int j = -1;
    if (eq(group, CFSTR("CPU Core Performance States"))) {
      if (CFStringFind(name, CFSTR("PCPU"), 0).location != kCFNotFound)
        j = 0;
      else if (CFStringFind(name, CFSTR("ECPU"), 0).location != kCFNotFound)
        j = 1;
    } else if (eq(name, CFSTR("GPUPH")) &&
               eq(group, CFSTR("GPU Performance States")))
      j = 2;
    if (j < 0 || !tables[j].count)
      continue;
    int n = IOReportStateGetCount(c), active = 0;
    double use = 0, weighted = 0;
    for (int k = 0; k < n; k++) {
      CFStringRef state = IOReportStateGetNameForIndex(c, k);
      if (!state || eq(state, CFSTR("IDLE")) || eq(state, CFSTR("OFF")) ||
          eq(state, CFSTR("DOWN")))
        continue;
      if (active >= tables[j].count) {
        active++;
        break;
      }
      int64_t t = IOReportStateGetResidency(c, k);
      if (t > 0) {
        use += t;
        weighted += tables[j].ghz[active] * t;
      }
      active++;
    }
    if (active == tables[j].count && use > 0) {
      sum[j] += weighted;
      weights[j] += use;
    }
  }
  double *out[] = {&s->pGHz, &s->eGHz, &s->gpuGHz};
  for (int j = 0; j < 3; j++)
    if (weights[j] > 0)
      *out[j] = sum[j] / weights[j];
  CFRelease(delta);
}
