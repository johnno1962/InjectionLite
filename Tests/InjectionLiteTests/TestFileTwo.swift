
import Foundation

class TestSubClass: TestSuperClass<Int> {
    func fileTwoPath() -> String {
        return #filePath
    }
    class func classValue() -> String {
        return "VALUE476560"
    }
    func value() -> String {
        return "VALUE476560"
    }
}
