public enum PrivacyBoundText {
    public static let redactedPathMarker = "<redacted-path>"

    private struct QuoteDelimiter: Equatable {
        var character: Character
        var isEscaped: Bool
    }

    /// Redacts local absolute, file-URL, and home-relative paths embedded in diagnostics.
    public static func redactingFilePaths(in text: String) -> String {
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var quoteStack: [QuoteDelimiter] = []
        var index = 0

        while index < characters.count {
            if isFileURLStart(in: characters, at: index) {
                appendRedactedPath(
                    from: index,
                    in: characters,
                    quote: quoteStack.last,
                    to: &output,
                    advancing: &index
                )
                continue
            }

            if isRemoteURLStart(in: characters, at: index)
                || isUnambiguousNetworkReference(in: characters, at: index)
            {
                index = appendRemoteURL(
                    from: index,
                    in: characters,
                    quote: quoteStack.last,
                    to: &output
                )
                continue
            }

            if isHomePathStart(in: characters, at: index)
                || isWindowsPathStart(in: characters, at: index)
                || isPOSIXPathStart(in: characters, at: index)
            {
                appendRedactedPath(
                    from: index,
                    in: characters,
                    quote: quoteStack.last,
                    to: &output,
                    advancing: &index
                )
                continue
            }

            let character = characters[index]
            output.append(character)
            updateQuoteStack(
                for: character,
                at: index,
                in: characters,
                stack: &quoteStack
            )
            index += 1
        }
        return output
    }

    private static func appendRedactedPath(
        from start: Int,
        in characters: [Character],
        quote: QuoteDelimiter?,
        to output: inout String,
        advancing index: inout Int
    ) {
        output += redactedPathMarker
        let end = pathEnd(from: start, in: characters, quote: quote)
        if quote == nil {
            let punctuationStart = trailingPunctuationStart(
                after: start,
                before: end,
                in: characters
            )
            output.append(contentsOf: characters[punctuationStart..<end])
        }
        index = end
    }

    private static func appendRemoteURL(
        from start: Int,
        in characters: [Character],
        quote: QuoteDelimiter?,
        to output: inout String
    ) -> Int {
        let end = remoteURLEnd(from: start, in: characters, quote: quote)
        var index = start
        while index < end {
            if isFileURLStart(in: characters, at: index) {
                output += redactedPathMarker
                index = embeddedFileURLEnd(
                    from: index,
                    before: end,
                    in: characters
                )
            } else {
                output.append(characters[index])
                index += 1
            }
        }
        return end
    }

    private static func isFileURLStart(
        in characters: [Character],
        at index: Int
    ) -> Bool {
        isPathBoundary(in: characters, before: index)
            && hasASCIIPrefix("file:", in: characters, at: index)
    }

    private static func isRemoteURLStart(
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard isPathBoundary(in: characters, before: index),
              index < characters.count,
              characters[index].isASCII,
              characters[index].isLetter else {
            return false
        }
        var cursor = index + 1
        while cursor < characters.count,
              isURLSchemeContinuation(characters[cursor]) {
            cursor += 1
        }
        guard cursor + 2 < characters.count,
              characters[cursor] == ":",
              characters[cursor + 1] == "/",
              characters[cursor + 2] == "/" else {
            return false
        }
        let scheme = String(characters[index..<cursor]).lowercased()
        return scheme != "file"
    }

    private static func isUnambiguousNetworkReference(
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard isPathBoundary(in: characters, before: index),
              index + 2 < characters.count,
              characters[index] == "/",
              characters[index + 1] == "/" else {
            return false
        }
        var cursor = index + 2
        while cursor < characters.count,
              !characters[cursor].isWhitespace,
              !networkAuthorityTerminators.contains(characters[cursor]) {
            cursor += 1
        }
        let authority = String(characters[(index + 2)..<cursor]).lowercased()
        guard !authority.isEmpty else { return false }
        return authority == "localhost"
            || authority.contains(".")
            || authority.contains(":")
            || (authority.first == "[" && authority.last == "]")
    }

    private static func isHomePathStart(
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard isPathBoundary(in: characters, before: index),
              index < characters.count,
              characters[index] == "~" else {
            return false
        }
        var cursor = index + 1
        while cursor < characters.count,
              isHomeUserCharacter(characters[cursor]) {
            cursor += 1
        }
        return cursor < characters.count && characters[cursor] == "/"
    }

    private static func isPOSIXPathStart(
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard isPathBoundary(in: characters, before: index),
              index < characters.count,
              characters[index] == "/" else {
            return false
        }
        return true
    }

    private static func isWindowsPathStart(
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard isPathBoundary(in: characters, before: index),
              index + 2 < characters.count,
              characters[index].isASCII,
              characters[index].isLetter,
              characters[index + 1] == ":" else {
            return false
        }
        return characters[index + 2] == "/" || characters[index + 2] == "\\"
    }

    private static func pathEnd(
        from start: Int,
        in characters: [Character],
        quote: QuoteDelimiter?
    ) -> Int {
        var cursor = start
        while cursor < characters.count {
            if let quote {
                if quoteDelimiter(at: cursor, in: characters) == quote {
                    break
                }
            } else if characters[cursor].isWhitespace {
                break
            }
            cursor += 1
        }
        return cursor
    }

    private static func embeddedFileURLEnd(
        from start: Int,
        before limit: Int,
        in characters: [Character]
    ) -> Int {
        var cursor = start
        while cursor < limit,
              characters[cursor] != "&",
              characters[cursor] != "#" {
            cursor += 1
        }
        return cursor
    }

    private static func remoteURLEnd(
        from start: Int,
        in characters: [Character],
        quote: QuoteDelimiter?
    ) -> Int {
        var cursor = start
        while cursor < characters.count {
            if let quote {
                if quoteDelimiter(at: cursor, in: characters) == quote {
                    break
                }
            } else if characters[cursor].isWhitespace
                        || remoteValueSeparators.contains(characters[cursor]) {
                break
            }
            cursor += 1
        }
        return cursor
    }

    private static func trailingPunctuationStart(
        after start: Int,
        before end: Int,
        in characters: [Character]
    ) -> Int {
        var cursor = end
        while cursor > start,
              safeTrailingPunctuation.contains(characters[cursor - 1]) {
            cursor -= 1
        }
        return cursor
    }

    private static func isPathBoundary(
        in characters: [Character],
        before index: Int
    ) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        return previous.isWhitespace
            || (!previous.isLetter
                && !previous.isNumber
                && !pathContinuationCharacters.contains(previous))
    }

    private static func updateQuoteStack(
        for character: Character,
        at index: Int,
        in characters: [Character],
        stack: inout [QuoteDelimiter]
    ) {
        guard character == "\"" || character == "'",
              !isApostrophe(at: index, in: characters),
              let delimiter = quoteDelimiter(at: index, in: characters) else {
            return
        }
        if stack.last == delimiter {
            stack.removeLast()
        } else {
            stack.append(delimiter)
        }
    }

    private static func quoteDelimiter(
        at index: Int,
        in characters: [Character]
    ) -> QuoteDelimiter? {
        guard index < characters.count,
              characters[index] == "\"" || characters[index] == "'" else {
            return nil
        }
        var backslashCount = 0
        var cursor = index
        while cursor > 0, characters[cursor - 1] == "\\" {
            backslashCount += 1
            cursor -= 1
        }
        return QuoteDelimiter(
            character: characters[index],
            isEscaped: backslashCount.isMultiple(of: 2) == false
        )
    }

    private static func isApostrophe(
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        guard characters[index] == "'",
              index > 0,
              index + 1 < characters.count else {
            return false
        }
        return characters[index - 1].isLetter && characters[index + 1].isLetter
    }

    private static func hasASCIIPrefix(
        _ prefix: String,
        in characters: [Character],
        at index: Int
    ) -> Bool {
        let expected = Array(prefix)
        guard index + expected.count <= characters.count else { return false }
        for offset in expected.indices {
            guard String(characters[index + offset]).lowercased()
                    == String(expected[offset]) else {
                return false
            }
        }
        return true
    }

    private static func isURLSchemeContinuation(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter
                || character.isNumber
                || character == "+"
                || character == "-"
                || character == ".")
    }

    private static func isHomeUserCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || character == "."
            || character == "_"
            || character == "-"
    }

    private static let pathContinuationCharacters = Set<Character>("._-/~%\\")
    private static let networkAuthorityTerminators = Set<Character>("/?#;,|{}()<>\"'")
    private static let remoteValueSeparators = Set<Character>(",;|{}()<>\"'")
    private static let safeTrailingPunctuation = Set<Character>(".,;:!?)}]>")
}
