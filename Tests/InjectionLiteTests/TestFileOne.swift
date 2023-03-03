
import Foundation

func topLevelValue() -> String {
    return "VALUE82144"
}

struct TestStruct {
    let c1 = TestSuperClass(t: 77)
    let c2 = TestSuperClass(t: 88.5)
    let c3 = TestSuperClass(t: "__")
    static func staticValue() -> String {
        return "VALUE82144"
    }
    func value() -> String {
        return "VALUE82144"
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
        return "VALUE82144"
    }
    class func classSuperValue() -> String {
        return "VALUE82144"
    }
    func superValue() -> String {
        return "VALUE82144"
    }

    @objc func injected() {
        InjectionLiteTests.checks.remove("VALUE82144-\(t)")
    }
}
