
import Foundation

class TestSubClass: GenericSuper<Int> {
    func fileTwoPath() -> String {
        return #filePath
    }
    class func classValue() -> String {
        return "VALUE234720"
    }
    func value() -> String {
        return "VALUE234720"
    }
}
