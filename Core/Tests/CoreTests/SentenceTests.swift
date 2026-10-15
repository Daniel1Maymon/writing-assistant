import Foundation
import Testing
@testable import Core

@Suite struct SegmentTests {
    @Test func abbreviationDoesNotSplit() {
        let sentences = segment("Dr. Smith arrived. He sat down.")
        #expect(sentences.map(\.text) == ["Dr. Smith arrived.", "He sat down."])
    }

    @Test func egDoesNotSplit() {
        let sentences = segment("Use a tool, e.g. this one. Then stop.")
        #expect(sentences.map(\.text) == ["Use a tool, e.g. this one.", "Then stop."])
    }

    @Test func rangesExcludeWhitespaceAndSkipBlankLines() {
        let text = "  First one.  \n\nSecond one.\n"
        let ns = text as NSString
        let sentences = segment(text)
        #expect(sentences.map(\.text) == ["First one.", "Second one."])
        for sentence in sentences {
            #expect(ns.substring(with: sentence.range) == sentence.text)
        }
        #expect(sentences[0].range == NSRange(location: 2, length: 10))
    }

    @Test func hebrewAndEmojiUseUTF16Ranges() {
        let text = "שלום לכולם. 😀 זה עובד? Yes it does."
        let ns = text as NSString
        let sentences = segment(text)
        #expect(sentences.count == 3)
        for sentence in sentences {
            #expect(ns.substring(with: sentence.range) == sentence.text)
        }
        // The emoji is 2 UTF-16 units, so the last sentence starts 1 later than its Character offset.
        let last = sentences[2]
        #expect(last.range.location == ns.range(of: "Yes").location)
        #expect(last.range.location == text.distance(from: text.startIndex, to: text.range(of: "Yes")!.lowerBound) + 1)
    }

    @Test func noFinalPunctuationAndEmptyText() {
        #expect(segment("No punctuation at the end").map(\.text) == ["No punctuation at the end"])
        #expect(segment("").isEmpty)
        #expect(segment("   \n ").isEmpty)
    }
}

@Suite struct HashTests {
    @Test func sameTextSameHashDifferentTextDifferentHash() {
        #expect(Sentence.hash("I recieve mail.") == Sentence.hash("I recieve mail."))
        #expect(Sentence.hash("I recieve mail.") != Sentence.hash("I receive mail."))
    }

    @Test func hashIgnoresPosition() {
        let a = segment("One. Two.")[1]
        let b = segment("Something longer first. Two.")[1]
        #expect(a.range != b.range)
        #expect(a.hash == b.hash)
    }
}

@Suite struct DiffTests {
    @Test func editingOneOfThreeMarksOnlyThatOneDirty() {
        let before = segment("First one. Second one. Third one.")
        let after = segment("First one. Second won. Third one.")
        let result = diff(previous: before, next: after)
        #expect(result.dirty.map(\.text) == ["Second won."])
        #expect(result.kept.map(\.text) == ["First one.", "Third one."])
    }

    @Test func sameTextNothingDirtyAndMovedSentenceKept() {
        let before = segment("Alpha here. Beta here.")
        #expect(diff(previous: before, next: before).dirty.isEmpty)
        let moved = diff(previous: before, next: segment("Beta here. Alpha here."))
        #expect(moved.dirty.isEmpty)
        #expect(moved.kept.count == 2)
    }
}
