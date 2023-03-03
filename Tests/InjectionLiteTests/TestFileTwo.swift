
import Foundation

class TestSubClass: TestSuperClass<Int> {
    func fileTwoPath() -> String {
        return #file
    }
    class func classValue() -> String {
        return "VALUE821440"
    }
    func value() -> String {
        return "VALUE821440"
    }
}
