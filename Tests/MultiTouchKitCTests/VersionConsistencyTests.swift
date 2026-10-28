import CMultiTouchKit
import Foundation
import MultiTouchKit
import Testing

/// 版本號分散在多個檔案：改了其中一個卻忘了其他的，Unity 會載入不相符的外掛（見 MultiTouchKitNative.IsAvailable）
@Suite struct VersionConsistencyTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let unityPackage = root.appendingPathComponent("Unity/com.xdxd-lab.multitouchkit")

    @Test func unityPackageVersionMatchesLibrary() throws {
        let data = try Data(contentsOf: Self.unityPackage.appendingPathComponent("package.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? String == MultiTouchKitVersion.string)
    }

    @Test func csharpApiVersionMatchesHeader() throws {
        let source = try String(contentsOf: Self.unityPackage.appendingPathComponent("Runtime/MultiTouchKitNative.cs"), encoding: .utf8)
        let line = try #require(source.split(separator: "\n").first { $0.contains("ExpectedApiVersion =") })
        let value = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ";")))
        #expect(value.flatMap { Int32($0) } == MTK_API_VERSION)
    }
}
