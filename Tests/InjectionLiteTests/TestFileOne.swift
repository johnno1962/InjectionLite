
import Foundation

func topLevelValue() -> String {
    return "VALUE77547"
}

struct TestStruct {
    let c1 = TestSuperClass(t: 77)
    let c2 = TestSuperClass(t: 88.5)
    let c3 = TestSuperClass(t: "__")
    static func staticValue() -> String {
        return "VALUE77547"
    }
    func value() -> String {
        return "VALUE77547"
    }
}

class TestSuperClass<T>: NSObject {
    var t: T
    init(t: T) {
        self.t = t
    }
    func fileOnePath() -> String {
        return #file
    }
    static func staticValue() -> String {
        return "VALUE77547"
    }
    class func classSuperValue() -> String {
        return "VALUE77547"
    }
    func superValue() -> String {
        return "VALUE77547"
    }

    @objc func injected() {
        InjectionLiteTests.checks.remove("VALUE77547-\(t)")
    }
}
