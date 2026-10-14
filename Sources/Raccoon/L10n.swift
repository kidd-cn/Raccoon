import Foundation

func loc(_ key: String) -> String {
    NSLocalizedString(key, bundle: Bundle.module, comment: "")
}

func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: Bundle.module, comment: ""), arguments: args)
}

func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
