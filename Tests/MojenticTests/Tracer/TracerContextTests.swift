import Foundation
import Testing

@testable import Mojentic

@Suite("TracerContext")
struct TracerContextTests {
    @Test("default init creates a fresh root with no parent")
    func freshRoot() {
        let context = TracerContext()
        #expect(context.parentId == nil)
    }

    @Test("child(parent:) preserves the root correlationId and sets parentId")
    func childPreservesRoot() {
        let root = TracerContext()
        let eventId = UUID()
        let child = root.child(parent: eventId)
        #expect(child.correlationId == root.correlationId)
        #expect(child.parentId == eventId)
    }
}
