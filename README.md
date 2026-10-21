# hap-swift

> **Fork notice.** This is a modified fork of [acumen-dev/hap-swift](https://github.com/acumen-dev/hap-swift), maintained for [TowerHub](https://github.com/orlandoamorim/TowerHub). The `feat/resource-endpoint` branch changes the original in these files (Apache-2.0, section 4(b)):
>
> - `Sources/HAPTransport/HAPSession.swift`, `HAPBridge.swift`, `CharacteristicProtocol.swift`: `POST /resource` for camera snapshots, encrypted responses split into 1024-byte HAP frames, and standalone accessories on AID 1.
> - `Sources/HAPCore/HAPCategory.swift`, `HAPCharacteristicType+Extended.swift`, `HAPServiceType+Extended.swift`: IP camera category and camera service and characteristic types.
> - `Sources/HAPApple/AppleTCPServer.swift`: logs the remote endpoint of new connections.
> - `Sources/HAPTransport/PairingStateMachine.swift`: refuses pair-setup once a controller is paired (`kTLVError_Unavailable`) and after 100 failed attempts (`kTLVError_MaxTries`).
> - Tests for the above in `Tests/HAPTransportTests`.
>
> All changes are licensed under Apache-2.0, like the original.

A native Swift implementation of the [HomeKit Accessory Protocol (HAP)](https://developer.apple.com/homekit/) — the TCP-based protocol Apple Home uses for SecuritySystem, GarageDoorOpener, and other device types that Matter does not support.

## Overview

Matter (spec 1.0–1.5) has no SecuritySystem or GarageDoorOpener device type. HAP fills that gap, letting Acumen advertise security panels and garage doors to Apple Home alongside Matter devices on the same network.

Both HAP and Matter use mDNS/DNS-SD for discovery via the shared [`mdns-swift`](https://github.com/acumen-dev/mdns-swift) package. HAP uses TCP transport; Matter uses UDP — the transport layers are separate.

## Module Architecture

```
HAPCore          — HAP types, TLV8, constants, service/characteristic definitions
    ↑
HAPCrypto        — SRP-6a (3072-bit), Curve25519, ChaCha20-Poly1305, HKDF-SHA512
    ↑
HAPTransport     — TCP server, pairing state machine, encrypted sessions, characteristic protocol
    ↑
├── HAPApple     — Network.framework TCP + MDNSApple  (Apple platforms)
└── HAPLinux     — SwiftNIO TCP + MDNSLinux            (Linux)

HAPSwift         — Umbrella re-export
```

## Usage

```swift
import HAPSwift

// Create a SecuritySystem accessory
let accessory = HAPAccessory(
    info: AccessoryInfo(
        name: "Front Panel",
        manufacturer: "Acumen",
        model: "SecuritySystem",
        serialNumber: "001",
        firmwareVersion: "1.0"
    ),
    category: .securitySystem,
    services: [securitySystemService]
)

// Advertise and serve via HAP
let bridge = HAPBridge(setupCode: "031-45-154")
bridge.addAccessory(accessory)
try await bridge.start()
```

## Platform Requirements

| Platform | Minimum |
|----------|---------|
| macOS    | 15      |
| iOS      | 18      |
| tvOS     | 18      |
| watchOS  | 11      |
| visionOS | 2       |
| Linux    | Swift 6.2 |

## Dependencies

| Package | Use |
|---------|-----|
| [`acumen-dev/mdns-swift`](https://github.com/acumen-dev/mdns-swift) | mDNS advertisement (`_hap._tcp`) |
| [`apple/swift-crypto`](https://github.com/apple/swift-crypto) | SRP-6a, Curve25519, ChaCha20-Poly1305 |
| [`apple/swift-log`](https://github.com/apple/swift-log) | Structured logging |
| [`apple/swift-nio`](https://github.com/apple/swift-nio) | TCP transport (Linux) |

## Adding to Your Package

```swift
dependencies: [
    .package(url: "https://github.com/acumen-dev/hap-swift.git", from: "1.0.0"),
],
targets: [
    .target(name: "MyTarget", dependencies: [
        .product(name: "HAPSwift", package: "hap-swift"),
    ]),
]
```

## License

Apache 2.0 — see [LICENSE.md](LICENSE.md).
