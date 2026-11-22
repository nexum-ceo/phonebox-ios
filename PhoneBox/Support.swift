import Foundation
import Security
import UIKit

/// Stores small secrets (the paired computers with their Wi-Fi tokens) in the iOS Keychain.
/// The Android app keeps them in private SharedPreferences; the Keychain is the iOS equivalent.
enum Keychain {
    private static let service = "net.oxog.phonebox.deskpanel"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let data = Data(value.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Quotes a string as a JavaScript string literal (the equivalent of JSONObject.quote).
func jsQuote(_ s: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
          let text = String(data: data, encoding: .utf8) else { return "\"\"" }
    // ["..."] -> "..."; U+2028/2029 are valid in JSON but end a line in older JavaScript
    return String(text.dropFirst().dropLast())
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}

func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let text = String(data: data, encoding: .utf8) else { return "null" }
    return text
}

/// The language of the native dialogs: the panel's language setting when it has one (like the Android app's
/// "language" preference), otherwise the phone's.
enum LocalizedStrings {
    private static let defaultsKey = "panel-language"
    private(set) static var bundle: Bundle = load(UserDefaults.standard.string(forKey: defaultsKey) ?? "auto")

    static func use(panelLanguage tag: String) {
        if UserDefaults.standard.string(forKey: defaultsKey) != tag { UserDefaults.standard.set(tag, forKey: defaultsKey) }
        bundle = load(tag)
    }

    private static func load(_ tag: String) -> Bundle {
        if tag == "auto" { return .main }
        let mapped: [String: String] = ["zh": "zh-Hans", "pt": "pt-PT"]
        var candidates = [mapped[tag] ?? tag]
        if let base = tag.split(separator: "-").first { candidates.append(mapped[String(base)] ?? String(base)) }
        for name in candidates {
            if let path = Bundle.main.path(forResource: name, ofType: "lproj"), let bundle = Bundle(path: path) { return bundle }
        }
        return .main
    }

    static func string(_ key: String) -> String {
        let missing = "\u{0}"
        let value = bundle.localizedString(forKey: key, value: missing, table: nil)
        return value == missing ? Bundle.main.localizedString(forKey: key, value: nil, table: nil) : value
    }
}

/// Strings shown by the native shell (pairing dialogs). Translated like the Android app's strings.xml.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = LocalizedStrings.string(key)
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// "Apple iPhone14,5": what the agent's phone list shows, like "Xiaomi Redmi Note 7" for Android.
enum DeviceInfo {
    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    private static let names: [String: String] = [
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
    ]

    static var model: String {
        let name = names[machine] ?? machine
        return "Apple \(name)".filter { $0 >= " " && $0 <= "~" }.trimmingCharacters(in: .whitespaces).prefix(40).description
    }

    /// A short hash of the vendor id, like the Android app's hash of ANDROID_ID.
    static var deviceId: String {
        let raw = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        return sha256Hex(Data(raw.utf8)).prefix(12).description
    }

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}
