import Foundation
import Mojentic

@main
struct ListModels {
    static func main() async {
        let gateway = OllamaGateway()
        do {
            let models = try await gateway.availableModels()
            if models.isEmpty {
                print("No models installed. Try `ollama pull llama3.2`.")
                return
            }
            for model in models {
                print(model)
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
