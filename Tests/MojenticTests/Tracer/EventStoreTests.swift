import Foundation
import Testing

@testable import Mojentic

@Suite("EventStore")
struct EventStoreTests {
    @Test("records and returns events in insertion order")
    func ordering() async {
        let store = EventStore()
        let root = UUID()
        let first = TracerEvent.llmCall(
            LLMCallPayload(
                correlationId: root,
                parentId: nil,
                model: "test",
                messages: [],
                tools: nil
            )
        )
        let second = TracerEvent.llmResponse(
            LLMResponsePayload(
                correlationId: root,
                parentId: first.id,
                duration: .milliseconds(5),
                model: "test",
                response: LLMGatewayResponse(content: "ok")
            )
        )
        await store.record(first)
        await store.record(second)
        let events = await store.allEvents()
        #expect(events.count == 2)
        #expect(events[0].id == first.id)
        #expect(events[1].id == second.id)
    }

    @Test("predicate filter returns only matching events")
    func predicateFilter() async {
        let store = EventStore()
        let root = UUID()
        await store.record(
            .llmCall(
                LLMCallPayload(
                    correlationId: root,
                    parentId: nil,
                    model: "a",
                    messages: [],
                    tools: nil
                )
            )
        )
        await store.record(
            .llmCall(
                LLMCallPayload(
                    correlationId: root,
                    parentId: nil,
                    model: "b",
                    messages: [],
                    tools: nil
                )
            )
        )
        let aOnly = await store.events { event in
            if case .llmCall(let payload) = event { return payload.model == "a" }
            return false
        }
        #expect(aOnly.count == 1)
    }

    @Test("events(correlatedTo:) returns the full nested correlation tree")
    func correlatedRetrieval() async {
        let store = EventStore()
        let root = UUID()
        let other = UUID()
        let parent = TracerEvent.llmCall(
            LLMCallPayload(
                correlationId: root,
                parentId: nil,
                model: "parent",
                messages: [],
                tools: nil
            )
        )
        let child = TracerEvent.toolCall(
            ToolCallPayload(
                correlationId: root,
                parentId: parent.id,
                callId: "1",
                name: "echo",
                arguments: .object([:])
            )
        )
        // A grand-child whose own correlationId matches the root via parent chain.
        let grandchild = TracerEvent.llmCall(
            LLMCallPayload(
                correlationId: root,
                parentId: child.id,
                model: "nested",
                messages: [],
                tools: nil
            )
        )
        let unrelated = TracerEvent.llmCall(
            LLMCallPayload(
                correlationId: other,
                parentId: nil,
                model: "unrelated",
                messages: [],
                tools: nil
            )
        )
        await store.record(parent)
        await store.record(child)
        await store.record(grandchild)
        await store.record(unrelated)
        let tree = await store.events(correlatedTo: root)
        #expect(tree.count == 3)
        #expect(tree.contains { $0.id == parent.id })
        #expect(tree.contains { $0.id == child.id })
        #expect(tree.contains { $0.id == grandchild.id })
        #expect(!tree.contains { $0.id == unrelated.id })
    }

    @Test("response events carry the measured duration")
    func responseHasDuration() async {
        let store = EventStore()
        let root = UUID()
        let response = TracerEvent.llmResponse(
            LLMResponsePayload(
                correlationId: root,
                parentId: nil,
                duration: .milliseconds(42),
                model: "x",
                response: LLMGatewayResponse(content: "")
            )
        )
        await store.record(response)
        let events = await store.allEvents()
        #expect(events.first?.duration == .milliseconds(42))
    }
}
