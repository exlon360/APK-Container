// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// Observes a deliberate three-finger tap without putting a touch-catching view over the APK.
struct AppControlsGesture: UIViewRepresentable {
    var active = true
    var action: () -> Void

    func makeUIView(context: Context) -> Observer { Observer() }
    func updateUIView(_ view: Observer, context: Context) {
        view.active = active
        view.action = action
    }
    static func dismantleUIView(_ view: Observer, coordinator: ()) { view.detach() }

    final class Observer: UIView, UIGestureRecognizerDelegate {
        var active = false
        var action: (() -> Void)?
        private weak var installedWindow: UIWindow?
        private lazy var tap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(reveal))
            tap.numberOfTouchesRequired = 3
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            return tap
        }()

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            installedWindow = window
            window?.addGestureRecognizer(tap)
        }
        func detach() { installedWindow?.removeGestureRecognizer(tap); installedWindow = nil }
        @objc private func reveal() { if active { action?() } }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard active, let window, window === installedWindow else { return false }
            return convert(bounds, to: window).contains(touch.location(in: window))
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

/// Native controls appear only on request; dismissing this sheet returns to the same app surface.
struct AppSessionControls<Controls: View>: View {
    var title = "App Controls"
    var app: TLApp? = nil
    let onReturn: () -> Void
    @ViewBuilder var controls: () -> Controls
    @Environment(\.dismiss) private var dismiss
    @State private var showFiles = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: onReturn) { Label("Return to Apps", systemImage: "square.stack.3d.up") }
                    Button { showFiles = true } label: { Label("App Files", systemImage: "folder") }
                }
                controls()
                Section {
                    Text("Tap with three fingers to open these controls. The app stays open until you choose Return to Apps.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(isPresented: $showFiles) {
            if let app { NativeAppFiles(app: app) } else { FilesTab() }
        }
    }
}

/// Native app storage is browsed with iOS controls, without opening an Android file manager.
private struct NativeAppFiles: View {
    let app: TLApp
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            NativeAppDirectory(url: TranslationLayer.root.appendingPathComponent(app.id, isDirectory: true), title: app.label)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct NativeAppDirectory: View {
    let url: URL
    let title: String
    @State private var entries: [URL] = []
    @State private var failure: String?
    @State private var sharing: URL?
    var body: some View {
        List {
            if let failure { Text(failure).foregroundStyle(.secondary) }
            else if entries.isEmpty { Text("This folder is empty.").foregroundStyle(.secondary) }
            ForEach(entries, id: \.path) { entry in
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    NavigationLink {
                        NativeAppDirectory(url: entry, title: entry.lastPathComponent)
                    } label: { Label(entry.lastPathComponent, systemImage: "folder") }
                } else {
                    Button { sharing = entry } label: { Label(entry.lastPathComponent, systemImage: "doc") }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                entries = try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } catch { failure = "This app has not created a readable data folder yet." }
        }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let sharing { ShareSheet(items: [sharing]) }
        }
    }
}

struct AppSessionStoppedNotice: View {
    let onReturn: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("The app stopped").font(.headline)
            Text("Your app session is still open.").font(.subheadline).foregroundStyle(.secondary)
            Button("Return to Apps", action: onReturn).buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding()
    }
}

struct AppControlsHint: View {
    @State private var visible = true
    var body: some View {
        Text("Tap with three fingers for app controls")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(.bottom, 26)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(!visible)
            .task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation(.easeOut(duration: 0.25)) { visible = false }
            }
    }
}
