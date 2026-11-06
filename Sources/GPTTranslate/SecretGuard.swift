import Foundation

/// Spots API keys, tokens and private keys so they are never sent for translation or saved to history.
enum SecretGuard {
    private static let patterns: [NSRegularExpression] = [
        #"sk-ant-[A-Za-z0-9_\-]{20,}"#,                 // Anthropic
        #"\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}"#,         // OpenAI and similar
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"#, // GitHub tokens
        #"\bgithub_pat_[A-Za-z0-9_]{30,}"#,
        #"\bglpat-[A-Za-z0-9_\-]{20,}"#,                // GitLab
        #"\bAKIA[0-9A-Z]{16}\b"#,                       // AWS access key id
        #"\bAIza[0-9A-Za-z_\-]{35}\b"#,                 // Google API key
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,            // Slack
        #"\bhf_[A-Za-z0-9]{30,}"#,                      // Hugging Face
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func containsSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}
