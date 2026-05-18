import Foundation
import Testing

@testable import Mojentic

@Suite("SharedWorkingMemory")
struct SharedWorkingMemoryTests {
    @Test("set + get + snapshot round-trip")
    func roundTrip() async {
        let memory = SharedWorkingMemory()
        await memory.set("name", to: .string("alice"))
        await memory.set("age", to: .integer(30))
        let snapshot = await memory.snapshot()
        #expect(snapshot["name"] == .string("alice"))
        #expect(snapshot["age"] == .integer(30))
    }

    @Test("scoped namespaces stay isolated from each other and from the global store")
    func namespaceIsolation() async {
        let memory = SharedWorkingMemory()
        let scopeOne = UUID()
        let scopeTwo = UUID()
        await memory.set("k", to: .string("global"))
        await memory.set("k", to: .string("one"), scope: scopeOne)
        await memory.set("k", to: .string("two"), scope: scopeTwo)
        #expect(await memory.get("k") == .string("global"))
        #expect(await memory.get("k", scope: scopeOne) == .string("one"))
        #expect(await memory.get("k", scope: scopeTwo) == .string("two"))
    }

    @Test("delete removes the key from the targeted namespace only")
    func deleteScoped() async {
        let memory = SharedWorkingMemory()
        let scope = UUID()
        await memory.set("k", to: .string("scoped"), scope: scope)
        await memory.set("k", to: .string("global"))
        #expect(await memory.delete("k", scope: scope))
        #expect(await memory.get("k", scope: scope) == nil)
        #expect(await memory.get("k") == .string("global"))
    }
}
