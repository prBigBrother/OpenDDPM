// Test waking from sustained Standby (0xd6 = 4) after 10 seconds
#define main native_helper_main
#include "../Sources/NativeDDC/main.m"
#undef main

int main(void) { @autoreleasepool {
    NativeDisplay *target = nil;
    for (NativeDisplay *d in displays()) {
        if ([d.name containsString:@"U4025QW"]) { target = d; break; }
    }
    if (!target) { printf("No U4025QW found\n"); return 1; }
    uint32_t chip = 0x37;
    AVService service = serviceForDisplay(target, &chip);
    if (!service) { printf("No service\n"); return 1; }

    IOReturn (*writeI2C)(AVService,uint32_t,uint32_t,void *,uint32_t) = dlsym(RTLD_DEFAULT,"IOAVServiceWriteI2C");
    IOReturn (*readI2C)(AVService,uint32_t,uint32_t,void *,uint32_t) = dlsym(RTLD_DEFAULT,"IOAVServiceReadI2C");

    printf("1. Verifying initial power...\n");
    uint8_t pktRead[4] = {0x82, 1, 0xd6, 0};
    pktRead[3] = 0x6e ^ 0x51 ^ pktRead[0] ^ pktRead[1] ^ pktRead[2];
    writeI2C(service, chip, 0x51, pktRead, 4);
    usleep(100000);
    uint8_t reply[16] = {0};
    readI2C(service, chip, 0x51, reply, sizeof(reply));
    uint16_t v = 0;
    validReply(reply, sizeof(reply), 0xd6, &v);
    printf("Initial power: %u\n", v);

    printf("2. Putting monitor to Standby (0xd6 = 4)...\n");
    uint8_t pktOff[6] = {0x84, 3, 0xd6, 0, 4, 0};
    pktOff[5] = 0x6e ^ 0x51 ^ pktOff[0] ^ pktOff[1] ^ pktOff[2] ^ pktOff[3] ^ pktOff[4];
    writeI2C(service, chip, 0x51, pktOff, 6);

    printf("3. Waiting 10 seconds in Standby...\n");
    for (int s = 1; s <= 10; s++) {
        sleep(1);
        printf("%d... ", s); fflush(stdout);
    }
    printf("\n");

    printf("4. Sending Wake Up (0xd6 = 1) over retained HDMI DDC...\n");
    uint8_t pktOn[6] = {0x84, 3, 0xd6, 0, 1, 0};
    pktOn[5] = 0x6e ^ 0x51 ^ pktOn[0] ^ pktOn[1] ^ pktOn[2] ^ pktOn[3] ^ pktOn[4];
    IOReturn w = writeI2C(service, chip, 0x51, pktOn, 6);
    printf("Write 1 returned: 0x%x\n", w);

    printf("5. Polling for wake confirmation (up to 5 attempts)...\n");
    BOOL awake = NO;
    for (int att = 1; att <= 5; att++) {
        usleep(800000); // 800ms
        // If needed, repeat write
        writeI2C(service, chip, 0x51, pktOn, 6);
        usleep(100000);
        writeI2C(service, chip, 0x51, pktRead, 4);
        usleep(150000);
        memset(reply, 0, sizeof(reply));
        IOReturn r = readI2C(service, chip, 0x51, reply, sizeof(reply));
        v = 0;
        if (r == kIOReturnSuccess && validReply(reply, sizeof(reply), 0xd6, &v)) {
            printf("Attempt %d: readback power = %u\n", att, v);
            if (v == 1) { awake = YES; break; }
        } else {
            printf("Attempt %d: read failed (ret=0x%x)\n", att, r);
        }
    }

    if (awake) {
        printf("SUCCESS: Monitor was woken from sustained Standby (0xd6 = 4) via HDMI DDC!\n");
    } else {
        printf("FAILED: Monitor did not wake via HDMI DDC after 10s standby.\n");
    }

    CFRelease(service);
    return awake ? 0 : 1;
}}
