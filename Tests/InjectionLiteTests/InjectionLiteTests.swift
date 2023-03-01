import XCTest
@testable import InjectionLite

final class InjectionLiteTests: XCTestCase {
    var expect: XCTestExpectation!

    func patch(file: String, with: String) {
        do {
            var text = try String(contentsOfFile: file)
            text = text
                .replacingOccurrences(of: #"VALUE\d+"#,
                  with: with, options: .regularExpression)
            try text.write(toFile: file,
                           atomically: true, encoding: .utf8)
        } catch {
            print(error)
        }
    }

    func flushInjection() {
        let soon = Date(timeInterval: 2.0, since: Date())
        RunLoop.main.run(until: soon)
    }

    func injectionComplete() {
        expect?.fulfill()
        expect = nil
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.

        setenv("INJECTION_DETAIL", "1", 1)

        flushInjection()

        NotificationCenter.default.addObserver(self,
            selector: #selector(injectionComplete),
            name: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"), object: nil)

        let s = TestStruct()
        let c = TestSubClass()

        let value = "VALUE\(getpid())"
        expect = expectation(description: "File1")
        Thread.sleep(forTimeInterval: 1.0)
        patch(file: c.fileOnePath(), with: value)
        waitForExpectations(timeout: 10.0)
        XCTAssertEqual(topLevelValue(), value, "OK")
        XCTAssertEqual(TestStruct.staticValue(), value, "OK")
        XCTAssertEqual(s.value(), value, "OK")
        XCTAssertEqual(TestSuperClass.staticValue(), value, "OK")
        XCTAssertEqual(TestSuperClass.classSuperValue(), value, "OK")

        expect = expectation(description: "File1")
        Thread.sleep(forTimeInterval: 1.0)
        patch(file: c.fileTwoPath(), with: value)
        waitForExpectations(timeout: 10.0)
        XCTAssertEqual(c.value(), value, "OK")
        XCTAssertEqual(c.superValue(), value, "OK")
    }
}
