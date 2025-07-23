
import Foundation

class TestSubClass: GenericSuper<Int> {
    func fileTwoPath() -> String {
        return #filePath
    }
    class func classValue() -> String {
        return "VALUE7600"
    }
    func value() -> String {
        return "VALUE7600"
    }
}

private class PrivateClass {
    @objc func injected() {}
}

class Foo<T> {}
