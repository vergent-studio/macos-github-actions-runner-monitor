import Foundation

/// Best-effort redaction utility for removing recognizable credentials and tokens from displayed or exported logs.
/// Note: Automated redaction is best-effort and cannot guarantee removal of every secret format.
public enum SecretRedactor {
    private static let patterns: [(regex: NSRegularExpression, replacement: String)] = {
        let definitions: [(String, String)] = [
            // GitHub Personal Access Tokens, OAuth tokens, App tokens, Refresh tokens
            (#"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{16,255}\b"#, "[REDACTED_GITHUB_TOKEN]"),
            (#"\bgithub_pat_[A-Za-z0-9_]{16,255}\b"#, "[REDACTED_GITHUB_PAT]"),
            // Authorization / Bearer headers
            (#"(?i)(Authorization\s*:\s*(?:Bearer|Basic|Token)\s+)[^\s"']+"#, "$1[REDACTED]"),
            (#"(?i)\bBearer\s+[A-Za-z0-9\-._~+/]{16,}=*"#, "Bearer [REDACTED]"),
            // Actions pipeline URLs containing embedded tenant/session tokens
            (#"(https://pipelines[a-z0-9.]*\.actions\.githubusercontent\.com/)[^/\s"']+(/?)"#, "$1[REDACTED]$2"),
            // Runner command-line token options
            (#"(Adding option 'token': ')[^']*(')"#, "$1[REDACTED]$2"),
            (#"(?i)(--token\s+)[^\s"']+"#, "$1[REDACTED]"),
            // Generic key=value or JSON fields for token/secret/password/private_key
            (#"(?i)("(?:access_token|refresh_token|client_secret|password|secret|token)"\s*:\s*")[^"]+(")"#, "$1[REDACTED]$2"),
            (#"(?i)\b((?:token|secret|password|api_key|apikey|access_key)\s*=\s*)[^\s&"']+"#, "$1[REDACTED]")
        ]

        return definitions.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return nil
            }
            return (regex, replacement)
        }
    }()

    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var current = text
        for item in patterns {
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            current = item.regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: item.replacement
            )
        }
        return current
    }
}
