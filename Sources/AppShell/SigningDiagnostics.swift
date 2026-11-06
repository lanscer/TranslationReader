import Foundation
import Security

/// 签名诊断：回答「为什么勾了辅助功能还是不生效」——先看清当前二进制到底以什么身份被系统登记。
/// 优先用 /usr/bin/codesign 读 Authority（与用户肉眼看到的钥匙串条目一致），失败退回 SecCode API。
enum SigningDiagnostics {
    struct Snapshot {
        let bundlePath: String
        let identity: String
        let isSandboxed: Bool
        let executable: String
    }

    static func describe() -> Snapshot {
        let path = Bundle.main.bundlePath
        let executable = Bundle.main.executablePath ?? path
        let identity = codesignIdentity(at: path) ?? secCodeIdentity() ?? "未签名 / ad-hoc（系统无法稳定记住授权）"
        return Snapshot(bundlePath: path, identity: identity, isSandboxed: false, executable: executable)
    }

    /// codesign -dv --verbose=2 → Authority=...（一次子进程，仅在刷新诊断时调用）。
    private static func codesignIdentity(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=2", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        var authority: String?
        var signature: String?
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Authority=") {
                authority = String(text.dropFirst("Authority=".count))
            } else if text.hasPrefix("Signature=") {
                signature = String(text.dropFirst("Signature=".count))
            }
        }
        if let authority { return "「\(authority)」（稳定签名，TCC 与钥匙串 ACL 可长期复用）" }
        if let signature { return "签名方式=\(signature)（ad-hoc/未证书签名，重建后授权会失效）" }
        return nil
    }

    /// SecCode 兜底：读取证书主题或 bundle identifier。
    private static func secCodeIdentity() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let first = certificates.first,
           let summary = SecCertificateCopySubjectSummary(first) as String? {
            return "「\(summary)」（SecCode）"
        }
        if let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String {
            return "identifier=\(identifier)（无证书）"
        }
        return nil
    }
}
