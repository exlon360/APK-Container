// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// Routes between the four things Husk can be doing.
///
/// The guest runs continuously once started; these are presentation states, not
/// lifecycle states. In particular `library` and `running` are the same VM --
/// the difference is only whether its surface is on screen.
struct ContentView: View {
    @StateObject private var guest = GuestImage.shared
    @StateObject private var runner = QemuRunner.shared
    @StateObject private var bridge = HuskBridgeFS.shared
    @ObservedObject private var host = AndroidHost.shared

    @State private var started = false
    /// Keep visited native screens mounted so a tab change preserves its draft and navigation.
    @State private var visitedTabs: Set<HuskTab> = [.library]
    /// A user-requested app launch or import waiting for JIT or runtime installation.
    @State private var runtimeRequested = false
    /// A failed automatic start stays suppressed for this entire process.
    @State private var autoStartSuppressed = false
    @State private var showLogs = false
    /// True while the guest's own screen is being shown instead of the library.
    /// Starts false: the tab UI is the home screen, and the guest -- including
    /// first boot's Android wizard, which runs underneath it -- is shown on
    /// demand from the library.
    @State private var showGuestScreen = false
    @ObservedObject private var router = Router.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var showOnboarding = Onboarding.needed
    /// True while the launch boot screen is up, rather than the library.
    @State private var booting = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Theme.Appearance.key) private var appearance = Theme.Appearance.system
    @ObservedObject private var theme = AppTheme.shared
    @ObservedObject private var incoming = IncomingFiles.shared
    @ObservedObject private var showcase = ShowcaseStore.shared
    @ObservedObject private var tlStore = TranslationLayerStore.shared
    @ObservedObject private var crash = CrashReport.shared
    @ObservedObject private var massTest = MassTest.shared

    /// The native session stays on screen through Android window transitions.
    /// Focus permission controls guest pixels and input, not the route back to Apps.
    private var appSessionPresented: Bool {
        showGuestScreen && host.presentationActive
    }

    /// Guest pixels are exposed only after the host validates an app foreground.
    private var appSurfaceVisible: Bool {
        scenePhase == .active && runner.isRunning && appSessionPresented && host.appSurfaceAllowed
    }

    var body: some View {
        ZStack {
            // The tabs, and the guest on top of them.
            //
            // The guest is not a tab: HuskGLView owns the CAMetalLayer QEMU
            // renders into, and it has to stay in the hierarchy for the whole
            // session -- a torn-down layer is a black picture with a frame
            // counter that keeps climbing. Keeping it mounted and covering it
            // with the tabs is the arrangement that survives that. Showing
            // Android is then a matter of hiding what is over it, which is also
            // why it appears instantly rather than reloading.
            navigationShell
            .opacity(appSessionPresented ? 0 : 1)
            .allowsHitTesting(!appSessionPresented)
            .accessibilityHidden(appSessionPresented)
            .animation(nil, value: appSessionPresented)

            // Multitasking: an app in a window over everything else in Husk (AppWindows.swift).
            AppWindowLayer()
                .ignoresSafeArea(.keyboard)

            // Outcomes, over whichever tab is showing. Above the tab bar rather
            // than over it: a message that covers the way out of the screen it
            // appears on is a message in the way.
            if let toast = host.toast {
                VStack {
                    Spacer()
                    ToastView(toast: toast) { host.toast = nil }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .task(id: toast.id) {
                    try? await Task.sleep(nanoseconds: 4_500_000_000)
                    withAnimation(.snappy) {
                        if host.toast?.id == toast.id { host.toast = nil }
                    }
                }
            }

            if (started && runner.isRunning) || host.presentationActive {
                GuestScreenView(showLogs: $showLogs,
                                isPresented: appSessionPresented,
                                pixelsAllowed: appSurfaceVisible,
                                onBack: endAppPresentation)
                    .opacity(appSessionPresented ? 1 : 0)
                    .allowsHitTesting(appSessionPresented)
                    .accessibilityHidden(!appSessionPresented)
                    .animation(nil, value: appSessionPresented)
            }

            // Over the tabs and over the start screen: when Husk is starting
            // Android for you, that is the whole screen until it is done.
            if booting {
                BootScreen { withAnimation(.easeInOut(duration: 0.3)) { booting = false } }
                    .transition(.opacity)
                    .zIndex(3)
                    .onChange(of: host.isReady) { ready in
                        if ready { withAnimation(.easeInOut(duration: 0.45)) { booting = false } }
                    }
            }
        }
        .tint(theme.accentColor)
        .onAppear { Theme.apply(appearance) }
        .onChange(of: appearance) { Theme.apply($0) }
        .animation(.snappy(duration: 0.25), value: host.toast)
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                showOnboarding = false
                if Onboarding.autoStart, JITBootstrap.ready {
                    booting = true
                    start()
                }
            }
        }
        .sheet(isPresented: $showLogs) { LogView() }
        .sheet(item: Binding(get: { showOnboarding ? nil : crash.pending }, set: { crash.pending = $0 })) { report in
            CrashReportSheet(report: report)
        }
        .task { await CompatibilityStore.shared.refresh() }
        .sheet(isPresented: $router.showFiles) { FilesTab() }
        .sheet(isPresented: $router.showDownloads) { DownloadsTab() }
        .task(id: showcasePackages) { showcase.refresh(for: showcasePackages) }
        .alert("Metadata Updated", isPresented: Binding(get: { showcase.shouldAsk && !showOnboarding },
                                                         set: { if !$0 { showcase.asked() } })) {
            Button("Download") { showcase.downloadUpdates() }
            Button("Not Now", role: .cancel) { showcase.asked() }
        } message: {
            let n = showcase.updates.count
            Text("Metadata for \(n) of your app\(n == 1 ? "" : "s") has been updated. Would you like to download the updates?")
        }
        .sheet(isPresented: Binding(get: { !incoming.waiting.isEmpty },
                                    set: { if !$0 { incoming.discard() } })) {
            IncomingChooser()
                .huskDetents([.medium], dragIndicator: true)
        }
        .onChange(of: host.isReady) { _ in resumeRuntimeRequests() }
        .onChange(of: host.busy) { _ in resumeRuntimeRequests() }
        .onChange(of: host.presentationActive) { active in
            // Focus can disappear temporarily during an activity transition.
            // Start with the native cover and keep this route until the session ends.
            showGuestScreen = active
        }
        .onChange(of: guest.state) { state in
            if state == .ready, runtimeRequested || !incoming.forAndroid.isEmpty {
                startFromLibrary()
            }
        }
        .sheet(isPresented: $jit.showSetup) { JITSetupFlow() }
        // The built-in helper attaches while Husk stays in the foreground, so
        // there is no relaunch to trigger the region claim below; this is it.
        .onChange(of: jit.attachGeneration) { _ in evaluate() }
        // Asking rather than downloading. Two gigabytes over someone's cellular
        // connection is not a decision to make on their behalf.
        .alert(guest.update.title, isPresented: Binding(
                get: { guest.update.isSomething },
                set: { if !$0 { guest.dismissUpdate() } })) {
            Button("Download") { guest.applyUpdate() }
            Button("Not now", role: .cancel) { guest.dismissUpdate() }
        } message: {
            Text(guest.update.detail)
        }
        .sheet(isPresented: $massTest.shareResults) { ShareSheet(items: [MassTest.resultsURL]) }
        .onAppear {
            crash.checkPreviousRun()
            // the developer mass test: the last app's fate, then the next app (it clears a crash report it has written down)
            massTest.resume(crash: crash)
            if crash.pending == nil, !massTest.active { router.resumeSwitch() }
            router.openGuest = showAppPresentation
            router.startAndroid = { startFromLibrary() }
            evaluate()
        }
        // The two-parameter onChange is iOS 17; this single-parameter form is
        // deprecated there but still works, and is the only one that compiles
        // against the 16.0 deployment target.
        .onChange(of: scenePhase) { phase in
            // StikDebug relaunches Husk after attaching, so returning to the
            // foreground is the moment worth re-checking, not first launch.
            if phase == .active {
                jit.returnedToForeground()
                evaluate()
            }
        }
    }

    /// A floating, horizontally scrollable capsule fits all destinations on a phone
    /// without collapsing Build or My Apps into a system "More" tab.
    private var navigationShell: some View {
        VStack(spacing: 0) {
            ContainerNavigationBar(selection: tabSelection)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            ZStack {
                retainedPage(.library) { LibraryScreen() }
                retainedPage(.build) { BuildScreen() }
                retainedPage(.myApps) { MyAppsScreen() }
                retainedPage(.repositories) { RepositoriesScreen() }
                retainedPage(.store) { RepositoryStoreScreen() }
                retainedPage(.settings) { SettingsTab() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Console.page.ignoresSafeArea())
        .onChange(of: router.tab) { visitedTabs.insert($0) }
    }

    @ViewBuilder
    private func retainedPage<Page: View>(_ tab: HuskTab, @ViewBuilder content: () -> Page) -> some View {
        if visitedTabs.contains(tab) || router.tab == tab {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(router.tab == tab ? 1 : 0)
                .allowsHitTesting(router.tab == tab)
                .accessibilityHidden(router.tab != tab)
                .zIndex(router.tab == tab ? 1 : 0)
        }
    }

    private func showAppPresentation() {
        guard host.presentationActive, host.appSurfaceAllowed else { return }
        // Preserve the validated route through temporary iOS interruptions.
        // appSurfaceVisible keeps it covered until this scene is active again.
        showGuestScreen = true
    }

    private func endAppPresentation() {
        showGuestScreen = false
        host.endAppPresentation()
    }

    /// Finish queued installs before opening an app, so bridge operations do not race.
    private func resumeRuntimeRequests() {
        guard host.isReady, host.busy == nil else { return }
        if !incoming.forAndroid.isEmpty {
            incoming.installForAndroidIfReady()
        } else if let package = router.pendingAndroidLaunch {
            router.pendingAndroidLaunch = nil
            host.launch(package, then: showAppPresentation)
        }
    }

    /// Selecting Apps again returns to the top of its navigation stack.
    private var tabSelection: Binding<HuskTab> {
        Binding(get: { router.tab }, set: { tab in
            if tab == router.tab {
                switch tab {
                case .library: router.library = []
                default: break
                }
            }
            router.tab = tab
        })
    }

    /// Every package Husk holds, from both sides: what the picture index is read for.
    private var showcasePackages: Set<String> {
        Set(tlStore.apps.compactMap(\.packageName) + host.packages.map(\.name))
    }

    private func evaluate() {
        try? guest.prepareFirmware()
        guest.refresh()
        if AutoStart.readyAtLaunch == nil { AutoStart.readyAtLaunch = guest.state == .ready }
        HuskBridgeFS.shared.prepare()

        // What is installed is compared against the release by digest, not by
        // version name -- see GuestManifest. Deliberately not awaited: it is a
        // network round trip, and nothing on this screen should wait for it.
        Task { await guest.checkForUpdates() }

        let requestedRuntime = runtimeRequested || !incoming.forAndroid.isEmpty || router.pendingAndroidLaunch != nil
        let automaticStartEligible = Onboarding.autoStart && !started && !showOnboarding
            && guest.state == .ready && AutoStart.readyAtLaunch == true
        // Consult the previous failure BEFORE a debugger trap. Otherwise the
        // trap can hang again before the recovery marker is ever inspected.
        if automaticStartEligible, !autoStartSuppressed, AutoStart.lastOneDied() {
            autoStartSuppressed = true
            HuskLog.log("ui", "previous automatic Android start did not finish; keeping the library open")
        }
        let automaticStart = automaticStartEligible && !autoStartSuppressed
        guard JITStartupPolicy.permitsPreparation(isHosted: JITBootstrap.isHosted,
                                                  runtimeRequested: requestedRuntime,
                                                  explicitJITRequested: jit.preparationRequested,
                                                  automaticStart: automaticStart) else {
            HuskLog.log("ui", "hosted library ready; JIT preparation waits for an app launch or explicit JIT action")
            return
        }

        let trackingAutomaticStart = automaticStart && !requestedRuntime
        if trackingAutomaticStart { AutoStart.begin() }
        defer {
            if trackingAutomaticStart && !started { AutoStart.end() }
        }
        jit.enableAtLaunchIfAsked()
        if !JITBootstrap.ready {
            HuskLog.log("ui", "no JIT yet; waiting for a debugger")
            return
        }

        // Preserve early allocation after an explicit JIT handoff, before a
        // long download can suspend StikDebug. A host's inherited debugger flag
        // alone is not permission to trap before the native library appears.
        jit.consumePreparationRequest()
        JITBootstrap.prewarm()

        // Resume a requested app/import after installation or JIT attachment.
        if !started, !showOnboarding, guest.state == .ready,
           requestedRuntime {
            start()
            return
        }

        // Start on launch, when that is what was asked for.
        //
        // This deliberately did nothing for a long time, and the reason was
        // sound: booting takes minutes and its cost depends on choices made
        // before it starts, so it should not be a side effect of opening the
        // app. But the setup flow now asks the question outright, and someone
        // who answered yes has made the decision -- continuing to ignore it
        // just means every launch begins by pressing Start.
        //
        // Only when Android was already installed as Husk opened (#75, #128): evaluate() runs on every return to the foreground,
        // so an image that finished downloading in this run would otherwise start the moment Husk came back -- with a debugger
        // that iOS may have suspended hours into the download, whose unanswered trap ends Husk. And not again after a start
        // that Husk did not survive, or every launch would end the same way.
        guard Onboarding.autoStart, !started, guest.state == .ready,
              !showOnboarding else { return }
        guard AutoStart.readyAtLaunch == true else {
            HuskLog.log("ui", "Android was installed in this run; not starting it on its own (press Start)")
            return
        }
        guard !autoStartSuppressed else { return }
        HuskLog.log("ui", "starting Android on launch")
        booting = true
        start()
    }

    /// Start the guest from the library, without leaving it.
    ///
    /// `start()` returns silently when there is no debugger attached, which as
    /// the action behind a button reads as a button that does nothing, so the
    /// JIT prompt is raised here instead.
    private func startFromLibrary() {
        runtimeRequested = true
        guard JITBootstrap.ready else {
            HuskLog.log("ui", "start asked for without JIT; enabling with \(jit.resolvedMethod.title)")
            jit.enable()
            return
        }
        guard guest.state == .ready else { return }
        start()
    }

    private func start() {
        guard !started else { return }
        guard JITBootstrap.ready else { return }
        HuskLog.log("ui", "JIT is available; starting QEMU")
        // Take the JIT region at the last moment before QEMU, as well as before
        // the download. Whichever comes first wins; the second call is a no-op.
        //
        // And refuse to continue without it. qemu_init() allocates its
        // translation buffer inside itself and has nowhere to get executable
        // memory from if this failed, so starting anyway is not optimism, it is
        // a guaranteed SIGSEGV a few milliseconds later -- with the log showing
        // gigabytes free, which sends everyone looking at memory.
        // Refuse only when there is genuinely nothing left to try.
        //
        // Two routes, and the second one is not a consolation prize: with
        // CS_DEBUGGED set the kernel honours a plain MAP_JIT mapping, which is
        // what QEMU falls back to on its own and what every other iOS emulator
        // runs on. Stopping here is only right when neither route exists.
        //
        // Which route is available is now measured. It used to be predicted
        // from the device model and the iOS version, and the prediction was
        // wrong for iOS 26: StikDebug attaches there without servicing traps,
        // because on that OS it does not need to, and Husk read that as "no
        // executable memory" and refused to start a guest that would have run.
        if !JITBootstrap.prewarm(), !JITBootstrap.isLive {
            guard JITBootstrap.mapJITWorks else {
                HuskLog.log("jit", "refusing to start QEMU: no trap servicer is "
                                 + "answering and MAP_JIT does not execute here")
                // Said on screen too: a Start button that silently does nothing reads as a hang (#122).
                host.say("Android can't start without JIT",
                         JITBootstrap.lastFailure ?? "APK Container could not get executable memory. Turn JIT on again (Settings > JIT) and retry.",
                         good: false)
                booting = false
                return
            }
            HuskLog.log("jit", "no dual mapping, but MAP_JIT executes -- letting "
                             + "QEMU map its own buffer")
        }
        started = true
        runtimeRequested = false
        router.androidStarted = true
        QemuRunner.shared.start()
        // Start probing the bridge now, not when the library happens to be
        // opened. isReady is only ever set here, and under the old screen-based
        // navigation this was called when someone chose library mode -- so with
        // tabs, opening Library after starting in full screen left it waiting
        // forever on a guest that was plainly up. It is idempotent and cheap.
        AndroidHost.shared.waitForReady()
        bridge.startWatching()
        GuestBridge.shared.startHealthWatch()
        if QemuRunner.soundEnabled { HuskAudio.shared.start() }
    }
}

/// Native navigation shared by the phone and iPad layouts. The capsule scrolls
/// when needed and follows programmatic navigation to an offscreen destination.
private struct ContainerNavigationBar: View {
    @Binding var selection: HuskTab

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(HuskTab.allCases) { tab in
                            Button { selection = tab } label: {
                                Text(tab.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(selection == tab ? Color.blue : Color.primary.opacity(0.85))
                                    .padding(.horizontal, 17)
                                    .frame(minHeight: 44)
                                    .background(selection == tab ? Console.page.opacity(0.75) : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == tab ? .isSelected : [])
                            .accessibilityIdentifier("container.tab." + tab.rawValue)
                            .id(tab)
                        }
                    }
                    .padding(4)
                }
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .onChange(of: selection) { tab in
                    withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(tab, anchor: .center) }
                }
            }
            .frame(maxWidth: 760)
            Spacer(minLength: 0)
        }
    }
}

/// The retained APK surface, with native recovery and controls shown on request.
struct GuestScreenView: View {
    @ObservedObject private var runner = QemuRunner.shared
    @ObservedObject private var host = AndroidHost.shared
    @Binding var showLogs: Bool
    /// Session lifecycle: transient focus changes must not close native controls.
    var isPresented: Bool
    /// Only verified guest pixels may be shown or receive input.
    var pixelsAllowed: Bool
    let onBack: () -> Void
    @State private var keyboard = false
    @State private var rotated = HuskGLView.rotated
    @State private var showControls = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            // The GL surface, not HuskDisplay. ANGLE renders into this layer
            // directly; HuskDisplay uploaded a CPU framebuffer itself, which is
            // the work the GPU path exists to remove. QemuRunner falls back to
            // the software display if GL cannot start, and that path draws
            // nothing here -- a black screen with "GL display FAILED" in the log
            // is the signal, rather than a silent wrong-looking picture.
            // HuskGLView always exists, because it is what publishes the
            // CAMetalLayer that QEMU needs before it can bring GL up. If GL
            // then fails, nothing ever draws into that layer -- so the software
            // display goes on top and takes over. Without this the fallback is
            // invisible: the log says it fell back and the screen stays black.
            HuskGLScreen().ignoresSafeArea()
                .allowsHitTesting(pixelsAllowed)
                .accessibilityHidden(!pixelsAllowed)
            // Only once GL is known to have FAILED. While the answer is
            // still undecided this must draw nothing: HuskDisplay is opaque,
            // and putting it over the GL layer on the chance that GL might not
            // work is how the guest ends up hidden behind a view that has
            // nothing to show.
            if runner.displayKind == .software {
                HuskDisplay().ignoresSafeArea()
                    .allowsHitTesting(pixelsAllowed)
                    .accessibilityHidden(!pixelsAllowed)
            }

            // Keep the renderer and its geometry in place. An opaque native cover
            // hides unverified Android windows without dropping back to the library.
            if !pixelsAllowed {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 14) {
                        Spacer()
                        ProgressView().tint(.white)
                        Text(!runner.isRunning ? "The Android runtime stopped. Restart APK Container to reopen this app."
                             : host.presentationRecovery ?? "Waiting for Android…")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        if host.presentationRecovery != nil && runner.isRunning {
                            Button("Retry App") { host.retryAppPresentation() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!host.isReady)
                        }
                        Button(action: onBack) {
                            Label("Return to Apps", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.identity)
                .animation(nil, value: pixelsAllowed)
            }

            // Boot progress, over the guest's own screen.
            //
            // Full screen shows the guest and nothing else, so a cold boot here
            // was several minutes of a mostly black screen with no indication
            // anything was happening -- the two other waiting screens had a bar
            // and this one, the one people actually watch a boot on, did not.
            //
            // Gone the moment the guest is up, and never shown on a restore.
            if runner.bootProgress > 0 && runner.bootProgress < 100 {
                VStack(spacing: 10) {
                    ProgressView(value: Double(runner.bootProgress), total: 100)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                    Text(runner.setupMessage ?? "Starting Android…")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .huskPanel(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 300)
                // Below the Back/keyboard/console pill rather than centred over
                // the guest: the ZStack is top-aligned, so without this the card
                // lands on top of the chrome and hides the way out.
                .padding(.top, 58)
                .transition(.opacity)
            }

            // Zero-sized: it exists only to hold first-responder status, which is
            // what both the on-screen keyboard and hardware key events depend on.
            KeyCapture(active: Binding(get: { isPresented && pixelsAllowed && keyboard && !showControls },
                                       set: { if isPresented && pixelsAllowed { keyboard = $0 } }))
                .frame(width: 0, height: 0)

            // Optional editing keys belong to the keyboard; no host navigation bar covers the APK.
            if keyboard && pixelsAllowed && !showControls {
                VStack {
                    Spacer()
                    SpecialKeysBar()
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .huskPanel(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.bottom, 8)
                }
            }

        }
        // The guest's screen is dark in every appearance: it is a picture of
        // another phone, mostly black, and its chrome is drawn to sit on that.
        .environment(\.colorScheme, .dark)
        // On the screen rather than the button: the chrome can hide while the
        // document picker is up, and an importer attached to a view that goes
        // away goes away with it.
        .statusBarHidden(isPresented)
        .huskHideSystemOverlays(isPresented)
        .background {
            AppControlsGesture(active: isPresented && !showControls) { showControls = true }
        }
        .overlay(alignment: .bottom) {
            if isPresented { AppControlsHint() }
        }
        .accessibilityAction(named: Text("App Controls")) { showControls = true }
        .sheet(isPresented: $showControls) {
            AppSessionControls(onReturn: onBack) {
                Section {
                    Toggle("Keyboard", isOn: $keyboard)
                    Button {
                        HuskGLView.rotated.toggle()
                        rotated = HuskGLView.rotated
                    } label: {
                        Label(rotated ? "Unrotate picture" : "Rotate picture", systemImage: "rotate.right")
                    }
                }
                Section {
                    Button {
                        QemuRunner.shared.saveState(reason: "asked from app controls")
                    } label: {
                        Label(runner.isSavingState ? "Saving…" : "Save Runtime", systemImage: "externaldrive.badge.checkmark")
                    }
                    .disabled(runner.isSavingState || !runner.snapshotSavingSupported)
                    Button { showControls = false; showLogs = true } label: {
                        Label("Console", systemImage: "terminal")
                    }
                }
            }
        }
        .onChange(of: isPresented) { visible in
            if !visible {
                keyboard = false
                showControls = false
            }
        }
    }
}

/// Live log tail with a share button. The share sheet is the practical way to get
/// husk.log and the guest's serial console off the device.
/// Settings, reached from the gear on the start screen.
///
/// These are the choices that have to be made before Android boots, because
/// booting is expensive and each of them changes what that boot costs.
struct LogView: View {
    var isSheet = true
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var showShare = false
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(color(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onReceive(tick) { _ in
                    lines = HuskLog.recentLines(800)
                    if let last = lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isSheet {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [
                    HuskLog.logFileURL,
                    URL(fileURLWithPath: QemuRunner.shared.guestSerialLogPath),
                    // QEMU's own output. Missing from this list until now, which
                    // is precisely why a crash could not be diagnosed from a
                    // shared log.
                    HuskLog.nativeLogURL,
                    HuskLog.previousNativeLogURL,
                ])
            }
        }
    }

    /// Colour by source so the JIT path stands out from QEMU's own chatter.
    private func color(for line: String) -> Color {
        if line.contains("FAIL") || line.contains("FATAL") || line.contains("error") {
            return .red
        }
        if line.contains("[husk-jit]") { return .green }
        if line.contains("[husk-dpy]") { return .cyan }
        if line.contains("[guest]")    { return .yellow }
        return .primary
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Starting Android on launch, made safe to repeat: whether the image was there as Husk opened, and a marker that is only on
/// disk while an automatic start is under way, so a start Husk did not survive is not tried again on the next launch.
enum AutoStart {
    /// Whether the guest was ready on the first look in this process; nil before it.
    nonisolated(unsafe) static var readyAtLaunch: Bool?
    nonisolated(unsafe) private static var generation: UInt64 = 0

    private static var marker: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("husk-autostart-pending").path
    }

    /// True once per crash: the marker of an automatic start that never finished is read and removed.
    static func lastOneDied() -> Bool {
        guard FileManager.default.fileExists(atPath: marker) else { return false }
        try? FileManager.default.removeItem(atPath: marker)
        return true
    }

    /// Marks an automatic start; the mark goes once QEMU has been running for a minute.
    static func begin() {
        generation &+= 1
        let attempt = generation
        FileManager.default.createFile(atPath: marker, contents: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            // An earlier no-JIT attempt must not clear a later start's marker.
            guard generation == attempt else { return }
            end()
        }
    }

    static func end() {
        generation &+= 1
        try? FileManager.default.removeItem(atPath: marker)
    }
}
