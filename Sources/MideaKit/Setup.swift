import Foundation

/// Errors thrown by ``Setup/run(account:password:)``.
public enum SetupError: Error {
  /// LAN discovery found no devices to set up.
  case noDevicesFound
  /// Devices were discovered, but none could be provisioned — every device
  /// failed to fetch a cloud key (version 3) or failed local verification. This
  /// usually means a cloud or connectivity problem, not an empty network.
  case noCredentialsObtained
  /// Devices were discovered, but none could be provisioned, and the cloud
  /// reported at least one of them as not registered to the given account.
  case notInAccount
}

/// One-shot setup: discover devices on the LAN, fetch each version-3 device's
/// token/key from the cloud, verify every device with a local query, and return
/// credentials ready to store. Version-2 devices need no cloud token. This is the
/// only step that contacts the cloud.
///
/// Run it once with the MSmartHome account the devices are registered to, persist
/// the result (for example with ``CredentialStore``), and from then on construct a
/// ``MideaClient`` from the stored credentials without touching the cloud again:
///
/// ```swift
/// let credentials = try await Setup.run(account: "you@example.com", password: "pw")
/// try CredentialStore.save(credentials, to: storeURL)
/// ```
public enum Setup {
  /// Discover devices, fetch and verify their keys, and return credentials to store.
  ///
  /// Signs in to the SmartHome cloud (see ``SmartHomeCloud``) only if a version-3
  /// device is found; version-2 devices need no cloud.
  ///
  /// - Parameters:
  ///   - account: The MSmartHome account email the devices are registered to.
  ///   - password: The MSmartHome account password.
  /// - Returns: Credentials for every device that could be set up, ready to
  ///   store. Best-effort: a device whose key can't be fetched or that fails
  ///   local verification is omitted rather than failing the whole run.
  /// - Throws: ``SetupError/noDevicesFound`` if discovery finds no devices,
  ///   ``CloudError/loginRejected(code:message:)`` if the cloud rejects the email or
  ///   password, ``SetupError/notInAccount`` if no device could be provisioned and
  ///   the cloud reported a device as not in the account, or
  ///   ``SetupError/noCredentialsObtained`` if no device could be provisioned for
  ///   another reason.
  public static func run(account: String, password: String) async throws
    -> [DeviceCredentials]
  {
    // Discovery is a blocking UDP listen loop; run it off the cooperative pool
    // so it doesn't stall a Swift concurrency thread for the whole timeout.
    let devices = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try Discovery.discover() })
      }
    }
    guard !devices.isEmpty else { throw SetupError.noDevicesFound }

    let cloud = SmartHomeCloud(account: account, password: password)
    let session: SmartHomeSession? =
      devices.contains { $0.version >= 3 } ? try await cloud.login() : nil

    // Each device's cloud lookup + local verification is independent, so
    // provision them concurrently: total latency is ~one device's worth rather
    // than the sum over all devices.
    let outcomes = await withTaskGroup(of: Outcome.self) { group in
      for device in devices {
        group.addTask { await provision(device, cloud: cloud, session: session) }
      }
      var collected: [Outcome] = []
      for await outcome in group { collected.append(outcome) }
      return collected
    }

    let results = outcomes.compactMap { outcome -> DeviceCredentials? in
      if case .provisioned(let credentials) = outcome { credentials } else { nil }
    }
    // Discovery found devices but nothing could be provisioned — surface that
    // distinctly rather than returning an empty array that looks like "nothing found".
    guard !results.isEmpty else {
      if outcomes.contains(where: { if case .notOwned = $0 { true } else { false } }) {
        throw SetupError.notInAccount
      } else {
        throw SetupError.noCredentialsObtained
      }
    }
    return results
  }

  private enum Outcome: Sendable {
    case provisioned(DeviceCredentials)
    case notOwned
    case failed
  }

  /// Provision one discovered device, verifying it answers a local query. A
  /// version-3 device needs a cloud key first; a version-2 device needs none.
  private static func provision(
    _ device: DiscoveredDevice, cloud: SmartHomeCloud, session: SmartHomeSession?
  ) async -> Outcome {
    if device.version >= 3, let session {
      return await provisionV3(device, cloud: cloud, session: session)
    } else {
      return await provisionV2(device).map(Outcome.provisioned) ?? .failed
    }
  }

  /// Verify a version-2 device over its keyless transport, returning credentials
  /// only if it answers a local query. V2 needs no cloud token.
  private static func provisionV2(_ device: DiscoveredDevice) async -> DeviceCredentials? {
    let client = MideaClient(
      host: device.ip, port: device.port, deviceId: device.id,
      version: device.version, token: [], key: [])
    do {
      _ = try await client.refresh()
      await client.disconnect()
      return DeviceCredentials(
        name: device.name, id: device.id, ip: device.ip, port: device.port,
        version: device.version, token: [], key: [], serialNumber: device.serialNumber)
    } catch {
      await client.disconnect()
      return nil
    }
  }

  /// Fetch a version-3 device's token/key from the cloud and verify it with a
  /// local query. The cloud key is looked up by a udpid derived from the device
  /// id; try both byte orders and keep the first pair that works.
  private static func provisionV3(
    _ device: DiscoveredDevice, cloud: SmartHomeCloud, session: SmartHomeSession
  ) async -> Outcome {
    var notOwned = false
    for bigEndian in [false, true] {
      let pair: (token: [UInt8], key: [UInt8])
      do {
        pair = try await cloud.getToken(session, deviceId: device.id, bigEndian: bigEndian)
      } catch CloudError.notDeviceOwner {
        notOwned = true
        continue
      } catch {
        continue
      }
      let credentials = DeviceCredentials(
        name: device.name, id: device.id, ip: device.ip, port: device.port,
        version: device.version, token: pair.token, key: pair.key,
        serialNumber: device.serialNumber)
      let client = MideaClient(credentials: credentials)
      do {
        _ = try await client.refresh()
        await client.disconnect()
        return .provisioned(credentials)
      } catch {
        await client.disconnect()
        continue
      }
    }
    return notOwned ? .notOwned : .failed
  }
}
