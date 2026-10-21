// Bounded HDMI DPMS test; writes only VCP D6=4 (DPMS Off / Standby) and D6=1 (On).
// Reuses the project's MIT-licensed native DDC transport.
#define main native_helper_main
#include "../Sources/NativeDDC/main.m"
#undef main

#if defined(__arm64__)
static BOOL dpmsTransaction(AVService service, uint32_t chip, BOOL writing, uint16_t *value) {
    if (writing && *value != 0x01 && *value != 0x04) return NO;
    IOReturn (*writeI2C)(AVService,uint32_t,uint32_t,void *,uint32_t) = dlsym(RTLD_DEFAULT,"IOAVServiceWriteI2C");
    IOReturn (*readI2C)(AVService,uint32_t,uint32_t,void *,uint32_t) = dlsym(RTLD_DEFAULT,"IOAVServiceReadI2C");
    if (!service || !writeI2C || !readI2C) return NO;
    uint8_t packet[6] = {writing ? 0x84 : 0x82, writing ? 3 : 1, 0xd6, 0, 0, 0};
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
        if (readI2C(service,chip,0x51,reply,sizeof(reply)) == kIOReturnSuccess && validReply(reply,sizeof(reply),0xd6,value)) return YES;
    }
    return NO;
}

static void save(NSDictionary *r) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:@"validation/hdmi-dpms-cycle-2026-10-20.json" atomically:YES];
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc!=2 || strcmp(argv[1],"--run")!=0) { fprintf(stderr,"Use --run for authorized DPMS test\n"); return 2; }
    NativeDisplay *selected=nil;
    for (NativeDisplay *d in displays()) {
        if (![d.name containsString:@"U4025QW"]) continue;
        uint16_t input=0, power=0;
        if (transaction(d,0x60,NO,&input) && input==0x1111 && transaction(d,0xd6,NO,&power) && power==1) {
            if (selected) { fprintf(stderr,"Ambiguous monitor; no writes\n"); return 1; }
            selected=d;
        }
    }
    if (!selected) { fprintf(stderr,"Expected awake U4025QW on HDMI; no writes\n"); return 1; }
    uint32_t chip=0x37;
    AVService service=serviceForDisplay(selected,&chip);
    if (!service) return 1;
    NSMutableDictionary *r=[@{
        @"serial":selected.serial,
        @"transport":@"HDMI DDC retained IOAVService",
        @"before_input":@0x1111,
        @"before_power":@1,
        @"write_vcp":@"0xd6",
        @"write_values":@[@4,@1],
        @"timestamp":[NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.systemTimeZone formatOptions:NSISO8601DateFormatWithInternetDateTime]
    } mutableCopy];
    save(r);

    // Step 1: Send DPMS Off / Standby (4)
    uint16_t standby=4;
    BOOL standbySent=dpmsTransaction(service,chip,YES,&standby);
    r[@"dpms_off_write_transport_accepted"]=@(standbySent);
    printf("DPMS Off (4) write transport accepted=%d\n", standbySent); fflush(stdout);
    save(r);

    // Step 2: Wait and check state while in standby
    usleep(2500000);
    uint16_t powerRead=0;
    BOOL readOk=dpmsTransaction(service,chip,NO,&powerRead);
    r[@"read_while_standby_ok"]=@(readOk);
    if (readOk) r[@"power_after_standby_request"]=@(powerRead);
    r[@"standby_readback_verified"]=@(readOk && powerRead!=1);
    printf("Read after DPMS Off: ok=%d power=%u\n", readOk, powerRead); fflush(stdout);
    save(r);

    // Step 3: Always attempt wake (On = 1)
    BOOL onVerified=NO;
    for (int attempt=0; attempt<6; attempt++) {
        uint16_t on=1;
        BOOL onSent=dpmsTransaction(service,chip,YES,&on);
        r[@"on_attempts"]=@(attempt+1);
        if (onSent) r[@"on_write_transport_accepted"]=@YES;
        usleep(800000);
        powerRead=0;
        if (dpmsTransaction(service,chip,NO,&powerRead) && powerRead==1) {
            onVerified=YES;
            break;
        }
        // Try rediscovery on HDMI if needed
        for (NativeDisplay *d in displays()) {
            if (![d.serial isEqualToString:selected.serial]) continue;
            uint16_t s=0;
            if (transaction(d,0x60,NO,&s) && (s>>8)==0x11) {
                uint32_t newChip=0x37;
                AVService newService=serviceForDisplay(d,&newChip);
                if (newService) { CFRelease(service); service=newService; chip=newChip; }
            }
        }
        save(r);
    }
    r[@"on_readback_verified"]=@(onVerified);
    if (onVerified) r[@"final_power"]=@(powerRead);
    r[@"dpms_cycle_verified"]=@([r[@"standby_readback_verified"] boolValue] && onVerified);
    save(r);

    puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil] encoding:NSUTF8StringEncoding].UTF8String);
    CFRelease(service);
    return onVerified ? 0 : 1;
}}
#else
int main(void) { return 2; }
#endif
