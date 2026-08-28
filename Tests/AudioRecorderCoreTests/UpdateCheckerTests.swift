import XCTest
@testable import AudioRecorderCore

final class AppVersionTests: XCTestCase {
    func testParsesPlainAndPrefixedVersions() throws {
        XCTAssertEqual(AppVersion("1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(AppVersion("v1.2.3")?.components, [1, 2, 3])
        XCTAssertEqual(AppVersion("V2.0")?.components, [2, 0])
        XCTAssertEqual(AppVersion(" 1.0.1 ")?.components, [1, 0, 1])
    }

    func testIgnoresPreReleaseSuffix() throws {
        XCTAssertEqual(AppVersion("1.4.0-beta.2")?.components, [1, 4, 0])
    }

    func testRejectsNonNumeric() {
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1.x.3"))
        XCTAssertNil(AppVersion(""))
    }

    func testOrdering() throws {
        let v100 = try XCTUnwrap(AppVersion("1.0.0"))
        let v101 = try XCTUnwrap(AppVersion("1.0.1"))
        let v110 = try XCTUnwrap(AppVersion("1.1.0"))
        let v200 = try XCTUnwrap(AppVersion("2.0.0"))
        let v1010 = try XCTUnwrap(AppVersion("1.0.10"))

        XCTAssertLessThan(v100, v101)
        XCTAssertLessThan(v101, v110)
        XCTAssertLessThan(v110, v200)
        // Numeric, not lexicographic: 1.0.10 > 1.0.1
        XCTAssertLessThan(v101, v1010)
    }

    /// Missing components are treated as zero, so "1.2" == "1.2.0".
    func testShorterVersionsCompareAsZeroPadded() throws {
        let short = try XCTUnwrap(AppVersion("1.2"))
        let long = try XCTUnwrap(AppVersion("1.2.0"))
        XCTAssertEqual(short, long)
        XCTAssertFalse(short < long)
        XCTAssertFalse(long < short)

        let patched = try XCTUnwrap(AppVersion("1.2.1"))
        XCTAssertLessThan(short, patched)
    }
}

/// Exercises the checker's decision logic against a stubbed URL session, so no
/// network access is required.
final class UpdateCheckerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "UpdateCheckerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeChecker(
        currentVersion: String,
        payload: String,
        statusCode: Int = 200
    ) -> UpdateChecker {
        StubURLProtocol.responseBody = Data(payload.utf8)
        StubURLProtocol.statusCode = statusCode
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return UpdateChecker(
            session: URLSession(configuration: configuration),
            defaults: defaults,
            currentVersion: currentVersion
        )
    }

    private func releaseJSON(
        tag: String, draft: Bool = false, prerelease: Bool = false
    ) -> String {
        """
        {
          "tag_name": "\(tag)",
          "html_url": "https://github.com/cmatskas/AudioRecorder/releases/tag/\(tag)",
          "body": "Release notes here",
          "draft": \(draft),
          "prerelease": \(prerelease)
        }
        """
    }

    func testReportsNewerVersion() async throws {
        let checker = makeChecker(currentVersion: "1.0.0", payload: releaseJSON(tag: "v1.1.0"))
        let update = try await checker.check(force: true)
        XCTAssertEqual(update?.version, "v1.1.0")
        XCTAssertEqual(update?.notes, "Release notes here")
    }

    func testIgnoresSameOrOlderVersion() async throws {
        let same = makeChecker(currentVersion: "1.2.0", payload: releaseJSON(tag: "v1.2.0"))
        let sameResult = try await same.check(force: true)
        XCTAssertNil(sameResult)

        let older = makeChecker(currentVersion: "2.0.0", payload: releaseJSON(tag: "v1.9.9"))
        let olderResult = try await older.check(force: true)
        XCTAssertNil(olderResult)
    }

    func testIgnoresDraftsAndPrereleases() async throws {
        let draft = makeChecker(
            currentVersion: "1.0.0", payload: releaseJSON(tag: "v2.0.0", draft: true)
        )
        let draftResult = try await draft.check(force: true)
        XCTAssertNil(draftResult)

        let pre = makeChecker(
            currentVersion: "1.0.0", payload: releaseJSON(tag: "v2.0.0", prerelease: true)
        )
        let preResult = try await pre.check(force: true)
        XCTAssertNil(preResult)
    }

    func testSkippedVersionIsNotReportedAgain() async throws {
        let checker = makeChecker(currentVersion: "1.0.0", payload: releaseJSON(tag: "v1.5.0"))
        let update = try await checker.check(force: true)
        let found = try XCTUnwrap(update)
        checker.skip(found)

        let again = try await checker.check(force: true)
        XCTAssertNil(again)
    }

    /// A newer version than the skipped one must still be reported.
    func testNewerThanSkippedIsStillReported() async throws {
        let first = makeChecker(currentVersion: "1.0.0", payload: releaseJSON(tag: "v1.5.0"))
        let firstResult = try await first.check(force: true)
        let skipped = try XCTUnwrap(firstResult)
        first.skip(skipped)

        let second = makeChecker(currentVersion: "1.0.0", payload: releaseJSON(tag: "v1.6.0"))
        let update = try await second.check(force: true)
        XCTAssertEqual(update?.version, "v1.6.0")
    }

    /// Without `force`, a second check inside the throttle window is skipped.
    func testDailyThrottle() async throws {
        let checker = makeChecker(currentVersion: "1.0.0", payload: releaseJSON(tag: "v1.1.0"))
        let first = try await checker.check(force: false)
        XCTAssertNotNil(first)
        let throttled = try await checker.check(force: false)
        XCTAssertNil(throttled)
        // Forcing bypasses the throttle.
        let forced = try await checker.check(force: true)
        XCTAssertNotNil(forced)
    }

    func testHTTPErrorThrows() async {
        let checker = makeChecker(
            currentVersion: "1.0.0", payload: "{}", statusCode: 403
        )
        do {
            _ = try await checker.check(force: true)
            XCTFail("expected an error")
        } catch {
            // Rate limiting or outage must surface, not be silently swallowed.
        }
    }
}

/// Returns a canned HTTP response for any request.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
