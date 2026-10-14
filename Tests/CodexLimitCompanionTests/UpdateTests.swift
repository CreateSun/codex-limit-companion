import XCTest
@testable import CodexLimitCompanion

final class UpdateTests: XCTestCase {
    private func release(_ version: String = "0.0.5", digest: String? = "sha256:" + String(repeating: "a", count: 64), url: String? = nil) -> GitHubRelease {
        GitHubRelease(tag_name: "v" + version, draft: false, prerelease: false, assets: [
            .init(name: "CodexLimitCompanion-\(version)-macos-arm64.zip", browser_download_url: URL(string: url ?? "https://github.com/CreateSun/codex-limit-companion/releases/download/v\(version)/CodexLimitCompanion-\(version)-macos-arm64.zip")!, size: 1000, digest: digest)
        ])
    }
    func testVersionOrderingDoesNotDowngradeOrAcceptPrereleaseSyntax() throws {
        XCTAssertTrue(ReleaseVersion("0.0.10")! > ReleaseVersion("v0.0.9")!)
        XCTAssertNil(ReleaseVersion("0.0.5-beta"))
        XCTAssertNil(ReleaseVersion("1.2"))
        XCTAssertNil(try release("0.0.3").updateAsset(current: "0.0.4"))
        XCTAssertNil(try release("0.0.4").updateAsset(current: "0.0.4"))
        XCTAssertNotNil(try release().updateAsset(current: "0.0.4"))
    }
    func testOnlyOfficialChecksummedPackageAccepted() {
        XCTAssertThrowsError(try release(digest: nil).updateAsset(current: "0.0.4"))
        XCTAssertThrowsError(try release(digest: "sha256:bad").updateAsset(current: "0.0.4"))
        XCTAssertThrowsError(try release(url: "https://example.com/update.zip").updateAsset(current: "0.0.4"))
        XCTAssertThrowsError(try release(url: "http://github.com/CreateSun/codex-limit-companion/releases/download/v0.0.5/CodexLimitCompanion-0.0.5-macos-arm64.zip").updateAsset(current: "0.0.4"))
    }
    func testArchiveTraversalAndUnexpectedRootsRejected() throws {
        try UpdatePackage.validateArchivePaths(["CodexLimitCompanion.app/Contents/Info.plist", "__MACOSX/CodexLimitCompanion.app/._Contents"])
        for path in ["/Applications/bad", "CodexLimitCompanion.app/../../bad", "other.app/Contents/Info.plist"] {
            XCTAssertThrowsError(try UpdatePackage.validateArchivePaths([path]))
        }
    }
    func testCorruptDownloadRejectedBeforeExtraction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("bad.zip")
        try Data("broken".utf8).write(to: archive)
        XCTAssertThrowsError(try UpdatePackage.prepare(archive: archive, asset: release().assets[0], version: "0.0.5", directory: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("extracted").path))
    }
}
