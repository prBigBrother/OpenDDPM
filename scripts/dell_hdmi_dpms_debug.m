// Detailed raw I2C probe for DPMS (0xd6 = 4)
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

    printf("Sending DPMS Off (0xd6 = 4)...\n");
    uint8_t pktOff[6] = {0x84, 3, 0xd6, 0, 4, 0};
    pktOff[5] = 0x6e ^ 0x51 ^ pktOff[0] ^ pktOff[1] ^ pktOff[2] ^ pktOff[3] ^ pktOff[4];
    IOReturn w1 = writeI2C(service, chip, 0x51, pktOff, 6);
    printf("Write 4: ret=0x%x\n", w1);

    for (int i = 1; i <= 5; i++) {
        usleep(1000000); // 1 sec
        uint8_t pktRead[4] = {0x82, 1, 0xd6, 0};
        pktRead[3] = 0x6e ^ 0x51 ^ pktRead[0] ^ pktRead[1] ^ pktRead[2];
        IOReturn wr = writeI2C(service, chip, 0x51, pktRead, 4);
        usleep(100000);
        uint8_t reply[16] = {0};
        IOReturn rd = readI2C(service, chip, 0x51, reply, sizeof(reply));
        printf("Sec %d: write_ret=0x%x read_ret=0x%x bytes=", i, wr, rd);
        for (int b = 0; b < 12; b++) printf("%02x ", reply[b]);
        printf("\n");
    }

    printf("Restoring Power On (0xd6 = 1)...\n");
    uint8_t pktOn[6] = {0x84, 3, 0xd6, 0, 1, 0};
    pktOn[5] = 0x6e ^ 0x51 ^ pktOn[0] ^ pktOn[1] ^ pktOn[2] ^ pktOn[3] ^ pktOn[4];
    IOReturn w2 = writeI2C(service, chip, 0x51, pktOn, 6);
    printf("Write 1: ret=0x%x\n", w2);
    usleep(1500000);

    uint8_t pktRead[4] = {0x82, 1, 0xd6, 0};
    pktRead[3] = 0x6e ^ 0x51 ^ pktRead[0] ^ pktRead[1] ^ pktRead[2];
    writeI2C(service, chip, 0x51, pktRead, 4);
    usleep(100000);
    uint8_t reply[16] = {0};
    readI2C(service, chip, 0x51, reply, sizeof(reply));
    printf("Final state: bytes=");
    for (int b = 0; b < 12; b++) printf("%02x ", reply[b]);
    uint16_t v = 0;
    if (validReply(reply, sizeof(reply), 0xd6, &v)) {
        printf(" -> parsed value=%u\n", v);
    } else {
        printf(" -> invalid reply\n");
    }
    CFRelease(service);
    return 0;
}}
