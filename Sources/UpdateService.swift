import Foundation

/// A newer release published on GitHub.
struct UpdateInfo: Equatable {
    let version: String
    let releaseURL: URL
}

/// Why an update check could not complete.
enum UpdateCheckError: Error, Equatable {
    /// Network failure or timeout.
    case unreachable
    /// The releases endpoint did not return a release — most commonly a
    /// private repository (GitHub answers 404 to anonymous callers).
    case noReleaseFound
}

/// One-off alert content for manual update checks.
struct UpdateAlert: Identifiable, Equatable {
    let title: String
    let message: String

    var id: String { title + message }
}

/// Checks GitHub Releases for a newer version of the app. Anonymous API calls
/// are rate-limited but more than sufficient for a launch-time check; no
/// credentials are stored in the app.
enum UpdateService {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/nthndvs/mcs/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Returns the update when one is available, nil when up to date, or an
    /// error explaining why the check could not be completed.
    static func checkForUpdate() async -> Result<UpdateInfo?, UpdateCheckError> {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String,
                  let page = object["html_url"] as? String,
                  let releaseURL = URL(string: page) else {
                return .failure(.noReleaseFound)
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isVersion(latest, newerThan: currentVersion) else { return .success(nil) }
            return .success(UpdateInfo(version: latest, releaseURL: releaseURL))
        } catch {
            return .failure(.unreachable)
        }
    }

    /// Component-wise numeric comparison; either side may have fewer
    /// components ("1.2" vs "1.2.0" are equal).
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
