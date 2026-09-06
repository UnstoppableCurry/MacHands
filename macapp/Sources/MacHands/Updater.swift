import AppKit
import CryptoKit
import MacHandsCore

/// 内置自动更新。
///
/// 为什么非做不可:0.1.0 → 0.2.0 是"下载新包、把 /Applications 里那个换掉"。
/// 每换一次,macOS 就把 MacHands 的 **屏幕录制** 与 **辅助功能** 授权清掉一次,
/// 用户得重勾,期间所有 agent 的截图和点按都在报错、而且报的错看不出是升级导致的。
/// 换成"App 自己在原路径上把自己换掉"之后,bundle id、路径、签名要求都不变,
/// 授权就有机会留住(签名换成 Developer ID + 公证之后才是真的稳)。
///
/// appcast 契约(`https://<host>/appcast.json`):
/// ```json
/// {"version":"0.3.0","build":30,"url":"https://…/MacHands-0.3.0.zip",
///  "sha256":"<hex>","sig":"<base64url>","notes_zh":"…","notes_en":"…",
///  "min_os":"13.0","published":"2026-09-06T12:00:00Z"}
/// ```
/// `sig` = 用**发布私钥**对 `sha256` 那串十六进制文本做的 Ed25519 签名。
/// 公钥内置在下面的 `releasePublicKey` 里 —— 公钥进仓库没问题,私钥**永远不进**,
/// 它只待在发布机的钥匙串里。发布脚本负责把占位串替换成真公钥。
final class Updater {

    static let shared = Updater()

    /// 发布公钥(base64url、Ed25519 raw)。占位值 = 还没接发布流程,
    /// 这时一切更新都会在验签这一步失败,**这是故意的**:宁可不更新,
    /// 也不要装一个没验过签的包。
    static let releasePublicKey = "WqKIYUVbJCuwbMN3CEYXVBm6HIk71m86oThMyuT0v2A"

    /// 启动后多久做第一次检查。让开机那阵子的 CPU 先给别人。
    static let firstCheckDelay: TimeInterval = 30
    static let checkInterval: TimeInterval = 6 * 3600
    static let downloadTimeout: TimeInterval = 120
    /// 换包要落两份(下载的 zip + 解出来的 .app),留够余量。
    static let minFreeBytes: Int64 = 200 * 1024 * 1024

    struct Release: Equatable {
        let version: String
        let build: Int
        let url: URL
        let sha256: String
        let sig: String
        let notes: String
        let minOS: String
    }

    enum Status: String {
        case upToDate = "up-to-date"
        case updating
        case failed
    }

    struct Outcome {
        let status: Status
        let current: String
        let latest: String?
        /// 失败时给人话原因;成功/无更新时是 nil。
        let reason: String?

        var json: JSONValue {
            var body: [String: JSONValue] = [
                "status": .string(status.rawValue),
                "current": .string(current)
            ]
            body["latest"] = latest.map { JSONValue.string($0) } ?? .null
            body["reason"] = reason.map { JSONValue.string($0) } ?? .null
            return .object(body)
        }
    }

    private let lock = NSLock()
    private var busy = false
    private var timer: Timer?
    /// 最近一次看到的新版本号,菜单栏状态行用。
    private var pendingVersion: String?

    /// 有新版本可装时通知界面刷新。
    var onFoundNewer: ((String) -> Void)?

    private init() {}

    var newerVersionAvailable: String? {
        lock.lock(); defer { lock.unlock() }
        return pendingVersion
    }

    var currentVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: - 定时

    /// AppDelegate 启动时调一次。关掉自动更新时只是不主动查,菜单里手动查照旧能用。
    func startScheduled() {
        guard SettingsStore.shared.current.autoUpdate else {
            Log.shared.write("auto-update is off; not scheduling checks")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Updater.firstCheckDelay) { [weak self] in
            self?.checkInBackground(installIfNewer: true)
        }
        let periodic = Timer(timeInterval: Updater.checkInterval, repeats: true) { [weak self] _ in
            guard SettingsStore.shared.current.autoUpdate else { return }
            self?.checkInBackground(installIfNewer: true)
        }
        RunLoop.main.add(periodic, forMode: .common)
        timer = periodic
    }

    func stopScheduled() {
        timer?.invalidate()
        timer = nil
    }

    /// 菜单「检查更新…」与定时器都走这里:不阻塞调用方。
    func checkInBackground(installIfNewer: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let outcome = self.runOnce(installIfNewer: installIfNewer)
            Log.shared.write("update check: \(outcome.status.rawValue)"
                             + (outcome.latest.map { " latest=\($0)" } ?? "")
                             + (outcome.reason.map { " — \($0)" } ?? ""))
        }
    }

    // MARK: - 一次完整的检查(阻塞,别在主线程调)

    @discardableResult
    func runOnce(installIfNewer: Bool) -> Outcome {
        let current = currentVersion

        lock.lock()
        if busy {
            lock.unlock()
            return Outcome(status: .updating, current: current, latest: pendingVersion,
                           reason: L("update.err.busy"))
        }
        busy = true
        lock.unlock()
        defer { lock.lock(); busy = false; lock.unlock() }

        SettingsStore.shared.update { $0.lastUpdateCheck = Date().timeIntervalSince1970 * 1000 }

        // 1. 取 appcast
        let release: Release
        switch fetchAppcast(timeout: 30) {
        case .failure(let reason):
            return Outcome(status: .failed, current: current, latest: nil, reason: reason)
        case .success(let value):
            release = value
        }

        guard Updater.isNewer(release.version, than: current) else {
            lock.lock(); pendingVersion = nil; lock.unlock()
            return Outcome(status: .upToDate, current: current, latest: release.version, reason: nil)
        }

        lock.lock(); pendingVersion = release.version; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onFoundNewer?(release.version) }

        guard installIfNewer else {
            return Outcome(status: .upToDate, current: current, latest: release.version, reason: nil)
        }

        // 2. 装得动吗(路径、翻译、磁盘)
        if let blocker = installBlocker() {
            return Outcome(status: .failed, current: current, latest: release.version, reason: blocker)
        }

        // 3. 下载 → 校验 → 解压 → 验签名 → 换包
        if let reason = downloadAndInstall(release) {
            return Outcome(status: .failed, current: current, latest: release.version, reason: reason)
        }
        return Outcome(status: .updating, current: current, latest: release.version, reason: nil)
    }

    // MARK: - 步骤

    private enum FetchResult {
        case success(Release)
        case failure(String)
    }

    private func appcastURL() -> URL? {
        var host = SettingsStore.shared.current.updateHost.trimmingCharacters(in: .whitespaces)
        while host.hasSuffix("/") { host.removeLast() }
        guard host.hasPrefix("https://") else { return nil }
        return URL(string: host + "/appcast.json")
    }

    /// 自检用:只问"appcast 拿得到吗"。不装、不改设置、不占 busy 锁,超时短。
    ///
    /// 为什么单独一条路:`verify.run` 是用户点了「授权并验证」在等的动作,
    /// 让它去等一个 30 秒的网络超时,等于把自检做成了"卡住"。
    func probe() -> (ok: Bool, detail: String) {
        switch fetchAppcast(timeout: 8) {
        case .failure(let reason):
            return (false, reason)
        case .success(let release):
            let current = currentVersion
            if Updater.isNewer(release.version, than: current) {
                return (true, Lf("update.alert.found", release.version))
            }
            return (true, Lf("update.alert.current", current))
        }
    }

    private func fetchAppcast(timeout: TimeInterval) -> FetchResult {
        guard let url = appcastURL() else {
            return .failure(L("update.err.host"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let box = LockedBox<(Data?, String?)>((nil, nil))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                box.value = (nil, error.localizedDescription)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                box.value = (nil, "HTTP \(http.statusCode)")
            } else {
                box.value = (data, nil)
            }
            done.signal()
        }.resume()

        if done.wait(timeout: .now() + timeout + 10) == .timedOut {
            return .failure(Lf("update.err.network", L("update.err.timeout")))
        }
        let (data, problem) = box.value
        if let problem = problem { return .failure(Lf("update.err.network", problem)) }
        guard let data = data, let root = JSONValue.parse(data)?.objectValue else {
            return .failure(L("update.err.badAppcast"))
        }
        guard let version = root["version"]?.stringValue,
              let urlText = root["url"]?.stringValue,
              let downloadURL = URL(string: urlText),
              let sha = root["sha256"]?.stringValue,
              let sig = root["sig"]?.stringValue else {
            return .failure(L("update.err.badAppcast"))
        }
        guard downloadURL.scheme?.lowercased() == "https" else {
            return .failure(L("update.err.notHTTPS"))
        }
        let lang = Strings.shared.lang == .zh ? "notes_zh" : "notes_en"
        let notes = root[lang]?.stringValue ?? root["notes_en"]?.stringValue ?? ""
        let minOS = root["min_os"]?.stringValue ?? "13.0"

        if !Updater.systemMeets(minOS) {
            return .failure(Lf("update.err.minOS", minOS))
        }
        return .success(Release(version: version,
                                build: root["build"]?.intValue ?? 0,
                                url: downloadURL,
                                sha256: sha.lowercased(),
                                sig: sig,
                                notes: notes,
                                minOS: minOS))
    }

    /// 现在这个装法能不能就地换包。每种拒绝都有自己的一句话。
    private func installBlocker() -> String? {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return L("update.err.notBundle") }
        // Gatekeeper 的 App Translocation:从 DMG/下载目录直接双击运行时,系统把
        // bundle 映射到一个只读的随机临时路径。往那儿写没有意义。
        if path.hasPrefix("/private/var/folders/") || path.contains("/AppTranslocation/") {
            return L("update.err.translocated")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inApplications = path.hasPrefix("/Applications/")
            || path.hasPrefix(home + "/Applications/")
        if !inApplications { return Lf("update.err.location", path) }

        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
           free < Updater.minFreeBytes {
            return Lf("update.err.disk", Int(Updater.minFreeBytes / 1024 / 1024))
        }
        if !FileManager.default.isWritableFile(atPath: path) {
            return Lf("update.err.readonly", path)
        }
        return nil
    }

    /// 成功返回 nil(此时 App 正在重启);失败返回一句人话,旧版原封不动。
    private func downloadAndInstall(_ release: Release) -> String? {
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let fm = FileManager.default

        // 换包用的临时目录必须和 App **同卷**,否则 replaceItemAt 跨卷失败。
        guard let workDir = try? fm.url(for: .itemReplacementDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: bundleURL,
                                        create: true) else {
            return L("update.err.tempDir")
        }
        defer { try? fm.removeItem(at: workDir) }

        // 1. 下载
        let zipURL = workDir.appendingPathComponent("MacHands-\(release.version).zip")
        if let problem = download(release.url, to: zipURL) { return problem }

        // 2. sha256
        guard let payload = try? Data(contentsOf: zipURL) else { return L("update.err.readBack") }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256 else {
            return Lf("update.err.sha", String(digest.prefix(12)), String(release.sha256.prefix(12)))
        }

        // 3. 验发布签名。占位公钥在这里必然失败 —— 没接发布流程就不许装。
        guard Updater.verifyReleaseSignature(sha256Hex: digest, signature: release.sig) else {
            return L("update.err.signature")
        }

        // 4. 解压。用 ditto 而不是 unzip:它保留扩展属性与签名结构。
        let extractDir = workDir.appendingPathComponent("x", isDirectory: true)
        try? fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDir.path], timeout: 180)
        guard unzip.ok else { return Lf("update.err.unzip", unzip.complaint) }

        guard let newBundle = Updater.findApp(in: extractDir, fileManager: fm) else {
            return L("update.err.noApp")
        }

        // 5. 新包自己的签名必须完好
        let verify = Shell.run("/usr/bin/codesign",
                               ["--verify", "--strict", "--deep", "-vv", newBundle.path],
                               timeout: 120)
        guard verify.status == 0 else { return Lf("update.err.codesign", verify.complaint) }

        // 6. 新包的"指定要求"必须和现在跑着的这一份**逐字相同**。
        //    这一条挡住的是:换了签名的包(TCC 授权会掉)、别人签的包(冒名顶替)。
        let currentDR = Updater.designatedRequirement(of: bundleURL.path)
        let newDR = Updater.designatedRequirement(of: newBundle.path)
        guard let mine = currentDR, let theirs = newDR else {
            return L("update.err.drUnreadable")
        }
        guard mine == theirs else {
            Log.shared.write("update refused: DR mismatch\n  current: \(mine)\n  new:     \(theirs)")
            return L("update.err.drMismatch")
        }

        // 7. 原地换包:同一个路径、同一个 inode 位置,Launch Services 不会当成新 App。
        do {
            _ = try fm.replaceItemAt(bundleURL,
                                     withItemAt: newBundle,
                                     backupItemName: "MacHands.previous.app",
                                     options: [.usingNewMetadataOnly])
        } catch {
            return Lf("update.err.replace", error.localizedDescription)
        }
        Log.shared.write("updated to \(release.version) in place at \(bundleURL.path); relaunching")

        // 8. 重启。延后一拍,让这条 RPC 的响应先发出去。
        //
        // 这里**先退再起**,不是先起再退。原先用 `open -n` 先拉一个新实例再 terminate,
        // 真机上的结果是:磁盘换成了新版,跑着的还是旧进程(新实例没活下来,旧的也没退),
        // 用户看到"已更新"却还在用旧版。同一个 bundle id 有两个实例同时活着,本来就会
        // 互相抢中继身份、在 TCC 里撞条目 —— 今天已经吃过这个亏。
        //
        // 改法:先派一个脱离的看门脚本,它盯着自己这个 PID,等我们真的退干净了再 open。
        // 顺带把旧 PID 与新实例的启动都写进日志,出问题一眼能定位先后。
        let myPid = ProcessInfo.processInfo.processIdentifier
        let logPath = Log.shared.fileURL.path
        let script = """
        while kill -0 \(myPid) 2>/dev/null; do sleep 0.2; done
        printf '%s relaunch: old pid \(myPid) gone, opening %s\\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '\(bundleURL.path)' >> '\(logPath)'
        /usr/bin/open -a '\(bundleURL.path)'
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let watcher = Process()
            watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
            watcher.arguments = ["-c", script]
            watcher.standardOutput = FileHandle.nullDevice
            watcher.standardError = FileHandle.nullDevice
            do {
                try watcher.run()
            } catch {
                Log.shared.write("relaunch watcher failed: \(error.localizedDescription)")
            }
            Log.shared.write("relaunch: quitting old pid \(myPid)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
        return nil
    }

    private func download(_ url: URL, to destination: URL) -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = Updater.downloadTimeout
        let box = LockedBox<String?>(nil)
        let done = DispatchSemaphore(value: 0)

        URLSession.shared.downloadTask(with: request) { temporary, response, error in
            defer { done.signal() }
            if let error = error {
                box.value = Lf("update.err.network", error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                box.value = Lf("update.err.network", "HTTP \(http.statusCode)")
                return
            }
            guard let temporary = temporary else {
                box.value = Lf("update.err.network", "empty body")
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                box.value = Lf("update.err.network", error.localizedDescription)
            }
        }.resume()

        if done.wait(timeout: .now() + Updater.downloadTimeout + 20) == .timedOut {
            return Lf("update.err.network", L("update.err.timeout"))
        }
        return box.value
    }

    // MARK: - 工具

    /// `0.3.0` > `0.2.9`。段数不同时短的那边补 0。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        return compare(candidate, current) > 0
    }

    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ text: String) -> [Int] {
            return text.split(whereSeparator: { $0 == "." || $0 == "-" })
                .map { Int($0.filter { $0.isNumber }) ?? 0 }
        }
        let left = parts(a)
        let right = parts(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    static func systemMeets(_ minimum: String) -> Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let running = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return compare(running, minimum) >= 0
    }

    static func verifyReleaseSignature(sha256Hex: String, signature: String) -> Bool {
        guard releasePublicKey != "REPLACE_ME_RELEASE_PUBKEY" else { return false }
        guard let rawKey = Base64URL.decode(releasePublicKey),
              let rawSignature = Base64URL.decode(signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
            return false
        }
        return key.isValidSignature(rawSignature, for: Data(sha256Hex.utf8))
    }

    /// 解出来的目录里找 `*.app`。zip 里可能带一层顶层目录。
    static func findApp(in directory: URL, fileManager fm: FileManager) -> URL? {
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: nil) else {
            return nil
        }
        if let direct = entries.first(where: { $0.pathExtension == "app" }) { return direct }
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let nested = findApp(in: entry, fileManager: fm) { return nested }
        }
        return nil
    }

    /// `codesign -d -r-` 把 designated requirement 写在 **stderr** 上。
    static func designatedRequirement(of path: String) -> String? {
        let result = Shell.run("/usr/bin/codesign", ["-d", "-r-", "--", path], timeout: 30)
        let haystack = result.stderr + "\n" + result.stdout
        for line in haystack.split(separator: "\n") {
            if let range = line.range(of: "designated => ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// `app.doctor` 用:这台机器上这份 App 到底是什么来路。
    static func signingAuthority(of path: String) -> String? {
        let result = Shell.run("/usr/bin/codesign", ["-dvv", "--", path], timeout: 30)
        let haystack = result.stderr + "\n" + result.stdout
        for line in haystack.split(separator: "\n") where line.hasPrefix("Authority=") {
            return String(line.dropFirst("Authority=".count))
        }
        return nil
    }

    /// 公证过没有。`spctl` 认不出时返回 nil,不猜。
    static func isNotarized(path: String) -> Bool? {
        let result = Shell.run("/usr/sbin/spctl", ["-a", "-vv", "-t", "exec", path], timeout: 30)
        let haystack = (result.stderr + result.stdout).lowercased()
        if haystack.contains("rejected") { return false }
        if haystack.contains("accepted") { return true }
        return nil
    }
}
