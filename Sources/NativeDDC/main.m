// OpenDDPM native DDC/CI transport. No external monitor-control app is required.
// Apple Silicon discovery follows the MIT-licensed m1ddc reference approach;
// see Vendor/NativeDDC/NOTICE.md. Intel uses Apple's IOI2CInterface API.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <IOKit/i2c/IOI2CInterface.h>
#include <dlfcn.h>
#include <unistd.h>
#include <mach/mach_time.h>

@interface NativeDisplay : NSObject
@property NSString *serial;
@property NSString *name;
@property(assign) io_service_t adapter;
@property(assign) CGDirectDisplayID displayID;
@end
@implementation NativeDisplay
- (void)dealloc { if (_adapter) IOObjectRelease(_adapter); }
@end

static id property(io_service_t entry, CFStringRef name, IOOptionBits options) {
    CFTypeRef value = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, name, kCFAllocatorDefault, options);
    return value ? CFBridgingRelease(value) : nil;
}

static NSString *descriptor(NSData *edid, unsigned char type) {
    if (edid.length < 128) return nil;
    const unsigned char *bytes = edid.bytes;
    for (int offset = 54; offset <= 108; offset += 18) {
        if (bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 3] == type) {
            NSString *text = [[NSString alloc] initWithBytes:bytes + offset + 5 length:13 encoding:NSASCIIStringEncoding];
            return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    return nil;
}

static NSArray<NativeDisplay *> *displays(void) {
    CGDirectDisplayID identifiers[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, identifiers, &count) != kCGErrorSuccess) return @[];
    NSMutableArray *result = [NSMutableArray array];
    void *coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
    CFDictionaryRef (*infoForDisplay)(CGDirectDisplayID) = coreDisplay ? dlsym(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary") : NULL;
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID identifier = identifiers[i];
        if (CGDisplayIsBuiltin(identifier)) continue;
        io_service_t adapter = 0;
        NSDictionary *info = nil;
        if (infoForDisplay) {
            CFDictionaryRef value = infoForDisplay(identifier);
            if (value) info = CFBridgingRelease(value);
            NSString *location = info[@"IODisplayLocation"];
            if ([location isKindOfClass:NSString.class]) adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, (__bridge CFStringRef)location);
        }
#if defined(__x86_64__)
        if (!adapter) {
            adapter = CGDisplayIOServicePort(identifier);
            if (adapter) IOObjectRetain(adapter);
        }
#endif
        if (!adapter) continue;
        NSDictionary *attributes = property(adapter, CFSTR("DisplayAttributes"), kIORegistryIterateRecursively);
        NSDictionary *product = [attributes isKindOfClass:NSDictionary.class] ? attributes[@"ProductAttributes"] : nil;
        NSString *serial = product[@"AlphanumericSerialNumber"];
        NSString *name = product[@"ProductName"];
        if (!serial.length || !name.length) {
            CFDictionaryRef value = IODisplayCreateInfoDictionary(adapter, kIODisplayOnlyPreferredName);
            NSDictionary *displayInfo = value ? CFBridgingRelease(value) : @{};
            NSData *edid = displayInfo[@kIODisplayEDIDKey] ?: property(adapter, CFSTR(kIODisplayEDIDKey), kIORegistryIterateRecursively);
            serial = serial ?: descriptor(edid, 0xff);
            name = name ?: descriptor(edid, 0xfc);
        }
        if (![serial isKindOfClass:NSString.class] || !serial.length || ![name isKindOfClass:NSString.class]) { IOObjectRelease(adapter); continue; }
        NativeDisplay *display = [NativeDisplay new];
        display.serial = serial; display.name = name; display.adapter = adapter; display.displayID = identifier;
        [result addObject:display];
    }
    return result;
}

static BOOL validReply(const uint8_t *reply, size_t length, uint8_t code, uint16_t *value) {
    if (length < 11 || reply[0] != 0x6e || reply[1] != 0x88 || reply[2] != 2 || reply[3] != 0 || reply[4] != code) return NO;
    uint8_t checksum = 0x50;
    for (int i = 0; i < 11; i++) checksum ^= reply[i];
    if (checksum != 0) return NO;
    *value = ((uint16_t)reply[8] << 8) | reply[9];
    return YES;
}

#if defined(__arm64__)
typedef CFTypeRef AVService;
static AVService serviceForDisplay(NativeDisplay *display, uint32_t *chip) {
    AVService (*create)(CFAllocatorRef, io_service_t) = dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
    if (!create) return NULL;
    io_iterator_t iterator = 0;
    uint64_t adapterID = 0;
    IORegistryEntryGetRegistryEntryID(display.adapter, &adapterID);
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    kern_return_t iterated = IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iterator);
    IOObjectRelease(root);
    if (iterated != KERN_SUCCESS) return NULL;
    BOOL matchesFramebuffer = NO;
    io_service_t entry; AVService result = NULL;
    while ((entry = IOIteratorNext(iterator))) {
        io_name_t name; IORegistryEntryGetName(entry, name);
        if (IOObjectConformsTo(entry, "IOMobileFramebuffer")) {
            uint64_t identifier = 0; IORegistryEntryGetRegistryEntryID(entry, &identifier);
            matchesFramebuffer = identifier == adapterID;
        }
        if (matchesFramebuffer && strcmp(name, "DCPAVServiceProxy") == 0) {
            NSString *location = property(entry, CFSTR("Location"), kIORegistryIterateRecursively);
            if ([location isEqualToString:@"External"]) {
                result = create(kCFAllocatorDefault, entry);
                NSString *provider = property(entry, CFSTR("EPICProviderClass"), kIORegistryIterateRecursively | kIORegistryIterateParents);
                *chip = [provider isEqualToString:@"AppleDCPMCDP29XX"] ? 0xb7 : 0x37;
            }
        }
        IOObjectRelease(entry);
        if (result) break;
    }
    IOObjectRelease(iterator);
    return result;
}

static BOOL transaction(NativeDisplay *display, uint8_t code, BOOL writing, uint16_t *value) {
    uint32_t chip = 0x37;
    AVService service = serviceForDisplay(display, &chip);
    IOReturn (*writeI2C)(AVService, uint32_t, uint32_t, void *, uint32_t) = dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    IOReturn (*readI2C)(AVService, uint32_t, uint32_t, void *, uint32_t) = dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
    if (!service || !writeI2C || !readI2C) { if (service) CFRelease(service); return NO; }
    if (getenv("OPENDDPM_DEBUG")) fprintf(stderr, "AV service=%p chip=%x\n", service, chip);
    uint8_t packet[6] = {writing ? 0x84 : 0x82, writing ? 3 : 1, code, 0, 0, 0};
    int size = writing ? 6 : 4;
    if (writing) { packet[3] = *value >> 8; packet[4] = *value & 0xff; }
    packet[size - 1] = 0x6e ^ 0x51;
    for (int i = 0; i < size - 1; i++) packet[size - 1] ^= packet[i];
    BOOL success = NO;
    for (int attempt = 0; attempt < 4 && !success; attempt++) {
        usleep(50000);
        IOReturn sent = writeI2C(service, chip, 0x51, packet, size);
        if (getenv("OPENDDPM_DEBUG")) fprintf(stderr, "write result=%x\n", sent);
        if (sent != kIOReturnSuccess) continue;
        if (writing) { success = YES; break; }
        usleep(80000);
        uint8_t reply[12] = {0};
        IOReturn readResult = readI2C(service, chip, 0x51, reply, sizeof(reply));
        if (getenv("OPENDDPM_DEBUG")) { fprintf(stderr, "read result=%x bytes:", readResult); for (int i=0;i<12;i++) fprintf(stderr," %02x",reply[i]); fprintf(stderr,"\n"); }
        if (readResult == kIOReturnSuccess) success = validReply(reply, sizeof(reply), code, value);
    }
    CFRelease(service);
    return success;
}
#else
static BOOL transaction(NativeDisplay *display, uint8_t code, BOOL writing, uint16_t *value) {
    IOItemCount buses = 0;
    if (IOFBGetI2CInterfaceCount(display.adapter, &buses) != KERN_SUCCESS) return NO;
    uint8_t packet[7] = {0x51, writing ? 0x84 : 0x82, writing ? 3 : 1, code, 0, 0, 0};
    int size = writing ? 7 : 5;
    if (writing) { packet[4] = *value >> 8; packet[5] = *value & 0xff; }
    packet[size - 1] = 0x6e;
    for (int i = 0; i < size - 1; i++) packet[size - 1] ^= packet[i];
    for (IOOptionBits bus = 0; bus < buses; bus++) {
        io_service_t interface = 0; IOI2CConnectRef connection = NULL;
        if (IOFBCopyI2CInterfaceForBus(display.adapter, bus, &interface) != KERN_SUCCESS) continue;
        IOReturn opened = IOI2CInterfaceOpen(interface, 0, &connection);
        IOObjectRelease(interface);
        if (opened != KERN_SUCCESS) continue;
        for (int attempt = 0; attempt < 4; attempt++) {
            IOI2CRequest request = {0};
            request.sendAddress = 0x6e; request.sendTransactionType = kIOI2CSimpleTransactionType;
            request.sendBuffer = (vm_address_t)packet; request.sendBytes = size;
            request.replyTransactionType = kIOI2CNoTransactionType;
            BOOL sent = IOI2CSendRequest(connection, 0, &request) == KERN_SUCCESS && request.result == KERN_SUCCESS;
            if (sent && writing) { IOI2CInterfaceClose(connection, 0); return YES; }
            if (!sent) continue;
            usleep(80000);
            // Separate read avoids Intel framebuffer combined-DDC transaction limitations.
            uint8_t reply[12] = {0}; IOI2CRequest readRequest = {0};
            readRequest.sendTransactionType = kIOI2CNoTransactionType;
            readRequest.replyAddress = 0x6f;
            readRequest.replyTransactionType = attempt % 2 ? kIOI2CDDCciReplyTransactionType : kIOI2CSimpleTransactionType;
            readRequest.replyBuffer = (vm_address_t)reply; readRequest.replyBytes = sizeof(reply);
            if (IOI2CSendRequest(connection, 0, &readRequest) == KERN_SUCCESS && readRequest.result == KERN_SUCCESS && validReply(reply, readRequest.replyBytes, code, value)) { IOI2CInterfaceClose(connection, 0); return YES; }
        }
        IOI2CInterfaceClose(connection, 0);
    }
    return NO;
}
#endif

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "Usage: openddpm-ddc list | read SERIAL REGISTER | write SERIAL REGISTER VALUE\n"); return 2; }
        if (strcmp(argv[1], "--self-test") == 0) {
            uint8_t reply[12] = {0x6e, 0x88, 2, 0, 0xe9, 0, 0, 0xff, 0, 0x24, 0x86, 0};
            uint16_t value = 0;
            if (!validReply(reply, sizeof(reply), 0xe9, &value) || value != 0x24) return 1;
            if (validReply(reply, sizeof(reply), 0xe8, &value)) return 1;
            reply[10] ^= 1;
            if (validReply(reply, sizeof(reply), 0xe9, &value)) return 1;
            reply[10] ^= 1; reply[3] = 1;
            if (validReply(reply, sizeof(reply), 0xe9, &value)) return 1;
            if (validReply(reply, 5, 0xe9, &value)) return 1;
            puts("PASS: native DDC packet validation"); return 0;
        }
        NSArray<NativeDisplay *> *found = displays();
        if (strcmp(argv[1], "list") == 0) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NativeDisplay *display in found) [rows addObject:@{@"serial":display.serial, @"name":display.name, @"model":display.name}];
            NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
            puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String); return 0;
        }
        BOOL writing = strcmp(argv[1], "write") == 0;
        if ((!writing && strcmp(argv[1], "read") != 0) || argc != (writing ? 5 : 4)) return 2;
        char *end = NULL; long registerCode = strtol(argv[3], &end, 0);
        if (*end || registerCode < 0 || registerCode > 255) return 2;
        // Limit writes to the registers OpenDDPM needs (inputs, layout, power).
        if (writing && registerCode != 0x60 && registerCode != 0xe8 && registerCode != 0xe9 && registerCode != 0xd6) return 2;
        uint16_t value = 0;
        if (writing) {
            long parsed = strtol(argv[4], &end, 0); if (*end || parsed < 0 || parsed > 65535) return 2;
            if (registerCode == 0xd6 && parsed != 1 && parsed != 4) return 2;
            value = parsed;
        }
        NSString *serial = [NSString stringWithUTF8String:argv[2]];
        NSArray *matches = [found filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NativeDisplay *display, NSDictionary *bindings) { return [display.serial isEqualToString:serial]; }]];
        if (matches.count != 1) { fprintf(stderr, "Monitor is disconnected or its serial is ambiguous. Rediscover your monitor.\n"); return 1; }
        if (!transaction(matches[0], (uint8_t)registerCode, writing, &value)) { fprintf(stderr, "Native DDC transaction failed. Check the cable and enable DDC/CI in the monitor menu.\n"); return 1; }
        if (!writing) printf("%u\n", value);
        return 0;
    }
}
