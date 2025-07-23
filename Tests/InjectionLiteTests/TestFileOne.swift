
import Foundation

func topLevelValue() -> String {
    return "VALUE23472"
}

struct TestStruct {
    let c1 = GenericSuper(t: 77)
    let c2 = GenericSuper(t: 88.5)
    let c3 = GenericSuper(t: "__")
    static func staticValue() -> String {
        return "VALUE23472"
    }
    func value() -> String {
        return "VALUE23472"
    }
}

class TestSuper<T> {
    func fileOnePath() -> String {
        return #filePath
    }
    static func staticBaseValue() -> String {
        return "VALUE23472"
    }
    class func classBaseValue() -> String {
        return "VALUE23472"
    }
    func baseValue() -> String {
        return "VALUE23472"
    }
}

class GenericSuper<T>: TestSuper<T> {
    var t: T
    init(t: T) {
        self.t = t
    }
    static func staticValue() -> String {
        return "VALUE23472"
    }
    class func classSuperValue() -> String {
        return "VALUE23472"
    }
    func superValue() -> String {
        return "VALUE23472"
    }

    @objc func injected() {
        InjectionLiteTests.checks.remove("VALUE23472-\(t)")
    }
}
