import Testing
@testable import Mojentic

@Suite("Package smoke tests")
struct MojenticTests {
    @Test("Module loads and exposes a version string")
    func versionIsExposed() {
        #expect(!Mojentic.version.isEmpty)
    }
}
