import Foundation
import Testing
@testable import Antarium

/// The catalog decides the order agents appear in, because the registry is
/// built from it and the menu bar is built from the registry. It is assembled
/// by iterating a dictionary, so the sort is what stops items moving between
/// launches — the sixth instance of that shape found this week.
@Suite("The harness catalog is ordered and says what went wrong", .serialized)
struct HarnessCatalogOrderTests {

    private func folder(_ files: [(name: String, id: String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let object: [String: Any] = [
                "formatVersion": 1, "id": file.id, "name": file.id.capitalized,
                "process": [:], "source": ["kind": "none", "path": ""]]
            try JSONSerialization.data(withJSONObject: object)
                .write(to: root.appendingPathComponent("\(file.name).json"))
        }
        return root
    }

    @Test("Descriptors come back in id order, whatever order the files are read in")
    func orderedByID() throws {
        let root = try folder([("zeta", "zeta"), ("alpha", "alpha"),
                               ("mid", "mid"), ("beta", "beta")])
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = HarnessCatalog(directory: root)
        let ids = catalog.snapshot().enabled.map(\.id)
        #expect(ids == ["alpha", "beta", "mid", "zeta"])
    }

    @Test("Two catalogs over the same folder agree")
    func repeatable() throws {
        let root = try folder((0..<8).map { (name: "f\($0)", id: "agent-\($0)") })
        defer { try? FileManager.default.removeItem(at: root) }
        let first = HarnessCatalog(directory: root).snapshot().enabled.map(\.id)
        let again = HarnessCatalog(directory: root).snapshot().enabled.map(\.id)
        #expect(first == again)
        #expect(first == first.sorted(), "the catalog came back in dictionary order")
    }

    /// Two files claiming one id is ambiguous, and the catalog says so rather
    /// than picking one — whichever it picked would depend on read order.
    @Test("Two files claiming one id are reported, not silently merged")
    func duplicateIsReported() throws {
        let root = try folder([("one", "shared"), ("two", "shared"), ("other", "unique")])
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = HarnessCatalog(directory: root)
        let snapshot = catalog.snapshot()
        #expect(snapshot.enabled.map(\.id) == ["unique"],
                "an ambiguous id was resolved by read order")
        #expect(catalog.issues.contains { $0.contains("same ID") })
    }

    /// The same complaint from several files is one complaint. A list
    /// repeating itself reads as several different problems.
    @Test("Repeated problems are reported once")
    func problemsAreDeduplicated() throws {
        let root = try folder([("one", "shared"), ("two", "shared"),
                               ("three", "also"), ("four", "also")])
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = HarnessCatalog(directory: root)
        // `issues` reports what the last load found and does not trigger one,
        // so the snapshot has to be taken first. The app does this already —
        // it reads the descriptors before it reads the complaints.
        _ = catalog.snapshot()
        let issues = catalog.issues
        let sameID = issues.filter { $0.contains("same ID") }
        #expect(sameID.count == 1, "one problem was reported \(sameID.count) times")
    }

    @Test("Issues come back in a stable order too")
    func issuesAreOrdered() throws {
        let root = try folder([("one", "shared"), ("two", "shared")])
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = HarnessCatalog(directory: root)
        _ = catalog.snapshot()
        #expect(catalog.issues == catalog.issues.sorted())
    }
}
