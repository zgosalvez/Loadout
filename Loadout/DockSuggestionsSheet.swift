import SwiftUI

/// Looks through the apps on this Mac and suggests a Dock for the profile, using Apple Intelligence
/// on-device when it's available. The person ticks the ones they want; nothing is added until they confirm.
struct DockSuggestionsSheet: View {
    let profile: Profile
    let add: (_ apps: [String]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var installed: [InstalledApp] = []
    @State private var suggestions: [DockSuggestion] = []
    @State private var source: SuggestionSource?
    @State private var selected: Set<String> = []
    @State private var loading = true

    private var profileName: String { profile.name.isEmpty ? "this profile" : "“\(profile.name)”" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Suggest Apps", systemImage: "sparkles")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(loading
                     ? "Looking through the apps on your Mac…"
                     : "Picked for \(profileName) from the \(installed.count) apps on your Mac. Untick any you don't want.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Group {
                if loading {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(source == nil ? "Thinking…" : "")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if suggestions.isEmpty {
                    Text("No new suggestions. This profile may already have the apps that fit it.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(suggestions) { suggestion in row(suggestion) }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if let source, !loading {
                sourceNote(source)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            HStack(spacing: 8) {
                Button { Task { await load() } } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .disabled(loading)
                    .opacity(loading ? 0.4 : 1)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassCapsuleStyle())
                    .keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Add" : "Add \(selected.count)") {
                    // Keep the suggested order: the most useful app first.
                    add(suggestions.map(\.app.path).filter(selected.contains))
                    dismiss()
                }
                .buttonStyle(GlassCapsuleStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.5 : 1)
            }
            .padding(16)
            .background(.black.opacity(0.15))
        }
        .frame(width: 440, height: 540)
        .foregroundStyle(.white)
        .background(EditorBackground(tint: profile.themeColor))
        .environment(\.colorScheme, .dark)
        .task { await load() }
    }

    private func row(_ suggestion: DockSuggestion) -> some View {
        let checked = selected.contains(suggestion.id)
        return Button {
            if checked { selected.remove(suggestion.id) } else { selected.insert(suggestion.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(checked ? .white : .white.opacity(0.35))
                Image(nsImage: NSWorkspace.shared.icon(forFile: suggestion.app.path))
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.app.name).font(.system(size: 13, weight: .semibold))
                    Text(suggestion.reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(checked ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sourceNote(_ source: SuggestionSource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: source == .appleIntelligence ? "apple.intelligence" : "square.grid.2x2")
            Text(source == .appleIntelligence
                 ? "Suggested on-device by Apple Intelligence. Your app list never leaves your Mac."
                 : "Suggested from app categories. With Apple Intelligence turned on, suggestions get smarter.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.5))
    }

    private func load() async {
        loading = true
        source = nil
        if installed.isEmpty {
            installed = await Task.detached(priority: .userInitiated) { InstalledApps.scan() }.value
        }
        let favorites = DockManager.currentApps()
        let result = await DockSuggester.suggest(for: profile, from: installed, favorites: favorites)
        withAnimation(.snappy) {
            suggestions = result.suggestions
            source = result.source
            selected = Set(result.suggestions.map(\.id))
            loading = false
        }
    }
}
