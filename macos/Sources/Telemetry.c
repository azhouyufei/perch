#include "Telemetry.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <mach/mach.h>
#include <net/if.h>
#include <net/if_types.h>
#include <net/route.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <sys/socket.h>
#include <stdlib.h>
#include <string.h>

static double number(CFDictionaryRef d, CFStringRef k, double fallback) {
    CFNumberRef n = CFDictionaryGetValue(d, k);
    double value;
    return n && CFGetTypeID(n)==CFNumberGetTypeID() && CFNumberGetValue(n,kCFNumberDoubleType,&value) ? value : fallback;
}
static void cpu(SBMetrics *s, host_t host) {
    static natural_t last[128][CPU_STATE_MAX];
    static natural_t lastCount;
    natural_t count;
    processor_info_array_t data;
    mach_msg_type_number_t length;
    if (host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &data, &length)!=KERN_SUCCESS) return;
    processor_cpu_load_info_t ticks=(processor_cpu_load_info_t)data;
    s->cores = count>128 ? 128 : count;
    double total=0, idle=0;
    for (int i=0; i<s->cores; i++) {
        double unit=0, rest=0;
        for(int j=0;j<CPU_STATE_MAX;j++) {
            natural_t current=ticks[i].cpu_ticks[j];
            natural_t delta=current-last[i][j];
            last[i][j]=current;
            unit+=delta;
            if (j==CPU_STATE_IDLE) rest=delta;
        }
        s->coreUsage[i]=lastCount==count && unit>0 ? 100*(unit-rest)/unit : -1;
        total+=unit; idle+=rest;
    }
    if(lastCount==count && total>0) s->cpu=100*(total-idle)/total;
    lastCount=count;
    vm_deallocate(mach_task_self(), (vm_address_t)data,length*sizeof(integer_t));
}
double sb_core(SBMetrics s,int i) { return i>=0 && i<s.cores ? s.coreUsage[i] : -1; }

static void network(SBMetrics *s) {
    int mib[]={CTL_NET,PF_ROUTE,0,0,NET_RT_IFLIST2,0};
    size_t len=0;
    if(sysctl(mib,6,NULL,&len,NULL,0) || !len) return;
    char *buf=malloc(len);
    if (!buf) return;
    if (!sysctl(mib,6,buf,&len,NULL,0)) {
        double rx=0, tx=0;
        for(size_t pos=0;pos+sizeof(struct if_msghdr)<=len;) {
            struct if_msghdr *h=(void *)(buf+pos);
            if(!h->ifm_msglen || pos+h->ifm_msglen>len) break;
            if(h->ifm_type==RTM_IFINFO2 && h->ifm_msglen>=sizeof(struct if_msghdr2)) {
                struct if_msghdr2 *m=(void *)h;
                // Count hardware Ethernet/Wi-Fi links once, excluding loopback and VPNs.
                if(m->ifm_data.ifi_type==IFT_ETHER && !(m->ifm_flags & IFF_LOOPBACK)) {
                    rx+=m->ifm_data.ifi_ibytes; tx+=m->ifm_data.ifi_obytes;
                }
            }
            pos+=h->ifm_msglen;
        }
        s->received=rx; s->sent=tx;
    }
    free(buf);
}
static void diskIO(SBMetrics *s) {
    io_iterator_t it;
    if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOBlockStorageDriver"),&it)!=KERN_SUCCESS) return;
    double read=0, written=0;
    int valid=0;
    io_object_t obj;
    while((obj=IOIteratorNext(it))) {
        CFDictionaryRef d=IORegistryEntryCreateCFProperty(obj,CFSTR(kIOBlockStorageDriverStatisticsKey),kCFAllocatorDefault,0);
        if(d && CFGetTypeID(d)==CFDictionaryGetTypeID()) {
            double r=number(d,CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey),-1);
            double w=number(d,CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey),-1);
            if(r>=0 && w>=0) { valid=1; read+=r; written+=w; }
        }
        if(d) CFRelease(d);
        IOObjectRelease(obj);
    }
    IOObjectRelease(it);
    if(valid) { s->diskRead=read; s->diskWrite=written; }
}
static void battery(SBMetrics *s) {
    CFTypeRef info=IOPSCopyPowerSourcesInfo();
    if(!info) return;
    CFArrayRef sources=IOPSCopyPowerSourcesList(info);
    for(CFIndex i=0;sources && i<CFArrayGetCount(sources);i++) {
        CFDictionaryRef d=IOPSGetPowerSourceDescription(info,CFArrayGetValueAtIndex(sources,i));
        if(!d) continue;
        CFStringRef type=CFDictionaryGetValue(d,CFSTR("Type"));
        if(!type || !CFEqual(type,CFSTR("InternalBattery"))) continue;
        double max=number(d,CFSTR("Max Capacity"),-1), current=number(d,CFSTR("Current Capacity"),-1);
        if(max>0 && current>=0) s->battery=(int)(100*current/max+.5);
        CFStringRef state=CFDictionaryGetValue(d,CFSTR("Power Source State"));
        s->charging=state && CFEqual(state,CFSTR("AC Power"));
        break;
    }
    if(sources) CFRelease(sources);
    CFRelease(info);
}
SBMetrics sb_sample(void) {
    SBMetrics s={.cpu=-1,.memoryUsed=-1,.memoryTotal=-1,.diskFree=-1,.diskTotal=-1,.received=-1,.sent=-1,.diskRead=-1,.diskWrite=-1,.battery=-1};
    host_t host = mach_host_self();
    cpu(&s, host);
    uint64_t total=0; size_t n=sizeof(total);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t len=HOST_VM_INFO64_COUNT;
    if(!sysctlbyname("hw.memsize",&total,&n,NULL,0) && host_statistics64(host,HOST_VM_INFO64,(host_info64_t)&vm,&len)==KERN_SUCCESS) {
        s.memoryTotal=total;
        s.memoryUsed=((double)vm.internal_page_count-vm.purgeable_count+vm.wire_count+vm.compressor_page_count)*vm_kernel_page_size;
    }
    struct xsw_usage swap = {0};
    size_t swapSize = sizeof(swap), pressureSize = sizeof(s.pressure);
    s.swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, NULL, 0) == 0 ? (double)swap.xsu_used : -1;
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &s.pressure, &pressureSize, NULL, 0) != 0)
        s.pressure = 0;
    struct statfs fs;
    if(!statfs("/System/Volumes/Data",&fs) || !statfs("/",&fs)) {
        s.diskTotal=(double)fs.f_blocks*fs.f_bsize;
        s.diskFree=(double)fs.f_bavail*fs.f_bsize;
    }
    mach_port_deallocate(mach_task_self(), host);
    network(&s); diskIO(&s); battery(&s);
    return s;
}
