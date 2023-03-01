
func topLevelValue() -> String {
    return "VALUE25744"
}

struct TestStruct {
    static func staticValue() -> String {
        return "VALUE25744"
    }
    func value() -> String {
        return "VALUE25744"
    }
}

class TestSuperClass {
    func fileOnePath() -> String {
        return #file
    }
    static func staticValue() -> String {
        return "VALUE25744"
    }
    class func classSuperValue() -> String {
        return "VALUE25744"
    }
    func superValue() -> String {
        return "VALUE25744"
    }
}
