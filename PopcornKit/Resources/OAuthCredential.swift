

import Alamofire
import Foundation
import Security

enum OAuthGrantType: String {
    case Code = "authorization_code"
    case ClientCredentials = "client_credentials"
    case PasswordCredentials = "password"
    case Refresh = "refresh_token"
}

private enum KeychainStore {
    static let service = "OAuthCredentialService"

    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: "com.popcorntimetv.popcornkit.keychain", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain save failed (\(status))"])
        }
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: "com.popcorntimetv.popcornkit.keychain", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain delete failed (\(status))"])
        }
    }
}

class OAuthCredential: NSObject, NSCoding {

    override var description: String {
        return "<\(type(of: self)): \(String(format: "%p", unsafeBitCast(self, to: Int.self))); accessToken = '\(self.accessToken)'; tokenType = '\(self.tokenType)'; refreshToken = '\(self.refreshToken ?? "none")'; expiration = \(self.expiration ?? Date.distantFuture)>"
    }

    private(set) var accessToken: String
    private(set) var tokenType: String
    var refreshToken: String?

    var expired: Bool {
        return self.expiration?.compare(Date()) == .orderedAscending
    }

    var expiration: Date?

    required init(token: String, tokenType: String) {
        self.accessToken = token
        self.tokenType = tokenType
        super.init()
    }

    convenience init(
        _ url: String,
        username: String,
        password: String,
        scope: String? = nil,
        clientID: String,
        clientSecret: String,
        useBasicAuthentication: Bool = true
        ) throws {
        var params = ["username": username, "password": password, "grant_type": OAuthGrantType.PasswordCredentials.rawValue]
        if scope != nil {
            params["scope"] = scope!
        }
        try self.init(url, parameters: params as [String: Any], clientID: clientID, clientSecret: clientSecret, useBasicAuthentication: useBasicAuthentication)
    }

    convenience init(
        _ url: String,
        refreshToken: String,
        clientID: String,
        clientSecret: String,
        useBasicAuthentication: Bool = true
        ) throws {
        let params = ["refresh_token": refreshToken, "grant_type": OAuthGrantType.Refresh.rawValue]
        try self.init(url, parameters: params as [String: Any], clientID: clientID, clientSecret: clientSecret, useBasicAuthentication: useBasicAuthentication)
    }

    convenience init(
        _ url: String,
        code: String,
        redirectURI: String,
        clientID: String,
        clientSecret: String,
        useBasicAuthentication: Bool = true
        ) throws {
        let params = ["grant_type": OAuthGrantType.Code.rawValue, "code": code, "redirect_uri": redirectURI]
        try self.init(url, parameters: params as [String: Any], clientID: clientID, clientSecret: clientSecret, useBasicAuthentication: useBasicAuthentication)
    }

    init(
        _ url: String,
        parameters: [String: Any],
        clientID: String,
        clientSecret: String,
        useBasicAuthentication: Bool = true
        ) throws {
        accessToken = ""; tokenType = ""
        super.init()
        if Thread.isMainThread { print("Consider moving this method to a background thread to prevent performance loss.") }
        var headers: HTTPHeaders = [:]
        var parameters = parameters
        if useBasicAuthentication {
            let basic = "\(clientID):\(clientSecret)".data(using: .utf8)!.base64EncodedString()
            headers.add(name: "Authorization", value: "Basic \(basic)")
        } else {
            parameters["client_id"] = clientID
            parameters["client_secret"] = clientSecret
        }
        let semaphore = DispatchSemaphore(value: 0)
        var error: NSError?
        let queue = DispatchQueue(label: "com.popcorntimetv.popcornkit.response.queue", attributes: .concurrent)
        AF.request(url, method: .post, parameters: parameters, headers: headers).validate().responseData(queue: queue) { response in
            switch response.result {
            case .success(let data):
                guard
                    let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
                    let responseObject = json as? [String: Any]
                else {
                    error = NSError(domain: "com.popcorntimetv.popcornkit.oauth", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid OAuth response payload"])
                    semaphore.signal()
                    return
                }
                let refreshToken = responseObject["refresh_token"] as? String ?? parameters["refresh_token"] as? String
                self.accessToken = responseObject["access_token"] as? String ?? ""
                self.tokenType   = responseObject["token_type"] as? String ?? ""
                if let r = refreshToken {
                    self.refreshToken = r
                }
                var expireDate = Date.distantFuture
                if let expiresIn = responseObject["expires_in"] as? Int {
                    expireDate = Date(timeIntervalSinceNow: Double(expiresIn))
                }
                self.expiration = expireDate
                semaphore.signal()
            case .failure(let afError):
                error = afError as NSError
                semaphore.signal()
            }
        }
        semaphore.wait()
        if let e = error { throw e }
    }

    func setRefreshToken(_ refreshToken: String, expiration: Date) {
        self.refreshToken = refreshToken
        self.expiration = expiration
    }

    func store(
        withIdentifier identifier: String,
        accessibility: AnyObject = kSecAttrAccessibleAfterFirstUnlock
        ) throws {
        let archived = try NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: false)
        try KeychainStore.save(archived, account: identifier)
    }

    init?(identifier: String) {
        accessToken = ""; tokenType = ""
        super.init()
        guard
            let data = KeychainStore.load(account: identifier),
            let credential = (try? NSKeyedUnarchiver.unarchivedObject(ofClass: OAuthCredential.self, from: data)) ?? (NSKeyedUnarchiver.unarchiveObject(with: data) as? OAuthCredential)
        else { return nil }
        self.accessToken  = credential.accessToken
        self.tokenType    = credential.tokenType
        self.refreshToken = credential.refreshToken
        self.expiration   = credential.expiration
    }

    class func delete(withIdentifier identifier: String) throws {
        try KeychainStore.delete(account: identifier)
    }

    // MARK: - NSCoding

    func encode(with aCoder: NSCoder) {
        aCoder.encode(accessToken, forKey: "accessToken")
        aCoder.encode(tokenType, forKey: "tokenType")
        aCoder.encode(refreshToken, forKey: "refreshToken")
        aCoder.encode(expiration, forKey: "expiration")
    }

    required init(coder aDecoder: NSCoder) {
        accessToken  = aDecoder.decodeObject(forKey: "accessToken") as? String ?? ""
        tokenType    = aDecoder.decodeObject(forKey: "tokenType")  as? String ?? ""
        refreshToken = aDecoder.decodeObject(forKey: "refreshToken") as? String
        expiration   = aDecoder.decodeObject(forKey: "expiration") as? Date
        super.init()
    }
}
