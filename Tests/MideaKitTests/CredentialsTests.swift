import Foundation
import Testing

@testable import MideaKit

@Suite struct CredentialsTests {
  /// Credentials persisted before `serialNumber` existed must still decode, with the
  /// serial reported as absent rather than failing the whole load.
  @Test func decodesJSONPersistedWithoutSerialNumber() throws {
    let json = """
      {"name":"ac","id":1234,"ip":"10.0.0.7","port":6444,"version":3,
       "token":"aabb","key":"ccdd"}
      """
    let credentials = try JSONDecoder().decode(
      DeviceCredentials.self, from: Data(json.utf8))

    #expect(credentials.serialNumber == nil)
    #expect(credentials.name == "ac")
    #expect(credentials.token == [0xAA, 0xBB])
  }

  /// An absent serial round-trips as absent — it must not come back as `""`.
  @Test func roundTripsAbsentSerialNumber() throws {
    let original = DeviceCredentials(
      name: "ac", id: 1234, ip: "10.0.0.7", port: 6444,
      version: 3, token: [0xAA, 0xBB], key: [0xCC, 0xDD], serialNumber: nil)
    let decoded = try JSONDecoder().decode(
      DeviceCredentials.self, from: try JSONEncoder().encode(original))

    #expect(decoded.serialNumber == nil)
  }

  @Test func roundTripsPresentSerialNumber() throws {
    let original = DeviceCredentials(
      name: "ac", id: 1234, ip: "10.0.0.7", port: 6444,
      version: 3, token: [0xAA, 0xBB], key: [0xCC, 0xDD], serialNumber: "ABC123")
    let decoded = try JSONDecoder().decode(
      DeviceCredentials.self, from: try JSONEncoder().encode(original))

    #expect(decoded.serialNumber == "ABC123")
  }

  /// Saved credentials keep the token and key as hex, and a value that isn't hex
  /// fails the load rather than the handshake.
  @Test func savesHexAndRejectsMalformedHex() throws {
    let original = DeviceCredentials(
      name: "ac", id: 1, ip: "10.0.0.7", port: 6444,
      version: 3, token: [0xAA, 0xBB], key: [0xCC, 0xDD], serialNumber: nil)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
    let fields = try #require(object as? [String: Any])
    #expect(fields["token"] as? String == "aabb")
    #expect(fields["key"] as? String == "ccdd")

    for (token, key) in [("zz", "ccdd"), ("aabb", "ccd")] {
      let json = """
        {"name":"ac","id":1,"ip":"10.0.0.7","port":6444,"version":3,\
        "token":"\(token)","key":"\(key)"}
        """
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(DeviceCredentials.self, from: Data(json.utf8))
      }
    }
  }

  @Test func hexRoundTrips() {
    let bytes: [UInt8] = [0x00, 0x0F, 0xA5, 0xFF]
    #expect(Hex.encode(bytes) == "000fa5ff")
    #expect(Hex.decode("000FA5ff") == bytes)
  }
}
