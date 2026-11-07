import Foundation

/// An error from Midea's SmartHome cloud.
///
/// The cases separate the failures an app reports differently: a rejected sign-in
/// (``loginRejected(code:message:)``) versus a device that isn't registered to the
/// signed-in account (``notDeviceOwner(message:)``).
public enum CloudError: Error, CustomStringConvertible, Sendable {
  /// The cloud rejected the sign-in, typically a wrong email or password.
  case loginRejected(code: Int, message: String)
  /// The device isn't registered to the signed-in account (cloud code 3201).
  case notDeviceOwner(message: String)
  /// The cloud answered with any other error code.
  case api(code: Int, message: String)
  /// The response was malformed or lacked an expected field.
  case invalidResponse(String)
  /// The cloud answered without a token/key for the device.
  case keyNotFound(udpid: String)

  /// The cloud's numeric error code, if it returned one.
  public var code: Int? {
    switch self {
    case .loginRejected(let code, _), .api(let code, _): code
    case .notDeviceOwner: SmartHomeCloud.notOwnerCode
    case .invalidResponse, .keyNotFound: nil
    }
  }

  /// A textual representation of the failure.
  public var description: String {
    switch self {
    case .loginRejected(let code, let message): "CloudError.loginRejected(\(code)): \(message)"
    case .notDeviceOwner(let message): "CloudError.notDeviceOwner: \(message)"
    case .api(let code, let message): "CloudError.api(\(code)): \(message)"
    case .invalidResponse(let message): "CloudError.invalidResponse: \(message)"
    case .keyNotFound(let udpid): "CloudError.keyNotFound: no token/key for udpid \(udpid)"
    }
  }
}

/// Compute the "udpid" the cloud uses to look up a device's token/key.
enum UDPID {
  /// Derive the udpid for a device. The byte order isn't known in advance, so
  /// setup tries both values and keeps whichever authenticates.
  ///
  /// - Parameters:
  ///   - deviceId: The device's numeric id.
  ///   - bigEndian: Whether to encode `deviceId` big-endian before hashing.
  /// - Returns: The hex-encoded udpid used to look up the device's keys.
  static func compute(deviceId: UInt64, bigEndian: Bool) -> String {
    var bytes = [UInt8]()
    var value = deviceId
    for _ in 0..<6 {
      bytes.append(UInt8(value & 0xFF))
      value >>= 8
    }
    if bigEndian { bytes.reverse() }
    let hash = Crypto.sha256(bytes)
    let folded = (0..<16).map { hash[$0] ^ hash[$0 + 16] }
    return DeviceCredentials.bytesToHex(folded)
  }
}
