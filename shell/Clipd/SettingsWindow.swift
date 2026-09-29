import AppKit
import SwiftUI

/// The Settings window's content: Mac-standard toolbar tabs (icon over label, like
/// Safari's settings), each pane a SwiftUI view in its own hosting controller.
///
/// Not a SwiftUI TabView. TabView only renders as toolbar tabs inside a SwiftUI
/// `Settings` scene, and the app is AppKit-bootstrapped (main.swift builds
/// NSApplication directly), so a TabView hosted in a plain NSWindow draws the
/// in-window segmented box instead.
///
/// The window is sized from the selected pane. A hosting controller nested in a tab
/// controller never publishes a preferredContentSize of its own, so the pane's
/// fittingSize is measured instead — and only once the window is on screen, since
/// before that there is no layout to measure.
final class SettingsTabViewController: NSTabViewController {
    /// Every pane's width, so switching tabs only ever changes the window's height.
    private static let paneWidth: CGFloat = 500

    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsTabViewController is built in code, not from a nib")
    }

    /// Adds one tab: its toolbar label and SF Symbol, and the SwiftUI view shown
    /// while it's selected.
    func addPane<Content: View>(_ label: String, systemImage: String, _ content: Content) {
        let host = NSHostingController(rootView: content.frame(width: Self.paneWidth))
        // Intrinsic size only, so fittingSize tracks the SwiftUI content. The
        // min/max options would add required constraints that pin the window to
        // one pane's size and fight the resize below.
        host.sizingOptions = [.intrinsicContentSize]
        // The window's title is bound to this controller's title, which passes
        // through the selected pane's — so naming the pane titles the window
        // after the selected tab, the macOS settings convention.
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: label)
        addTabViewItem(item)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        fitWindowToSelectedPane(animate: false)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)  // NSTabViewController relies on its delegate calls
        fitWindowToSelectedPane(animate: true)
    }

    /// Resizes the window to the selected pane, keeping the title bar where it is.
    private func fitWindowToSelectedPane(animate: Bool) {
        guard let window = view.window,
              let pane = tabView.selectedTabViewItem?.viewController?.view,
              let current = window.contentView?.frame.size else { return }
        pane.layoutSubtreeIfNeeded()
        let target = pane.fittingSize
        // AppKit's origin is the bottom-left corner, so growing the window while
        // its top edge stays put means moving the bottom edge down.
        var frame = window.frame
        frame.size.width += target.width - current.width
        frame.size.height += target.height - current.height
        frame.origin.y -= target.height - current.height
        window.setFrame(frame, display: true, animate: animate)
    }
}
