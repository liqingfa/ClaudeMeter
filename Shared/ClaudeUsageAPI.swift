import Foundation
import Security

/// Reads the Claude Code OAuth token from the login Keychain and queries the
/// official usage endpoint (the same data shown by `/usage` inside Claude Code).
enum ClaudeUsageAPI {

    /// Keychain service name under which Claude Code stores its credentials.
    static let keychainService = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    enum APIError: LocalizedError {
        case noCredentials
        case malformedCredentials
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case http(Int)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "未找到 Claude Code 凭证，请先在 Claude Code 中登录。"
            case .malformedCredentials:
                return "Claude Code 凭证格式异常。"
            case .unauthorized:
                return "凭证已过期，请打开 Claude Code 重新登录。"
            case .rateLimited:
                return "额度接口请求过于频繁，已自动降低频率，稍后恢复。"
            case .http(let code):
                return "额度接口返回 HTTP \(code)。"
            case .decoding(let msg):
                return "解析额度数据失败：\(msg)"
            }
        }
    }

    // MARK: Keychain

    /// Reads the OAuth access token. Triggers a one-time Keychain permission
    /// prompt the first time, since the item was created by another app.
    static func readAccessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw APIError.noCredentials
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw APIError.malformedCredentials
        }
        return token
    }

    // MARK: Usage endpoint

    private struct RawWindow: Decodable {
        let utilization: Double?
        let resets_at: String?
    }
    private struct RawUsage: Decodable {
        let five_hour: RawWindow?
        let seven_day: RawWindow?
    }

    /// Fetches the 5-hour and 7-day rate-limit windows.
    static func fetchWindows() async throws -> (fiveHour: WindowUsage?, sevenDay: WindowUsage?) {
        let token = try readAccessToken()

        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(-1)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized
        }
        if http.statusCode == 429 {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            throw APIError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode)
        }

        let raw: RawUsage
        do {
            raw = try JSONDecoder().decode(RawUsage.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }

        return (window(from: raw.five_hour), window(from: raw.seven_day))
    }

    private static func window(from raw: RawWindow?) -> WindowUsage? {
        guard let raw, let util = raw.utilization,
              let resetStr = raw.resets_at,
              let reset = parseDate(resetStr)
        else { return nil }
        return WindowUsage(utilization: util, resetsAt: reset)
    }

    /// Parses ISO-8601 timestamps that may carry microsecond precision, e.g.
    /// "2026-06-12T11:50:00.547129+00:00", which the stock formatters reject.
    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        // Strip the fractional-seconds component (.NNNNNN) and retry.
        if let dot = s.firstIndex(of: ".") {
            let after = s[dot...].dropFirst()
            let tzStart = after.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
                .map { after.distance(from: after.startIndex, to: $0) } ?? after.count
            let tz = String(after.dropFirst(tzStart))
            let stripped = String(s[s.startIndex..<dot]) + tz
            if let d = iso.date(from: stripped) { return d }
        }
        return iso.date(from: s)
    }
}
