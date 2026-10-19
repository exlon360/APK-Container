// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit
import WebKit

extension WebAppRuntime {
    /// A web app closed itself; the object is the app's id.
    static let closed = Notification.Name("husk.web.closed")
}

/// The web app's page, wherever it is shown: full screen or in a window. The same web view each time, so the app keeps its state.
struct WebAppSurface: UIViewRepresentable {
    let app: TLApp
    var onThreeFingerTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> WebAppHostView {
        let view = WebAppHostView(app: app)
        view.onThreeFingerTap = onThreeFingerTap
        return view
    }
    func updateUIView(_ view: WebAppHostView, context: Context) { view.onThreeFingerTap = onThreeFingerTap }
}

final class WebAppHostView: UIView {
    private let runtime: WebAppRuntime?
    var onThreeFingerTap: (() -> Void)?

    init(app: TLApp) {
        runtime = WebAppRuntime.runtime(for: app)
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        let controls = UITapGestureRecognizer(target: self, action: #selector(showControls))
        controls.numberOfTouchesRequired = 3
        controls.cancelsTouchesInView = false
        controls.delaysTouchesBegan = false
        controls.delaysTouchesEnded = false
        addGestureRecognizer(controls)
        guard let runtime else { return }
        let id = app.id
        runtime.onClose = { NotificationCenter.default.post(name: WebAppRuntime.closed, object: id) }
        runtime.webView.removeFromSuperview()
        addSubview(runtime.webView)
        // Android's back gesture: a swipe in from the left edge goes to the app's back handler, then the page history.
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgeSwiped(_:)))
        edge.edges = .left
        addGestureRecognizer(edge)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func showControls() { onThreeFingerTap?() }

    @objc private func edgeSwiped(_ g: UIScreenEdgePanGestureRecognizer) {
        if g.state == .ended, g.translation(in: self).x > 60 { runtime?.back() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if runtime?.webView.superview === self { runtime?.webView.frame = bounds }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        runtime?.setActive(window != nil)
        if window != nil, let rt = runtime, rt.webView.superview !== self {
            addSubview(rt.webView)
            setNeedsLayout()
        }
    }
}

/// A web app full screen: a thin bar to leave it by, and the page below the status bar, in the colour the app asked for.
struct WebAppScreenView: View {
    let app: TLApp
    @Environment(\.dismiss) private var dismiss
    @State private var color: Color = Color(uiColor: .systemBackground)
    @State private var showControls = false
    @State private var appStopped = false

    private var portrait: Bool { app.apks.first.map { husk_apk_orientation($0) != 0 } ?? true }

    var body: some View {
        WebAppSurface(app: app, onThreeFingerTap: { showControls = true })
        .ignoresSafeArea()
        .overlay { if appStopped { AppSessionStoppedNotice { returnToApps() } } }
        .overlay(alignment: .bottom) { AppControlsHint() }
        .statusBarHidden(true)
        .huskHideSystemOverlays()
        .accessibilityAction(named: Text("App Controls")) { showControls = true }
        .sheet(isPresented: $showControls) {
            AppSessionControls(title: app.label, app: app, onReturn: returnToApps) { EmptyView() }
        }
        .background(color.ignoresSafeArea())
        .onAppear {
            HuskOrientation.set(portrait ? .portrait : .landscape)
            refreshColor()
        }
        .onDisappear { HuskOrientation.set(HuskOrientation.standard) }
        .onReceive(NotificationCenter.default.publisher(for: WebAppRuntime.closed)) { n in
            if (n.object as? String) == app.id { appStopped = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: WebAppRuntime.chromeChanged)) { _ in refreshColor() }
    }

    private func returnToApps() { WebAppRuntime.close(app); dismiss() }

    private func refreshColor() {
        if let hex = WebAppRuntime.runtime(for: app)?.chromeColor, let c = Color(hexString: hex) { color = c }
    }
}

private extension Color {
    /// "#07070f" or "#07070fff".
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgb = s.count == 8 ? v >> 8 : v
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
