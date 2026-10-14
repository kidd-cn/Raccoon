import Foundation

func loc(_ key: String) -> String {
    NSLocalizedString(key, bundle: Bundle.module, comment: "")
}

func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: Bundle.module, comment: ""), arguments: args)
}

/// 字节人性化显示;Task 12 起被主页/明细/报告消费(基线阶段暂无调用方)。
func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
