import AppKit
import Security

/// Downloads a new version, checks it is really ours, and swaps it in.
///
/// **Why this is allowed to exist at all.**
///
/// `10-RELEASE.md` used to say we would never do this, and the reason it gave
/// was right: a program with Accessibility permission that can replace its own
/// binary is a self-updating keylogger, and asking people to trust that is
/// asking too much. What changed is not the risk but the evidence — the trust is
/// no longer on somebody's word.
///
/// The control is `SecStaticCodeCheckValidity` against **our own designated
/// requirement**. The downloaded application has to satisfy the same requirement
/// that identifies the running one: same bundle identifier, signed by the same
/// certificate. That certificate's private key lives in one keychain and is
/// published nowhere, so an attacker who replaces the release on GitHub, hijacks
/// DNS or intercepts the connection still cannot produce a bundle that passes.
/// The download is refused and nothing is installed.
///
/// This is a checkable guarantee rather than a promise, which is the whole
/// difference. Three things follow from it and are not negotiable:
///
/// · the requirement comes from the **running** binary, never from the download;
/// · verification happens before anything is copied anywhere;
/// · a failure is loud and total — no fallback, no "install anyway".
enum Updater {

    enum Failure: LocalizedError {
        case noAsset
        case download(String)
        case mount(String)
        case notAnApp
        case signatureRejected(String)
        case install(String)
        case notInApplications

        var errorDescription: String? {
            switch self {
            case .noAsset: return L("update.error.noAsset")
            case .download(let why): return L("update.error.download", why)
            case .mount(let why): return L("update.error.mount", why)
            case .notAnApp: return L("update.error.notAnApp")
            case .signatureRejected(let why): return L("update.error.signature", why)
            case .install(let why): return L("update.error.install", why)
            case .notInApplications: return L("update.error.notInApplications")
            }
        }
    }

    enum Progress {
        case downloading(Double)
        case verifying
        case installing
        case restarting
    }

    // MARK: - The whole sequence

    static func downloadAndInstall(progress: @escaping (Progress) -> Void,
                                   completion: @escaping (Result<Void, Failure>) -> Void) {
        // Updating in place needs to write where we live. Anywhere else — a
        // Downloads folder, a translocated copy — and we would be installing
        // over something that is not the app the user runs.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            completion(.failure(.notInApplications)); return
        }

        assetURL { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let url):
                download(url, progress: progress) { downloaded in
                    switch downloaded {
                    case .failure(let error): completion(.failure(error))
                    case .success(let dmg):
                        DispatchQueue.global(qos: .userInitiated).async {
                            let outcome = verifyAndInstall(dmg: dmg, progress: progress)
                            DispatchQueue.main.async { completion(outcome) }
                        }
                    }
                }
            }
        }
    }

    /// Finds the disk image attached to the latest release.
    private static func assetURL(_ completion: @escaping (Result<URL, Failure>) -> Void) {
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(UpdateChecker.repository)/releases/latest")!)
        request.timeoutInterval = 15
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(.download(error.localizedDescription))) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]],
                  let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                  let link = dmg["browser_download_url"] as? String,
                  let url = URL(string: link) else {
                DispatchQueue.main.async { completion(.failure(.noAsset)) }
                return
            }
            DispatchQueue.main.async { completion(.success(url)) }
        }.resume()
    }

    private static func download(_ url: URL, progress: @escaping (Progress) -> Void,
                                 completion: @escaping (Result<URL, Failure>) -> Void) {
        progress(.downloading(0))
        let task = URLSession(configuration: .ephemeral).downloadTask(with: url) { temporary, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(.download(error.localizedDescription))) }
                return
            }
            guard let temporary else {
                DispatchQueue.main.async { completion(.failure(.download("нет файла"))) }
                return
            }
            // The temporary file is deleted the moment this callback returns.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("LazySwitcher-update.dmg")
            try? FileManager.default.removeItem(at: destination)
            do { try FileManager.default.moveItem(at: temporary, to: destination) }
            catch {
                DispatchQueue.main.async { completion(.failure(.download(error.localizedDescription))) }
                return
            }
            DispatchQueue.main.async { completion(.success(destination)) }
        }
        task.resume()
    }

    // MARK: - The part that matters

    private static func verifyAndInstall(dmg: URL, progress: @escaping (Progress) -> Void) -> Result<Void, Failure> {
        DispatchQueue.main.async { progress(.verifying) }

        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("LazySwitcher-update-volume")
        try? FileManager.default.removeItem(at: mountPoint)
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attach = run("/usr/bin/hdiutil",
                         ["attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mountPoint.path])
        guard attach.status == 0 else { return .failure(.mount(attach.output)) }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"])
            try? FileManager.default.removeItem(at: dmg)
        }

        guard let app = (try? FileManager.default.contentsOfDirectory(at: mountPoint,
                                                                     includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else { return .failure(.notAnApp) }

        if let why = signatureProblem(of: app) { return .failure(.signatureRejected(why)) }

        DispatchQueue.main.async { progress(.installing) }
        // Staged next to the destination, not inside it: a copy that fails
        // halfway must not leave a half-written bundle where the app lives.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("LazySwitcher-staged.app")
        try? FileManager.default.removeItem(at: staged)
        do { try FileManager.default.copyItem(at: app, to: staged) }
        catch { return .failure(.install(error.localizedDescription)) }

        // Verify again, at the staged copy. The image is about to be unmounted,
        // and what gets installed is this file, not the one we checked.
        if let why = signatureProblem(of: staged) { return .failure(.signatureRejected(why)) }

        DispatchQueue.main.async { progress(.restarting) }
        return handOff(staged: staged)
    }

    /// Does the downloaded bundle satisfy the requirement that identifies *us*?
    ///
    /// Returns nil when it does. The requirement is read from the running
    /// binary — never from the download, which would let the download vouch for
    /// itself.
    static func signatureProblem(of app: URL) -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            return L("update.error.ownSignature")
        }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess,
              let selfStatic else { return L("update.error.ownSignature") }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess,
              let requirement else { return L("update.error.ownSignature") }

        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess,
              let candidate else { return L("update.error.unreadableSignature") }

        // kSecCSCheckAllArchitectures so a universal binary cannot smuggle a
        // differently signed slice past a check that only looked at one, and
        // kSecCSCheckNestedCode so a valid outer shell cannot carry an unsigned
        // framework inside it. Swift does not surface these as named members of
        // SecCSFlags, so they are built from the raw constants.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures
                                       | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(
            candidate, flags, requirement, &error)
        guard status == errSecSuccess else {
            let detail = (error?.takeRetainedValue() as Error?)?.localizedDescription
                ?? "OSStatus \(status)"
            return detail
        }
        return nil
    }

    /// Swaps the bundle after we are gone.
    ///
    /// A running application cannot replace itself: the files are open, and the
    /// system is entitled to assume they stay put. So the last thing we do is
    /// hand a small script the job and quit — it waits for our process to
    /// disappear, moves the new bundle into place and launches it.
    ///
    /// The old bundle goes to a neighbouring path first and is deleted only
    /// after the move succeeds, so a failure at the worst possible moment leaves
    /// a working application rather than none.
    private static func handOff(staged: URL) -> Result<Void, Failure> {
        let destination = Bundle.main.bundleURL
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".LazySwitcher-previous.app")
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazyswitcher-update.sh")

        let body = """
        #!/bin/bash
        # Ждём, пока приложение закроется, и только потом трогаем бандл.
        for _ in $(seq 1 100); do
          kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break
          sleep 0.1
        done
        rm -rf "\(backup.path)"
        mv "\(destination.path)" "\(backup.path)" || exit 1
        if mv "\(staged.path)" "\(destination.path)"; then
          rm -rf "\(backup.path)"
        else
          # Не получилось — возвращаем прежнее, чтобы человек не остался без приложения.
          mv "\(backup.path)" "\(destination.path)"
          exit 1
        fi
        open "\(destination.path)"
        rm -f "$0"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)
        } catch { return .failure(.install(error.localizedDescription)) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        do { try process.run() } catch { return .failure(.install(error.localizedDescription)) }
        return .success(())
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
