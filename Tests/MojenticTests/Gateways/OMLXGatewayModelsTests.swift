import Foundation
@testable import Mojentic
import Testing

@Suite("oMLX gateway models")
struct OMLXModelsTests {
    @Test("available models are the sorted data ids of GET /v1/models")
    func availableModels() async throws {
        let listing = #"{"object":"list","data":[{"id":"b-model"},{"id":"a-model"}]}"#
        let transport = FakeRequestTransport(.success(Data(listing.utf8)))
        let models = try await omlxGateway(transport).availableModels()
        #expect(models == ["a-model", "b-model"])
        let request = try await transport.onlyRequest()
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "http://localhost:8000/v1/models")
        #expect(request.body == nil)
    }

    @Test("the models fixture lists the served model")
    func modelsFixture() async throws {
        let transport = try FakeRequestTransport(.fixture("models.json"))
        #expect(try await omlxGateway(transport).availableModels() == [omlxFixtureModel])
    }

    @Test("load posts to /v1/models/{id}/load with the configured timeout")
    func load() async throws {
        let transport = try FakeRequestTransport(.fixture("model_load.json"))
        let gateway = omlxGateway(transport, configuration: OMLXConfiguration(timeout: 1200))
        try await gateway.loadModel(omlxFixtureModel)
        let request = try await transport.onlyRequest()
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://localhost:8000/v1/models/\(omlxFixtureModel)/load")
        #expect(request.timeout == 1200)
    }

    @Test("unload posts to /v1/models/{id}/unload")
    func unload() async throws {
        let transport = try FakeRequestTransport(.fixture("model_unload.json"))
        try await omlxGateway(transport).unloadModel(omlxFixtureModel)
        let request = try await transport.onlyRequest()
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://localhost:8000/v1/models/\(omlxFixtureModel)/unload")
    }

    @Test("the model id is percent-encoded as one path segment")
    func encodedModelID() async throws {
        let transport = try FakeRequestTransport(.fixture("model_load.json"))
        try await omlxGateway(transport).loadModel("mlx-community/Qwen 3?")
        let request = try await transport.onlyRequest()
        #expect(
            request.url.absoluteString == "http://localhost:8000/v1/models/mlx-community%2FQwen%203%3F/load"
        )
    }

    @Test("unloading a model that is not loaded is a provider error")
    func unloadNotLoaded() async throws {
        let transport = try FakeRequestTransport(.fixture("error_model_not_loaded.json", status: 400))
        let failure = await httpFailure { try await omlxGateway(transport).unloadModel(omlxFixtureModel) }
        #expect(failure?.status == 400)
        #expect(failure?.body.contains("invalid_request_error") == true)
    }

    @Test("a blank model id is rejected before any request", arguments: ["", " ", "\n\t"])
    func emptyModelID(
        _ model: String
    ) async throws {
        let transport = FakeRequestTransport()
        await #expect(throws: MojenticError.self) { try await omlxGateway(transport).loadModel(model) }
        await #expect(throws: MojenticError.self) { try await omlxGateway(transport).unloadModel(model) }
        #expect(await transport.recorder.requests.isEmpty)
    }
}

@Suite("oMLX gateway embeddings")
struct OMLXEmbeddingsTests {
    private let embedding =
        #"""
        {"object":"list","data":[{"object":"embedding","index":0,"embedding":[\#
        0.5,-0.25]}]}
        """#

    @Test("one request per text with model and input, returning data[0].embedding")
    func requestShape()
        async throws
    {
        let transport = FakeRequestTransport(.success(Data(embedding.utf8)))
        let vector = try await omlxGateway(transport).embed(text: "hello", model: "bge-small")
        #expect(vector == [0.5, -0.25])
        let request = try await transport.onlyRequest()
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://localhost:8000/v1/embeddings")
        #expect(request.body == ["model": "bge-small", "input": "hello"])
    }

    @Test("each text is embedded with its own request, in order")
    func severalTexts() async throws {
        let transport = FakeRequestTransport(.success(Data(embedding.utf8)))
        let vectors = try await omlxGateway(transport).embed(texts: ["a", "b"], model: "bge-small")
        #expect(vectors == [[0.5, -0.25], [0.5, -0.25]])
        let inputs = await transport.recorder.requests.map { $0.body?.objectValue?["input"] }
        #expect(inputs == ["a", "b"])
    }

    @Test("a missing model is an argument error before any request", arguments: ["", "  ", "\n"])
    func missingModel(model: String) async throws {
        let transport = FakeRequestTransport(.success(Data(embedding.utf8)))
        let gateway = omlxGateway(transport)
        await #expect { _ = try await gateway.embed(text: "hello", model: model) } throws: { error in
            guard case MojenticError.invalidArgument = error else { return false }
            return true
        }
        #expect(await transport.recorder.requests.isEmpty)
    }

    @Test("a chat model is a provider error")
    func notAnEmbeddingModel() async throws {
        let transport = try FakeRequestTransport(.fixture("error_not_embedding_model.json", status: 400))
        let failure = await httpFailure {
            _ = try await omlxGateway(transport).embed(text: "hello", model: omlxFixtureModel)
        }
        #expect(failure?.status == 400)
        #expect(failure?.body.contains("is not an embedding model") == true)
    }
}
