# ``MideaKit``

Local control of Midea (and rebranded) WiFi air conditioners over the LAN — no
cloud after a one-time key fetch.

## Overview

MideaKit discovers air conditioners on the local network, fetches each device's
token/key from Midea's SmartHome cloud once, and from then on controls them
entirely over the LAN. The cloud only hands out keys for devices registered to
the signed-in account, so sign in with the MSmartHome account the devices were
added to. Run ``Setup/run(account:password:devices:)`` once, persist the returned
``DeviceCredentials``, and reuse a
``MideaClient`` for all subsequent control.

```swift
import MideaKit

// One-time setup (touches the cloud once); persist the result and reuse it.
let credentials = try await Setup.run(account: "you@example.com", password: "pw").first!

let client = MideaClient(credentials: credentials)
let state = try await client.refresh()

_ = try await client.apply { set in
  set.powerOn = true
  set.targetTemperature = 22
  set.mode = .cool
}
```

Calls are `async`. ``MideaClient`` is an actor, so it can be held from any
context and its work runs off the caller's actor. Calls on one client are
serialized in the order they're made, so overlapping calls are safe: each waits
its turn on the one connection, and starts its own timeout only when it runs.

## Topics

### Essentials

- ``MideaClient``
- ``Setup``
- ``DeviceCredentials``

### Device state and commands

- ``ACState``
- ``SetState``
- ``OperationalMode``
- ``FanSpeed``
- ``SwingMode``
- ``Command``

### Discovery

- ``Discovery``
- ``DiscoveredDevice``

### Cloud key fetch

- ``SmartHomeCloud``
- ``SmartHomeSession``

### Low-level transport

- ``MideaConnection``

### Errors

- ``SetupError``
- ``SetupFailure``
- ``DiscoveryError``
- ``CloudError``
- ``TimeoutError``
- ``HandshakeError``
- ``ProtocolError``
