//
//  MarkdownStripperTests.swift
//  AstrologieTests
//
//  The display-side backstop for markdown in replies (Week 9 Task 7): headings,
//  bold, italics and bullets come out, a lone or in-word `*` / `_` stays, a marker
//  split across stream chunks is still caught, plain prose passes through
//  untouched, and `message.text` stays raw.
//

import Testing

@testable import Astrologie

struct MarkdownStripperTests {

    // MARK: - Headings

    @Test(arguments: [
        ("# Saturn", "Saturn"),
        ("## Saturn in Pisces", "Saturn in Pisces"),
        ("###### Deepest", "Deepest"),
        ("  ### Indented", "Indented"),
        ("##", ""),
    ])
    func headingMarkersAtTheStartOfALineAreRemoved(input: String, expected: String) {
        #expect(MarkdownStripper.plainText(input) == expected)
    }

    @Test func headingsAreStrippedOnEveryLine() {
        let input = """
            ## Your Saturn Return
            Saturn moves into Pisces.

            ### What it means
            A time of consolidation.
            """
        let expected = """
            Your Saturn Return
            Saturn moves into Pisces.

            What it means
            A time of consolidation.
            """

        #expect(MarkdownStripper.plainText(input) == expected)
    }

    /// Only a real heading marker goes. A `#` mid-line, or one not followed by a
    /// space, is content.
    @Test(arguments: ["#1 priority", "Your #1 house", "C# and F#", "####### seven"])
    func hashesThatAreNotHeadingMarkersAreKept(input: String) {
        #expect(MarkdownStripper.plainText(input) == input)
    }

    // MARK: - Emphasis

    @Test(arguments: [
        ("**Saturn** is strong", "Saturn is strong"),
        ("Saturn is __strong__ here", "Saturn is strong here"),
        ("## **Saturn Return**", "Saturn Return"),
        ("*__*", ""),
    ])
    func emphasisMarkersAreRemoved(input: String, expected: String) {
        #expect(MarkdownStripper.plainText(input) == expected)
    }

    // MARK: - Single emphasis

    @Test(arguments: [
        ("*Saturn* rules", "Saturn rules"),
        ("_Saturn_ rules", "Saturn rules"),
        ("a *slow transit* here", "a slow transit here"),
        ("***both***", "both"),
    ])
    func pairedSingleEmphasisIsRemoved(input: String, expected: String) {
        #expect(MarkdownStripper.plainText(input) == expected)
    }

    /// A `*` or `_` inside a word, next to a space, or without a partner is
    /// content, not emphasis.
    @Test(arguments: ["snake_case_name", "2*3*4", "5 * 3", "*unpaired", "Saturn*", "file_"])
    func loneOrInWordMarkersAreKept(input: String) {
        #expect(MarkdownStripper.plainText(input) == input)
    }

    // MARK: - Bullets

    @Test(arguments: [
        ("* Saturn", "Saturn"),
        ("- Saturn", "Saturn"),
        ("+ Saturn", "Saturn"),
        ("  - Indented", "Indented"),
        ("* **Saturn**: strong", "Saturn: strong"),
    ])
    func bulletMarkersAreRemovedAndTheTextKept(input: String, expected: String) {
        #expect(MarkdownStripper.plainText(input) == expected)
    }

    @Test func bulletsAreStrippedOnEveryLine() {
        let input = """
            Three themes:
            - Discipline
            * Rest
            + Patience
            """

        #expect(MarkdownStripper.plainText(input) == "Three themes:\nDiscipline\nRest\nPatience")
    }

    /// A dash that isn't followed by a space isn't a bullet.
    @Test func aLeadingMinusSignIsKept() {
        #expect(MarkdownStripper.plainText("-5° in Pisces") == "-5° in Pisces")
    }

    // MARK: - Streaming

    /// A `**` split across two chunks is only a pair once the chunks are joined,
    /// which is why the stripper runs on the whole accumulated text.
    @Test func aMarkerSplitAcrossChunksIsCaughtOnTheAccumulatedText() {
        let chunks = ["## Sat", "urn\nThis is *", "*important*", "* for you."]

        var accumulated = ""
        for chunk in chunks { accumulated += chunk }

        #expect(MarkdownStripper.plainText(accumulated) == "Saturn\nThis is important for you.")
    }

    @Test func singleEmphasisSplitAcrossChunksIsCaught() {
        let chunks = ["This is _imp", "ortant_ now."]

        #expect(MarkdownStripper.plainText(chunks.joined()) == "This is important now.")
    }

    // MARK: - Pass-through

    @Test func textWithNoMarkdownPassesThroughUnchanged() {
        let text = """
            Saturn's return into Pisces asks you to finish what you started.
            Rest when you can; it's a long transit, not a sprint.
            """

        #expect(MarkdownStripper.plainText(text) == text)
        #expect(MarkdownStripper.plainText("") == "")
    }

    // MARK: - Bubble wiring

    @Test func theBubbleDisplaysStrippedTextButLeavesTheMessageRaw() {
        let raw = "## Saturn\n**Big** year."
        let message = ChatMessage.assistant(raw)

        #expect(ChatBubble.displayText(for: message) == "Saturn\nBig year.")
        #expect(message.text == raw)
    }

    @Test func voiceOverReadsTheStrippedText() {
        let label = ChatBubble.accessibilityLabel(for: .assistant("**Saturn** returns."))

        #expect(label == "Astrologer said: Saturn returns.")
    }

    @Test func theUsersOwnMessageIsShownAsTyped() {
        let message = ChatMessage.user("What does **this** mean? #curious")

        #expect(ChatBubble.displayText(for: message) == message.text)
    }
}
