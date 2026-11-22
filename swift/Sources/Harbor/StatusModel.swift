import Foundation

enum RunState: String, Codable {
    case ok, failed, running
    case authError = "auth_error"
    case stale
}

/// A stage/job's status within one run — distinct from RunState because
/// "pending/queued" is a real, meaningful state here (the stage hasn't
/// started yet) that RunState has no equivalent for, and baking it into
/// RunState would pollute that enum's other uses (tray icon, worst-state).
enum StageState: String, Codable {
    case pending, running, ok, failed
}

/// One job within a GitLab stage. GitHub has no stage concept, so its jobs
/// are modeled directly as top-level RunningStage entries with no jobs of
/// their own (jobs stays nil/empty there).
struct StageJob: Codable, Equatable {
    let name: String
    let status: StageState
}

/// One stage (GitLab: validate/test/build/...) or job (GitHub, which has no
/// stage concept — each job is its own row) within a single run. For
/// GitLab, `jobs` holds every individual job inside that stage (not just
/// the stage's aggregate status) — matches GitLab's own pipeline UI, which
/// shows each job in its stage's column, e.g. "validate" containing
/// validate-ios-key / validate-runner-count / validate-supabase-auth.
struct RunningStage: Codable, Equatable {
    let name: String
    let status: StageState
    let jobs: [StageJob]?

    var jobList: [StageJob] { jobs ?? [] }
}

struct HistoryEntry: Codable, Equatable {
    let state: RunState
    let url: String
    let createdAt: String
    // Optional, same reasoning as RepoStatus.history: fetched for every
    // returned run now (not just the latest), but poll.sh's fallback
    // entries never populate it.
    let stages: [RunningStage]?
    // GitHub calls this a "run" ID, GitLab a "pipeline" ID — one neutral
    // field name either way. Also optional: fallback entries never set it.
    let runId: String?

    enum CodingKeys: String, CodingKey {
        case state, url, stages
        case createdAt = "created_at"
        case runId = "run_id"
    }

    var stageList: [RunningStage] { stages ?? [] }
}

struct RepoStatus: Codable, Identifiable {
    var id: String { name }
    let name: String
    let platform: String
    let branch: String
    let state: RunState
    let label: String
    let url: String
    let updatedAt: String
    let fetchedAt: String
    // Optional: poll.sh's fallback entries (no-git-repo / not-found-in-prev /
    // auth_error) don't go through common.sh's fetch functions and so never
    // populate this field. A non-optional array here breaks decoding of the
    // ENTIRE status.json over a single repo missing the key — this bit us
    // for real with a watched repo that has no CI configured.
    let history: [HistoryEntry]?
    // Also optional, same reasoning: common.sh only populates this while a
    // run is actually "running" (it's not worth the extra API call
    // otherwise), and poll.sh's fallback entries never set it at all.
    let currentStep: String?

    enum CodingKeys: String, CodingKey {
        case name, platform, branch, state, label, url
        case updatedAt = "updated_at"
        case fetchedAt = "fetched_at"
        case history
        case currentStep = "current_step"
    }

    var recentHistory: [HistoryEntry] { history ?? [] }
    var runningStep: String? {
        guard state == .running, let currentStep, !currentStep.isEmpty else { return nil }
        return currentStep
    }
}

enum ProcessingState: String, Codable {
    case processing, failed, invalid, valid
}

enum BetaReviewStatus: String, Codable {
    case waitingForReview = "waiting_for_review"
    case inReview = "in_review"
    case rejected
    case approved

    var displayName: String {
        switch self {
        case .waitingForReview: return "Waiting for Review"
        case .inReview: return "In Review"
        case .rejected: return "Rejected"
        case .approved: return "Approved"
        }
    }
}

/// One build in a TestFlight app's recent history (newest last, same
/// picker convention as HistoryEntry/RepoCardView). Each build has no
/// separate TestFlight deep link of its own, so `url` is just the app's
/// TestFlight page, repeated — same value as the parent TestFlightStatus.
struct TestFlightHistoryEntry: Codable, Equatable {
    let processingState: ProcessingState
    let betaReviewStatus: BetaReviewStatus?
    let buildVersion: String
    let buildNumber: String
    let uploadedAt: String
    let url: String

    enum CodingKeys: String, CodingKey {
        case processingState = "processing_state"
        case betaReviewStatus = "beta_review_status"
        case buildVersion = "build_version"
        case buildNumber = "build_number"
        case uploadedAt = "uploaded_at"
        case url
    }

    var state: RunState {
        switch processingState {
        case .processing: return .running
        case .failed, .invalid: return .failed
        case .valid:
            switch betaReviewStatus {
            case .approved, .none: return .ok
            case .rejected: return .failed
            case .waitingForReview, .inReview: return .running
            }
        }
    }

    var label: String {
        var parts = ["Build \(buildVersion) (\(buildNumber)): \(processingState.rawValue.capitalized)"]
        if let betaReviewStatus {
            parts.append("Review: \(betaReviewStatus.displayName)")
        }
        return parts.joined(separator: " · ")
    }
}

/// TestFlight/App Store Connect doesn't fit RepoStatus's git-remote model at
/// all (no path, no branch) and carries TWO independent status dimensions
/// (build processing vs. beta review) instead of one — so it's its own type,
/// mapped down to the shared RunState only for color/icon/worst-state reuse.
struct TestFlightStatus: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let bundleId: String
    let processingState: ProcessingState
    let betaReviewStatus: BetaReviewStatus?
    let buildVersion: String
    let buildNumber: String
    let url: String
    let updatedAt: String
    let fetchedAt: String
    // "auth" (App Store Connect key rejected) or "missing_key" (no .p8 on
    // disk for the configured key_id) — set only by poll.sh's fallback
    // entries, never by a real fetch, so it must win over processingState
    // in both `state` and `label` below. Optional for the same reason
    // every other sometimes-absent field here is: a real fetch's JSON
    // never includes this key at all.
    let fetchError: String?
    // Last few builds (oldest first, same convention as RepoStatus.history),
    // for apps that release more than one build at a time — poll.sh's
    // fallback entries never populate this, same reasoning as elsewhere.
    let history: [TestFlightHistoryEntry]?

    enum CodingKeys: String, CodingKey {
        case name
        case bundleId = "bundle_id"
        case processingState = "processing_state"
        case betaReviewStatus = "beta_review_status"
        case buildVersion = "build_version"
        case buildNumber = "build_number"
        case url
        case updatedAt = "updated_at"
        case fetchedAt = "fetched_at"
        case fetchError = "fetch_error"
        case history
    }

    var recentHistory: [TestFlightHistoryEntry] { history ?? [] }

    var state: RunState {
        if fetchError != nil { return .authError }
        switch processingState {
        case .processing: return .running
        case .failed, .invalid: return .failed
        case .valid:
            switch betaReviewStatus {
            case .approved, .none: return .ok
            case .rejected: return .failed
            case .waitingForReview, .inReview: return .running
            }
        }
    }

    var label: String {
        if let fetchError {
            return fetchError == "missing_key" ? "No ASC key configured" : "Auth"
        }
        var parts = ["Build \(buildVersion) (\(buildNumber)): \(processingState.rawValue.capitalized)"]
        if let betaReviewStatus {
            parts.append("Review: \(betaReviewStatus.displayName)")
        }
        return parts.joined(separator: " · ")
    }
}

struct HarborStatus: Codable {
    let generatedAt: String
    let repos: [RepoStatus]
    // Optional from the start — same lesson as RepoStatus.history: a key
    // that's only sometimes present must never break decoding everything else.
    let testflight: [TestFlightStatus]?
    // Cached by poll.sh on the normal cycle now (bin/local-repos.sh), not
    // fetched on demand when the tab opens — same reasoning as testflight.
    let localRepos: [RepoBranchReport]?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case repos
        case testflight
        case localRepos = "local_repos"
    }

    var testflightApps: [TestFlightStatus] { testflight ?? [] }
    var localRepoReports: [RepoBranchReport] { localRepos ?? [] }
}

/// A repo's state as actually displayed, after applying the staleness rule:
/// if the last successful fetch is older than `staleThreshold` seconds, the
/// display state becomes `.stale` regardless of the underlying real state —
/// ported unchanged from the v0.1 xbar plugin's `display_badge` logic.
struct DisplayState {
    let state: RunState
    let ageSeconds: Int

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // GitLab's timestamps include fractional seconds ("...40.679Z"), which
    // the plain formatter above can't parse at all — it silently returns
    // nil, which fed straight into the 999_999 fallback below and displayed
    // as a bogus "277h ago" for data that was actually fresh. GitHub's
    // timestamps have no fraction, so both formatters stay in play.
    static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func ageSeconds(fetchedAt: String, now: Date = Date()) -> Int {
        guard !fetchedAt.isEmpty else { return 999_999 }
        guard let date = isoFormatter.date(from: fetchedAt) ?? isoFormatterWithFractionalSeconds.date(from: fetchedAt) else {
            return 999_999
        }
        return max(0, Int(now.timeIntervalSince(date)))
    }

    static func compute(repo: RepoStatus, staleThreshold: Int, now: Date = Date()) -> DisplayState {
        let age = ageSeconds(fetchedAt: repo.fetchedAt, now: now)
        if age > staleThreshold {
            return DisplayState(state: .stale, ageSeconds: age)
        }
        return DisplayState(state: repo.state, ageSeconds: age)
    }

    static func compute(testflight app: TestFlightStatus, staleThreshold: Int, now: Date = Date()) -> DisplayState {
        let age = ageSeconds(fetchedAt: app.fetchedAt, now: now)
        if age > staleThreshold {
            return DisplayState(state: .stale, ageSeconds: age)
        }
        return DisplayState(state: app.state, ageSeconds: age)
    }
}

enum WorstState {
    /// Priority order from the design spec: failed > auth_error > running > stale > ok.
    static func compute(_ displayStates: [RunState]) -> RunState {
        if displayStates.contains(.failed) { return .failed }
        if displayStates.contains(.authError) { return .authError }
        if displayStates.contains(.running) { return .running }
        if displayStates.contains(.stale) { return .stale }
        return .ok
    }
}

/// Floats repos with a currently-running pipeline to the top so one you're
/// watching doesn't get lost further down the list — a stable sort, so
/// everything else (including a repo that just stopped running) keeps its
/// config order underneath instead of jumping around. No separate "pin"
/// state to set or clear: a repo leaves the top on its own, the instant
/// its own real state stops being .running.
func sortedRunningFirst(_ repos: [RepoStatus], staleThreshold: Int, now: Date = Date()) -> [RepoStatus] {
    repos.sorted { a, b in
        let aRunning = DisplayState.compute(repo: a, staleThreshold: staleThreshold, now: now).state == .running
        let bRunning = DisplayState.compute(repo: b, staleThreshold: staleThreshold, now: now).state == .running
        return aRunning && !bRunning
    }
}

/// One prunable worktree, exactly as `git worktree list --porcelain`
/// reports it (reason text is git's own, not reinterpreted).
struct PrunableWorktree: Codable {
    let path: String
    let reason: String
}

/// Local-only git-hygiene report for one configured repo (bin/local-repos.sh),
/// computed on demand when the Local Repos tab opens — read-only, no
/// delete/prune action anywhere downstream of this.
struct RepoBranchReport: Codable, Identifiable {
    var id: String { name }
    let name: String
    let mergedBranches: [String]
    let prunableWorktrees: [PrunableWorktree]
}

func formatAge(_ seconds: Int) -> String {
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    return "\(seconds / 3600)h ago"
}

func loadStatus(from path: String) -> HarborStatus? {
    guard let data = FileManager.default.contents(atPath: path) else {
        harborLog("loadStatus: no file at \(path)")
        return nil
    }
    do {
        return try JSONDecoder().decode(HarborStatus.self, from: data)
    } catch {
        harborLog("loadStatus: decode failed for \(path): \(error)")
        return nil
    }
}
