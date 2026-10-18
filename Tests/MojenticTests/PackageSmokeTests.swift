@testable import Mojentic
import Testing

@Suite("Package smoke tests")
struct PackageSmokeTests {
    @Test("Module loads and exposes a version string")
    func versionIsExposed() {
        #expect(Mojentic.version == "3.0.0")
    }
}
