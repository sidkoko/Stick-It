import Foundation

// The only network request this app ever makes — a single lightweight check
// against GitHub's public API when All Notes is opened, nothing else.
enum UpdateChecker {
    struct ReleaseInfo { let version: String; let url: URL }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // Deliberately not /releases/latest: that endpoint is repo-global, and the Windows
    // build ships from the same repo on its own `win-v*` tags. Whichever platform
    // published last would otherwise be offered to users of the other one. Releases come
    // back newest-first, so the first `v<number>` tag is this channel's current version.
    static func fetchLatest() async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/sidkoko/Stick-It/releases?per_page=30"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for release in releases {
            guard release["draft"] as? Bool != true,
                  release["prerelease"] as? Bool != true,
                  let tag = release["tag_name"] as? String,
                  isMacTag(tag),
                  let htmlURLString = release["html_url"] as? String,
                  let htmlURL = URL(string: htmlURLString) else { continue }
            return ReleaseInfo(version: String(tag.dropFirst()), url: htmlURL)
        }
        return nil
    }

    /// The macOS channel: `v1.0.8`. Anything else — `win-v0.2.0`, a docs tag — isn't ours.
    static func isMacTag(_ tag: String) -> Bool {
        tag.first == "v" && (tag.dropFirst().first?.isNumber ?? false)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").compactMap { Int($0) }
        let bv = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
