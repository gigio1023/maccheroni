public enum PrivacyBoundText {
    public static let redactedPathMarker = "<redacted-path>"

    /// Redacts local absolute, file-URL, and home-relative paths embedded in diagnostics.
    public static func redactingFilePaths(in text: String) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard let pathContentStart = pathContentStart(in: text, at: index) else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }
            output += redactedPathMarker
            let quotedTerminator = quotedTerminator(in: text, before: index)
            var pathEnd = pathContentStart
            while pathEnd < text.endIndex {
                let character = text[pathEnd]
                if let quotedTerminator {
                    if character == quotedTerminator { break }
                } else if character.isWhitespace {
                    break
                }
                pathEnd = text.index(after: pathEnd)
            }
            if quotedTerminator == nil {
                var punctuationStart = pathEnd
                while punctuationStart > pathContentStart {
                    let previous = text.index(before: punctuationStart)
                    guard safeTrailingPunctuation.contains(text[previous]) else { break }
                    punctuationStart = previous
                }
                output += text[punctuationStart..<pathEnd]
            }
            index = pathEnd
        }
        return output
    }

    private static func pathContentStart(
        in text: String,
        at index: String.Index
    ) -> String.Index? {
        guard isPathBoundary(in: text, before: index),
              !isInsideRemoteURL(in: text, before: index) else {
            return nil
        }
        let suffix = text[index...]
        if suffix.hasPrefix("file:///") {
            return text.index(index, offsetBy: 8)
        }
        if suffix.hasPrefix("~/") {
            return text.index(index, offsetBy: 2)
        }
        guard text[index] == "/" else { return nil }
        let next = text.index(after: index)
        if next < text.endIndex,
           text[next] == "/",
           index > text.startIndex,
           text[text.index(before: index)] == ":" {
            return nil
        }
        return next
    }

    private static func isPathBoundary(
        in text: String,
        before index: String.Index
    ) -> Bool {
        guard index != text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return previous.isWhitespace
            || (!previous.isLetter
                && !previous.isNumber
                && !pathContinuationCharacters.contains(previous))
    }

    private static func isInsideRemoteURL(
        in text: String,
        before index: String.Index
    ) -> Bool {
        var tokenStart = index
        while tokenStart > text.startIndex {
            let previous = text.index(before: tokenStart)
            guard !text[previous].isWhitespace,
                  !remoteValueSeparators.contains(text[previous]) else {
                break
            }
            tokenStart = previous
        }
        let prefix = text[tokenStart..<index].lowercased()
        return prefix.contains("://") && !prefix.contains("file:///")
    }

    private static func quotedTerminator(
        in text: String,
        before index: String.Index
    ) -> Character? {
        guard index > text.startIndex else { return nil }
        let previous = text[text.index(before: index)]
        return previous == "\"" || previous == "'" ? previous : nil
    }

    private static let pathContinuationCharacters = Set<Character>("._-/~%")
    private static let remoteValueSeparators = Set<Character>(",;|{}[]()<>\"'")
    private static let safeTrailingPunctuation = Set<Character>(",;)}]>")
}
