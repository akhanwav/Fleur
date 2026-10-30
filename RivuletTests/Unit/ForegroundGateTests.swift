import XCTest
@testable import Rivulet

/// Requests for the screen wait out the background and are sent again on
/// return; everything else goes straight through.
final class ForegroundGateTests: XCTestCase {

    private let url = URL(string: "https://gate.test/item")!

    override func setUp() {
        super.setUp()
        GateTestProtocol.reset()
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GateTestProtocol.self]
        return URLSession(configuration: config)
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func test_inTheForeground_aHeldRequestGoesStraightThrough() async throws {
        let gate = ForegroundGate()
        let (data, _) = try await gate.data(for: URLRequest(url: url), in: session(), always: true)
        XCTAssertEqual(data, GateTestProtocol.body)
        XCTAssertEqual(GateTestProtocol.started, 1)
    }

    func test_inTheBackground_aRequestNotHeldIsSent() async throws {
        let gate = ForegroundGate()
        gate.enterBackground()
        let (data, _) = try await gate.data(for: URLRequest(url: url), in: session())
        XCTAssertEqual(data, GateTestProtocol.body)
    }

    func test_aHeldRequestMadeInTheBackground_waitsForTheReturn() async throws {
        let gate = ForegroundGate()
        let session = session()
        let request = URLRequest(url: url)
        gate.enterBackground()
        let task = Task {
            try await ForegroundGate.$holdsInBackground.withValue(true) {
                try await gate.data(for: request, in: session)
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(GateTestProtocol.started, 0)
        gate.enterForeground()
        let (data, _) = try await task.value
        XCTAssertEqual(data, GateTestProtocol.body)
        XCTAssertEqual(GateTestProtocol.started, 1)
    }

    func test_aHeldRequestInFlight_isCancelledAndSentAgainOnReturn() async throws {
        let gate = ForegroundGate()
        let session = session()
        let request = URLRequest(url: url)
        GateTestProtocol.hangFirst = true
        let task = Task {
            try await gate.data(for: request, in: session, always: true)
        }
        await waitUntil { GateTestProtocol.started == 1 }
        gate.enterBackground()
        await waitUntil { GateTestProtocol.stopped == 1 }
        XCTAssertEqual(GateTestProtocol.stopped, 1, "the request in flight is cancelled")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(GateTestProtocol.started, 1, "and not sent again while backgrounded")
        gate.enterForeground()
        let (data, _) = try await task.value
        XCTAssertEqual(data, GateTestProtocol.body)
        XCTAssertEqual(GateTestProtocol.started, 2)
    }

    func test_cancellingTheCallerWhileHeld_throws() async {
        let gate = ForegroundGate()
        let session = session()
        let request = URLRequest(url: url)
        gate.enterBackground()
        let task = Task {
            try await gate.data(for: request, in: session, always: true)
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled caller gets no answer")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(GateTestProtocol.started, 0)
    }
}

/// Answers every request, except that with `hangFirst` the first one never
/// finishes until it is cancelled.
private final class GateTestProtocol: URLProtocol {
    static let body = Data("ok".utf8)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _started = 0
    nonisolated(unsafe) private static var _stopped = 0
    nonisolated(unsafe) static var hangFirst = false

    static var started: Int { lock.withLock { _started } }
    static var stopped: Int { lock.withLock { _stopped } }

    static func reset() {
        lock.withLock {
            _started = 0
            _stopped = 0
            hangFirst = false
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let hang = Self.lock.withLock {
            Self._started += 1
            return Self.hangFirst && Self._started == 1
        }
        guard !hang, let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.withLock { Self._stopped += 1 }
    }
}
