import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    // NSPopover has no user-resize affordance at all, so the dropdown is a
    // real floating panel instead — gives a draggable bottom-right resize
    // corner like any normal window, while staying borderless/non-activating
    // so it behaves like a menu bar dropdown (no Dock/title bar, closes on
    // click-away via windowDidResignKey below).
    private var panel: NSPanel!
    // Assigned ONCE in applicationDidFinishLaunching and never replaced.
    // Refreshing updates hostingController.rootView in place instead of
    // reassigning panel.contentViewController — reassigning it (the original
    // approach) makes AppKit auto-resize the window to fit the new content
    // controller's generic ideal size on every refresh tick, which produced
    // a visible grow-then-shrink flash every 5 seconds while the panel was
    // open, racing against our own explicit idealContentHeight sizing below.
    private var hostingController: NSHostingController<ContentView>!
    private var timer: Timer?
    private var lastRepoCount = 0
    private var lastRepoNames: [String] = []
    private var lastRepos: [RepoStatus] = []
    private var lastTestflightApps: [TestFlightStatus] = []
    private var isRefreshing = false
    private var refreshingRepoNames: Set<String> = []
    private let statusPath = NSString(string: "~/.harbor/status.json").expandingTildeInPath
    private let configPath = NSString(string: "~/.harbor/config.json").expandingTildeInPath
    // Set by install.sh into the launchd plist's EnvironmentVariables — the
    // compiled binary has no other way to know where its own source repo
    // (and therefore bin/poll.sh) lives at runtime. Manual/debug launches
    // outside launchd won't have this set; "Refresh All" just no-ops then.
    private let repoDir = ProcessInfo.processInfo.environment["HARBOR_REPO_DIR"]

    // Rough per-row heights for auto-sizing the panel to its content. These
    // are estimates of each card view's actual layout — not pixel-exact,
    // but close enough that any small mismatch just shows as a sliver of
    // extra/short space rather than clipping anything, since the content is
    // already in a ScrollView. Separate heights per card "shape" (expanded
    // repo card with the run picker + detail pane, collapsed single-line
    // card, TestFlight card) because mixing them under one flat per-card
    // number is exactly what made the panel oversized whenever "errors
    // only" or a search filter collapsed/hid most of the list — the old
    // estimate always assumed every visible row was a full expanded repo
    // card. Driven by real counts from ContentView now, not a guess.
    private let cardHeight: CGFloat = 130
    private let collapsedCardHeight: CGFloat = 44
    private let testflightCardHeight: CGFloat = 60
    private let testflightLabelHeight: CGFloat = 28
    private let cardSpacing: CGFloat = 8
    private let headerHeight: CGFloat = 70
    private let footerHeight: CGFloat = 44
    // Past this the panel stops growing and the ScrollView takes over
    // internally instead of pushing the panel off-screen for a long
    // visible list.
    private let maxContentHeight: CGFloat = 760
    // Raised from 420: that cap only ever measured repo name width, but the
    // horizontal stage-column breakdown (validate | test | build | ...,
    // each with its own jobs) regularly needs much more than that to avoid
    // the inner horizontal scroll. Still a real cap, not unlimited — a
    // pathological pipeline with many wide stages still scrolls internally
    // past this width instead of growing forever.
    private let maxContentWidth: CGFloat = 900

    /// Real target panel height for the given visible/collapsed counts —
    /// see the constants above for why this replaced a flat per-card guess.
    private func targetContentHeight(expandedCount: Int, collapsedCount: Int, testflightCount: Int) -> CGFloat {
        let totalCards = expandedCount + collapsedCount + testflightCount
        guard totalCards > 0 else {
            return max(headerHeight + footerHeight, panel.minSize.height)
        }
        let cardsHeight = CGFloat(expandedCount) * cardHeight
            + CGFloat(collapsedCount) * collapsedCardHeight
            + CGFloat(testflightCount) * testflightCardHeight
            + (testflightCount > 0 ? testflightLabelHeight : 0)
        let spacingHeight = CGFloat(max(totalCards - 1, 0)) * cardSpacing
        let uncapped = headerHeight + cardsHeight + spacingHeight + footerHeight
        return max(min(uncapped, maxContentHeight), panel.minSize.height)
    }

    /// Repos (post stale-threshold compute, not post-filter — used only for
    /// the very first open, where ContentView hasn't reported real
    /// post-search/toggle counts yet) split into "would show expanded" vs
    /// "would collapse" under the default errorsOnly=true, no-search state
    /// ContentView actually opens with.
    private func defaultCounts(repos: [RepoStatus], threshold: Int) -> (expanded: Int, collapsed: Int) {
        var expanded = 0, collapsed = 0
        for repo in repos {
            if DisplayState.compute(repo: repo, staleThreshold: threshold).state == .ok {
                collapsed += 1
            } else {
                expanded += 1
            }
        }
        return (expanded, collapsed)
    }

    /// Widest repo name's rendered width (same font/weight RepoCardView uses
    /// for the title), OR the widest stage-column row (whichever is wider),
    /// plus chrome, clamped to [panel.minSize.width, maxContentWidth]. Past
    /// that cap the window stops growing — names wrap (.fixedSize) and the
    /// stage row scrolls internally (ScrollView in StageListView) instead.
    private func idealContentWidth(repoNames: [String], repos: [RepoStatus]) -> CGFloat {
        let nameFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let longestNameWidth = repoNames
            .map { ($0 as NSString).size(withAttributes: [.font: nameFont]).width }
            .max() ?? 0
        // card horizontal padding (10 left + 10 right) + accent bar (4) +
        // the three title-row icons (refresh, open-in-browser, and the
        // status icon — now a 20x20 solid badge tile, not a bare glyph)
        // with their spacing (~52)
        let nameChrome: CGFloat = 10 + 10 + 4 + 52

        // Measures the same default-selected run every card opens to (the
        // newest/"Latest" entry) — matching RepoCardView's own default
        // selectedIndex — since that's what's actually visible without the
        // viewer picking an older run first.
        let stageFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let jobFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let iconAllowance: CGFloat = 14 + 12 // status glyph + its spacing, plus the stage box's own 6pt padding on each side
        // HStack spacing (6) on each side of the arrow connector (~10 at
        // this size) between columns, matching StageListView's actual layout.
        let columnSpacing: CGFloat = 6 + 10 + 6

        let widestStageRow = repos.compactMap { repo -> CGFloat? in
            guard let latest = repo.recentHistory.last else { return nil }
            let stages = latest.stageList
            guard !stages.isEmpty else { return nil }
            let columnWidths = stages.map { stage -> CGFloat in
                let stageWidth = (stage.name as NSString).size(withAttributes: [.font: stageFont]).width
                let widestJob = stage.jobList
                    .map { ($0.name as NSString).size(withAttributes: [.font: jobFont]).width }
                    .max() ?? 0
                return max(stageWidth, widestJob) + iconAllowance
            }
            return columnWidths.reduce(0, +) + columnSpacing * CGFloat(max(columnWidths.count - 1, 0))
        }.max() ?? 0

        // picker column (84) + its spacing (10) + divider (1) + its spacing
        // (10), same layout RepoCardView actually uses, plus the shared
        // name-row chrome above.
        let stageRowChrome: CGFloat = nameChrome + 84 + 10 + 1 + 10

        let target = max(longestNameWidth + nameChrome, widestStageRow + stageRowChrome)
        return min(max(target, panel.minSize.width), maxContentWidth)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .closable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 240)
        panel.delegate = self

        hostingController = NSHostingController(
            rootView: ContentView(status: nil, staleThreshold: 180, isRefreshing: false, refreshingRepoNames: [],
                                   onQuit: { NSApp.terminate(nil) },
                                   onRevealConfig: { [weak self] in self?.revealConfig() },
                                   onRefreshAll: { [weak self] in self?.refreshAllNow() },
                                   onRefreshRepo: { [weak self] name in self?.refreshRepoNow(name) },
                                   onContentSizeMightHaveChanged: { [weak self] expanded, collapsed, tf in
                                       self?.adjustHeight(expandedCount: expanded, collapsedCount: collapsed, testflightCount: tf)
                                   })
        )
        panel.contentViewController = hostingController

        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func staleThreshold() -> Int {
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let interval = json["interval_seconds"] as? Int
        else { return 180 }
        return interval * 3
    }

    private func refresh() {
        let status = loadStatus(from: statusPath)
        let threshold = staleThreshold()

        let repos = status?.repos ?? []
        let testflightApps = status?.testflightApps ?? []
        let worst: RunState
        if !repos.isEmpty || !testflightApps.isEmpty {
            let repoStates = repos.map { DisplayState.compute(repo: $0, staleThreshold: threshold).state }
            let tfStates = testflightApps.map { DisplayState.compute(testflight: $0, staleThreshold: threshold).state }
            worst = WorstState.compute(repoStates + tfStates)
        } else {
            worst = .stale
        }
        lastRepoCount = repos.count + testflightApps.count
        lastRepoNames = repos.map(\.name) + testflightApps.map(\.name)
        lastRepos = repos
        lastTestflightApps = testflightApps

        // SF Symbols have their own multicolor/palette rendering system that
        // bypasses contentTintColor + isTemplate (the classic menu-bar-icon
        // approach) entirely unless you explicitly request monochrome via a
        // palette-color symbol configuration — without it, "fill" symbols
        // render with their raw default appearance (solid black), which is
        // why the tray icon looked like a flat black blob regardless of
        // state. Sized down to match neighboring menu bar icons (SF Symbols
        // default larger than menu-bar scale).
        //
        // Quiet by default: secondaryLabelColor (blends in like every other
        // inactive menu bar icon) when everything's fine, colored only to
        // draw the eye when something actually needs attention.
        let tint: NSColor = (worst == .ok) ? .secondaryLabelColor : NSColor(worst.color)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        statusItem.button?.image = NSImage(
            systemSymbolName: worst.symbol,
            accessibilityDescription: "Harbor: \(worst.rawValue)"
        )?.withSymbolConfiguration(config)

        hostingController.rootView = ContentView(status: status, staleThreshold: threshold, isRefreshing: isRefreshing,
                                                  refreshingRepoNames: refreshingRepoNames,
                                                  onQuit: { NSApp.terminate(nil) },
                                                  onRevealConfig: { [weak self] in self?.revealConfig() },
                                                  onRefreshAll: { [weak self] in self?.refreshAllNow() },
                                                  onRefreshRepo: { [weak self] name in self?.refreshRepoNow(name) },
                                                  onContentSizeMightHaveChanged: { [weak self] expanded, collapsed, tf in
                                                      self?.adjustHeight(expandedCount: expanded, collapsedCount: collapsed, testflightCount: tf)
                                                  })
    }

    /// Resizes the panel to the REAL height its visible content needs,
    /// given the actual post-filter/post-collapse counts ContentView just
    /// reported — e.g. the "errors only" toggle collapsing most cards, or a
    /// search filter hiding most of the list. Grows or shrinks as needed
    /// (not shrink-only) since the counts are now accurate rather than a
    /// rough estimate, and keeps the TOP edge fixed — the bottom edge
    /// moves, matching how the user described wanting this to feel. Not
    /// hooked into the periodic 5s refresh timer, deliberately: that
    /// decoupling is what fixed the original grow-then-shrink flicker bug,
    /// and this path is opt-in (only fired by deliberate toggle/search/open
    /// interaction in ContentView), not automatic background refresh.
    private func adjustHeight(expandedCount: Int, collapsedCount: Int, testflightCount: Int) {
        guard panel.isVisible else { return }
        let targetHeight = targetContentHeight(expandedCount: expandedCount, collapsedCount: collapsedCount, testflightCount: testflightCount)
        guard abs(targetHeight - panel.frame.height) > 1 else { return }

        var frame = panel.frame
        let delta = frame.height - targetHeight
        frame.origin.y += delta
        frame.size.height = targetHeight
        panel.setFrame(frame, display: true, animate: true)
    }

    /// Same as refreshAllNow, but for a single card's "Refresh" button:
    /// runs poll.sh <name> (the single-repo mode) + notify.sh, so clicking
    /// one repo doesn't wait on or re-fetch every other one. Tracked per
    /// repo name rather than one global flag, so refreshing one card
    /// doesn't disable every other card's button.
    private func refreshRepoNow(_ name: String) {
        guard !refreshingRepoNames.contains(name), let repoDir else { return }
        refreshingRepoNames.insert(name)
        refresh()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            // Repo name passed as a real argument ($2), not interpolated
            // into the shell string — safe regardless of what characters
            // end up in it, unlike refreshAllNow's fixed/trusted repoDir-only command.
            process.arguments = ["-c", "\"$1/bin/poll.sh\" \"$2\" && \"$1/bin/notify.sh\"", "bash", repoDir, name]
            try? process.run()
            process.waitUntilExit()

            DispatchQueue.main.async {
                self?.refreshingRepoNames.remove(name)
                self?.refresh()
            }
        }
    }

    /// Runs poll.sh + notify.sh right now instead of waiting for launchd's
    /// own interval, then re-reads the result. Runs off the main thread so
    /// the UI stays responsive while the API calls are in flight; guarded
    /// against overlap so mashing the button doesn't stack up processes.
    private func refreshAllNow() {
        guard !isRefreshing, let repoDir else { return }
        isRefreshing = true
        refresh() // re-render immediately so the button shows "Refreshing…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "\(repoDir)/bin/poll.sh && \(repoDir)/bin/notify.sh"]
            try? process.run()
            process.waitUntilExit()

            DispatchQueue.main.async {
                self?.isRefreshing = false
                self?.refresh()
            }
        }
    }

    /// Reveals the config file in Finder. Resolves through the symlink first
    /// when HARBOR_DOTFILES_CONFIG mode is active, so this always points at
    /// the real editable file rather than just the ~/.harbor symlink.
    private func revealConfig() {
        var target = configPath
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: configPath) {
            target = resolved
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        refresh()

        // ContentView opens with errorsOnly=true and no search filter, so
        // compute the SAME split up front instead of assuming every card is
        // expanded — that stale assumption was the original source of the
        // oversized-on-open panel. (ContentView also reports its own real
        // counts via onAppear right after, which will just confirm this
        // same number since the assumption matches its actual default.)
        let threshold = staleThreshold()
        let (expanded, collapsed) = defaultCounts(repos: lastRepos, threshold: threshold)

        var frame = panel.frame
        frame.size.height = targetContentHeight(expandedCount: expanded, collapsedCount: collapsed, testflightCount: lastTestflightApps.count)
        frame.size.width = idealContentWidth(repoNames: lastRepoNames, repos: lastRepos)
        panel.setFrame(frame, display: false)

        let buttonScreenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: buttonScreenRect.midX - panelSize.width / 2,
            y: buttonScreenRect.minY - panelSize.height
        )
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        panel.orderOut(nil)
    }
}
