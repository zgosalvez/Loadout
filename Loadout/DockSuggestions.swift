import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// An app installed on this Mac.
struct InstalledApp: Hashable, Sendable {
    let path: String
    let name: String
    /// The App Store category, e.g. "productivity", when the app declares one.
    let category: String?
}

enum InstalledApps {
    /// Every regular app in the usual Applications folders, once each, sorted by name.
    /// Menu bar helpers and background agents are left out; they don't belong in the Dock.
    static func scan() -> [InstalledApp] {
        let fileManager = FileManager.default
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        // Some apps (Adobe's, DaVinci Resolve) install inside a folder of their own, so look one level down too.
        var bundles: [String] = []
        for folder in folders {
            guard let items = try? fileManager.contentsOfDirectory(atPath: folder) else { continue }
            for item in items where !item.hasPrefix(".") {
                let path = (folder as NSString).appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    bundles.append(path)
                } else if !folder.hasPrefix("/System"), let inner = try? fileManager.contentsOfDirectory(atPath: path) {
                    bundles += inner.filter { $0.hasSuffix(".app") }.map { (path as NSString).appendingPathComponent($0) }
                }
            }
        }

        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for path in bundles {
            guard let bundle = Bundle(path: path), let info = bundle.infoDictionary else { continue }
            if isTrue(info["LSUIElement"]) || isTrue(info["LSBackgroundOnly"]) { continue }
            let name = fileManager.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            // Most of macOS's Utilities folder is setup and repair tools nobody keeps in a Dock.
            if path.hasPrefix("/System/Applications/Utilities/"), !dockworthyUtilities.contains(name) { continue }
            // App folders often ship an uninstaller or installer next to the app itself.
            if name.localizedCaseInsensitiveContains("uninstall") || name.localizedCaseInsensitiveContains("installer") { continue }
            let id = bundle.bundleIdentifier ?? path
            guard id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            apps.append(InstalledApp(
                path: path,
                name: name,
                category: (info["LSApplicationCategoryType"] as? String)?
                    .replacingOccurrences(of: "public.app-category.", with: "")))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static let dockworthyUtilities: Set = ["Terminal", "Activity Monitor", "Screenshot"]

    private static func isTrue(_ value: Any?) -> Bool {
        (value as? Bool) == true || (value as? String) == "1" || (value as? NSNumber)?.boolValue == true
    }
}

struct DockSuggestion: Identifiable, Hashable, Sendable {
    var id: String { app.path }
    let app: InstalledApp
    /// A few words on why it fits the profile.
    let reason: String
}

enum SuggestionSource: Sendable {
    /// Picked by Apple's on-device model. Nothing leaves the Mac.
    case appleIntelligence
    /// Picked from app categories and well-known apps, when Apple Intelligence isn't available.
    case categories
}

enum DockSuggester {
    /// Suggests Dock apps for a profile from the installed apps, leaving out ones it already has.
    /// Uses Apple Intelligence when the Mac has it, and app categories otherwise.
    /// `favorites` are paths of apps the person already keeps in their Dock, a hint about what they really use.
    static func suggest(for profile: Profile, from apps: [InstalledApp], favorites: [String] = []) async -> (suggestions: [DockSuggestion], source: SuggestionSource) {
        let candidates = apps.filter { !profile.dockApps.contains($0.path) }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), SystemLanguageModel.default.isAvailable,
           let picks = try? await IntelligenceSuggester.suggest(for: profile, from: candidates, favorites: favorites), !picks.isEmpty {
            return (blend(ai: picks, for: profile, from: candidates), .appleIntelligence)
        }
        #endif
        return (CategorySuggester.suggest(for: profile, from: candidates), .categories)
    }

    /// The on-device model is small and sometimes picks odd apps, so when the profile's name says what kind of
    /// Focus it is, steady the picks with what fits that kind: apps both agree on first, then well-known apps
    /// for it, then the model's other picks, minus any whose category plainly doesn't fit.
    private static func blend(ai: [DockSuggestion], for profile: Profile, from apps: [InstalledApp], limit: Int = 8) -> [DockSuggestion] {
        guard CategorySuggester.recognizes(profile) else { return ai }
        let known = CategorySuggester.suggest(for: profile, from: apps)
        let knownPaths = Set(known.map(\.id))
        let aiPaths = Set(ai.map(\.id))
        let agreed = ai.filter { knownPaths.contains($0.id) }
        let knownOnly = known.filter { !aiPaths.contains($0.id) }
        let aiOnly = ai.filter { !knownPaths.contains($0.id) && !CategorySuggester.isOffTopic($0.app, for: profile) }
        return Array((agreed + knownOnly + aiOnly).prefix(limit))
    }
}

// MARK: - Apple Intelligence

#if canImport(FoundationModels)
@available(macOS 26, *)
enum IntelligenceSuggester {
    static func suggest(for profile: Profile, from apps: [InstalledApp], favorites: [String]) async throws -> [DockSuggestion] {
        // App names can repeat across versions; offer each name once.
        var byName: [String: InstalledApp] = [:]
        for app in apps where byName[app.name] == nil { byName[app.name] = app }
        let names = byName.keys.sorted()
        guard !names.isEmpty else { return [] }

        // The answer is constrained to the exact app names, so every pick is a real app. Asking for the
        // Focus's activities first gives the small on-device model something to choose the apps against.
        let shortText = DynamicGenerationSchema(type: String.self)
        let pick = DynamicGenerationSchema(name: "DockPick", properties: [
            .init(name: "name", description: "An app from the list", schema: DynamicGenerationSchema(name: "AppName", anyOf: names)),
            .init(name: "reason", description: "What it's for in this Focus, in one short sentence",
                  schema: shortText),
        ])
        let root = DynamicGenerationSchema(name: "DockPlan", properties: [
            .init(name: "activities", description: "What someone does during this Focus, like 'answer email' or 'edit video'",
                  schema: DynamicGenerationSchema(arrayOf: shortText, minimumElements: 2, maximumElements: 5)),
            .init(name: "apps", description: "The apps for this Focus's Dock, most useful first",
                  schema: DynamicGenerationSchema(arrayOf: pick, minimumElements: 3, maximumElements: 8)),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])

        let session = LanguageModelSession(instructions: """
            You help someone set up their Mac's Dock for one Focus mode. First think about what they will do \
            during this Focus. Then choose the installed apps they would open for those activities. Leave out \
            apps that have nothing to do with it or would distract from it.
            """)
        let icon = profile.displaySymbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ")
        let everyday = apps.filter { favorites.contains($0.path) }.map(\.name)
        let prompt = """
            Focus: \(profile.name.isEmpty ? "Untitled" : profile.name) (icon: \(icon))

            Apps they use every day (prefer these when they fit this Focus): \(everyday.isEmpty ? "unknown" : everyday.joined(separator: ", "))

            Installed apps, with their App Store category where they have one:
            \(names.map { name in byName[name]?.category.map { "\(name) (\($0))" } ?? name }.joined(separator: "\n"))
            """
        let response = try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: false,
                                                 options: GenerationOptions(maximumResponseTokens: 500))

        var seen = Set<String>()
        return try response.content.value([GeneratedContent].self, forProperty: "apps").compactMap { item in
            guard let app = byName[try item.value(String.self, forProperty: "name")], seen.insert(app.path).inserted else { return nil }
            return DockSuggestion(app: app, reason: try item.value(String.self, forProperty: "reason"))
        }
    }
}
#endif

// MARK: - Fallback: app categories

enum CategorySuggester {
    /// What a kind of Focus usually needs: words that identify it in a profile name,
    /// App Store categories that fit, and well-known apps in order of preference.
    private struct Theme {
        let words: [String]
        let categories: [String]
        let apps: [String]
        let label: String
    }

    private static let themes: [Theme] = [
        Theme(words: ["work", "office", "deep", "job", "meeting", "focus"],
              categories: ["productivity", "business", "developer-tools"],
              apps: ["Mail", "Calendar", "Notes", "Reminders", "Slack", "Microsoft Outlook", "Microsoft Teams", "Zoom", "Notion", "Safari"],
              label: "work"),
        Theme(words: ["code", "dev", "build", "engineer", "program"],
              categories: ["developer-tools"],
              apps: ["Xcode", "Visual Studio Code", "Terminal", "Ghostty", "GitHub Desktop", "Simulator", "Safari"],
              label: "coding"),
        Theme(words: ["game", "gaming", "play"],
              categories: ["games", "entertainment"],
              apps: ["Games", "Steam", "Discord", "PS Remote Play", "Chess", "Music", "Spotify"],
              label: "gaming"),
        Theme(words: ["sleep", "night", "bed", "wind", "rest", "relax", "calm", "mindful"],
              categories: ["healthcare-fitness", "music", "books", "lifestyle"],
              apps: ["Podcasts", "Books", "Music", "Spotify"],
              label: "winding down"),
        Theme(words: ["read", "study", "learn", "school", "class", "research"],
              categories: ["books", "education", "reference", "news"],
              apps: ["Books", "Notes", "Preview", "Goodnotes", "PDF Expert", "Dictionary", "Safari"],
              label: "reading"),
        Theme(words: ["personal", "home", "weekend", "family", "social", "friends"],
              categories: ["social-networking", "photography", "lifestyle", "entertainment", "music", "travel", "navigation"],
              apps: ["Messages", "WhatsApp", "FaceTime", "Photos", "Music", "Maps", "Safari"],
              label: "personal time"),
        Theme(words: ["fit", "workout", "gym", "run", "train", "health", "sport"],
              categories: ["healthcare-fitness", "sports"],
              apps: ["Music", "Spotify", "Fitness", "Clock", "Podcasts"],
              label: "workouts"),
        Theme(words: ["video", "film", "movie", "youtube", "stream"],
              categories: ["video"],
              apps: ["Final Cut Pro", "DaVinci Resolve", "Adobe Premiere Pro", "iMovie", "Adobe After Effects", "OBS", "HandBrake", "QuickTime Player"],
              label: "video work"),
        Theme(words: ["design", "creat", "studio", "art", "photo", "edit", "draw"],
              categories: ["graphics-design", "photography"],
              apps: ["Figma", "Adobe Photoshop", "Adobe Illustrator", "Affinity", "Pixelmator Pro", "Adobe Lightroom", "Capture One", "Photos", "Preview"],
              label: "creative work"),
        Theme(words: ["drive", "travel", "commute", "trip"],
              categories: ["navigation", "travel"],
              apps: ["Maps", "Music", "Podcasts", "Weather"],
              label: "travel"),
    ]

    private static func theme(for profile: Profile) -> Theme? {
        let name = profile.name.lowercased()
        return themes.first { $0.words.contains(where: name.contains) }
    }

    /// Whether the profile's name says what kind of Focus it is (Work, Gaming, Sleep…).
    static func recognizes(_ profile: Profile) -> Bool { theme(for: profile) != nil }

    /// Whether an app's App Store category plainly doesn't fit the kind of Focus the profile's name describes.
    /// Apps without a category, and well-known apps for that kind of Focus, always count as fitting.
    static func isOffTopic(_ app: InstalledApp, for profile: Profile) -> Bool {
        guard let theme = theme(for: profile), let category = app.category else { return false }
        let name = app.name.lowercased()
        return !theme.categories.contains(where: category.contains) && !theme.apps.contains { name.hasPrefix($0.lowercased()) }
    }

    /// Without a recognisable name, it falls back to the work picks.
    static func suggest(for profile: Profile, from apps: [InstalledApp], limit: Int = 6) -> [DockSuggestion] {
        let theme = theme(for: profile) ?? themes[0]

        let scored: [(app: InstalledApp, score: Int, reason: String)] = apps.compactMap { app in
            let appName = app.name.lowercased()
            if let rank = theme.apps.firstIndex(where: { appName.hasPrefix($0.lowercased()) }) {
                return (app, 100 - rank, "Popular for \(theme.label)")
            }
            if let category = app.category, theme.categories.contains(where: category.contains) {
                return (app, 10, "\(category.replacingOccurrences(of: "-", with: " ").capitalized) app")
            }
            return nil
        }
        return scored.sorted { $0.score > $1.score }
            .prefix(limit)
            .map { DockSuggestion(app: $0.app, reason: $0.reason) }
    }
}
