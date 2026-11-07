import Testing

@testable import MideaKit

@Suite struct SetupTests {
  private let device = DiscoveredDevice(
    id: 1, ip: "10.0.0.7", port: 6444, version: 3, name: "ac", serialNumber: nil)

  private func failure(_ error: any Error) -> Result<DeviceCredentials, SetupFailure> {
    .failure(SetupFailure(device: device, error: error))
  }

  /// One device set up is a success, whatever happened to the others.
  @Test func returnsCredentialsDespiteOtherFailures() throws {
    let credentials = DeviceCredentials(
      name: "ac", id: 2, ip: "10.0.0.8", port: 6444, version: 2, token: [], key: [],
      serialNumber: nil)

    let results = try Setup.collect([.success(credentials), failure(TimeoutError())])

    #expect(results.map(\.id) == [2])
  }

  /// A device outside the account is reported as such, with every device's reason.
  @Test func reportsNotInAccount() {
    #expect {
      try Setup.collect([
        failure(TimeoutError()), failure(CloudError.notDeviceOwner(message: "no")),
      ])
    } throws: { error in
      guard case SetupError.notInAccount(let failures) = error else { return false }
      return failures.count == 2
    }
  }

  /// Without an ownership problem, the failures come back for the app to show.
  @Test func reportsEachFailure() {
    #expect {
      try Setup.collect([failure(HandshakeError.rejected)])
    } throws: { error in
      guard case SetupError.noCredentialsObtained(let failures) = error,
        case HandshakeError.rejected = failures[0].error
      else { return false }
      return failures[0].device.id == 1
    }
  }

  /// A version-3 device can't get a key without a cloud session.
  @Test func versionThreeNeedsASession() async {
    await #expect {
      try await Setup.credentials(for: device, session: nil)
    } throws: { error in
      if case SetupError.accountRequired = error { true } else { false }
    }
  }
}
