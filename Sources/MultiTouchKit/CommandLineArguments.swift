import Foundation

/// mtk-server／mtk-probe／mtk-viewer 共用的命令列解析：選項值缺少或格式錯誤、未知選項，一律印出原因與用法並以 exit 2 結束，
/// 不會默默沿用預設值（使用者以為設定生效，其實沒有）。
package struct CommandLineArguments {
    package let usage: String
    private var iterator: IndexingIterator<[String]>

    package init(_ arguments: [String] = Array(CommandLine.arguments.dropFirst()), usage: String) {
        self.usage = usage
        iterator = arguments.makeIterator()
    }

    /// 下一個選項；`--help`／`-h` 直接印出用法並以 exit 0 結束
    package mutating func next() -> String? {
        guard let option = iterator.next() else { return nil }
        if option == "--help" || option == "-h" {
            print(usage)
            exit(0)
        }
        return option
    }

    package func fail(_ message: String) -> Never {
        print(message)
        print(usage)
        exit(2)
    }

    package func unknown(_ option: String) -> Never {
        fail("未知選項：\(option)")
    }

    /// 選項的值（例如 `--csv PATH` 的 PATH）
    package mutating func value(for option: String, _ expectation: String) -> String {
        guard let value = iterator.next() else { fail("\(option) 需要\(expectation)") }
        return value
    }

    /// 數字選項；`range` 之外也視為格式錯誤
    package mutating func double(for option: String, _ expectation: String,
                                 in range: PartialRangeFrom<Double> = (-Double.infinity)...) -> Double {
        let text = value(for: option, expectation)
        guard let v = Double(text), v.isFinite, range.contains(v) else { fail("\(option) 需要\(expectation)（收到「\(text)」）") }
        return v
    }

    /// 大於 0 的數字
    package mutating func positive(for option: String, _ expectation: String) -> Double {
        let v = double(for: option, expectation, in: 0...)
        guard v > 0 else { fail("\(option) 需要\(expectation)（收到「\(v)」）") }
        return v
    }

    /// 整數，可寫成 16 進位（0x222A）
    package mutating func integer(for option: String, _ expectation: String) -> Int {
        let text = value(for: option, expectation)
        let parsed = text.lowercased().hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text)
        guard let parsed else { fail("\(option) 需要\(expectation)（收到「\(text)」）") }
        return parsed
    }

    /// `--display SEL`（格式見 DisplaySelector）
    package mutating func displaySelector(for option: String = "--display") -> DisplaySelector {
        let text = value(for: option, "顯示器條件")
        guard let selector = DisplaySelector(text) else { fail("\(option) 格式錯誤：\(text)") }
        return selector
    }

    /// `--stale-touch-timeout SEC`
    package mutating func staleTouchTimeout(for option: String = "--stale-touch-timeout") -> Double {
        double(for: option, " 0 以上的秒數", in: 0...)
    }
}
