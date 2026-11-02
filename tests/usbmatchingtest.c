/* Verify the actual IOKit dictionaries include the Xiaomi 14 ef/04/01 interface. */
#include "usb.h"
#include <stdio.h>

static bool number_is(CFDictionaryRef values, CFStringRef key, int expected) {
    CFTypeRef value = CFDictionaryGetValue(values, key);
    int number = -1;
    return value && CFGetTypeID(value) == CFNumberGetTypeID() &&
           CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number) && number == expected;
}

int main(void) {
    static const int expected[][3] = {{0xe0, 0x01, 0x03}, {0x02, 0x02, 0xff}, {0xef, 0x04, 0x01}};
    unsigned failures = 0;
    if (USB_MATCHING_KINDS != sizeof expected / sizeof *expected) return 1;
    for (unsigned i = 0; i < USB_MATCHING_KINDS; ++i) {
        CFMutableDictionaryRef match = usb_create_matching((UsbMatching)i);
        CFDictionaryRef properties = match ? CFDictionaryGetValue(match, CFSTR("IOPropertyMatch")) : NULL;
        bool ok = properties && number_is(properties, CFSTR("bInterfaceClass"), expected[i][0]) &&
                  number_is(properties, CFSTR("bInterfaceSubClass"), expected[i][1]) &&
                  number_is(properties, CFSTR("bInterfaceProtocol"), expected[i][2]);
        if (!ok) { fprintf(stderr, "matching variant %u missing or incorrect\n", i); ++failures; }
        if (match) CFRelease(match);
    }
    printf("usbmatchingtest: %u failures\n", failures);
    return failures ? 1 : 0;
}
