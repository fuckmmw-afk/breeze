import Foundation

public struct FetchedSubscription {
    public var servers: [ServerNode]
    public var traffic: SubscriptionTraffic?
    public var title: String?
    public var updateInterval: TimeInterval?
    public var supportURL: String?
}

public enum SubscriptionFetcher {
    public static func fetch(url: String, userAgent: String) async throws -> FetchedSubscription {
        guard let requestURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = requestURL.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            throw BreezeError("Неверная ссылка подписки")
        }
        var request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BreezeError("Нет ответа от сервера")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw BreezeError("Сервер подписки ответил \(http.statusCode)")
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let servers = SubscriptionParser.parse(text)
        if servers.isEmpty {
            throw BreezeError("В подписке не найдено поддерживаемых серверов")
        }
        func header(_ name: String) -> String? {
            http.value(forHTTPHeaderField: name)
        }
        return FetchedSubscription(
            servers: servers,
            traffic: header("subscription-userinfo").flatMap(parseUserInfo),
            title: header("profile-title").flatMap(decodeTitle) ?? filename(header("content-disposition")),
            updateInterval: header("profile-update-interval").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { $0 * 3600 },
            supportURL: header("support-url")
        )
    }

    /// "upload=1; download=2; total=3; expire=1700000000"
    static func parseUserInfo(_ value: String) -> SubscriptionTraffic? {
        var fields: [String: Int64] = [:]
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, let number = Int64(pair[1]) ?? Double(pair[1]).map({ Int64($0) }) {
                fields[pair[0].lowercased()] = number
            }
        }
        guard !fields.isEmpty else { return nil }
        let expire = fields["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return SubscriptionTraffic(
            upload: fields["upload"] ?? 0,
            download: fields["download"] ?? 0,
            total: fields["total"] ?? 0,
            expire: expire
        )
    }

    static func decodeTitle(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("base64:") {
            return Base64.decodeString(String(trimmed.dropFirst(7)))
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func filename(_ disposition: String?) -> String? {
        guard let disposition, let range = disposition.range(of: "filename=") else { return nil }
        var name = String(disposition[range.upperBound...])
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ;"))
        return name.removingPercentEncoding ?? name
    }
}
