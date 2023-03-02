import XCTest
@testable import InjectionLite

final class InjectionLiteTests: XCTestCase {

    static var shared: InjectionLiteTests!
    var expect: XCTestExpectation!
    let c = TestSubClass(t: 99)
    let s = TestStruct()
    static var value = "VALUE\(getpid())"
    static var checks = Set([77, 88.5, 99, "__"].map { value+"-\($0)" })

    override func setUp() {
        setenv("INJECTION_DETAIL", "1", 1)
        Self.shared = self
        flushInjection()

        NotificationCenter.default.addObserver(self,
           selector: #selector(injectionComplete),
            name: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"), object: nil)

        SwiftSweeper.seeds += [self]
    }

    func flushInjection() {
        let soon = Date(timeInterval: 2.0, since: Date())
        RunLoop.main.run(until: soon)
    }

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

    func injectionComplete() {
        expect?.fulfill()
        expect = nil
    }

    @objc func injected() {
        print("HERERRER")
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.

        let value = Self.value
        expect = expectation(description: "File1")
        patch(file: c.fileOnePath(), with: value)
        waitForExpectations(timeout: 10.0)
        XCTAssertEqual(topLevelValue(), value, "top level")
        XCTAssertEqual(TestStruct.staticValue(), value, "struct static")
        XCTAssertEqual(s.value(), value, "struct method")
        XCTAssertEqual(TestSuperClass<Int>.staticValue(), value, "class static")

        let value2 = value + "0"
        expect = expectation(description: "File2")
        patch(file: c.fileTwoPath(), with: value2)
        waitForExpectations(timeout: 10.0)
        XCTAssertEqual(c.value(), value2, "class method")
        XCTAssertEqual(c.superValue(), value, "inherited method")
        XCTAssertEqual(TestSubClass(t: 99).value(), value2, "instance method")
        XCTAssertEqual(TestSubClass.staticValue(), value, "subclass static")
        XCTAssertEqual(TestSubClass.classValue(), value2, "subclass class")
        XCTAssertEqual(TestSubClass.classSuperValue(), value, "subclass method")
        XCTAssertEqual(Self.checks, [], "sweeper")
    }
}
