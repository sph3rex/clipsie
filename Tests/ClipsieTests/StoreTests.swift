import Foundation
import Testing
@testable import Clipsie

final class StoreTests {
    private let folder: URL
    private let store: Store

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClipsieTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        store = try Store(url: folder.appendingPathComponent("history.sqlite"), key: key)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func add(_ text: String) throws -> Int64 {
        Thread.sleep(forTimeInterval: 0.01)
        return try #require(store.save(Capture(text: text, sourceApp: "com.example.app"), maxItems: 1_000))
    }

    private func list(_ query: String = "", in tab: HistoryTab = .history) -> [Int64] {
        store.ids(matching: query, in: tab)
    }

    @Test func searchFindsMatchingItemsNewestFirst() throws {
        let alpha = try add("alpha invoice")
        _ = try add("beta")
        let gamma = try add("gamma INVOICE")
        #expect(list("invoice") == [gamma, alpha])
        #expect(list("invoice gamma") == [gamma])
        #expect(list("nothing-like-this") == [])
    }

    @Test func copyingTheSameTextAgainMovesItToTheTop() throws {
        let first = try add("same")
        let other = try add("other")
        #expect(try add("same") == first)
        #expect(list() == [first, other])
        #expect(store.count() == 2)
    }

    @Test func tagsFilterAndTaggedList() throws {
        let a = try add("a")
        let b = try add("b")
        store.setTags(a, ["work"])
        Thread.sleep(forTimeInterval: 0.01)
        store.setTags(b, ["work", "home"])
        #expect(list("tag:work") == [b, a])
        #expect(list("tag:home") == [b])
        #expect(list(in: .tagged) == [b, a])
    }

    @Test func movingInHistory() throws {
        let a = try add("a")
        let b = try add("b")
        let c = try add("c")
        #expect(list() == [c, b, a])
        store.move(a, below: c, above: b, in: .history)
        #expect(list() == [c, a, b])
        store.move(c, below: b, above: nil, in: .history)
        #expect(list() == [a, b, c])
    }

    @Test func movingPinnedItemsChangesOnlyTheirOrder() throws {
        let a = try add("a")
        let b = try add("b")
        let c = try add("c")
        store.setPinned(a, true)
        store.setPinned(c, true)
        let pinned = Array(list().prefix(2))
        #expect(Set(pinned) == [a, c])
        store.move(pinned[1], below: nil, above: pinned[0], in: .history)
        #expect(list() == [pinned[1], pinned[0], b])
    }

    @Test func movingInTaggedList() throws {
        let a = try add("a")
        let b = try add("b")
        store.setTags(a, ["x"])
        Thread.sleep(forTimeInterval: 0.01)
        store.setTags(b, ["x"])
        #expect(list(in: .tagged) == [b, a])
        store.move(a, below: nil, above: b, in: .tagged)
        #expect(list(in: .tagged) == [a, b])
    }

    @Test func clearingKeepsItemsWithKeptTags() throws {
        let kept = try add("keep me")
        _ = try add("drop me")
        store.setTags(kept, [Store.importantTag])
        store.clearEverything(keepingTags: [Store.importantTag])
        #expect(list() == [kept])
        #expect(store.count() == 1)
    }
}
