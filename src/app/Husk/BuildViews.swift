// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct BuildScreen: View {
    @ObservedObject private var bridge = BuildBridgeStore.shared
    @ObservedObject private var router = Router.shared
    @Environment(\.scenePhase) private var phase
    @State private var showSetup = false
    @State private var showImporter = false
    @State private var showForget = false
    @FocusState private var composing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bridge.selected?.name ?? "Build your app").font(.title2.bold()).lineLimit(2)
                        Button { showSetup = true } label: {
                            HStack(spacing: 6) {
                                Circle().fill(bridge.connected && bridge.paired ? Color.green : Color.orange).frame(width: 7, height: 7)
                                Text(bridge.connectionLabel).font(.caption)
                            }.foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 8)
                    if bridge.profile != nil && !bridge.connected {
                        Button { Task { await bridge.refresh() } } label: {
                            if bridge.checkingConnection { ProgressView() }
                            else { Image(systemName: "arrow.clockwise") }
                        }.buttonStyle(.bordered).disabled(bridge.checkingConnection || bridge.busy)
                            .accessibilityLabel("Reconnect to Mac")
                    }
                    Button { bridge.newChat() } label: { Image(systemName: "plus").font(.title3) }
                        .buttonStyle(.bordered).accessibilityLabel("New app chat")
                    Menu {
                        Button { router.tab = .myApps } label: { Label("My Apps", systemImage: "square.stack.3d.up") }
                        Button { Task { await bridge.refresh() } } label: { Label("Reconnect to Mac", systemImage: "arrow.clockwise") }
                            .disabled(bridge.profile == nil || bridge.checkingConnection || bridge.busy)
                        Button { showSetup = true } label: { Label("Pairing setup", systemImage: "link") }
                        Button { showImporter = true } label: { Label("Import agent.prf", systemImage: "doc.badge.plus") }
                        if bridge.profile != nil { Button("Forget this Mac", role: .destructive) { showForget = true } }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                }.padding(18)
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if bridge.profile == nil {
                                setupCard
                            } else if bridge.selected == nil {
                                welcomeCard
                            }
                            if let project = bridge.selected {
                                ForEach(project.messages) { message in BuildMessageRow(message: message) }
                                ForEach(project.approvals) { approval in
                                    BuildApprovalCard(approval: approval, project: project)
                                }
                                if let summary = project.summary, !project.artifacts.isEmpty {
                                    BuildCompletionCard(summary: summary) { router.tab = .myApps }
                                }
                                if project.isActive {
                                    HStack {
                                        ProgressView()
                                        Text(project.statusLabel).font(.callout).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Stop") { Task { await bridge.interrupt(project) } }.buttonStyle(.bordered)
                                    }.padding(14).background(Console.card, in: RoundedRectangle(cornerRadius: 18))
                                }
                                if let error = project.error, !error.isEmpty { BuildErrorCard(text: error) }
                            }
                            if let error = bridge.error { BuildErrorCard(text: error) }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(.horizontal, 18).padding(.bottom, 16)
                    }
                    .onChange(of: bridge.selected?.messages.count) { _ in
                        withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                composer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Console.page)
            .navigationBarHidden(true)
            .sheet(isPresented: $showSetup) { BridgeSetupSheet(showImporter: $showImporter) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                do { if let url = try result.get().first { bridge.importProfile(url) } }
                catch { bridge.error = error.localizedDescription }
            }
            .alert("Forget this Mac?", isPresented: $showForget) {
                Button("Forget Mac", role: .destructive) { bridge.forgetMac() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your apps and conversations stay on your Mac. Import agent.prf to reconnect.") }
            .task {
                await bridge.refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { break }
                    if phase == .active && router.tab == .build { await bridge.poll() }
                }
            }
        }
    }
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "desktopcomputer.and.arrow.down").font(.system(size: 34)).foregroundStyle(.blue)
            Text("Generate agent.prf").font(.title2.bold())
            Text("Install APK Container Bridge on your Mac, then generate your pairing file. Import it here and pair the /apk skill to start building.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Set Up Mac Bridge") { showSetup = true }.buttonStyle(.bordered)
                Button("Import agent.prf") { showImporter = true }.buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 24))
    }
    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you want to make?").font(.title2.bold())
            Text("Describe your app below. Codex builds it on your Mac, and its replies appear here. Keep editing in the same chat, or use + for a new app.")
                .foregroundStyle(.secondary)
            Label("Your finished APKs appear in My Apps", systemImage: "square.stack.3d.up")
                .font(.callout).foregroundStyle(.blue)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Console.card, in: RoundedRectangle(cornerRadius: 24))
    }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $bridge.draft).focused($composing)
                    .frame(minHeight: 48, maxHeight: 100).padding(4)
                    .accessibilityLabel(bridge.selected == nil ? "Describe your app" : "Edit your app")
                if bridge.draft.isEmpty { Text(bridge.selected == nil ? "Describe the app you want to build…" : "What should we change?")
                    .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 12).allowsHitTesting(false) }
            }.background(Console.card, in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            Button {
                composing = false
                Task { await bridge.send() }
            } label: {
                if bridge.busy { ProgressView().frame(width: 26, height: 26) }
                else { Image(systemName: "arrow.up").font(.title3.bold()).frame(width: 26, height: 26) }
            }.buttonStyle(.borderedProminent).clipShape(Circle())
                .disabled(bridge.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bridge.draft.count > 20_000
                          || bridge.busy || bridge.selected?.isActive == true || !bridge.paired || !bridge.connected)
                .accessibilityLabel("Send to Codex")
        }.padding(16).background(.ultraThinMaterial)
    }
}

struct MyAppsScreen: View {
    @ObservedObject private var bridge = BuildBridgeStore.shared
    @ObservedObject private var router = Router.shared
    @Environment(\.scenePhase) private var phase
    @State private var query = ""
    private var projects: [BuildProject] {
        bridge.projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("My Apps").font(.largeTitle.bold())
                            Text("Made by you, built on your Mac.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { bridge.newChat() } label: { Image(systemName: "plus").font(.title2) }
                            .buttonStyle(.borderedProminent).accessibilityLabel("Create a new app chat")
                    }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search your apps", text: $query)
                        Button { Task { await bridge.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh My Apps")
                    }.padding(14).background(Console.card, in: Capsule())
                    if projects.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "hammer.fill").font(.system(size: 40)).foregroundStyle(.blue)
                            Text(query.isEmpty ? "Your next app starts here" : "No matching apps").font(.title2.bold())
                            Text(query.isEmpty ? "Create a chat in Build. Your projects and finished APKs will appear here." : "Try another search.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if query.isEmpty { Button("Build your app") { bridge.newChat() }.buttonStyle(.borderedProminent) }
                        }.frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                    ForEach(projects) { project in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 14) {
                                Image(systemName: "app.gift.fill").font(.title).foregroundStyle(.blue)
                                    .frame(width: 62, height: 62).background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.name).font(.headline).lineLimit(2)
                                    Text(project.statusLabel).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Button("Open Chat") { bridge.open(project) }.buttonStyle(.bordered)
                            }
                            if let artifact = project.artifacts.first {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(artifact.name).font(.callout).lineLimit(1)
                                        Text(ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button { Task { await bridge.install(artifact, project: project) } } label: {
                                        if bridge.downloading == artifact.id { ProgressView() }
                                        else { Label("Install APK", systemImage: "arrow.down.circle") }
                                    }.buttonStyle(.borderedProminent).disabled(!bridge.connected || bridge.downloading != nil)
                                }
                            }
                            if let summary = project.summary {
                                Text(summary.headline).font(.callout).foregroundStyle(.green)
                            }
                        }.padding(18).background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 24))
                    }
                    if let error = bridge.error { BuildErrorCard(text: error) }
                }.padding(20)
            }.background(Console.page).navigationBarHidden(true)
                .task {
                    await bridge.refresh()
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { break }
                        if phase == .active && router.tab == .myApps { await bridge.refresh() }
                    }
                }
        }
    }
}

private struct BuildMessageRow: View {
    let message: BuildMessage
    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 30) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.role == "user" ? "You" : message.role == "assistant" ? "Codex" : "Build")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.text.isEmpty ? "…" : message.text).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(16).background(message.role == "user" ? Color.blue.opacity(0.18) : Console.card,
                                     in: RoundedRectangle(cornerRadius: 20))
            if message.role != "user" { Spacer(minLength: 12) }
        }
    }
}
private struct BuildErrorCard: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
    }
}
private struct BuildCompletionCard: View {
    let summary: BuildSummary
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(summary.headline, systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            group("Features", summary.features)
            group("Issues", summary.issues)
            group("Ideas", summary.ideas)
            Button("Click here to open My Apps", action: open).buttonStyle(.borderedProminent)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))
    }
    private func group(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.bold())
            if values.isEmpty { Text("None reported.").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in Text("• " + value).font(.callout) }
        }
    }
}
private struct BuildApprovalCard: View {
    @ObservedObject private var bridge = BuildBridgeStore.shared
    let approval: BuildApproval
    let project: BuildProject
    @State private var answers: [String: String] = [:]
    @State private var sending = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(approval.title, systemImage: "hand.raised.fill").font(.headline)
            Text(approval.detail).font(.callout).textSelection(.enabled)
            ForEach(approval.questions ?? []) { question in
                Text(question.question).font(.subheadline.bold())
                if let options = question.options, !options.isEmpty {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Button { answers[question.id] = option.label } label: {
                            HStack {
                                Image(systemName: answers[question.id] == option.label ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) { Text(option.label); Text(option.description).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.buttonStyle(.plain)
                    }
                }
                TextField("Your answer", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Decline") { respond(false) }.buttonStyle(.bordered)
                Button(approval.kind == "input" ? "Send Answer" : "Allow Once") { respond(true) }
                    .buttonStyle(.borderedProminent)
                    .disabled((approval.questions ?? []).contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
            }.disabled(sending)
        }.padding(18).background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 20))
    }
    private func respond(_ accept: Bool) {
        sending = true
        Task {
            await bridge.approve(approval, project: project, accept: accept, answers: answers.mapValues { [$0] })
            sending = false
        }
    }
}
private struct BridgeSetupSheet: View {
    @ObservedObject private var bridge = BuildBridgeStore.shared
    @State private var macAddress = ""
    @Environment(\.dismiss) private var dismiss
    @Binding var showImporter: Bool
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 48)).foregroundStyle(.blue)
                    Text("Your Mac builds. Your device creates.").font(.largeTitle.bold())
                    if bridge.profile != nil { connectionCard }
                    step("1", "Install APK Container Bridge", "Open the Mac companion while Codex is signed in on that Mac.")
                    Link("Download the Mac Bridge", destination: URL(string: "https://github.com/exlon360/APK-Container/releases/tag/v1.0.0-preview.10")!)
                    step("2", "Generate agent.prf", "In the Mac bridge, choose Generate agent.prf. AirDrop the file or save it in Files, then import it here.")
                    step("3", "Pair Skill /apk", "Choose Pair Skill /apk on your Mac, or send /apk pair in Codex. Keep the bridge running and both devices on the same network or VPN.")
                    step("4", "Build your app", "Describe your idea in Build. Replies arrive here, and verified APKs appear in My Apps. The + button starts another app chat.")
                    Button("Import agent.prf") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showImporter = true }
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("The pairing file gives your device access to this bridge. Keep it private. Your Codex sign-in stays on the Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }.navigationTitle("Mac Bridge").navigationBarTitleDisplayMode(.inline)
                .onAppear { macAddress = bridge.profile?.url ?? "" }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(bridge.connectionLabel, systemImage: bridge.connected ? "checkmark.circle" : "wifi.exclamationmark")
                .font(.headline)
            if let address = bridge.connectedAddress {
                Text("Connected through " + address).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Keep the Mac bridge running and both devices on the same Wi-Fi or a reachable VPN. In Settings, allow Local Network for APK Container. If you run it inside LiveContainer, allow it for LiveContainer too.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(bridge.checkingConnection ? "Connecting…" : "Reconnect") { Task { await bridge.refresh() } }
                    .buttonStyle(.borderedProminent).disabled(bridge.checkingConnection || bridge.busy)
                Button("Open Settings") {
                    if let settings = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(settings) }
                }.buttonStyle(.bordered)
            }
            Divider()
            Text("Mac address").font(.subheadline.bold())
            TextField("https://192.168.1.20:48152", text: $macAddress)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder).accessibilityLabel("Mac bridge address")
            Text("Copy the address shown in the Mac bridge if your network changed. Your saved pairing and certificate stay the same.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Use This Address") { Task { await bridge.updateAddress(macAddress) } }
                .buttonStyle(.bordered).disabled(macAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bridge.checkingConnection || bridge.busy)
            if let error = bridge.error { Text(error).font(.callout).foregroundStyle(.orange) }
        }.padding(18).background(Console.card, in: RoundedRectangle(cornerRadius: 20))
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.headline).frame(width: 30, height: 30).background(Color.blue.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).foregroundStyle(.secondary) }
        }
    }
}
