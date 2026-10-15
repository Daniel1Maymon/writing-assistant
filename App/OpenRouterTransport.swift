import Core
import Foundation
import Security

/// The one network call of the app: POST the body Core built, return the raw answer (decision 0010).
enum OpenRouterTransport {
    static func make(key: String, baseURL: URL) -> TierTwoScheduler.Send {
        let session = URLSession(configuration: .ephemeral)
        let url = baseURL.appendingPathComponent("chat/completions")
        return { body in
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("WritingAssistant", forHTTPHeaderField: "X-Title")
            request.httpBody = body
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw TierTwoError.http(code) }
            return data
        }
    }
}

/// The OpenRouter key in the login keychain (release builds; debug builds prefer `.env`).
enum KeychainStore {
    static let service = "com.danielmaymon.WritingAssistant.openrouter"
    static let keyAccount = "OPENROUTER_API_KEY"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String = keyAccount) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, account: String = keyAccount) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String = keyAccount) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
