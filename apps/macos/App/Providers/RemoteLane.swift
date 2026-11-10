import Foundation

/// Polling and back-off shared by lanes that read a local sign-in and make one
/// GET (Cursor, Grok). Tokens are read fresh for each request, held only in
/// that request, and never logged or stored; the vendors' own apps refresh them.
@MainActor
final class RemoteLane {
    private(set) var snapshot: ProviderUsage?
    private(set) var problem: String?
    private var nextAttempt = Date.distantPast
    private var inFlight = false
    let every: TimeInterval
    let name: String

    init(name: String, every: TimeInterval = 600) { self.name = name; self.every = every }

    func refreshNow() { if problem == nil { nextAttempt = .distantPast } }

    func poll(interactive: Bool, onUpdate: (() -> Void)?,
              _ fetch: @escaping @Sendable () async throws -> ProviderUsage) {
        guard interactive, !inFlight, Date() >= nextAttempt else { return }
        inFlight = true
        nextAttempt = Date().addingTimeInterval(every)
        Task { @MainActor in
            defer { inFlight = false }
            do {
                snapshot = try await fetch()
                problem = nil
            } catch let e as LaneError {
                log.error("\(self.name, privacy: .public): \(e.message, privacy: .public)")
                problem = e.message
                nextAttempt = Date().addingTimeInterval(e.retryAfter)
            } catch {
                log.error("\(self.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            onUpdate?()
        }
    }
}

struct LaneError: Error {
    var message: String
    var retryAfter: TimeInterval = 1800

    static func http(_ status: Int, vendor: String) -> LaneError {
        switch status {
        case 401, 403: LaneError(message: "\(vendor) sign-in expired. Open \(vendor) to renew it.", retryAfter: 3600)
        case 429:      LaneError(message: "\(vendor) is rate limiting; retrying later.", retryAfter: 1800)
        default:       LaneError(message: "\(vendor) usage endpoint returned \(status).")
        }
    }
}

extension Local {
    /// ISO-8601 string, epoch seconds, or epoch milliseconds (as number or string).
    static func time(_ v: Any?) -> TimeInterval? {
        if let s = v as? String, let d = ISO8601DateFormatter.lenient(s) { return d.timeIntervalSince1970 }
        guard let n = number(v) else { return nil }
        return n > 1e11 ? n / 1000 : n
    }

    static func getJSON(_ req: URLRequest, vendor: String) async throws -> [String: Any] {
        let (data, resp) = try await VendorSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw LaneError.http(status, vendor: vendor) }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LaneError(message: "\(vendor) usage response was not JSON.")
        }
        return o
    }
}
