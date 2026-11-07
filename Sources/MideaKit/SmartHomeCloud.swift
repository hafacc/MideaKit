import CryptoKit
import Foundation

/// An authenticated SmartHome session.
///
/// Returned by ``SmartHomeCloud/login()`` and passed to ``Setup``. It is immutable,
/// so a single session can serve many devices at once.
public struct SmartHomeSession: Sendable {
  let cloud: SmartHomeCloud
  let accessToken: String
}

/// Minimal client for Midea's SmartHome cloud (the MSmartHome app's backend).
///
/// It does just enough to fetch a device's token/key, and is ported from msmart's
/// `SmartHomeCloud`. The cloud only hands out keys for devices registered to the
/// signed-in account, so sign in with the account the device was added to in the
/// MSmartHome app.
///
/// Stateless after construction (the session lives in ``SmartHomeSession``), so it is
/// `Sendable` and safe to share across tasks.
///
/// ```swift
/// let cloud = SmartHomeCloud(account: "you@example.com", password: "pw")
/// let session = try await cloud.login()
/// ```
public final class SmartHomeCloud: Sendable {
  private static let baseURL = "https://mp-prod.appsmb.com"
  private static let appId = "1010"
  private static let hmacKey = "PROD_VnoClJI9aikS8dyy"
  private static let iotKey = "meicloud"
  private static let loginKey = "ac21b9f9cbfe4ca5a88562ef25e2b768"
  static let notOwnerCode = 3201

  private let account: String
  private let password: String
  private let deviceId: String

  /// Create a client for the account the device is registered to.
  ///
  /// - Parameters:
  ///   - account: The MSmartHome account email.
  ///   - password: The MSmartHome account password.
  public init(account: String, password: String) {
    self.account = account
    self.password = password
    self.deviceId = Self.randomHex(byteCount: 8)
  }

  /// Sign in and return a session to pass to ``Setup``.
  ///
  /// - Returns: An authenticated ``SmartHomeSession``.
  /// - Throws: ``CloudError/loginRejected(code:message:)`` if the cloud rejects the
  ///   email or password, another ``CloudError`` for a malformed response, or a
  ///   `URLError` if the cloud can't be reached.
  public func login() async throws -> SmartHomeSession {
    do {
      let loginIdResult = try await apiRequest(
        "/v1/user/login/id/get", body(["loginAccount": account]), accessToken: "")
      guard let loginId = loginIdResult["loginId"] as? String else {
        throw CloudError.invalidResponse("No loginId in response")
      }
      let loginBody: [String: Any] = [
        "data": ["platform": 2, "deviceId": deviceId],
        "iotData": [
          "appId": Self.appId,
          "src": Self.appId,
          "clientType": 1,
          "loginAccount": account,
          "iampwd": Self.iamPassword(loginId: loginId, password: password),
          "password": Self.encryptedPassword(loginId: loginId, password: password),
          "pushToken": Self.randomHex(byteCount: 90),
          "stamp": Self.timestamp(),
          "reqId": Self.randomHex(byteCount: 16),
        ],
      ]
      let result = try await apiRequest("/mj/user/login", loginBody, accessToken: "")
      guard let mdata = result["mdata"] as? [String: Any],
        let accessToken = mdata["accessToken"] as? String
      else {
        throw CloudError.invalidResponse("No accessToken in login response")
      }
      return SmartHomeSession(cloud: self, accessToken: accessToken)
    } catch CloudError.api(let code, let message) {
      throw CloudError.loginRejected(code: code, message: message)
    }
  }

  /// Fetch the token/key pair, hex-encoded, the cloud files under one byte order of
  /// `deviceId`.
  func getToken(_ session: SmartHomeSession, deviceId: UInt64, bigEndian: Bool)
    async throws -> (token: String, key: String)
  {
    let udpid = UDPID.compute(deviceId: deviceId, bigEndian: bigEndian)
    let result: [String: Any]
    do {
      result = try await apiRequest(
        "/v1/iot/secure/getToken",
        body(["udpid": udpid, "applianceCodes": String(deviceId)]),
        accessToken: session.accessToken)
    } catch CloudError.api(Self.notOwnerCode, let message) {
      throw CloudError.notDeviceOwner(message: message)
    }
    guard let list = result["tokenlist"] as? [[String: Any]] else {
      throw CloudError.invalidResponse("No tokenlist in response")
    }
    for entry in list where (entry["udpId"] as? String) == udpid {
      if let token = entry["token"] as? String, let key = entry["key"] as? String {
        return (token, key)
      }
    }
    throw CloudError.keyNotFound(udpid: udpid)
  }

  private func body(_ data: [String: Any]) -> [String: Any] {
    var body: [String: Any] = [
      "appId": Self.appId,
      "src": Self.appId,
      "format": 2,
      "clientType": 1,
      "language": "en_US",
      "deviceId": deviceId,
      "stamp": Self.timestamp(),
      "reqId": Self.randomHex(byteCount: 16),
    ]
    body.merge(data) { _, new in new }
    return body
  }

  private func apiRequest(_ endpoint: String, _ body: [String: Any], accessToken: String)
    async throws -> [String: Any]
  {
    let contents = try JSONSerialization.data(withJSONObject: body)
    let random = Self.randomHex(byteCount: 16)
    var request = URLRequest(
      url: URL(string: Self.baseURL + "/mas/v5/app/proxy?alias=" + endpoint)!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "secretVersion")
    request.setValue(Self.sign(contents, random: random), forHTTPHeaderField: "sign")
    request.setValue(random, forHTTPHeaderField: "random")
    request.setValue(accessToken, forHTTPHeaderField: "accessToken")
    request.httpBody = contents
    request.timeoutInterval = 10

    let (responseData, _) = try await URLSession.shared.data(for: request)
    guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    else {
      throw CloudError.invalidResponse("Invalid JSON response")
    }
    let codeValue = json["code"]
    guard let code = (codeValue as? String).flatMap({ Int($0) }) ?? (codeValue as? Int) else {
      throw CloudError.invalidResponse("No code in response")
    }
    if code == 0 {
      return (json["data"] as? [String: Any]) ?? [:]
    } else {
      throw CloudError.api(code: code, message: (json["msg"] as? String) ?? "Unknown cloud error")
    }
  }

  /// Sign a request body: hex HMAC-SHA256 over iotKey + body + random.
  static func sign(_ contents: Data, random: String) -> String {
    let message = Data(iotKey.utf8) + contents + Data(random.utf8)
    let mac = HMAC<SHA256>.authenticationCode(
      for: message, using: SymmetricKey(data: Data(hmacKey.utf8)))
    return DeviceCredentials.bytesToHex(Array(mac))
  }

  /// Hash the password for the login's `password` field.
  static func encryptedPassword(loginId: String, password: String) -> String {
    hexSHA256(loginId + hexSHA256(password) + loginKey)
  }

  /// Hash the password for the login's `iampwd` field.
  static func iamPassword(loginId: String, password: String) -> String {
    hexSHA256(loginId + hexMD5(hexMD5(password)) + loginKey)
  }

  private static func hexSHA256(_ string: String) -> String {
    DeviceCredentials.bytesToHex(Crypto.sha256(Array(string.utf8)))
  }

  private static func hexMD5(_ string: String) -> String {
    DeviceCredentials.bytesToHex(Crypto.md5(Array(string.utf8)))
  }

  private static func randomHex(byteCount: Int) -> String {
    DeviceCredentials.bytesToHex((0..<byteCount).map { _ in UInt8.random(in: 0...255) })
  }

  // Built once and reused instead of per request.
  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMddHHmmss"
    return formatter
  }()

  private static func timestamp() -> String {
    timestampFormatter.string(from: Date())
  }
}
