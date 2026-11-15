import Foundation

enum RunState: String, Codable {
    case ok, failed, running
    case authError = "auth_error"
    case stale
}

struct HistoryEntry: Codable, Equatable {
    let state: RunState
    let url: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case state, url
        case createdAt = "created_at"
    }
}

/// A stage/job's status while a run is in progress — distinct from RunState
/// because "pending/queued" is a real, meaningful state here (the stage
/// hasn't started yet) that RunState has no equivalent for, and baking it
/// into RunState would pollute that enum's other uses (tray icon, worst-state).
enum StageState: String, Codable {
    case pending, running, ok, failed
}

/// One stage (GitLab: validate/test/build/...) or job (GitHub, which has no
/// stage concept — each job is its own row) in a currently-running pipeline.
struct RunningStage: Codable, Equatable {
    let name: String
    let status: StageState
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
    // Same optional-from-the-start reasoning as history/currentStep.
    let runningStages: [RunningStage]?

    enum CodingKeys: String, CodingKey {
        case name, platform, branch, state, label, url
        case updatedAt = "updated_at"
        case fetchedAt = "fetched_at"
        case history
        case currentStep = "current_step"
        case runningStages = "running_stages"
    }

    var recentHistory: [HistoryEntry] { history ?? [] }
    var runningStep: String? {
        guard state == .running, let currentStep, !currentStep.isEmpty else { return nil }
        return currentStep
    }
    var stages: [RunningStage] {
        guard state == .running else { return [] }
        return runningStages ?? []
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

struct HarborStatus: Codable {
    let generatedAt: String
    let repos: [RepoStatus]
    // Optional from the start — same lesson as RepoStatus.history: a key
    // that's only sometimes present must never break decoding everything else.
    let testflight: [TestFlightStatus]?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case repos
        case testflight
    }

    var testflightApps: [TestFlightStatus] { testflight ?? [] }
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

    static func ageSeconds(fetchedAt: String, now: Date = Date()) -> Int {
        guard !fetchedAt.isEmpty, let date = isoFormatter.date(from: fetchedAt) else {
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

func formatAge(_ seconds: Int) -> String {
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    return "\(seconds / 3600)h ago"
}

func loadStatus(from path: String) -> HarborStatus? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(HarborStatus.self, from: data)
}
