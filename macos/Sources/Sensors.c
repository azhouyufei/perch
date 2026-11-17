#include "Telemetry.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <string.h>
#include <sys/sysctl.h>

// AppleSMC user client ABI. Only key metadata and read commands are issued.
typedef struct {
  uint8_t major, minor, build, reserved;
  uint16_t release;
} SMCVersion;
typedef struct {
  uint16_t version, length;
  uint32_t cpu, gpu, memory;
} SMCLimits;
typedef struct {
  uint32_t size, type;
  uint8_t attributes;
} SMCKeyInfo;
typedef struct {
  uint32_t key;
  SMCVersion version;
  SMCLimits limits;
  SMCKeyInfo info;
  uint8_t result, status, command;
  uint32_t index;
  uint8_t bytes[32];
} SMCRequest;
_Static_assert(sizeof(SMCRequest) == 80, "Unexpected SMC request layout");
static uint32_t fourcc(const char *str) {
  return (uint32_t)str[0] << 24 | (uint32_t)str[1] << 16 |
         (uint32_t)str[2] << 8 | (uint32_t)str[3];
}
static double readKey(io_connect_t port, const char *name) {
  SMCRequest in = {0}, out = {0};
  in.key = fourcc(name);
  in.command = 9;
  size_t len = sizeof(out);
  if (IOConnectCallStructMethod(port, 2, &in, sizeof(in), &out, &len) !=
          KERN_SUCCESS ||
      out.result || !out.info.size || out.info.size > 32)
    return NAN;
  in.info = out.info;
  in.command = 5;
  len = sizeof(out);
  if (IOConnectCallStructMethod(port, 2, &in, sizeof(in), &out, &len) !=
          KERN_SUCCESS ||
      out.result)
    return NAN;
  const uint8_t *b = out.bytes;
  if (in.info.type == fourcc("flt ") && in.info.size == 4) {
    float f;
    memcpy(&f, b, 4);
    return f;
  }
  const uint16_t word = (uint16_t)b[0] << 8 | b[1];
  if (in.info.type == fourcc("fpe2"))
    return word / 4.0;
  if (in.info.type == fourcc("sp78"))
    return (int16_t)word / 256.0;
  if (in.info.type == fourcc("ui16"))
    return word;
  if (in.info.type == fourcc("ui8 "))
    return b[0];
  return NAN;
}
static double averageTemps(io_connect_t port, const char *const keys[],
                           int count) {
  double sum = 0;
  int n = 0;
  for (int i = 0; i < count; i++) {
    double v = readKey(port, keys[i]);
    if (v > 0 && v < 130) {
      sum += v;
      n++;
    }
  }
  return n ? sum / n : NAN;
}
static double property(CFDictionaryRef dict, CFStringRef key) {
  CFNumberRef n = dict ? CFDictionaryGetValue(dict, key) : NULL;
  double x;
  return n && CFGetTypeID(n) == CFNumberGetTypeID() &&
                 CFNumberGetValue(n, kCFNumberDoubleType, &x)
             ? x
             : NAN;
}
static CFDictionaryRef deviceProperties(const char *device, CFStringRef key) {
  io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                     IOServiceMatching(device));
  if (!service)
    return NULL;
  CFDictionaryRef d = NULL;
  if (key)
    d = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
  else
    IORegistryEntryCreateCFProperties(service, (CFMutableDictionaryRef *)&d,
                                      kCFAllocatorDefault, 0);
  IOObjectRelease(service);
  if (d && CFGetTypeID(d) != CFDictionaryGetTypeID()) {
    CFRelease(d);
    return NULL;
  }
  return d;
}
SBSensors sb_sensors(void) {
  SBSensors s = {.pTemp = NAN,
                 .eTemp = NAN,
                 .gpuTemp = NAN,
                 .gpuLoad = NAN,
                 .batteryTemp = NAN,
                 .systemWatts = NAN,
                 .voltage = NAN,
                 .fan0 = NAN,
                 .fan1 = NAN,
                 .max0 = NAN,
                 .max1 = NAN,
                 .min0 = NAN,
                 .min1 = NAN,
                 .ssd = NAN,
                 .cpuWatts = NAN,
                 .gpuWatts = NAN,
                 .pGHz = NAN,
                 .eGHz = NAN,
                 .gpuGHz = NAN,
                 .thunderLeft = NAN,
                 .thunderRight = NAN,
                 .wifi = NAN,
                 .display = NAN,
                 .airflow = NAN};
  sb_energy(&s);
  CFDictionaryRef gpu =
      deviceProperties("AGXAccelerator", CFSTR("PerformanceStatistics"));
  if (gpu) {
    s.gpuLoad = property(gpu, CFSTR("Device Utilization %"));
    CFRelease(gpu);
  }
  CFDictionaryRef battery = deviceProperties("AppleSmartBattery", NULL);
  if (battery) {
    s.voltage = property(battery, CFSTR("Voltage")) / 1000.0;
    s.batteryTemp = property(battery, CFSTR("Temperature")) / 100.0;
    CFDictionaryRef power =
        CFDictionaryGetValue(battery, CFSTR("PowerTelemetryData"));
    if (power && CFGetTypeID(power) == CFDictionaryGetTypeID())
      s.systemWatts = property(power, CFSTR("SystemPowerIn")) / 1000.0;
    CFRelease(battery);
  }
  io_service_t service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("AppleSMC"));
  io_connect_t port = 0;
  if (!service)
    return s;
  kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &port);
  IOObjectRelease(service);
  if (result != KERN_SUCCESS)
    return s;
  char brand[128] = {0};
  size_t size = sizeof(brand);
  if (sysctlbyname("machdep.cpu.brand_string", brand, &size, NULL, 0) == 0 &&
      strstr(brand, "M4")) {
    const char *p[] = {"Tp01", "Tp05", "Tp09", "Tp0D",
                       "Tp0V", "Tp0Y", "Tp0b", "Tp0e"};
    const char *e[] = {"Te05", "Te09", "Te0H", "Te0S"};
    const char *g[] = {"Tg0f", "Tg0j", "Tg0b", "Tg0T", "Tg0L",
                       "Tg05", "Tg09", "Tg0D", "Tg0H"};
    s.pTemp = averageTemps(port, p, sizeof(p) / sizeof(*p));
    s.eTemp = averageTemps(port, e, sizeof(e) / sizeof(*e));
    s.gpuTemp = averageTemps(port, g, sizeof(g) / sizeof(*g));
  }
  double power = readKey(port, "PSTR");
  if (isfinite(power) && power > 0)
    s.systemWatts = power;
  s.fan0 = readKey(port, "F0Ac");
  s.fan1 = readKey(port, "F1Ac");
  s.max0 = readKey(port, "F0Mx");
  s.max1 = readKey(port, "F1Mx");
  s.min0 = readKey(port, "F0Mn");
  s.min1 = readKey(port, "F1Mn");
  s.ssd = readKey(port, "TH0x");
  s.thunderLeft = readKey(port, "TTLD");
  s.thunderRight = readKey(port, "TTRD");
  s.wifi = readKey(port, "TW0P");
  s.display = readKey(port, "TL0P");
  const char *air[] = {"TaLP", "TaRF"};
  s.airflow = averageTemps(port, air, 2);
  IOServiceClose(port);
  return s;
}
