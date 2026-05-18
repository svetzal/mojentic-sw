import Testing

@testable import Mojentic

@Suite("Package smoke tests")
struct PackageSmokeTests {
    @Test("Module loads and exposes a version string")
    func versionIsExposed() {
        #expect(Mojentic.version == "1.4.0")
    }
}
