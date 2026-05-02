

import Alamofire

/// Manager for subtitle search.
///
/// The legacy XML-RPC OpenSubtitles client (AlamofireXMLRPC) was removed during
/// the modernization sweep. The public surface is preserved as no-ops so the
/// rest of the app keeps building. Reintroducing real lookups should target
/// the OpenSubtitles REST API (https://api.opensubtitles.com) — see plan
/// Phase 7 (polish) for the follow-up task.
open class SubtitlesManager: NetworkManager {

    public static let shared = SubtitlesManager()

    open func search(_ episode: Episode? = nil,
                     imdbId: String? = nil,
                     limit: String = "500",
                     completion: @escaping ([Subtitle], NSError?) -> Void) {
        DispatchQueue.main.async { completion([], nil) }
    }

    public func login(_ completion: ((NSError?) -> Void)?) {
        DispatchQueue.main.async { completion?(nil) }
    }

    open func logout(completion: ((NSError?) -> Void)? = nil) {
        DispatchQueue.main.async { completion?(nil) }
    }
}
