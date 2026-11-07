import Foundation

/// Decides whether a reply should be spoken, and what to say.
/// Spoken: answers to questions, questions back to the user, and problems.
/// Silent: plain "done" confirmations of actions (they're on screen already).
enum SpeechPolicy {
    static func line(reply: String, request: String, mode: SpokenReplies, fromVoice: Bool) -> String? {
        let (display, tagged) = SpeakTag.split(reply)
        let plain = plainText(display)
        switch mode {
        case .off:
            return nil
        case .always:
            return tagged ?? summary(plain)
        case .smart:
            // Typed requests stay quiet unless Claude explicitly marked something to say.
            guard fromVoice else { return tagged }
            // Claude writes a line meant for listening; use it when present.
            if let tagged { return tagged }
            // Fallback when Claude forgot: still answer questions out loud, briefly.
            if isQuestion(request) || plain.hasSuffix("?") || looksLikeProblem(plain) { return summary(plain, maxChars: 200) }
            return nil
        }
    }

    private static let questionStarts = [
        "what", "what's", "whats", "why", "how", "who", "whom", "whose", "when", "where", "which",
        "is ", "are ", "am i", "was ", "were ", "do ", "does ", "did ", "can you explain", "could you explain",
        "can you tell", "could you tell", "explain", "tell me", "describe", "define", "summarize", "summarise",
        "should i", "will ", "would ", "any idea",
        // Hindi / Hinglish
        "kya", "kyu", "kyun", "kaise", "kaun", "kab", "kahan", "kitna", "kitne", "batao", "bataiye", "samjhao", "samjhaiye",
        "क्या", "क्यों", "कैसे", "कौन", "कब", "कहाँ", "कितना", "बताओ", "समझाओ",
    ]

    static func isQuestion(_ request: String) -> Bool {
        let r = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if r.hasSuffix("?") { return true }
        return questionStarts.contains { r.hasPrefix($0) } || r.contains(" kya ") || r.hasSuffix(" kya")
            || r.contains("batao") || r.contains("explain")
    }

    private static func looksLikeProblem(_ t: String) -> Bool {
        let l = t.lowercased()
        return ["couldn't", "could not", "can't", "cannot", "failed", "permission", "not allowed", "didn't work"]
            .contains { l.contains($0) }
    }

    /// Markdown → speakable text.
    static func plainText(_ md: String) -> String {
        var s = md
        s = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*([-*•]|\d+\.)\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)          // inline code
        s = s.replacingOccurrences(of: #"\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b"#, with: "", options: .regularExpression) // IPs
        s = s.replacingOccurrences(of: #"(~|/)[\w.\-/]+"#, with: "", options: .regularExpression)    // file paths
        for token in ["**", "__", "#", "*", "_"] { s = s.replacingOccurrences(of: token, with: "") }
        s = s.replacingOccurrences(of: #"\s*\n+\s*"#, with: ". ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\.\s*\."#, with: ".", options: .regularExpression)
        s = s.replacingOccurrences(of: #":\."#, with: ":", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first few sentences, so long answers don't talk for minutes. The rest stays on screen.
    static func summary(_ plain: String, maxChars: Int = 320) -> String {
        guard plain.count > maxChars else { return plain }
        var out = ""
        plain.enumerateSubstrings(in: plain.startIndex..., options: .bySentences) { sub, _, _, stop in
            guard let sub else { return }
            if !out.isEmpty && out.count + sub.count > maxChars { stop = true; return }
            out += sub
        }
        return out.isEmpty ? String(plain.prefix(maxChars)) : out.trimmingCharacters(in: .whitespaces)
    }
}
