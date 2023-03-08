
import Foundation

func topLevelValue() -> String {
    return "VALUE47656"
}

struct TestStruct {
    let c1 = TestSuperClass(t: 77)
    let c2 = TestSuperClass(t: 88.5)
    let c3 = TestSuperClass(t: "__")
    static func staticValue() -> String {
        return "VALUE47656"
    }
    func value() -> String {
        return "VALUE47656"
    }
}

class TestSuperClass<T>: NSObject {
    var t: T
    init(t: T) {
        self.t = t
    }
    func fileOnePath() -> String {
        return #filePath
    }
    static func staticValue() -> String {
        return "VALUE47656"
    }
    class func classSuperValue() -> String {
        return "VALUE47656"
    }
    func superValue() -> String {
        return "VALUE47656"
    }

    @objc func injected() {
        InjectionLiteTests.checks.remove("VALUE47656-\(t)")
    }
}
