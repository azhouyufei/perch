#pragma once
#include <stdint.h>
typedef struct {
    double cpu, memoryUsed, memoryTotal, diskFree, diskTotal;
    double received, sent, diskRead, diskWrite;
    double swapUsed;
    int pressure, battery, charging, cores;
    double coreUsage[128];
} SBMetrics;
SBMetrics sb_sample(void);
double sb_core(SBMetrics sample, int index);
typedef struct {
    double pTemp, eTemp, gpuTemp, gpuLoad, batteryTemp, systemWatts, voltage;
    double fan0, fan1, max0, max1, min0, min1, ssd;
    double cpuWatts, gpuWatts, pGHz, eGHz, gpuGHz;
    double thunderLeft, thunderRight, wifi, display, airflow;
} SBSensors;
SBSensors sb_sensors(void);
void sb_energy(SBSensors *sample);
