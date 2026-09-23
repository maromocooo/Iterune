import SwiftUI
import SkillStudioCore

struct AgentIconView: View {
    let agent: AgentKind
    var size: CGFloat = 32
    var foreground: Color = .primary
    // Original text badges; no vendor artwork or installed application resources.
    private var initials: String {
        switch agent {
        case .claude: return "Cl"
        case .codex: return "Cx"
        case .gemini: return "Ge"
        }
    }
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: size * 0.25))
            .overlay(RoundedRectangle(cornerRadius: size * 0.25).strokeBorder(foreground.opacity(0.25)))
            .accessibilityLabel(agent.title)
    }
}
