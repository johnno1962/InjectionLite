
import Foundation

class TestSubClass: TestSuperClass<Int> {
    func fileTwoPath() -> String {
        return #file
    }
    class func classValue() -> String {
        return "VALUE775470"
    }
    func value() -> String {
        return "VALUE775470"
    }
}
