import Foundation
import Testing
@testable import PageKit

@Suite(.watchdog) struct PrivacyManifestTests {
    private func manifest() throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test func declaresFileTimestampsForTheAppsOwnFiles() throws {
        let accessed = try #require(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])

        #expect(accessed.count == 1)
        #expect(accessed.first?["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryFileTimestamp")
        #expect(accessed.first?["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["C617.1"])
    }

    @Test func declaresNoTrackingAndNoCollectedData() throws {
        let manifest = try manifest()

        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.isEmpty == true)
    }
}
