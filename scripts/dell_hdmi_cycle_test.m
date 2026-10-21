// Bounded HDMI DDC test. Reuses the project's MIT-licensed native transport.
// Only writes main-input VCP 0x60: Thunderbolt (0x19) and HDMI (0x11).
#define main native_helper_main
#include "../Sources/NativeDDC/main.m"
#undef main

#if defined(__arm64__)
static BOOL hdmiTransaction(AVService service, uint32_t chip, BOOL writing, uint16_t *value) {
    if (writing && *value != 0x19 && *value != 0x11) return NO;
    IOReturn (*writeI2C)(AVService,uint32_t,uint32_t,void *,uint32_t) = dlsym(RTLD_DEFAULT,"IOAVServiceWriteI2C");
    IOReturn (*readI2C)(AVService,uint32_t,uint32_t,void *,uint32_t) = dlsym(RTLD_DEFAULT,"IOAVServiceReadI2C");
    if (!service || !writeI2C || !readI2C) return NO;
    uint8_t packet[6] = {writing ? 0x84 : 0x82, writing ? 3 : 1, 0x60, 0, 0, 0};
    int length = writing ? 6 : 4;
    if (writing) { packet[3] = *value >> 8; packet[4] = *value & 255; }
    packet[length-1] = 0x6e ^ 0x51;
    for (int i=0;i<length-1;i++) packet[length-1] ^= packet[i];
    for (int n=0;n<3;n++) {
        usleep(100000);
        IOReturn wr = writeI2C(service,chip,0x51,packet,length);
        if (wr != kIOReturnSuccess) continue;
        if (writing) return YES;
        usleep(150000);
        uint8_t reply[12] = {0};
        if (readI2C(service,chip,0x51,reply,sizeof(reply)) == kIOReturnSuccess && validReply(reply,sizeof(reply),0x60,value)) return YES;
    }
    return NO;
}
static void saveReport(NSDictionary *report) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:@"validation/hdmi-thunderbolt-cycle-2026-10-20.json" atomically:YES];
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc != 2 || strcmp(argv[1],"--run") != 0) { fprintf(stderr,"Use --run for authorized HDMI -> TB -> HDMI test\n"); return 2; }
    NativeDisplay *selected = nil;
    for (NativeDisplay *d in displays()) {
        if (![d.name containsString:@"U4025QW"]) continue;
        uint16_t source=0,layout=0;
        if (!transaction(d,0x60,NO,&source) || !transaction(d,0xe9,NO,&layout)) continue;
        if ((source>>8) == 0x11 && (source&255) == 0x11 && layout == 0) {
            if (selected) { fprintf(stderr,"Ambiguous HDMI target; no writes\n"); return 1; }
            selected=d;
        }
    }
    if (!selected) { fprintf(stderr,"Expected Dell U4025QW full-screen HDMI over HDMI DDC; no writes\n"); return 1; }
    uint32_t chip=0x37;
    AVService service=serviceForDisplay(selected,&chip);
    if (!service) { fprintf(stderr,"Cannot retain HDMI IOAVService; no writes\n"); return 1; }
    NSMutableDictionary *report=[@{@"transport":@"HDMI DDC, retained IOAVService",@"serial":selected.serial,
        @"before_source":@0x1111,@"write_vcp":@"0x60",@"write_values":@[@0x19,@0x11],
        @"timestamp":[NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.systemTimeZone formatOptions:NSISO8601DateFormatWithInternetDateTime]} mutableCopy];
    saveReport(report);
    uint16_t target=0x19;
    BOOL sent=hdmiTransaction(service,chip,YES,&target);
    report[@"thunderbolt_write_transport_accepted"]=@(sent);
    printf("Thunderbolt write transport accepted=%d\n",sent); fflush(stdout);
    // Always attempt HDMI restoration, even after an ambiguous write failure.
    usleep(1800000);
    uint16_t observed=0;
    BOOL readTB=hdmiTransaction(service,chip,NO,&observed);
    report[@"read_during_thunderbolt_ok"]=@(readTB);
    if (readTB) report[@"source_during_thunderbolt"]=@(observed);
    report[@"thunderbolt_verified"]=@(readTB && (observed&255)==0x19);
    printf("Read while TB selected: ok=%d source=0x%04x\n",readTB,observed); fflush(stdout);
    saveReport(report);
    uint16_t back=0x11;
    BOOL restoredWrite=hdmiTransaction(service,chip,YES,&back);
    report[@"hdmi_restore_write_transport_accepted"]=@(restoredWrite);
    usleep(1800000);
    BOOL restoredRead=NO;
    for (int attempt=0;attempt<5;attempt++) {
        observed=0;
        restoredRead=hdmiTransaction(service,chip,NO,&observed) && (observed&255)==0x11;
        if (restoredRead) break;
        // Rediscovery is allowed only for the same serial and HDMI local context.
        for (NativeDisplay *d in displays()) {
            if (![d.serial isEqualToString:selected.serial]) continue;
            uint16_t s=0;
            if (transaction(d,0x60,NO,&s) && (s>>8)==0x11) {
                uint32_t candidateChip=0x37;
                AVService candidate=serviceForDisplay(d,&candidateChip);
                if (candidate) { CFRelease(service); service=candidate; chip=candidateChip; }
            }
        }
        back=0x11;
        if (hdmiTransaction(service,chip,YES,&back)) report[@"hdmi_restore_write_transport_accepted"]=@YES;
        usleep(400000);
    }
    report[@"hdmi_restored_verified"]=@(restoredRead);
    if (restoredRead) report[@"final_source"]=@(observed);
    report[@"success"]=@([report[@"thunderbolt_verified"] boolValue] && restoredRead);
    saveReport(report);
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    CFRelease(service);
    return [report[@"success"] boolValue] ? 0 : 1;
}}
#else
int main(void) { fprintf(stderr,"This retained-service diagnostic requires Apple Silicon\n"); return 2; }
#endif
