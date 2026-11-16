import SwiftUI

extension RunState {
    var color: Color {
        switch self {
        case .ok: return .green
        case .failed: return .red
        case .running: return .yellow
        case .authError: return .orange
        case .stale: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "circle.dotted"
        case .authError: return "exclamationmark.triangle.fill"
        case .stale: return "questionmark.circle.fill"
        }
    }

    var displayLabel: String {
        switch self {
        case .ok: return "OK"
        case .failed: return "Failed"
        case .running: return "Running"
        case .authError: return "Auth"
        case .stale: return "Stale"
        }
    }
}

extension StageState {
    var color: Color {
        switch self {
        case .ok: return .green
        case .failed: return .red
        case .running: return .yellow
        case .pending: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "circle.dotted"
        case .pending: return "circle"
        }
    }
}

/// validate -> test -> build -> ... breakdown for one run, mirroring the
/// stage COLUMNS GitLab's own pipeline page shows left-to-right (not a
/// top-down list) — each stage's individual jobs stacked vertically within
/// its own column, so "where are we, is it stuck" reads the same way
/// GitLab's own UI does. Wrapped in its own horizontal ScrollView so a
/// pipeline with many stages scrolls within this block instead of forcing
/// the whole card (and panel) wider — same behavior GitLab's own page has
/// when stages overflow. GitHub jobs have no stage to group under (one
/// column per job, jobList empty), so they render as a row of single-job
/// columns instead of stage columns — same shape, no stage grouping.
struct StageListView: View {
    let stages: [RunningStage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(stages.enumerated()), id: \.element.name) { index, stage in
                    // Boxing each stage's jobs together (not just stacking
                    // them under a header) is what actually makes "these
                    // belong together" unambiguous — a connector alone
                    // between headers left the job rows underneath reading
                    // as loose, ungrouped lines. Matches the reference
                    // bordered-card-per-stage layout.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: stage.status.symbol)
                                .font(.system(size: 9))
                                .foregroundStyle(stage.status.color)
                            Text(stage.name)
                                .font(.system(.caption2, design: .monospaced))
                                .fontWeight(.semibold)
                                .foregroundStyle(stage.status == .pending ? .secondary : .primary)
                        }
                        ForEach(stage.jobList, id: \.name) { job in
                            HStack(spacing: 5) {
                                Image(systemName: job.status.symbol)
                                    .font(.system(size: 8))
                                    .foregroundStyle(job.status.color)
                                Text(job.name)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(job.status == .pending ? .secondary : .primary)
                            }
                        }
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Arrow connecting this stage's box to the next, so the
                    // validate -> test -> build -> ... order still reads as
                    // a flow between the boxes — aligned to roughly the
                    // header row's vertical center, accounting for the
                    // box's own top padding now.
                    if index < stages.count - 1 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
            }
        }
    }
}

/// Every repo's standard card: a left-column picker over the last 3 runs
/// (same history the backend already fetches, no extra API cost) and a
/// right-side detail pane for whichever run is selected (newest by default).
/// The live stage breakdown only ever applies to the newest run while it's
/// actually running — older runs show their basic outcome + a link, since
/// fetching full job/stage detail for finished runs isn't worth the extra
/// API calls for data that's no longer actionable. This used to be a
/// separate drill-in screen behind a tap + Back button; the user wanted it
/// as the standing default for every card instead, so there's no navigation
/// here at all — just always-visible detail.
struct RepoCardView: View {
    let repo: RepoStatus
    let staleThreshold: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void
    @State private var selectedIndex: Int

    init(repo: RepoStatus, staleThreshold: Int, isRefreshing: Bool, onRefresh: @escaping () -> Void) {
        self.repo = repo
        self.staleThreshold = staleThreshold
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        _selectedIndex = State(initialValue: max(repo.recentHistory.count - 1, 0))
    }

    var display: DisplayState { DisplayState.compute(repo: repo, staleThreshold: staleThreshold) }
    // Whichever run is currently selected in the picker (defaults to
    // newest) — the title-row "open in browser" icon follows the
    // selection rather than always opening the latest run, so it's a true
    // move of the old per-run "Open in Browser" button, not a second,
    // narrower shortcut that loses the ability to open an older run.
    var selectedEntry: HistoryEntry? {
        repo.recentHistory.indices.contains(selectedIndex) ? repo.recentHistory[selectedIndex] : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(display.state.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 8) {
                // .top alignment + fixedSize so a name that wraps (past the
                // panel's width cap, see AppDelegate.idealContentWidth)
                // grows downward instead of compressing or clipping, with
                // the status icon staying pinned to the first line.
                HStack(alignment: .top) {
                    Text(repo.name)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(action: onRefresh) {
                        if isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                    .help("Refresh this repo")
                    if let entryUrl = selectedEntry?.url, !entryUrl.isEmpty {
                        Button(action: {
                            if let url = URL(string: entryUrl) {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open selected run in browser")
                    }
                    Image(systemName: display.state.symbol)
                        .foregroundStyle(display.state.color)
                }

            if repo.recentHistory.isEmpty {
                Text("No run history yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(repo.recentHistory.enumerated()), id: \.offset) { idx, entry in
                            let isNewest = idx == repo.recentHistory.count - 1
                            Button(action: { selectedIndex = idx }) {
                                HStack(spacing: 6) {
                                    Circle().fill(entry.state.color).frame(width: 7, height: 7)
                                    Text(isNewest ? "Latest" : "Run \(idx + 1)")
                                        .font(.system(.caption2, design: .monospaced))
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(idx == selectedIndex ? Color.secondary.opacity(0.2) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 84)

                    Divider()

                    if repo.recentHistory.indices.contains(selectedIndex) {
                        let entry = repo.recentHistory[selectedIndex]
                        let isNewest = selectedIndex == repo.recentHistory.count - 1
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Image(systemName: entry.state.symbol)
                                    .foregroundStyle(entry.state.color)
                                Text(entry.state.displayLabel)
                                    .font(.system(.caption, design: .monospaced))
                                    .fontWeight(.semibold)
                            }

                            if let runId = entry.runId, !runId.isEmpty {
                                Text("\(repo.platform == "github" ? "Run" : "Pipeline") #\(runId)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            if isNewest, let step = repo.runningStep {
                                Text("Running · \(step)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(RunState.running.color)
                            } else {
                                Text(formatAge(DisplayState.ageSeconds(fetchedAt: entry.createdAt)))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            // Every fetched run now carries its own step
                            // breakdown (not just the live one), so whichever
                            // run is selected in the picker shows its real
                            // stages — a finished run's stages are just all
                            // ok/failed instead of some still pending.
                            if !entry.stageList.isEmpty {
                                StageListView(stages: entry.stageList)
                            }
                            // "Open in Browser" moved to the title row's
                            // icon above (follows this same selection) —
                            // no longer duplicated down here.
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct TestFlightCardView: View {
    let app: TestFlightStatus
    let staleThreshold: Int

    var display: DisplayState { DisplayState.compute(testflight: app, staleThreshold: staleThreshold) }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(display.state.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    // paperplane badge distinguishes this at a glance as a
                    // TestFlight/App Store entry, not a git-based pipeline.
                    Image(systemName: "paperplane.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(app.name)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: display.state.symbol)
                        .foregroundStyle(display.state.color)
                }

                Text("\(app.label) · \(formatAge(display.ageSeconds))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: app.url), !app.url.isEmpty {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

struct ContentView: View {
    let status: HarborStatus?
    let staleThreshold: Int
    let isRefreshing: Bool
    let refreshingRepoNames: Set<String>
    let onQuit: () -> Void
    let onRevealConfig: () -> Void
    let onRefreshAll: () -> Void
    let onRefreshRepo: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HARBOR")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onRefreshAll) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help("Refresh all now")
                .padding(.trailing, 12)
            }
            .padding(.leading, 12)
            .padding(.top, 10)

            if let status, !status.repos.isEmpty || !status.testflightApps.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(status.repos) { repo in
                            RepoCardView(repo: repo, staleThreshold: staleThreshold,
                                         isRefreshing: refreshingRepoNames.contains(repo.name),
                                         onRefresh: { onRefreshRepo(repo.name) })
                        }

                        // A clear section break, not just a spacing gap —
                        // TestFlight builds aren't a git-based pipeline, so
                        // they get their own labeled divider instead of
                        // blending into the repo list above.
                        if !status.testflightApps.isEmpty {
                            HStack(spacing: 8) {
                                Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
                                Text("TESTFLIGHT")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
                            }
                            .padding(.top, 4)

                            ForEach(status.testflightApps) { app in
                                TestFlightCardView(app: app, staleThreshold: staleThreshold)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            } else {
                Text("No status.json yet — check the launchd job")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }

            Divider()
            HStack {
                Button("Reveal Config", action: onRevealConfig)
                Spacer()
                Button("Quit Harbor", action: onQuit)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: .infinity,
               minHeight: 240, idealHeight: 420, maxHeight: .infinity)
    }
}
