import Foundation
import Testing

@testable import Mojentic

@Suite("AskUser + TellUser via ScriptedIOGateway")
struct AskTellUserToolTests {
    @Test("AskUserTool returns the next scripted answer")
    func askReturnsAnswer() async throws {
        let io = ScriptedIOGateway(answers: ["Alice"])
        let tool = AskUserTool(io: io)
        let result = try await tool.execute(arguments: ["question": "Name?"])
        #expect(result.objectValue?["answer"]?.stringValue == "Alice")
        let prompts = await io.recordedPrompts()
        #expect(prompts.first?.contains("Name?") == true)
    }

    @Test("TellUserTool records the surfaced message")
    func tellRecordsMessage() async throws {
        let io = ScriptedIOGateway()
        let tool = TellUserTool(io: io)
        let result = try await tool.execute(arguments: ["message": "hello"])
        #expect(result.objectValue?["delivered"] == .bool(true))
        let recorded = await io.recordedOutput()
        #expect(recorded == ["hello"])
    }
}
