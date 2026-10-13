# Native DDC transport

OpenDDPM's standalone helper is implemented in `Sources/NativeDDC/main.m`.
It does not use or require BetterDisplay, DDPM, or a third-party executable.

The Apple Silicon IOAVService/discovery approach is adapted from the MIT-licensed
m1ddc reference by waydabber and contributors:
https://github.com/waydabber/m1ddc
Reference commit: 04d949794102eb8df01ad3681afff6464a3eede2.
The MIT notice is retained in LICENSE-m1ddc.txt and bundled with the application.

Intel transport is implemented using Apple's IOI2CInterface public headers and
standard DDC/CI packet framing. No ddcctl code is copied or included.

IOAVService and CoreDisplay discovery use dynamically loaded Apple APIs that are
not public SDK contracts. Future macOS versions may require driver adjustments.
