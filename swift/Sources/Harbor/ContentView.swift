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
}

struct RepoCardView: View {
    let repo: RepoStatus
    let staleThreshold: Int

    var display: DisplayState { DisplayState.compute(repo: repo, staleThreshold: staleThreshold) }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(display.state.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
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
                    Image(systemName: display.state.symbol)
                        .foregroundStyle(display.state.color)
                }

                if !repo.recentHistory.isEmpty {
                    let dotDiameter: CGFloat = 8
                    let dotSpacing: CGFloat = 6
                    let dotStride = dotDiameter + dotSpacing
                    let dotCount = repo.recentHistory.count

                    // A connecting rail behind the dots, like a real pipeline
                    // timeline — a continuous line from the first dot's
                    // center to the last, with colored dots layered on top
                    // (each dot visually interrupts the line under it, same
                    // as the reference ShipBoard/CIMon stage graphics).
                    ZStack(alignment: .leading) {
                        if dotCount > 1 {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(width: CGFloat(dotCount - 1) * dotStride, height: 1.5)
                                .offset(x: dotDiameter / 2)
                        }
                        HStack(spacing: dotSpacing) {
                            ForEach(Array(repo.recentHistory.enumerated()), id: \.offset) { _, entry in
                                Circle()
                                    .fill(entry.state.color)
                                    .frame(width: dotDiameter, height: dotDiameter)
                            }
                        }
                    }
                    .frame(height: dotDiameter)
                }

                if let step = repo.runningStep {
                    Text("Running · \(step)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(RunState.running.color)
                } else {
                    Text("\(repo.branch) · \(repo.platform) · \(formatAge(display.ageSeconds))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: repo.url), !repo.url.isEmpty {
                NSWorkspace.shared.open(url)
            }
        }
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
    let onQuit: () -> Void
    let onRevealConfig: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HARBOR")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            if let status, !status.repos.isEmpty || !status.testflightApps.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(status.repos) { repo in
                            RepoCardView(repo: repo, staleThreshold: staleThreshold)
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
