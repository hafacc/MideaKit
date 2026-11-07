import Foundation

/// Credentials and addressing for one device.
///
/// During setup the app discovers these and fetches the token/key from the
/// cloud, then persists them (they're `Codable`) and reuses them for all
/// subsequent local control. The token and key are encoded as hex strings, and
/// decoding fails if either isn't valid hex.
public struct DeviceCredentials: Codable, Sendable {
  /// The device's advertised name.
  public let name: String
  /// The device's numeric id.
  public let id: UInt64
  /// The device's IPv4 address.
  public let ip: String
  /// The device's control port.
  public let port: UInt16
  /// The LAN protocol version (2 or 3).
  public let version: Int
  /// The authentication token (empty for V2 devices).
  public let token: [UInt8]
  /// The session key (empty for V2 devices).
  public let key: [UInt8]
  /// The device's serial number, from discovery; `nil` if it didn't report one.
  public let serialNumber: String?

  private enum CodingKeys: String, CodingKey {
    case name, id, ip, port, version, token, key, serialNumber
  }

  /// Create credentials from their stored fields.
  ///
  /// - Parameters:
  ///   - name: The device's advertised name.
  ///   - id: The device's numeric id.
  ///   - ip: The device's IPv4 address.
  ///   - port: The device's control port.
  ///   - version: The LAN protocol version (2 or 3).
  ///   - token: The authentication token.
  ///   - key: The session key.
  ///   - serialNumber: The device's serial number, or `nil` if it didn't report one.
  public init(
    name: String, id: UInt64, ip: String, port: UInt16,
    version: Int, token: [UInt8], key: [UInt8], serialNumber: String?
  ) {
    self.name = name
    self.id = id
    self.ip = ip
    self.port = port
    self.version = version
    self.token = token
    self.key = key
    self.serialNumber = serialNumber
  }

  /// Create credentials for a device found by ``Discovery``.
  ///
  /// - Parameters:
  ///   - device: The device, as discovered.
  ///   - token: The authentication token (empty for V2 devices).
  ///   - key: The session key (empty for V2 devices).
  public init(device: DiscoveredDevice, token: [UInt8] = [], key: [UInt8] = []) {
    self.init(
      name: device.name, id: device.id, ip: device.ip, port: device.port,
      version: device.version, token: token, key: key, serialNumber: device.serialNumber)
  }

  /// Decode credentials, rejecting a token or key that isn't valid hex.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    id = try container.decode(UInt64.self, forKey: .id)
    ip = try container.decode(String.self, forKey: .ip)
    port = try container.decode(UInt16.self, forKey: .port)
    version = try container.decode(Int.self, forKey: .version)
    token = try Self.decodeHex(container, forKey: .token)
    key = try Self.decodeHex(container, forKey: .key)
    serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber)
  }

  /// Encode credentials with the token and key as hex strings.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(id, forKey: .id)
    try container.encode(ip, forKey: .ip)
    try container.encode(port, forKey: .port)
    try container.encode(version, forKey: .version)
    try container.encode(Hex.encode(token), forKey: .token)
    try container.encode(Hex.encode(key), forKey: .key)
    try container.encodeIfPresent(serialNumber, forKey: .serialNumber)
  }

  private static func decodeHex(
    _ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
  ) throws -> [UInt8] {
    guard let bytes = Hex.decode(try container.decode(String.self, forKey: key)) else {
      throw DecodingError.dataCorruptedError(
        forKey: key, in: container, debugDescription: "Not an even-length hex string")
    }
    return bytes
  }
}

/// Lowercase hex encoding, two characters per byte.
enum Hex {
  private static let digits = Array("0123456789abcdef".utf8)

  static func encode(_ bytes: [UInt8]) -> String {
    var characters = [UInt8]()
    characters.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      characters.append(digits[Int(byte >> 4)])
      characters.append(digits[Int(byte & 0xF)])
    }
    return String(decoding: characters, as: UTF8.self)
  }

  /// Decode hex in either case, or `nil` for an odd length or a non-hex character.
  static func decode(_ string: String) -> [UInt8]? {
    let characters = Array(string.utf8)
    guard characters.count.isMultiple(of: 2) else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(characters.count / 2)
    for index in stride(from: 0, to: characters.count, by: 2) {
      guard let high = nibble(characters[index]), let low = nibble(characters[index + 1])
      else { return nil }
      bytes.append(high << 4 | low)
    }
    return bytes
  }

  private static func nibble(_ character: UInt8) -> UInt8? {
    switch character {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
    default: nil
    }
  }
}

extension MideaClient {
  /// Create a client from stored ``DeviceCredentials``.
  ///
  /// - Parameter credentials: The stored credentials for one device.
  public init(credentials: DeviceCredentials) {
    self.init(
      host: credentials.ip, port: credentials.port, deviceId: credentials.id,
      version: credentials.version, token: credentials.token, key: credentials.key
    )
  }
}
