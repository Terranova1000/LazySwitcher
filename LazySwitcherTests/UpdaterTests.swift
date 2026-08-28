import XCTest
@testable import Lazy_Switcher

/// The one control that makes automatic updating defensible.
///
/// Everything else about the updater is plumbing. This is the part that decides
/// whether a program with Accessibility permission may replace its own binary:
/// the download has to satisfy the designated requirement of the **running**
/// application — same identifier, same certificate. The private key for that
/// certificate exists in one keychain and is published nowhere, so a release
/// swapped on GitHub, a hijacked domain or an intercepted connection all fail
/// here rather than at the user's expense.
///
/// If these tests ever stop passing, automatic updating has to be turned off,
/// not debugged around.
final class UpdaterSignatureTests: XCTestCase {

    /// We satisfy our own requirement. Trivially true and worth pinning: a
    /// verification that rejects everything is as broken as one that accepts
    /// everything, and looks safer.
    func testOurOwnBundlePasses() {
        let problem = Updater.signatureProblem(of: Bundle.main.bundleURL)
        XCTAssertNil(problem, "Собственный бандл обязан проходить проверку: \(problem ?? "")")
    }

    /// An Apple-signed application is signed perfectly well — and is not us.
    /// A check that only asked "is the signature valid" would accept this.
    func testAValidlySignedButDifferentApplicationIsRejected() throws {
        let candidates = ["/System/Applications/TextEdit.app",
                          "/System/Applications/Calculator.app",
                          "/System/Applications/Chess.app"]
        guard let other = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        else { throw XCTSkip("Не нашлось системного приложения для проверки") }

        let problem = Updater.signatureProblem(of: URL(fileURLWithPath: other))
        XCTAssertNotNil(problem,
                        "Чужое приложение с исправной подписью Apple обязано быть отвергнуто — "
                      + "иначе проверяется валидность подписи, а не то, наша ли она")
    }

    /// Something with no signature at all.
    func testUnsignedDirectoryIsRejected() throws {
        let fake = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotAnApp-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fake) }
        XCTAssertNotNil(Updater.signatureProblem(of: fake))
    }

    func testMissingPathIsRejected() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).app")
        XCTAssertNotNil(Updater.signatureProblem(of: missing))
    }

    /// Updating in place has to write where we live. Anywhere else and we would
    /// be installing over something that is not the app the user runs — a copy
    /// in Downloads, or a translocated read-only mount.
    func testUpdatingIsRefusedOutsideApplications() {
        // The test host runs from DerivedData, which is exactly such a place.
        let expectation = expectation(description: "отказ")
        Updater.downloadAndInstall(progress: { _ in }) { result in
            if case .failure(.notInApplications) = result {
                expectation.fulfill()
            } else {
                XCTFail("Ожидали отказ из-за пути, получили \(result)")
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 5)
    }
}
