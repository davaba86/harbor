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
    private let statusPath = NSString(string: "~/.harbor/status.json").expandingTildeInPath
    private let configPath = NSString(string: "~/.harbor/config.json").expandingTildeInPath

    // Rough per-row heights for auto-sizing the panel to its content. These
    // are estimates of RepoCardView's actual layout (name+icon row, dot row,
    // caption row, padding) — not pixel-exact, but close enough that any
    // small mismatch just shows as a sliver of extra/short space rather than
    // clipping anything, since the content is already in a ScrollView.
    private let cardHeight: CGFloat = 84
    private let cardSpacing: CGFloat = 8
    private let headerHeight: CGFloat = 34
    private let footerHeight: CGFloat = 44
    private let maxVisibleCards = 8
    private let maxContentWidth: CGFloat = 420

    private func idealContentHeight(repoCount: Int) -> CGFloat {
        let visible = min(max(repoCount, 0), maxVisibleCards)
        let cardsHeight = visible > 0
            ? CGFloat(visible) * cardHeight + CGFloat(visible - 1) * cardSpacing
            : 0
        return max(headerHeight + cardsHeight + footerHeight, panel.minSize.height)
    }

    /// Widest repo name's rendered width (same font/weight RepoCardView uses
    /// for the title), plus the card chrome around it, clamped to
    /// [panel.minSize.width, maxContentWidth]. Past that cap the window stops
    /// growing and RepoCardView's name Text wraps instead (see its
    /// .fixedSize(horizontal: false, vertical: true)).
    private func idealContentWidth(repoNames: [String]) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let longestNameWidth = repoNames
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        // card horizontal padding (10 left + 10 right) + accent bar (4) +
        // spacer/icon on the title row (~28)
        let chrome: CGFloat = 10 + 10 + 4 + 28
        return min(max(longestNameWidth + chrome, panel.minSize.width), maxContentWidth)
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
            rootView: ContentView(status: nil, staleThreshold: 180,
                                   onQuit: { NSApp.terminate(nil) },
                                   onRevealConfig: { [weak self] in self?.revealConfig() })
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

        hostingController.rootView = ContentView(status: status, staleThreshold: threshold,
                                                  onQuit: { NSApp.terminate(nil) },
                                                  onRevealConfig: { [weak self] in self?.revealConfig() })
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

        var frame = panel.frame
        frame.size.height = idealContentHeight(repoCount: lastRepoCount)
        frame.size.width = idealContentWidth(repoNames: lastRepoNames)
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
