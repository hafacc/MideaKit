# MideaKit

[![build](https://github.com/hafacc/MideaKit/actions/workflows/build.yml/badge.svg)](https://github.com/hafacc/MideaKit/actions/workflows/build.yml)
[![docs](https://img.shields.io/badge/docs-DocC-informational.svg)](https://hafa.cc/MideaKit/)

Native Swift library for local control of Midea (and rebranded) WiFi air
conditioners over the LAN — no cloud after a one-time key fetch.
This is a Swift port of [msmart-ng](https://github.com/mill1000/midea-msmart).

Works on macOS 26 and iOS 26 or later. Pure Swift (Network, CryptoKit,
CommonCrypto) with no third-party dependencies.

Calls are `async`, and calls on one client are serialized in the order they're
made, so overlapping calls from different tasks are safe.

## Features

- **Discovery** of devices on the LAN (UDP broadcast, plus probes to given addresses for modules that ignore broadcasts).
- **Cloud key fetch** (Midea's SmartHome cloud, the MSmartHome app's backend) to
  obtain a device's token/key once, with the account the device is registered to.
- **Setup**: discover → fetch key → verify → credentials.
- **Local control**: power, mode, temperature, fan, eco/turbo/swing, display
  toggle; reads full state. Persistent connection with cheap polling.

## Install (Swift Package Manager)

```swift
.package(url: "https://github.com/hafacc/MideaKit", from: "0.0.0")
```

## Usage

```swift
import MideaKit

// One-time setup (touches the cloud once). Sign in with the MSmartHome account
// the AC is registered to; the cloud only hands out keys for that account's devices.
let credentials = try await Setup.run(account: "you@example.com", password: "pw").first!

// All local from here — store the credentials (Keychain) and reuse:
let client = MideaClient(credentials: credentials)
let state = try await client.refresh()
print(state.targetTemperature, state.mode)  // e.g. 22.0 cool

_ = try await client.apply { set in
    set.powerOn = true
    set.targetTemperature = 22
    set.mode = .cool
}
```

For one-off work, `withSession` builds a client, runs your closure, and
disconnects afterwards — even if it throws:

```swift
let state = try await MideaClient.withSession(credentials: credentials) { client in
    try await client.apply { $0.targetTemperature = 20 }
}
```

Setup throws `CloudError.loginRejected` when the cloud rejects the email or
password, and `SetupError.notInAccount` when the AC isn't registered to that
account, so an app can tell the two apart. Version-2 devices need no cloud key.

### Manual setup

`Setup.run` is the high-level path. The same steps are exposed individually if you
want to drive setup yourself — discover, fetch the key from the cloud, then connect:

```swift
let cloud = SmartHomeCloud(account: "you@example.com", password: "pw")
let session = try await cloud.login()

let device = try await Discovery.discover().first!   // a DiscoveredDevice on the LAN

// The cloud keys the token on the udpid; the byte order isn't discoverable, so
// try both and use whichever the cloud answers (see "Token endianness").
var pair: (token: [UInt8], key: [UInt8])?
for bigEndian in [false, true] {
    let udpid = UDPID.compute(deviceId: device.id, bigEndian: bigEndian)
    if let found = try? await cloud.getToken(session, udpid: udpid, deviceId: device.id) {
        pair = found
        break
    }
}

let client = MideaClient(credentials: DeviceCredentials(
    name: device.name, id: device.id, ip: device.ip, port: device.port,
    version: device.version, token: pair!.token, key: pair!.key,
    serialNumber: device.serialNumber))
print(try await client.refresh().targetTemperature)
```

## iOS

Discovery sends UDP broadcasts, which on iOS require the **Local Network** privacy
permission: add an `NSLocalNetworkUsageDescription` string to your `Info.plist`,
and the first discovery triggers the system prompt. Sending to broadcast addresses
may also require the
[multicast networking entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_developer_networking_multicast).
Local control of an already-known device (via stored `DeviceCredentials`) is a
normal TCP connection and needs neither.

## Design notes

### Post-authentication warm-up

A freshly authenticated version-3 device drops or ignores queries sent in the
first moment after the handshake. After a brief (~200 ms) floor, `MideaClient`
sends one throwaway `getState` probe and proceeds the instant its reply lands.
The reply is read with the normal timeout and fully consumed, so a slow unit's
late answer can't linger in the buffer and desync every later request from its
response. `getState` is idempotent, so the probe is harmless; if the device
never answers, the read times out and the first real call surfaces the failure.
Version-2 devices have no handshake, so they skip the warm-up entirely.

### Concurrency

`MideaClient` is an actor, so it is safe to hold anywhere — a `@MainActor` view
model included — and its work runs on its own executor rather than the caller's.
It still owns one stateful connection, so calls on a client are serialized in
the order they're made: overlapping calls from a polling timer, a UI action, and
anywhere else are safe, and a call queued behind a slow one waits its turn, its
own timeout starting only when it runs. A connection dropped while idle is
re-established automatically, and only transport-level errors are retried
(protocol, auth, and timeout errors surface immediately). The cloud client, by
contrast, is stateless after `login()` and fully `Sendable`, so
`Setup` provisions all discovered devices concurrently.

### Token endianness

The cloud stores a device's token/key under a *udpid* derived from its device id.
The official app computed that udpid using a particular byte order of the id when
it registered the device, and that order varies across firmware/app versions.
Nothing in the device's discovery reply or the cloud API reports which order was
used, so it can't be computed or detected locally — the only signal is the cloud
itself. So setup computes both candidates and calls `getToken` for each; whichever
returns a token is correct. Hence `Setup` (and the manual example) try
little-endian, then big-endian.

### Device ids and JSON

Device ids arrive as raw bytes from UDP discovery (6 bytes, ≤ 2^48), never from
JSON, and the cloud JSON carries only strings — so the JSON number representation
never affects them.

### Cross-validation

`Tests/MideaKitTests/vectors.json` was generated from the canonical Python
reference ([msmart-ng](https://github.com/mill1000/midea-msmart)); the tests assert
MideaKit's framing, CRC, command encodings, and state parsing match it.
