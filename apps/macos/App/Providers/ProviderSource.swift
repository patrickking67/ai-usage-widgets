import Foundation

/// One vendor lane. Adding a vendor means writing one of these and listing it
/// in `Collector.sources`; every view, widget and alert picks it up from the
/// board without changes.
///
/// Sources read local files synchronously in `usage(now:)` (cheap: small JSON,
/// file tails) and do any network work asynchronously, calling `onUpdate`
/// when a fetch lands so the collector rebuilds the board.
@MainActor
protocol ProviderSource: AnyObject {
    var vendor: Vendor { get }
    /// Why data is missing or degraded, shown under the card; nil when fine.
    var problem: String? { get }
    /// False when nothing of this vendor is installed; the lane is hidden.
    var isInstalled: Bool { get }
    var onUpdate: (() -> Void)? { get set }
    func usage(now: Date) -> ProviderUsage?
    /// The refresh button: skip any polling interval that is not a back-off.
    func refreshNow()
}

extension ProviderSource {
    func refreshNow() {}
}

/// Small file helpers shared by the sources.
enum Local {
    static let home = UsageStore.realHome

    static func json(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// A display name set in Settings (or `defaults write com.patrickking.tokenmeter <key> <name>`).
    static func override(_ key: String) -> String? {
        let v = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespaces)
        return v?.isEmpty == false ? v : nil
    }

    /// Decodes a JWT's claims locally. Only non-secret claims are ever read.
    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func readTail(_ url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return (try? h.readToEnd()).flatMap { String(decoding: $0, as: UTF8.self) }
    }

    /// Finds a key at any depth; vendors move things between versions.
    static func findKey(_ key: String, in obj: Any) -> Any? {
        if let d = obj as? [String: Any] {
            if let v = d[key] { return v }
            for v in d.values { if let hit = findKey(key, in: v) { return hit } }
        } else if let a = obj as? [Any] {
            for v in a { if let hit = findKey(key, in: v) { return hit } }
        }
        return nil
    }

    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}
