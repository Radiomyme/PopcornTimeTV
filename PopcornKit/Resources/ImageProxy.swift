

import Foundation

/// Wraps third-party image URLs through `images.weserv.nl` so they reach the
/// app even when the source host is DNS-blocked by the user's ISP. YTS hosts
/// poster/background images on `yts.bz` / `img.yts.bz` which French FAIs
/// blacklist — the API itself moved to `movies-api.accel.li`, but the image
/// URLs in the JSON payload still point at the dead host. weserv.nl is a
/// public Cloudflare-hosted proxy that fetches any HTTPS URL and returns the
/// JPEG/PNG bytes; it has aggressive caching (1 year) so subsequent loads are
/// CDN-fast.
public enum ImageProxy {

    /// Hosts whose images need proxying. Matched as a domain suffix so both
    /// `yts.bz` and `img.yts.bz` are caught with a single entry.
    ///
    /// NOTE: YTS rotates its image CDN periodically (the API host moved to
    /// `movies-api.accel.li` but the poster URLs in the JSON now point at
    /// `yts.gg`). Keep every historical host here — French ISPs DNS-block
    /// most of them, so anything not proxied renders as a placeholder.
    public static var proxiedHostSuffixes: [String] = [
        "yts.gg", "yts.bz", "yts.mx", "yts.am", "yts.lt", "yts.rs", "yts.ag",
    ]

    /// Hosts that are known to be reachable globally and never need proxying
    /// (Cloudflare, Apple, Amazon, TMDB CDN, …).
    public static let bypassHostSuffixes: [String] = [
        "themoviedb.org", "tmdb.org", "fanart.tv", "amazon.com",
        "ssl-images-amazon.com", "media-amazon.com", "weserv.nl",
        "googleapis.com", "googleusercontent.com",
    ]

    public static func proxied(_ rawURL: String?) -> String? {
        guard let raw = rawURL, !raw.isEmpty else { return rawURL }
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return raw }

        if bypassHostSuffixes.contains(where: { host.hasSuffix($0) }) { return raw }
        guard proxiedHostSuffixes.contains(where: { host.hasSuffix($0) }) else { return raw }

        // weserv expects the URL with no scheme; we keep https for safety.
        var safe = raw
        // If the API returned the upstream `yts.bz` host, swap to the canonical
        // CDN `img.yts.bz` first so weserv hits the right asset path (yts.bz
        // 301-redirects to img.yts.bz which weserv won't follow on its own).
        if host == "yts.bz" {
            safe = raw.replacingOccurrences(of: "://yts.bz/assets/",
                                            with: "://img.yts.bz/assets/")
        }
        let encoded = safe.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? safe
        return "https://images.weserv.nl/?url=\(encoded)"
    }
}
