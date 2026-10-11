// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Network

/// Loopback HTTP relay in front of a server whose certificate only
/// `PlexCertificateDelegate` accepts. AVPlayer has no trust hook, so the `hls`
/// route plays through this when system trust refuses the origin (#337).
nonisolated final class HLSTrustRelay: @unchecked Sendable {
    /// `scheme://host:port`, no trailing slash.
    private let origin: String
    private let listener: NWListener
    private let session = URLSession(
        configuration: .ephemeral, delegate: PlexCertificateDelegate(), delegateQueue: nil)
    private let queue = DispatchQueue(label: "com.rivulet.hls-trust-relay")

    private static let headerEnd = Data("\r\n\r\n".utf8)
    /// Request headers that describe the loopback hop, not the origin request.
    private static let hopHeaders: Set<String> = ["host", "connection", "accept-encoding", "keep-alive"]
    private static let trustFailures: Set<Int> = [
        NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
    ]

    init?(origin url: URL) {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard url.host != nil, let origin = components.string,
              let listener = try? NWListener(using: parameters) else { return nil }
        self.origin = origin
        self.listener = listener
    }

    deinit {
        listener.cancel()
        session.invalidateAndCancel()
    }

    /// A listening relay for `url`'s origin, or nil if the listener cannot start.
    static func start(for url: URL) async -> HLSTrustRelay? {
        guard let relay = HLSTrustRelay(origin: url) else { return nil }
        let listener = relay.listener
        listener.newConnectionHandler = { [weak relay] connection in relay?.accept(connection) }
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume(returning: true)
                case .failed, .cancelled: continuation.resume(returning: false)
                default: return
                }
                // One answer only: a later state must not resume again.
                listener.stateUpdateHandler = nil
            }
            listener.start(queue: relay.queue)
        }
        return ready ? relay : nil
    }

    /// Whether one system-trust handshake with `url`'s origin is refused.
    /// Anything else (unreachable, timeout, an HTTP error) answers false.
    static func systemTrustRefuses(_ url: URL) async -> Bool {
        guard url.scheme == "https",
              let probe = URL(string: "/identity", relativeTo: url)?.absoluteURL else { return false }
        // A fresh session, so no connection another session already trusted is reused.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(for: URLRequest(url: probe, timeoutInterval: 5))
            return false
        } catch {
            let nsError = error as NSError
            return nsError.domain == NSURLErrorDomain && trustFailures.contains(nsError.code)
        }
    }

    /// `url` re-pointed at the relay, or nil when it is not on this relay's origin.
    func localURL(for url: URL) -> URL? {
        guard let port = listener.port?.rawValue, url.absoluteString.hasPrefix(origin + "/") else { return nil }
        return URL(string: "http://127.0.0.1:\(port)" + url.absoluteString.dropFirst(origin.count))
    }

    /// The origin request for one relayed HTTP request head (no trailing blank line).
    func originRequest(head: String) -> URLRequest? {
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[1].hasPrefix("/"),
              let url = URL(string: origin + parts[1]) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = String(parts[0])
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            if Self.hopHeaders.contains(name.lowercased()) { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(from: connection, buffered: Data())
    }

    private func readHead(from connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil else { return connection.cancel() }
            let buffer = buffered + data
            guard let end = buffer.range(of: Self.headerEnd) else {
                if isComplete || buffer.count > 65_536 { return connection.cancel() }
                return self.readHead(from: connection, buffered: buffer)
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            guard let request = self.originRequest(head: head) else { return connection.cancel() }
            self.forward(request, to: connection)
        }
    }

    // ponytail: buffers each response whole and closes the connection after it.
    // Playlists and segments are small; stream and keep alive if startup lags.
    private func forward(_ request: URLRequest, to connection: NWConnection) {
        Task {
            var head = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n"
            var body = Data()
            if let (data, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse {
                head = "HTTP/1.1 \(http.statusCode) Relayed\r\n"
                for name in ["Content-Type", "Content-Range", "Accept-Ranges", "Cache-Control"] {
                    if let value = http.value(forHTTPHeaderField: name) { head += "\(name): \(value)\r\n" }
                }
                head += "Content-Length: \(data.count)\r\n"
                body = data
            }
            connection.send(
                content: Data((head + "Connection: close\r\n\r\n").utf8) + body,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
