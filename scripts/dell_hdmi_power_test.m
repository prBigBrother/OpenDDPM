// Bounded HDMI power-off/on test; writes only VCP D6=5 (off), D6=1 (on).
// Reuses the project's MIT-licensed native DDC transport.
#define main native_helper_main
#include "../Sources/NativeDDC/main.m"
#undef main
#if defined(__arm64__)
static BOOL powerTransaction(AVService service, uint32_t chip, BOOL writing, uint16_t *value) {
    if (writing && *value != 0x01 && *value != 0x05) return NO;
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
 [data writeToFile:@"validation/hdmi-power-cycle-2026-10-20.json" atomically:YES];
}
int main(int argc,const char *argv[]) { @autoreleasepool {
 if(argc!=2 || strcmp(argv[1],"--run")!=0) { fprintf(stderr,"Use --run for authorized power test\n");return 2; }
 NativeDisplay *selected=nil;
 for(NativeDisplay *d in displays()) {
  if(![d.name containsString:@"U4025QW"]) continue;
  uint16_t input=0,power=0;
  if(transaction(d,0x60,NO,&input) && input==0x1111 && transaction(d,0xd6,NO,&power) && power==1) {
   if(selected) { fprintf(stderr,"Ambiguous monitor; no writes\n");return 1; }
   selected=d;
  }
 }
 if(!selected) { fprintf(stderr,"Expected awake U4025QW on HDMI; no writes\n");return 1; }
 uint32_t chip=0x37;
 AVService service=serviceForDisplay(selected,&chip);
 if(!service) return 1;
 NSMutableDictionary *r=[@{@"serial":selected.serial,@"transport":@"HDMI DDC retained IOAVService",
   @"before_input":@0x1111,@"before_power":@1,@"write_vcp":@"0xd6",@"write_values":@[@5,@1],
   @"timestamp":[NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.systemTimeZone formatOptions:NSISO8601DateFormatWithInternetDateTime]} mutableCopy];
 save(r);
 uint16_t off=5;
 r[@"off_write_transport_accepted"]=@(powerTransaction(service,chip,YES,&off));
 printf("Off command transport accepted=%d\n",[r[@"off_write_transport_accepted"] boolValue]);fflush(stdout);
 save(r);
 usleep(2500000);
 uint16_t power=0;
 BOOL offRead=powerTransaction(service,chip,NO,&power);
 r[@"read_while_off_ok"]=@(offRead);
 if(offRead) r[@"power_after_off_request"]=@(power);
 r[@"off_readback_verified"]=@(offRead && power!=1);
 printf("Read after OFF: ok=%d power=%u\n",offRead,power);fflush(stdout);
 save(r);
 // Always attempt on, even when off-state readback is unavailable.
 BOOL onVerified=NO;
 for(int attempt=0;attempt<6;attempt++) {
  uint16_t on=1;
  BOOL onSent=powerTransaction(service,chip,YES,&on);
  r[@"on_attempts"]=@(attempt+1);
  if(onSent) r[@"on_write_transport_accepted"]=@YES;
  usleep(800000);
  power=0;
  if(powerTransaction(service,chip,NO,&power) && power==1) { onVerified=YES;break; }
  // Recover only the same monitor over HDMI; never use a different transport.
  for(NativeDisplay *d in displays()) {
   if(![d.serial isEqualToString:selected.serial]) continue;
   uint16_t s=0;
   if(transaction(d,0x60,NO,&s) && (s>>8)==0x11) {
    uint32_t newChip=0x37; AVService newService=serviceForDisplay(d,&newChip);
    if(newService) { CFRelease(service);service=newService;chip=newChip; }
   }
  }
  save(r);
 }
 r[@"on_readback_verified"]=@(onVerified);
 if(onVerified) r[@"final_power"]=@(power);
 r[@"power_cycle_verified"]=@([r[@"off_readback_verified"] boolValue] && onVerified);
 save(r);
 puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil] encoding:NSUTF8StringEncoding].UTF8String);
 CFRelease(service);
 return onVerified ? 0 : 1;
}}
#else
int main(void) { return 2; }
#endif
