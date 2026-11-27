import Foundation
import Testing
@testable import Clipsie

struct DecoderTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func jwtShowsHeaderPayloadAndExpiry() throws {
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIiwiZXhwIjoxMDAwMDAwMDAwfQ.c2lnbmF0dXJl"
        let section = try #require(Decoders.sections(for: token, now: Date(timeIntervalSince1970: 2_000_000_000)).first)
        #expect(section.title.hasPrefix("JWT · "))
        #expect(section.body.contains("\"alg\""))
        #expect(section.body.contains("\"sub\""))
    }

    @Test func unixTimestampsInSecondsAndMilliseconds() {
        #expect(Decoders.sections(for: " 1700000000\n", timeZone: utc).first?.body == "2023-11-14T22:13:20Z\n2023-11-14T22:13:20Z")
        #expect(Decoders.sections(for: "1700000000123", timeZone: utc).first?.body == "2023-11-14T22:13:20.123Z\n2023-11-14T22:13:20.123Z")
    }

    @Test func numbersThatAreNotTimestampsAreLeftAlone() {
        #expect(Decoders.sections(for: "123456").isEmpty)
        #expect(Decoders.sections(for: "0712345678").isEmpty)
    }

    @Test func urlParametersAreListed() {
        #expect(Decoders.sections(for: "https://x.com/a?q=hello%20world&b=2").first?.body == "q = hello world\nb = 2")
        #expect(Decoders.sections(for: "https://x.com/a").isEmpty)
    }

    @Test func base64OnlyWhenItDecodesToText() {
        #expect(Decoders.sections(for: "aGVsbG8gd29ybGQ=").first?.body == "hello world")
        #expect(Decoders.sections(for: "abcdefghijkl").isEmpty)
        #expect(Decoders.sections(for: "Thisisateststring").isEmpty)
    }

    @Test func textWithSpacesIsNotDecoded() {
        #expect(Decoders.sections(for: "hello 1700000000").isEmpty)
    }
}

struct LineDiffTests {
    private func render(_ lines: [LineDiff.Line]) -> [String] {
        lines.map { line in
            switch line.kind {
            case .same: return "  " + line.text
            case .removed: return "- " + line.text
            case .added: return "+ " + line.text
            }
        }
    }

    @Test func changedLineIsShownAsRemovedThenAdded() {
        #expect(render(LineDiff.lines(from: "a\nb\nc", to: "a\nx\nc")) == ["  a", "- b", "+ x", "  c"])
    }

    @Test func insertionsDeletionsAndIdenticalTexts() {
        #expect(render(LineDiff.lines(from: "a\nc", to: "a\nb\nc")) == ["  a", "+ b", "  c"])
        #expect(render(LineDiff.lines(from: "a\nb", to: "b")) == ["- a", "  b"])
        #expect(LineDiff.lines(from: "same\ntext", to: "same\ntext").allSatisfy { $0.kind == .same })
    }
}
