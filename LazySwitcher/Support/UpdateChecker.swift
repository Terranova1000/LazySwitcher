import AppKit

/// Asks GitHub whether a newer release exists.
///
/// **This is the only network code in the project, and it exists under protest.**
///
/// The promise "makes zero outgoing connections" is what separates this app from
/// the closed-source alternative that also sees everything you type, and it is a
/// promise a user can verify with Little Snitch in ten seconds. Weakening it is a
/// real cost, not a formality.
///
/// Against that: an agent that quietly stops working after a system update, with
/// no way for its user to learn a fix exists, is listed in this project's own
/// definition of failure. Both are real, so the compromise is in the defaults and
/// in what is said out loud:
///
/// · Nothing happens unless the user asks. The menu item is a deliberate act.
/// · The weekly check is a setting, **off** by default.
/// · One plain GET to a public releases endpoint. No identifiers, no analytics,
///   no version of anything sent — the request carries no body at all.
/// · What GitHub can infer is stated honestly in the settings screen: an IP
///   address asked about this repository at this time. Not nothing, so the user
///   decides rather than being decided for.
///
/// Sparkle would have done all this and more, and is rejected on the same
/// grounds: it is a dependency with its own network behaviour and its own
/// update-installing machinery, and neither is auditable at a glance.
enum UpdateChecker {

    /// Repository to ask about. Wired to a constant rather than a setting: a
    /// configurable update URL is how a helpful tool becomes a delivery channel
    /// for something else.
    static let repository = "Terranova1000/LazySwitcher"
    private static var endpoint: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }
    static var releasesPage: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    enum Outcome {
        case upToDate(current: String)
        case updateAvailable(latest: String, current: String)
        case failed(String)
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Performs one check. Called only from the menu item or the weekly timer.
    static func check(completion: @escaping (Outcome) -> Void) {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.httpMethod = "GET"
        // Ephemeral: no cookies, no cache, no credential store. Nothing about
        // this request should outlive it.
        let session = URLSession(configuration: .ephemeral)

        session.dataTask(with: request) { data, _, error in
            Settings.shared.lastUpdateCheck = Date()
            if let error {
                DispatchQueue.main.async { completion(.failed(error.localizedDescription)) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                DispatchQueue.main.async { completion(.failed(L("updates.error.malformed"))) }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = currentVersion
            DispatchQueue.main.async {
                completion(isNewer(latest, than: current)
                           ? .updateAvailable(latest: latest, current: current)
                           : .upToDate(current: current))
            }
        }.resume()
    }

    /// Compares dotted versions numerically, so 0.10.0 is newer than 0.9.0 —
    /// which string comparison gets backwards.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Weekly, and only if the user turned it on.
    static func checkOnScheduleIfEnabled(completion: @escaping (Outcome) -> Void) {
        guard Settings.shared.checkUpdatesAutomatically else { return }
        if let last = Settings.shared.lastUpdateCheck,
           Date().timeIntervalSince(last) < 7 * 24 * 3600 { return }
        check(completion: completion)
    }
}
