import Foundation
import Testing

@testable import MideaKit

/// Reference vectors computed with msmart's `SmartHomeCloud` formulas.
@Suite struct SmartHomeCloudTests {
  @Test func signMatchesReference() {
    let body = Data(#"{"appId":"1010","loginAccount":"user@example.com"}"#.utf8)
    #expect(
      SmartHomeCloud.sign(body, random: "00112233445566778899aabbccddeeff")
        == "a7000535dd05fe33660ff3b19774af222021ce0e99a2e65ba3a1055e5981aa48")
  }

  @Test func encryptedPasswordMatchesReference() {
    #expect(
      SmartHomeCloud.encryptedPassword(loginId: "d1c6a1c0c7b2d4f6", password: "hunter2")
        == "29bed488e8211e2d8524b272f0406fbae0e04a25ba1d75e91dd47b7f542aa781")
  }

  @Test func iamPasswordMatchesReference() {
    #expect(
      SmartHomeCloud.iamPassword(loginId: "d1c6a1c0c7b2d4f6", password: "hunter2")
        == "061ef8c952d6792901cfc5d11d49f512c71543392f824d8b229108b8b403fd37")
  }

  @Test func notDeviceOwnerReportsCloudCode() {
    #expect(CloudError.notDeviceOwner(message: "You have no permissions").code == 3201)
  }
}
