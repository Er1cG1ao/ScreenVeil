import AppKit
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case about = "About"

    var id: Self { self }
    var icon: String { self == .general ? "slider.horizontal.3" : "info.circle" }
}

private final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = .general
    @Published var confirmKarabiner = false
}

private struct SettingsMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct SettingsView: View {
    @ObservedObject var lock: LockController
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var navigation = SettingsNavigation()
    @Namespace private var tabSelection

    private let accent = Color(red: 0.204, green: 0.600, blue: 1.0)
    private var cardFill: Color { .white.opacity(colorScheme == .dark ? 0.08 : 0.75) }
    private var border: Color { colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.15) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Label(lock.ready ? "Ready" : "Setup required",
                      systemImage: lock.ready ? "lock.open.fill" : "exclamationmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(cardFill, in: Capsule())
                    .overlay { Capsule().strokeBorder(border) }
            }
            .frame(height: 52)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch navigation.page {
                    case .general: general
                    case .about: about
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            tabBar
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 16)
        .background { SettingsMaterial().ignoresSafeArea() }
        .ignoresSafeArea()
        .tint(accent)
        .confirmationDialog("Update Karabiner shortcuts?", isPresented: $navigation.confirmKarabiner) {
            Button("Back Up and Update") { lock.setKarabinerProtection(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ScreenVeil will back up karabiner.json and add a condition to rules that run scripts or system actions. Those rules pause during ScreenVeil locks.")
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !lock.permissionsGranted {
                sectionTitle("Permissions")
                group {
                    if !lock.accessibility {
                        row("Accessibility", detail: "Allows ScreenVeil to block input.") {
                            permissionButton(lock.requestAccessibility)
                        }
                    }
                    if !lock.accessibility && !lock.inputMonitoring { rowDivider }
                    if !lock.inputMonitoring {
                        row("Input Monitoring", detail: "Allows ScreenVeil to detect the unlock shortcut.") {
                            permissionButton(lock.requestInputMonitoring)
                        }
                    }
                }
            }
            sectionTitle("Screen lock")
            group {
                row("Lock and unlock", detail: lock.isRecordingShortcut ? "Press your shortcut. Esc cancels."
                    : "Click the shortcut to change it.") {
                    Button {
                        if lock.isRecordingShortcut { lock.cancelShortcutRecording() }
                        else { lock.beginShortcutRecording() }
                    } label: {
                        Text(lock.isRecordingShortcut ? "Recording…" : lock.currentShortcut.label)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(lock.isRecordingShortcut ? accent.opacity(0.24) : Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(lock.isRecordingShortcut ? "Cancel shortcut recording"
                                        : "Change shortcut, current shortcut \(lock.currentShortcut.label)")
                }
                rowDivider
                row("Show unlock shortcut", detail: "Show the shortcut on the blurred screen.") {
                    Toggle("Show unlock shortcut", isOn: $lock.showUnlockHint)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            if let message = lock.shortcutError ?? lock.message {
                statusText(message)
            } else if !lock.shortcutAvailable && !lock.isRecordingShortcut {
                statusText("This shortcut is in use. Choose another one.")
            }

            if lock.karabinerAvailable {
                sectionTitle("Karabiner")
                group {
                    let coverage = lock.karabinerCoverage
                    row("Pause direct actions while locked",
                        detail: coverage.unguarded > 0 && coverage.isEnabled
                            ? "Some rules still need the ScreenVeil condition."
                            : "Pause shortcuts that run scripts or system actions.") {
                        if coverage.isEnabled && coverage.unguarded == 0 {
                            Button("Disable") { lock.setKarabinerProtection(false) }
                                .buttonStyle(.bordered).controlSize(.small)
                        } else if !lock.karabinerSupported {
                            Text("Needs Karabiner \(KarabinerLease.minimumVersion)+")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if coverage.unguarded > 0 {
                            Button(coverage.isEnabled ? "Update…" : "Enable…") { navigation.confirmKarabiner = true }
                                .buttonStyle(.bordered).controlSize(.small)
                        } else {
                            Text("No applicable rules").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = lock.karabinerError { statusText(error) }
            }
        }
    }

    private var rowDivider: some View {
        Divider().padding(.horizontal, 13)
    }

    private func statusText(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .padding(.horizontal, 5)
    }

    private var about: some View {
        group {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "lock.rectangle.on.rectangle.fill")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text("ScreenVeil").font(.title2.bold())
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
                Text("Version \(version)").font(.subheadline).foregroundStyle(.secondary)
                Text("ScreenVeil temporarily pauses input. Use macOS Lock Screen if you need password protection.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(SettingsPage.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { navigation.page = tab }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.icon).font(.system(size: 15, weight: .medium))
                            .frame(width: 19, height: 19)
                        if navigation.page == tab {
                            Text(tab.rawValue).font(.system(size: 13, weight: .medium)).fixedSize()
                        }
                    }
                    .padding(.horizontal, navigation.page == tab ? 14 : 11)
                    .frame(height: 42)
                    .contentShape(Capsule())
                    .background {
                        if navigation.page == tab {
                            Capsule().fill(cardFill)
                                .overlay { Capsule().strokeBorder(border) }
                                .matchedGeometryEffect(id: "selectedTab", in: tabSelection)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(tab.rawValue)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(navigation.page == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 54)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(border) }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 5)
            .accessibilityAddTraits(.isHeader)
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(border) }
    }

    private func row<Accessory: View>(
        _ title: String, detail: String, @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
    }

    private func permissionButton(_ action: @escaping () -> Void) -> some View {
        Button("Open Settings", action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}
