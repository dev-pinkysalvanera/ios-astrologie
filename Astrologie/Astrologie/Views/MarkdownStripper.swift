//
//  MarkdownStripper.swift
//  Astrologie
//
//  Display-side backstop for markdown the model wasn't supposed to write. The
//  system prompt asks for plain prose, but the model doesn't always comply, and
//  `Text(String)` shows markdown verbatim — raw `##` and `**` in the bubble, and
//  read aloud by VoiceOver. We chose plain text over rendering markdown (Week 9
//  Task 7), so this removes the markers rather than interpreting them.
//
//  Only the displayed text goes through here. `ChatMessage.text` stays exactly
//  what the model produced, so a report sends the original.
//

import Foundation

/// Removes heading, bullet and emphasis markers from text meant for display.
enum MarkdownStripper {

    /// The text with markdown markers removed.
    ///
    /// Meant to run on the whole accumulated message on every render, not per
    /// chunk: a `**` split across two stream chunks only exists as a pair once
    /// they've been joined.
    ///
    /// - Heading: 1–6 `#` at the start of a line (after optional indentation),
    ///   followed by whitespace or the end of the line. `#1` or `C#` is left
    ///   alone. A bare `##` at the end of the text counts, so a heading that has
    ///   only half-arrived doesn't flash its marker.
    /// - Bullet: `*`, `-` or `+` at the start of a line (after optional
    ///   indentation), followed by whitespace. The line's text is kept. `-5°` is
    ///   left alone.
    /// - Strong emphasis: every `**` and `__`, repeated until none remain, so
    ///   removing one pair can't leave another behind (`*__*`).
    /// - Single emphasis: a `*` or `_` pair around a word or phrase on one line
    ///   (`*Saturn*`, `_Saturn_`). A marker inside a word (`snake_case`, `2*3`),
    ///   one followed or preceded by a space (`a * b`), or an unpaired one stays.
    static func plainText(_ text: String) -> String {
        guard text.contains(where: { "#*_-+".contains($0) }) else {
            return text
        }

        var result = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(stripLineMarker)
            .joined(separator: "\n")

        while result.contains("**") || result.contains("__") {
            result = result
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
        }

        for pattern in singleEmphasis {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result, range: range, withTemplate: "$1")
        }
        return result
    }

    /// `*text*` and `_text_`: the opening marker isn't preceded by a word
    /// character and is followed by non-space; the closing marker mirrors it.
    /// The content can't span lines or contain the marker itself.
    ///
    /// `NSRegularExpression` rather than Swift `Regex`, which doesn't support
    /// the lookbehind this needs.
    private static let singleEmphasis: [NSRegularExpression] = ["\\*", "_"].map { m in
        // Force-try: the patterns are constants, so a failure is a programming
        // error caught by the first test run, not a runtime condition.
        try! NSRegularExpression(
            pattern: "(?<![\\w\(m)])\(m)(?=\\S)([^\(m)\\n]+?)(?<=\\S)\(m)(?![\\w\(m)])")
    }

    /// One line with a leading heading or bullet marker removed, if it has one.
    private static func stripLineMarker(_ line: Substring) -> Substring {
        let isIndent: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        let content = line.drop(while: isIndent)

        // Bullet: one marker character, then at least one space or tab.
        if let first = content.first, "*-+".contains(first),
            let next = content.dropFirst().first, isIndent(next)
        {
            return content.dropFirst().drop(while: isIndent)
        }

        // Heading: 1–6 `#`, then whitespace or the end of the line.
        let hashes = content.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return line }

        let afterHashes = content.dropFirst(hashes.count)
        if let next = afterHashes.first, !isIndent(next), next != "\r" {
            return line
        }
        return afterHashes.drop(while: isIndent)
    }
}
