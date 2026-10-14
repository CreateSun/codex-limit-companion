import AppKit
import CryptoKit
import SwiftUI

struct ReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        self.parts = parts.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int
        let digest: String?
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    func updateAsset(current: String) throws -> Asset? {
        guard !draft, !prerelease, let latest = ReleaseVersion(version), let installed = ReleaseVersion(current) else {
            throw UpdateFailure("发布版本格式无效。")
        }
        guard latest > installed else { return nil }
        let expected = "CodexLimitCompanion-\(version)-macos-arm64.zip"
        guard let asset = assets.first(where: { $0.name == expected }),
              asset.size > 0, asset.size <= 100_000_000,
              asset.browser_download_url.absoluteString == "https://github.com/CreateSun/codex-limit-companion/releases/download/\(tag_name)/\(expected)",
              let digest = asset.digest, digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw UpdateFailure("新版缺少可校验的 Apple Silicon 安装包，请到 GitHub 手动下载。")
        }
        return asset
    }
}

struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum UpdatePackage {
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure("安装包校验失败：" + (String(data: output, encoding: .utf8) ?? "未知错误")) }
        return String(data: output, encoding: .utf8) ?? ""
    }
    static func validateArchivePaths(_ paths: [String]) throws {
        guard !paths.isEmpty, paths.allSatisfy({ path in
            !path.hasPrefix("/") && !path.split(separator: "/").contains("..") &&
            (path.hasPrefix("CodexLimitCompanion.app/") || path.hasPrefix("__MACOSX/"))
        }) else { throw UpdateFailure("安装包目录结构无效。") }
    }
    static func prepare(archive: URL, asset: GitHubRelease.Asset, version: String, directory: URL) throws -> URL {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == asset.size, digest.lowercased() == asset.digest?.lowercased() else { throw UpdateFailure("下载校验不匹配，请重新下载。") }
        let paths = try run("/usr/bin/unzip", ["-Z1", archive.path]).split(separator: "\n").map(String.init)
        try validateArchivePaths(paths)
        let extracted = directory.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        let app = extracted.appendingPathComponent("CodexLimitCompanion.app")
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == "local.codex.limit-companion",
              info?["CFBundleShortVersionString"] as? String == version,
              info?["CFBundleExecutable"] as? String == "CodexLimitCompanion" else { throw UpdateFailure("安装包身份或版本不匹配。") }
        if let minimum = info?["LSMinimumSystemVersion"] as? String {
            let parts = minimum.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == parts.count, (1...3).contains(numbers.count), numbers.allSatisfy({ $0 >= 0 }) else { throw UpdateFailure("安装包系统版本要求无效。") }
            let os = OperatingSystemVersion(majorVersion: numbers[0], minorVersion: numbers.count > 1 ? numbers[1] : 0, patchVersion: numbers.count > 2 ? numbers[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(os) else { throw UpdateFailure("新版需要 macOS \(minimum) 或更高版本。") }
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        _ = try run("/usr/bin/lipo", [app.appendingPathComponent("Contents/MacOS/CodexLimitCompanion").path, "-verify_arch", "arm64"])
        return app
    }
    // Arguments, never interpolated shell source. Old app is retained until the replacement opens.
    static let installer = #"""
    set -eu
    candidate="$1"
    target="$2"
    old_pid="$3"
    incoming="${target}.incoming-$old_pid"
    backup="${target}.previous-$old_pid"
    log="$4"
    exec >> "$log" 2>&1
    rollback() {
      if [ -d "$backup" ]; then
        /bin/rm -rf "$target"
        /bin/mv "$backup" "$target"
      fi
      /bin/rm -rf "$incoming"
      /usr/bin/open "$target" || true
    }
    [ ! -e "$incoming" ] && [ ! -e "$backup" ]
    trap rollback EXIT
    count=0
    while /bin/kill -0 "$old_pid" 2>/dev/null; do
      count=$((count + 1))
      [ "$count" -lt 30 ] || exit 1
      /bin/sleep 1
    done
    /usr/bin/codesign --verify --deep --strict "$candidate"
    /usr/bin/ditto "$candidate" "$incoming"
    /usr/bin/codesign --verify --deep --strict "$incoming"
    /bin/mv "$target" "$backup"
    /bin/mv "$incoming" "$target"
    /usr/bin/open "$target"
    trap - EXIT
    /bin/rm -rf "$backup"
    echo 'Update installed and launch requested.'
    """#
}

@MainActor
final class AppUpdater: ObservableObject {
    static let releasesURL = URL(string: "https://github.com/CreateSun/codex-limit-companion/releases")!
    @Published private(set) var release: GitHubRelease?
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var preparedApp: URL?
    @Published var automaticallyDownload = UserDefaults.standard.bool(forKey: "automaticallyDownloadUpdates") {
        didSet {
            UserDefaults.standard.set(automaticallyDownload, forKey: "automaticallyDownloadUpdates")
            if automaticallyDownload, release != nil, !busy { download() }
        }
    }
    var canInstall: () -> Bool = { true }
    let installedVersion: String
    private var asset: GitHubRelease.Asset?
    private var directory: URL?
    private var timer: Timer?
    private var lastAutomaticAttempt: String?
    init(installedVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.4") {
        self.installedVersion = installedVersion
    }
    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }
    func check() {
        guard !busy else { return }
        // Keep a verified pending update available instead of discarding it on another check.
        guard preparedApp == nil else { status = "新版已下载，等待确认安装"; return }
        busy = true; error = nil; status = "正在检查更新…"
        Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/CreateSun/codex-limit-companion/releases/latest")!)
                request.timeoutInterval = 30
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("CodexLimitCompanion/\(installedVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure("暂时无法检查 GitHub 更新，请稍后重试。") }
                let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)
                #if arch(arm64)
                let candidate = try latest.updateAsset(current: installedVersion)
                asset = candidate; release = candidate == nil ? nil : latest
                status = candidate == nil ? "当前已是最新版本 \(installedVersion)" : "发现新版本 \(latest.version)"
                #else
                status = "Intel Mac 请从源码更新"; release = nil; asset = nil
                #endif
            } catch { self.error = error.localizedDescription; status = "检查更新失败" }
            busy = false
            if automaticallyDownload, let release, lastAutomaticAttempt != release.tag_name {
                lastAutomaticAttempt = release.tag_name
                download()
            }
        }
    }
    func download() {
        guard !busy, let asset, let release else { return }
        if preparedApp != nil { confirmInstallation(); return }
        busy = true; error = nil; status = "正在下载 \(release.version)…"
        Task {
            do {
                let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("CodexLimitCompanion/Updates")
                let work = root.appendingPathComponent(UUID().uuidString)
                directory = work
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                var request = URLRequest(url: asset.browser_download_url)
                request.timeoutInterval = 120
                let (temporary, response) = try await URLSession.shared.download(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure("下载失败，请稍后重试。") }
                let archive = work.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: temporary, to: archive)
                status = "正在校验安装包…"
                let version = release.version
                preparedApp = try await Task.detached(priority: .utility) {
                    try UpdatePackage.prepare(archive: archive, asset: asset, version: version, directory: work)
                }.value
                status = "\(version) 已下载，等待确认安装"
                busy = false
                confirmInstallation()
            } catch {
                self.error = error.localizedDescription; status = "下载或校验失败"; busy = false
                if let directory { try? FileManager.default.removeItem(at: directory) }
                directory = nil; preparedApp = nil
            }
        }
    }
    func confirmInstallation() {
        guard let candidate = preparedApp, let release, let directory else { return }
        let alert = NSAlert()
        alert.messageText = "安装 Codex Limit Companion \(release.version)？"
        alert.informativeText = "安装包已通过 SHA-256、应用身份和签名完整性校验。确认后将退出并替换当前应用，然后重新启动；设置与恢复日志会保留。此发行包为临时签名，未经 Apple 公证。"
        alert.addButton(withTitle: "安装并重新启动")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            guard canInstall() else { throw UpdateFailure("会话消息仍在发送，请等待完成后再安装。") }
            let target = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            let parent = target.deletingLastPathComponent()
            let allowed = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            guard target.lastPathComponent == "CodexLimitCompanion.app", allowed.contains(parent),
                  FileManager.default.isWritableFile(atPath: parent.path) else {
                throw UpdateFailure("请先将应用安装到可写的 Applications 文件夹，或在 GitHub 下载后手动替换。")
            }
            let script = directory.appendingPathComponent("install.sh")
            try UpdatePackage.installer.write(to: script, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/zsh")
            helper.arguments = [script.path, candidate.path, target.path, String(ProcessInfo.processInfo.processIdentifier), directory.appendingPathComponent("install.log").path]
            try helper.run()
            NSApp.terminate(nil)
        } catch { self.error = error.localizedDescription }
    }
}

struct UpdateBanner: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        if let release = updater.release {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新版本 \(release.version)").font(.system(size: 11, weight: .semibold))
                    Text(updater.error ?? updater.status).font(.system(size: 9)).foregroundStyle(updater.error == nil ? Color.secondary : .orange).lineLimit(2)
                }
                Spacer()
                Button(updater.preparedApp == nil ? "下载" : "安装") { updater.download() }.disabled(updater.busy)
                if updater.busy { ProgressView().controlSize(.small) }
            }.padding(10).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 20).padding(.bottom, 12)
        }
    }
}

struct UpdateSettings: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("软件更新 · \(updater.installedVersion)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("检查更新") { updater.check() }.disabled(updater.busy)
            }
            Toggle("自动下载新版本", isOn: $updater.automaticallyDownload)
            Text("启动及每 6 小时检查；自动下载默认关闭，安装始终需要确认。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(updater.error ?? updater.status).font(.system(size: 10)).foregroundStyle(updater.error == nil ? Color.secondary : .orange)
            Button("在 GitHub 查看版本") { NSWorkspace.shared.open(AppUpdater.releasesURL) }.font(.system(size: 10))
        }.font(.system(size: 11)).padding(14)
    }
}
