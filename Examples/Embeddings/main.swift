import Foundation
import Mojentic

/// Embed three sentences via OpenAI and print pairwise cosine similarities.
@main
struct Embeddings {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let gateway = OpenAIEmbeddingsGateway(apiKey: key)
        let sentences = [
            "The cat sat on the mat.",
            "A feline rested on the rug.",
            "Quantum mechanics describes nature at the smallest scales.",
        ]
        do {
            let vectors = try await gateway.embed(
                texts: sentences,
                model: "text-embedding-3-small"
            )
            print("similarity(0, 1) = \(cosine(vectors[0], vectors[1]))")
            print("similarity(0, 2) = \(cosine(vectors[0], vectors[2]))")
            print("similarity(1, 2) = \(cosine(vectors[1], vectors[2]))")
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }

    static func cosine(_ first: [Float], _ second: [Float]) -> Float {
        let length = min(first.count, second.count)
        var dot: Float = 0
        var firstNorm: Float = 0
        var secondNorm: Float = 0
        for index in 0..<length {
            dot += first[index] * second[index]
            firstNorm += first[index] * first[index]
            secondNorm += second[index] * second[index]
        }
        guard firstNorm > 0 && secondNorm > 0 else { return 0 }
        return dot / (firstNorm.squareRoot() * secondNorm.squareRoot())
    }
}
