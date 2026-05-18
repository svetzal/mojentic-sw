import Foundation
import Testing

@testable import Mojentic

@Suite("Multimodal LLMMessage")
struct MultimodalMessagesTests {
    @Test("user(text:images:) carries both content and image attachments")
    func userMultimodal() {
        let image = ImageContent(base64: "abc", mimeType: "image/png")
        let message = LLMMessage.user(text: "what is this?", images: [image])
        #expect(message.role == .user)
        #expect(message.content == "what is this?")
        #expect(message.images?.count == 1)
    }

    @Test("plain user composer leaves images nil")
    func userPlain() {
        let message = LLMMessage.user("hi")
        #expect(message.images == nil)
    }

    @Test("ImageContent round-trips a URL source via Codable")
    func imageURLRoundTrip() throws {
        guard let url = URL(string: "https://example.com/cat.png") else {
            Issue.record("URL literal failed")
            return
        }
        let image = ImageContent(url: url, detail: "high")
        let data = try JSONEncoder().encode(image)
        let decoded = try JSONDecoder().decode(ImageContent.self, from: data)
        #expect(decoded == image)
    }
}
