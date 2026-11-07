import Foundation

/// Errors thrown by ``Setup``.
public enum SetupError: Error {
  /// LAN discovery found no devices to set up.
  case noDevicesFound
  /// Devices were discovered, but none could be set up; each failure says why.
  case noCredentialsObtained([SetupFailure])
  /// Devices were discovered, but none could be set up, and the cloud reported at
  /// least one of them as not registered to the given account.
  case notInAccount([SetupFailure])
  /// A version-3 device needs a cloud key, but setup ran without an account.
  case accountRequired
}

/// A discovered device that setup couldn't provision, and why.
public struct SetupFailure: Error {
  /// The device as discovered.
  public let device: DiscoveredDevice
  /// Why it failed: ``SetupError/accountRequired``, a ``CloudError`` from the key
  /// fetch, or the error from the local check, such as ``HandshakeError/rejected``
  /// or ``TimeoutError``.
  public let error: any Error
}

/// One-shot setup: discover devices on the LAN, fetch each version-3 device's
/// token/key from the cloud, verify every device with a local query, and return
/// credentials ready to store. Version-2 devices need no cloud token. This is the
/// only step that contacts the cloud.
///
/// Run it once with the MSmartHome account the devices are registered to, persist
/// the result (``DeviceCredentials`` is `Codable`), and from then on construct a
/// ``MideaClient`` from the stored credentials without touching the cloud again:
///
/// ```swift
/// let credentials = try await Setup.run(account: "you@example.com", password: "pw")
/// try JSONEncoder().encode(credentials).write(to: storeURL)
/// ```
///
/// A home with only version-2 devices can call ``run(devices:)`` with no account.
/// To set up devices found some other way, pass them as `devices`.
public enum Setup {
  /// Discover devices, fetch and verify their keys, and return credentials to store.
  ///
  /// Signs in to the SmartHome cloud (see ``SmartHomeCloud``) only if a version-3
  /// device is found; version-2 devices need no cloud.
  ///
  /// - Parameters:
  ///   - account: The MSmartHome account email the devices are registered to.
  ///   - password: The MSmartHome account password.
  ///   - devices: The devices to set up; `nil` runs ``Discovery`` with its defaults.
  /// - Returns: Credentials for every device that could be set up, ready to
  ///   store. Best-effort: a device whose key can't be fetched or that fails
  ///   local verification is omitted rather than failing the whole run.
  /// - Throws: ``SetupError/noDevicesFound`` if discovery finds no devices,
  ///   ``CloudError/loginRejected(code:message:)`` if the cloud rejects the email or
  ///   password, ``SetupError/notInAccount(_:)`` if no device could be set up and
  ///   the cloud reported a device as not in the account, or
  ///   ``SetupError/noCredentialsObtained(_:)`` if no device could be set up for
  ///   another reason.
  public static func run(
    account: String, password: String, devices: [DiscoveredDevice]? = nil
  ) async throws -> [DeviceCredentials] {
    try await run(
      cloud: SmartHomeCloud(account: account, password: password), devices: devices)
  }

  /// Discover and verify version-2 devices, which need no cloud account.
  ///
  /// Version-3 devices found along the way fail with ``SetupError/accountRequired``;
  /// use ``run(account:password:devices:)`` for them.
  ///
  /// - Parameter devices: The devices to set up; `nil` runs ``Discovery`` with its
  ///   defaults.
  /// - Returns: Credentials for every version-2 device that answered, ready to store.
  /// - Throws: ``SetupError/noDevicesFound`` if discovery finds no devices, or
  ///   ``SetupError/noCredentialsObtained(_:)`` if none could be set up.
  public static func run(devices: [DiscoveredDevice]? = nil) async throws
    -> [DeviceCredentials]
  {
    try await run(cloud: nil, devices: devices)
  }

  private static func run(cloud: SmartHomeCloud?, devices: [DiscoveredDevice]?) async throws
    -> [DeviceCredentials]
  {
    let devices: [DiscoveredDevice] =
      if let devices { devices } else { try await Discovery.discover() }
    guard !devices.isEmpty else { throw SetupError.noDevicesFound }

    let session: SmartHomeSession? =
      if let cloud, devices.contains(where: { $0.version >= 3 }) {
        try await cloud.login()
      } else {
        nil
      }

    // Each device's cloud lookup + local verification is independent, so
    // provision them concurrently: total latency is ~one device's worth rather
    // than the sum over all devices.
    let outcomes = await withTaskGroup(of: Result<DeviceCredentials, SetupFailure>.self) {
      group in
      for device in devices {
        group.addTask {
          do {
            return .success(try await credentials(for: device, session: session))
          } catch {
            return .failure(SetupFailure(device: device, error: error))
          }
        }
      }
      var collected: [Result<DeviceCredentials, SetupFailure>] = []
      for await outcome in group { collected.append(outcome) }
      return collected
    }
    return try collect(outcomes)
  }

  /// Return the credentials obtained, or throw the error that explains why there are none.
  static func collect(_ outcomes: [Result<DeviceCredentials, SetupFailure>]) throws
    -> [DeviceCredentials]
  {
    var results: [DeviceCredentials] = []
    var failures: [SetupFailure] = []
    for outcome in outcomes {
      switch outcome {
      case .success(let credentials): results.append(credentials)
      case .failure(let failure): failures.append(failure)
      }
    }
    guard results.isEmpty else { return results }
    let notOwned = failures.contains {
      if case CloudError.notDeviceOwner = $0.error { true } else { false }
    }
    throw notOwned
      ? SetupError.notInAccount(failures) : SetupError.noCredentialsObtained(failures)
  }

  /// Fetch and check the credentials for one device.
  ///
  /// A version-3 device's key comes from the cloud through `session`. The cloud may
  /// file it under either byte order of the device id and answer for both with
  /// different pairs, so this fetches both at once and returns the one the device accepts. A
  /// version-2 device needs no session.
  ///
  /// - Parameters:
  ///   - device: The device, as discovered.
  ///   - session: A session from ``SmartHomeCloud/login()``; needed for version 3.
  /// - Returns: Credentials the device answered a local query with, ready to store.
  /// - Throws: ``SetupError/accountRequired`` for a version-3 device without a
  ///   session. Otherwise the error that best explains the failure: the device
  ///   refusing a key (such as ``HandshakeError/rejected``), then
  ///   ``CloudError/notDeviceOwner(message:)``, then any other cloud error.
  public static func credentials(for device: DiscoveredDevice, session: SmartHomeSession?)
    async throws -> DeviceCredentials
  {
    guard device.version >= 3 else {
      return try await checked(DeviceCredentials(device: device))
    }
    guard let session else { throw SetupError.accountRequired }
    async let littleEndian = fetchToken(session, device: device, bigEndian: false)
    async let bigEndian = fetchToken(session, device: device, bigEndian: true)
    var cloudError: (any Error)?
    var checkError: (any Error)?
    for fetched in [await littleEndian, await bigEndian] {
      switch fetched {
      case .failure(let error):
        // Not being the owner explains a failure better than a missing key does.
        if case CloudError.notDeviceOwner = error {
          cloudError = error
        } else if cloudError == nil {
          cloudError = error
        }
      case .success(let pair):
        do {
          return try await checked(
            DeviceCredentials(device: device, token: pair.token, key: pair.key))
        } catch {
          checkError = error
        }
      }
    }
    // A key the device turned down says more than a byte order the cloud didn't know.
    // Each pass sets one of the two, so they can't both be nil.
    throw (checkError ?? cloudError)!
  }

  private static func fetchToken(
    _ session: SmartHomeSession, device: DiscoveredDevice, bigEndian: Bool
  ) async -> Result<(token: [UInt8], key: [UInt8]), any Error> {
    do {
      return .success(
        try await session.cloud.getToken(session, deviceId: device.id, bigEndian: bigEndian))
    } catch {
      return .failure(error)
    }
  }

  /// Return `credentials` if the device answers a local query with them.
  private static func checked(_ credentials: DeviceCredentials) async throws
    -> DeviceCredentials
  {
    let client = MideaClient(credentials: credentials)
    do {
      _ = try await client.refresh()
      await client.disconnect()
      return credentials
    } catch {
      await client.disconnect()
      throw error
    }
  }
}
