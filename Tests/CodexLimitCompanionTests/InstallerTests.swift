import XCTest
@testable import CodexLimitCompanion

final class InstallerTests: XCTestCase {
    private func exerciseInstaller(openFails: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update test " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent("candidate.app")
        let target = root.appendingPathComponent("installed.app")
        try FileManager.default.createDirectory(at: candidate.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: candidate.appendingPathComponent("Contents/MacOS/Fixture"))
        let info: [String: Any] = ["CFBundleIdentifier": "local.companion.update-test", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: candidate.appendingPathComponent("Contents/Info.plist"))
        _ = try UpdatePackage.run("/usr/bin/codesign", ["--force", "--sign", "-", candidate.path])
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: target.appendingPathComponent("original.txt"))
        // Stub only the UI launch, to exercise real copy/rename/rollback without launching apps.
        let opener = openFails ? "/usr/bin/false" : "/usr/bin/true"
        let script = root.appendingPathComponent("install.sh")
        try UpdatePackage.installer.replacingOccurrences(of: "/usr/bin/open", with: opener).write(to: script, atomically: true, encoding: .utf8)
        let arguments = [script.path, candidate.path, target.path, "99999999", root.appendingPathComponent("install.log").path]
        if openFails {
            XCTAssertThrowsError(try UpdatePackage.run("/bin/zsh", arguments))
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("original.txt")), "original")
        } else {
            _ = try UpdatePackage.run("/bin/zsh", arguments)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/MacOS/Fixture").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("original.txt").path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".previous-99999999"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".incoming-99999999"))
    }
    func testConfirmedInstallerReplacesOnlyFixture() throws { try exerciseInstaller(openFails: false) }
    func testLaunchFailureRestoresOriginalFixture() throws { try exerciseInstaller(openFails: true) }

    func testActualPublishedArchiveValidationWhenEnabled() throws {
        guard let path = ProcessInfo.processInfo.environment["COMPANION_UPDATE_ARCHIVE"] else { throw XCTSkip("Optional published archive integration check") }
        let archive = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: archive)
        // Published v0.0.3 GitHub asset digest, verified at release time.
        let asset = GitHubRelease.Asset(name: archive.lastPathComponent, browser_download_url: URL(string: "https://github.com/CreateSun/codex-limit-companion/releases/download/v0.0.3/CodexLimitCompanion-0.0.3-macos-arm64.zip")!, size: data.count, digest: "sha256:9d1851f6e312785c3126528bd7560202a48d8635cd43183f490f52342af658fd")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try UpdatePackage.prepare(archive: archive, asset: asset, version: "0.0.3", directory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/CodexLimitCompanion").path))
    }
}
