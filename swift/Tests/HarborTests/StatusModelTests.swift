import XCTest
@testable import Harbor

final class StatusModelTests: XCTestCase {
    func makeRepo(state: RunState, fetchedAt: String) -> RepoStatus {
        RepoStatus(name: "test-repo", platform: "gitlab", branch: "main",
                   state: state, label: "x", url: "", updatedAt: "", fetchedAt: fetchedAt,
                   history: [], currentStep: nil)
    }

    func testFreshOkStateIsNotStale() {
        let now = Date()
        let fetchedAt = DisplayState.isoFormatter.string(from: now)
        let repo = makeRepo(state: .ok, fetchedAt: fetchedAt)
        let display = DisplayState.compute(repo: repo, staleThreshold: 180, now: now)
        XCTAssertEqual(display.state, .ok)
    }

    func testOldFetchDowngradesToStaleRegardlessOfState() {
        let now = Date()
        let oldFetch = now.addingTimeInterval(-600) // 10 minutes old
        let fetchedAt = DisplayState.isoFormatter.string(from: oldFetch)
        let repo = makeRepo(state: .ok, fetchedAt: fetchedAt)
        let display = DisplayState.compute(repo: repo, staleThreshold: 180, now: now)
        XCTAssertEqual(display.state, .stale)
    }

    func testEmptyFetchedAtIsAlwaysStale() {
        let repo = makeRepo(state: .ok, fetchedAt: "")
        let display = DisplayState.compute(repo: repo, staleThreshold: 180)
        XCTAssertEqual(display.state, .stale)
    }

    /// Regression test: GitLab's timestamps include fractional seconds
    /// ("...40.679Z"), which the plain ISO8601 formatter can't parse at all —
    /// it silently returned nil and fell into the 999_999 sentinel, which
    /// then displayed as a bogus "277h ago" for data that was actually
    /// fresh (seen for real in the run picker's "Open in Browser" detail).
    func testAgeSecondsParsesFractionalSecondTimestamps() {
        let now = Date()
        let tenMinutesAgo = now.addingTimeInterval(-600)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fetchedAt = f.string(from: tenMinutesAgo)

        let age = DisplayState.ageSeconds(fetchedAt: fetchedAt, now: now)
        // Within 1s to absorb sub-second truncation in the format/parse
        // round-trip — the actual regression this guards against is a
        // 999_999 sentinel, off by orders of magnitude, not a rounding blip.
        XCTAssertLessThan(abs(age - 600), 2, "a fractional-second timestamp must parse to its real age, not fall back to the 999_999 stale sentinel")
    }

    func testWorstStatePriorityFailedBeatsEverything() {
        XCTAssertEqual(WorstState.compute([.ok, .running, .failed, .stale]), .failed)
    }

    func testWorstStatePriorityAuthBeatsRunningAndStale() {
        XCTAssertEqual(WorstState.compute([.ok, .stale, .authError, .running]), .authError)
    }

    func testWorstStateAllOkIsOk() {
        XCTAssertEqual(WorstState.compute([.ok, .ok]), .ok)
    }

    func testFormatAgeBuckets() {
        XCTAssertEqual(formatAge(30), "just now")
        XCTAssertEqual(formatAge(125), "2m ago")
        XCTAssertEqual(formatAge(7200), "2h ago")
    }

    /// Regression test: poll.sh's fallback entries (no-git-repo, not-found-in-prev,
    /// auth_error) never populate "history" at all. A single repo missing that key
    /// must not break decoding of the whole status.json — this happened for real
    /// with a watched repo that has no CI configured, and silently made the
    /// entire app fall back to a "stale" display.
    func testDecodingSucceedsWhenHistoryKeyIsEntirelyMissing() throws {
        let json = """
        {
          "generated_at": "2026-11-15T11:34:51Z",
          "repos": [
            {
              "name": "no-ci-repo",
              "platform": "gitlab",
              "branch": "",
              "state": "stale",
              "label": "Stale",
              "url": "",
              "updated_at": "",
              "fetched_at": "2026-11-15T11:34:51Z"
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(HarborStatus.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.repos.count, 1)
        XCTAssertEqual(decoded.repos[0].recentHistory, [])
        XCTAssertNil(decoded.repos[0].runningStep)
    }

    func testRunningStepOnlyShownWhenActuallyRunningAndNonEmpty() {
        let running = makeRepo(state: .running, fetchedAt: "")
        XCTAssertNil(running.runningStep, "base fixture has no current_step set")

        let runningWithStep = RepoStatus(name: "x", platform: "gitlab", branch: "main", state: .running,
                                          label: "Running", url: "", updatedAt: "", fetchedAt: "",
                                          history: [], currentStep: "test")
        XCTAssertEqual(runningWithStep.runningStep, "test")

        // common.sh never actually produces this combination (current_step is
        // recomputed fresh every poll from the live state), but runningStep
        // must not rely on the string alone — only trust it when state is
        // genuinely "running", as a defensive guard against future backend bugs.
        let okWithUnexpectedStep = RepoStatus(name: "x", platform: "gitlab", branch: "main", state: .ok,
                                               label: "OK", url: "", updatedAt: "", fetchedAt: "",
                                               history: [], currentStep: "test")
        XCTAssertNil(okWithUnexpectedStep.runningStep)
    }

    /// Stages moved from RepoStatus (only the newest, only while running) to
    /// each HistoryEntry (every fetched run has its own), so the picker can
    /// show real step detail for any selected run, not just the live one.
    /// Same missing-key lesson as elsewhere: an entry with no "stages" key
    /// at all (every entry before this feature shipped, and any of
    /// poll.sh's fallback paths) must decode cleanly as an empty list.
    func testHistoryEntryStagesDefaultsToEmptyWhenMissing() throws {
        let json = """
        {"state": "ok", "url": "", "created_at": ""}
        """
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.stageList, [])
    }

    func testHistoryEntryStagesPresent() {
        let stages = [RunningStage(name: "validate", status: .ok, jobs: nil), RunningStage(name: "test", status: .running, jobs: nil)]
        let entry = HistoryEntry(state: .running, url: "", createdAt: "", stages: stages, runId: nil)
        XCTAssertEqual(entry.stageList, stages)
    }

    func makeTestFlight(processing: ProcessingState, review: BetaReviewStatus?) -> TestFlightStatus {
        TestFlightStatus(name: "ExampleApp", bundleId: "com.example.app", processingState: processing,
                          betaReviewStatus: review, buildVersion: "1.0", buildNumber: "42",
                          url: "", updatedAt: "", fetchedAt: "")
    }

    func testTestFlightStateMapping() {
        XCTAssertEqual(makeTestFlight(processing: .processing, review: nil).state, .running)
        XCTAssertEqual(makeTestFlight(processing: .failed, review: nil).state, .failed)
        XCTAssertEqual(makeTestFlight(processing: .invalid, review: nil).state, .failed)
        XCTAssertEqual(makeTestFlight(processing: .valid, review: .approved).state, .ok)
        XCTAssertEqual(makeTestFlight(processing: .valid, review: nil).state, .ok,
                       "no review status yet (e.g. internal-only build) should not read as a problem")
        XCTAssertEqual(makeTestFlight(processing: .valid, review: .rejected).state, .failed)
        XCTAssertEqual(makeTestFlight(processing: .valid, review: .waitingForReview).state, .running)
        XCTAssertEqual(makeTestFlight(processing: .valid, review: .inReview).state, .running)
    }

    /// Same missing-key lesson as history/current_step: a status.json with no
    /// "testflight" key at all (true for every existing user until they add
    /// an app) must still decode cleanly.
    func testDecodingSucceedsWhenTestflightKeyIsEntirelyMissing() throws {
        let json = """
        {
          "generated_at": "2026-11-15T11:34:51Z",
          "repos": []
        }
        """
        let decoded = try JSONDecoder().decode(HarborStatus.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.testflightApps, [])
    }
}
