import Foundation

enum AppLanguage: String {
    case system
    case russian = "ru"
    case english = "en"
}

struct AppLocalization {
    let locale: Locale
    private let bundle: Bundle

    init(language: AppLanguage, bundle: Bundle = .main) {
        let code = language == .system ? bundle.preferredLocalizations.first ?? "en" : language.rawValue
        locale = Locale(identifier: code)
        self.bundle = bundle.url(forResource: code, withExtension: "lproj")
            .flatMap { Bundle(url: $0) } ?? bundle
    }

    func text(_ english: String, _ arguments: CVarArg...) -> String {
        let translation = bundle.localizedString(forKey: english, value: english, table: nil)
        return arguments.isEmpty ? translation : String(format: translation, locale: locale, arguments: arguments)
    }

    func title(for action: LeftClickAction) -> String {
        switch action {
        case .showMenu: text("Open menu")
        case .selectMac: text("Switch to Mac")
        case .toggleInputs: text("Toggle between two inputs")
        }
    }
}
