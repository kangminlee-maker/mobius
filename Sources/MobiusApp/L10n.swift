import Foundation

/// 앱 UI 다국어. 키 = 한국어 원문 — 번역이 없으면 한국어로 폴백한다.
/// "system"이면 macOS 선호 언어를 따르고(ko/en/ja 매칭, 없으면 en), 아니면 지정 언어 고정.
enum L10n {
    static let defaultsKey = "appLanguage" // "system" | "ko" | "en" | "ja"
    static let supported = ["ko", "en", "ja"]

    static var current: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? "system"
    }

    static func setLanguage(_ lang: String) {
        UserDefaults.standard.set(lang, forKey: defaultsKey)
        cachedLang = nil
    }

    private static var cachedLang: String?
    private static var cachedBundle: Bundle = .module

    private static func resolvedLang() -> String {
        let pref = current
        if pref != "system" { return pref }
        for l in Locale.preferredLanguages {
            let code = String(l.prefix(2))
            if supported.contains(code) { return code }
        }
        return "en"
    }

    static func bundle() -> Bundle {
        let lang = resolvedLang()
        if lang == cachedLang { return cachedBundle }
        cachedLang = lang
        // ko는 원문(키 그대로)이므로 lproj가 없어도 된다
        if let path = Bundle.module.path(forResource: lang, ofType: "lproj"),
           let b = Bundle(path: path) {
            cachedBundle = b
        } else {
            cachedBundle = .module
        }
        return cachedBundle
    }
}

/// 모든 사용자 노출 문자열은 이 함수를 거친다. 키가 곧 한국어 원문.
func loc(_ key: String) -> String {
    L10n.bundle().localizedString(forKey: key, value: key, table: nil)
}

/// 포맷 인자 버전 — 키는 %@/%d 포함 한국어 포맷 문자열.
func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: loc(key), arguments: args)
}
