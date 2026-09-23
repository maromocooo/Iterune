import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case english = "en"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    public var id: String { rawValue }
    public var nativeName: String {
        switch self { case .english: return "English"; case .japanese: return "日本語"; case .simplifiedChinese: return "简体中文"; case .traditionalChinese: return "繁體中文" }
    }
    public var translationName: String {
        switch self { case .english: return "English"; case .japanese: return "Japanese"; case .simplifiedChinese: return "Simplified Chinese"; case .traditionalChinese: return "Traditional Chinese" }
    }
    public var offersSkillTranslation: Bool { self != .english }
    public var locale: Locale { Locale(identifier: rawValue) }
    public static func resolve(saved: String?, preferredLanguages: [String]) -> AppLanguage {
        if let saved, let language = AppLanguage(rawValue: saved) { return language }
        for code in preferredLanguages {
            if code.hasPrefix("ja") { return .japanese }
            if code.hasPrefix("zh-Hant") || ["zh-TW", "zh-HK", "zh-MO"].contains(where: { code.hasPrefix($0) }) { return .traditionalChinese }
            if code.hasPrefix("zh") { return .simplifiedChinese }
            if code.hasPrefix("en") { return .english }
        }
        return .english
    }
}

public enum Localization {
    public static let preferenceKey = "studio.interfaceLanguage"
    public static var language: AppLanguage {
        AppLanguage.resolve(saved: UserDefaults.standard.string(forKey: preferenceKey), preferredLanguages: Locale.preferredLanguages)
    }
    // The packaged .app uses Resources; SwiftPM uses its generated module bundle.
    private static let resourceBundle: Bundle = {
        let name = "Attune_SkillStudioCore.bundle"
        let locations = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for location in locations.compactMap({ $0 }) {
            if let bundle = Bundle(url: location.appendingPathComponent(name)) { return bundle }
        }
        #if DEBUG
        return Bundle.module
        #else
        // SwiftPM's generated fallback embeds the developer's build path. Shipping apps
        // resolve resources relative to their executable instead; missing resources fall back to keys.
        return Bundle.main
        #endif
    }()
    public static func resourceURL(_ name: String, extension ext: String) -> URL? { resourceBundle.url(forResource: name, withExtension: ext) }
    private static let catalogs: [AppLanguage: [String: String]] = {
        Dictionary(uniqueKeysWithValues: AppLanguage.allCases.map { language in
            guard let url = resourceBundle.url(forResource: language.rawValue, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let table = try? JSONDecoder().decode([String: String].self, from: data) else { return (language, [:]) }
            return (language, table)
        })
    }()
    public static func catalog(for language: AppLanguage) -> [String: String] { catalogs[language] ?? [:] }
    public static func text(_ key: String, language: AppLanguage, arguments: [String] = []) -> String {
        let template = catalogs[language]?[key] ?? catalogs[.english]?[key] ?? key
        // Replace only placeholders in the template, never tokens inside user-provided arguments.
        let pattern = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        let ns = template as NSString
        var result = template
        for match in pattern.matches(in: template, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let index = Int(ns.substring(with: match.range(at: 1))), arguments.indices.contains(index),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: arguments[index])
        }
        return result
    }
    public static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale))
    }
    public static func versionNote(_ note: String) -> String {
        if note.hasPrefix("Restored from v") { return L("Restored from v{0}", String(note.dropFirst("Restored from v".count))) }
        if note.hasPrefix("Improvement: ") { return L("Improvement: {0}", String(note.dropFirst("Improvement: ".count))) }
        return L(note)
    }
}

public func L(_ key: String, _ arguments: String...) -> String {
    Localization.text(key, language: Localization.language, arguments: arguments)
}
