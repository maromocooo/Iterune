import SwiftUI
import SkillStudioCore

enum StudioTheme {
    static let ink = Color(red: 0.16, green: 0.18, blue: 0.23)
    static let muted = Color(red: 0.44, green: 0.46, blue: 0.51)
    static let accent = Color(red: 0.40, green: 0.34, blue: 0.77)
    static let background = Color(red: 0.97, green: 0.97, blue: 0.985)
    static let rail = Color(red: 0.115, green: 0.12, blue: 0.18)
    static let border = Color.black.opacity(0.07)
    static func agent(_ agent: AgentKind) -> Color {
        switch agent { case .claude: return Color(red: 0.79, green: 0.46, blue: 0.32); case .codex: return Color(red: 0.27, green: 0.59, blue: 0.49); case .gemini: return Color(red: 0.39, green: 0.52, blue: 0.89) }
    }
}

struct Tag: View {
    @Environment(\.locale) private var locale
    let text: String
    var color: Color = StudioTheme.muted
    var body: some View {
        Text(Localization.text(text, language: AppLanguage.resolve(saved: locale.identifier, preferredLanguages: [locale.identifier]))).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct SectionCaption: View {
    @Environment(\.locale) private var locale
    let text: String
    var body: some View { Text(Localization.text(text, language: AppLanguage.resolve(saved: locale.identifier, preferredLanguages: [locale.identifier])).uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(StudioTheme.muted) }
}

struct StudioCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioTheme.border, lineWidth: 1))
    }
}

struct EmptyState: View {
    @Environment(\.locale) private var locale
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(StudioTheme.accent)
            Text(localized(title)).font(.system(size: 21, weight: .semibold))
            Text(localized(detail)).font(.system(size: 13)).foregroundStyle(StudioTheme.muted).multilineTextAlignment(.center).frame(maxWidth: 370)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
    private func localized(_ text: String) -> String {
        Localization.text(text, language: AppLanguage.resolve(saved: locale.identifier, preferredLanguages: [locale.identifier]))
    }
}
