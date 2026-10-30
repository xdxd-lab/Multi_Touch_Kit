import Foundation

/// 觸控校正：把控制器回報的正規化座標（0...1）對應到使用者實際想按的位置。
///
/// 為什麼需要：觸控面板與 LCD 的對位、面板的線性度不完美。MF156LR 實測在 9 個校正點上仍有系統性的小偏差
/// （上列偏下、右上角偏向左下），且各角落方向不同，單純的縮放與平移修不掉。
///
/// 模型：每個軸各一個二次多項式 f(u, v) = c0 + c1·u + c2·v + c3·u² + c4·u·v + c5·v²（u、v 為以 0.5 為中心的原始座標）。
/// - 仿射（前 3 項）只能修縮放、平移、旋轉、歪斜，修不了角落各自不同的偏差。
/// - 網格插值會剛好穿過每個校正點，沒有冗餘，單次誤觸就會扭曲那一區。
/// - 二次多項式能吸收常見的對位非線性，9 點擬合 6 項仍有 3 個自由度可平均雜訊；點數不足 6 時退回仿射。
public struct TouchCalibration: Sendable, Equatable, Codable {
    /// 多項式的項數（rawValue 即 calibration.json 中的 `model`）
    public enum Model: String, Sendable, Codable {
        /// 3 項：c0 + c1·u + c2·v
        case affine
        /// 6 項：仿射再加 u²、u·v、v²
        case quadratic
    }

    /// 使用的模型；決定 `x`、`y` 應有的係數數量
    public var model: Model
    /// 輸出 x 的係數（仿射 3 項、二次 6 項，順序見型別說明）
    public var x: [Double]
    /// 輸出 y 的係數（同 `x`）
    public var y: [Double]

    /// 係數數量與 `model` 不符的軸在套用時不校正（見 `apply(x:y:)`）
    public init(model: Model, x: [Double], y: [Double]) {
        self.model = model
        self.x = x
        self.y = y
    }

    /// 不做任何改變的校正
    public static let identity = TouchCalibration(model: .affine, x: [0.5, 1, 0], y: [0.5, 0, 1])

    /// 套用校正，結果夾在 0...1。每個觸點、每個報告都會呼叫：直接展開多項式，不配置陣列
    public func apply(x rawX: Double, y rawY: Double) -> (x: Double, y: Double) {
        let p = unclampedApply(rawX, rawY)
        return (min(max(p.x, 0), 1), min(max(p.y, 0), 1))
    }

    /// 以 0.5 為中心的多項式項：讓係數的數值範圍相近，正規方程式比較穩定
    static func terms(_ x: Double, _ y: Double, _ model: Model) -> [Double] {
        let u = x - 0.5, v = y - 0.5
        switch model {
        case .affine: return [1, u, v]
        case .quadratic: return [1, u, v, u * u, u * v, v * v]
        }
    }

    // MARK: - 擬合

    /// 一個校正點：使用者想按的位置（十字）與實際量到的原始座標（多次點擊的中位數）
    public struct Sample: Sendable, Equatable, Codable {
        /// 十字的位置（正規化座標）
        public var target: Point
        /// 量到的校正前座標（正規化座標）
        public var measured: Point
        /// 這個點收集到的點擊次數（只供顯示與紀錄）
        public var count: Int

        /// - Parameter count: 點擊次數，只供顯示與紀錄
        public init(target: Point, measured: Point, count: Int = 1) {
            self.target = target
            self.measured = measured
            self.count = count
        }
    }

    /// 正規化座標（0...1，原點在面板左上，與 `Touch.x`／`Touch.y` 相同）
    public struct Point: Sendable, Equatable, Codable {
        /// 由左到右
        public var x: Double
        /// 由上到下
        public var y: Double
        /// 以正規化座標建立
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// 擬合結果
    public struct Fit: Sendable, Equatable {
        /// 擬合出的校正（`problem` 不為 nil 時不應套用）
        public var calibration: TouchCalibration
        /// 每個點（與輸入順序相同）套用後與目標的距離（正規化座標，以面板長寬換算成 mm 見 `residualMillimeters`）
        public var residuals: [Double]
        /// 被判定為離群而不參與擬合的點（輸入的索引）
        public var excluded: [Int]
        /// 為什麼不能使用（nil 表示可以使用）：校正量過大、映射會翻轉或摺疊
        public var problem: String?
    }

    /// 以最小平方擬合。點數 ≥ 6 且分布足以決定二次項時用二次，否則用仿射；少於 3 點或全部共線時回傳 nil。
    ///
    /// 穩健性：以 leave-one-out 找離群點——逐一排除某點擬合後預測它，預測誤差超過「其他點中位數的 3 倍」且超過
    /// `outlierFloor`（正規化，預設約 1%，MF156LR 約 3 mm）時剔除後重擬（只剔除一點）。一般殘差判斷不到：
    /// 9 點擬合 6 個參數只剩 3 個冗餘，二次模型會把大部分離群偏差吸收掉。
    /// 結果另做健全性檢查：在 11×11 格點上，校正量不得超過 `maximumCorrection`，映射的 Jacobian 行列式必須為正（不翻轉、不摺疊）。
    public static func fit(_ samples: [Sample], outlierFloor: Double = 0.01, maximumCorrection: Double = 0.06) -> Fit? {
        guard samples.count >= 3 else { return nil }
        let all = Array(samples.indices)
        guard var calibration = solve(samples, all) else { return nil }
        var excluded: [Int] = []
        if samples.count >= 5 {
            let prediction = all.map { i -> Double in
                solve(samples, all.filter { $0 != i })?.residual(for: samples[i]) ?? 0
            }
            let median = prediction.sorted()[prediction.count / 2]
            if let worst = prediction.indices.max(by: { prediction[$0] < prediction[$1] }),
               prediction[worst] > max(outlierFloor, median * 3),
               let refit = solve(samples, all.filter { $0 != worst }) {
                calibration = refit
                excluded = [worst]
            }
        }
        return Fit(calibration: calibration, residuals: samples.map { calibration.residual(for: $0) },
                   excluded: excluded, problem: calibration.problem(maximumCorrection: maximumCorrection))
    }

    func residual(for sample: Sample) -> Double {
        let p = apply(x: sample.measured.x, y: sample.measured.y)
        return hypot(p.x - sample.target.x, p.y - sample.target.y)
    }

    /// 二次項無法決定（例如點只分布在兩列）時退回仿射
    private static func solve(_ samples: [Sample], _ indices: [Int]) -> TouchCalibration? {
        for model in indices.count >= 6 ? [Model.quadratic, .affine] : [.affine] {
            let rows = indices.map { terms(samples[$0].measured.x, samples[$0].measured.y, model) }
            if let cx = leastSquares(rows, indices.map { samples[$0].target.x }),
               let cy = leastSquares(rows, indices.map { samples[$0].target.y }) {
                return TouchCalibration(model: model, x: cx, y: cy)
            }
        }
        return nil
    }

    /// 正規方程式 AᵀA·c = Aᵀb，以部分選主元的高斯消去法求解；矩陣接近奇異（點太集中、共線）時回傳 nil
    static func leastSquares(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = a.first?.count ?? 0
        guard n > 0, a.count >= n else { return nil }
        var m = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for (row, value) in zip(a, b) {
            for i in 0..<n {
                for j in 0..<n { m[i][j] += row[i] * row[j] }
                m[i][n] += row[i] * value
            }
        }
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-9 else { return nil }
            m.swapAt(col, pivot)
            for r in 0..<n where r != col {
                let f = m[r][col] / m[col][col]
                for c in col...n { m[r][c] -= f * m[col][c] }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }

    /// 健全性檢查（見 `fit`）；沒有問題時回傳 nil
    func problem(maximumCorrection: Double) -> String? {
        let steps = 10
        var largest = 0.0
        for i in 0...steps {
            for j in 0...steps {
                let x = Double(i) / Double(steps), y = Double(j) / Double(steps)
                let p = unclampedApply(x, y)
                largest = max(largest, hypot(p.x - x, p.y - y))
                // 數值 Jacobian：x、y 方向各差 1/1000
                let h = 0.001
                let px = unclampedApply(x + h, y), py = unclampedApply(x, y + h)
                let det = (px.x - p.x) * (py.y - p.y) - (px.y - p.y) * (py.x - p.x)
                if det <= 0 { return "校正後的座標會翻轉或摺疊（校正點可能點錯）" }
            }
        }
        if largest > maximumCorrection {
            return String(format: "校正量過大（最多 %.1f%%，上限 %.0f%%）：可能點錯了十字", largest * 100, maximumCorrection * 100)
        }
        return nil
    }

    private func unclampedApply(_ rawX: Double, _ rawY: Double) -> (x: Double, y: Double) {
        let u = rawX - 0.5, v = rawY - 0.5
        func evaluate(_ c: [Double]) -> Double {
            // 係數數量不符（檔案損毀）時不校正該軸
            switch (model, c.count) {
            case (.affine, 3): return c[0] + c[1] * u + c[2] * v
            case (.quadratic, 6): return c[0] + c[1] * u + c[2] * v + c[3] * u * u + c[4] * u * v + c[5] * v * v
            default: return .nan
            }
        }
        let outX = evaluate(x), outY = evaluate(y)
        return (outX.isNaN ? rawX : outX, outY.isNaN ? rawY : outY)
    }
}

/// 校正的來源（`MultiTouchManager.Configuration.calibration`）
public enum TouchCalibrationSource: Sendable, Equatable {
    /// 讀取 `TouchCalibrationStore`（預設）：有該裝置的校正就套用，檔案改變時自動重新載入；環境變數 MTK_CALIBRATION=off 時停用
    case stored
    /// 不套用校正（校正工具收集原始座標時使用）
    case disabled
    /// 套用指定的校正（所有裝置）
    case custom(TouchCalibration)
}

/// 校正檔 ~/Library/Application Support/MultiTouchKit/calibration.json 的讀寫。
///
/// 依裝置比對：VID＋PID，序號非空時也要相同。ILITEK 沒有序號，USB 位置（LocationID）又會隨插孔改變，
/// 所以只在同一個 VID／PID 有多筆時才以 LocationID 優先。顯示器的 EDID 只供紀錄（面板與 LCD 是一體的）。
public struct TouchCalibrationStore: Sendable {
    /// 一個裝置的校正紀錄
    public struct Entry: Sendable, Equatable, Codable {
        /// 校正時的觸控裝置（比對規則見 `TouchCalibrationStore`）
        public struct Device: Sendable, Equatable, Codable {
            /// USB Vendor ID
            public var vendorID: Int
            /// USB Product ID
            public var productID: Int
            /// 序號；空字串代表裝置沒有序號（ILITEK），比對時不檢查
            public var serialNumber: String
            /// USB 位置；同 VID／PID 有多筆紀錄時才用來挑選
            public var locationID: Int
            /// 產品名稱；只供紀錄
            public var product: String

            /// 取出 `info` 中用來比對的欄位
            public init(_ info: MultiTouchDeviceInfo) {
                vendorID = info.vendorID
                productID = info.productID
                serialNumber = info.serialNumber
                locationID = info.locationID
                product = info.product
            }
        }

        /// 校正的裝置
        public var device: Device
        /// 校正時觸控螢幕所在顯示器的 `DisplayInfo.edid`；只供紀錄
        public var displayEDID: String?
        /// 校正時觸控螢幕所在顯示器的名稱；只供紀錄
        public var displayName: String?
        /// 要套用的校正
        public var calibration: TouchCalibration
        /// 擬合時使用的校正點
        public var samples: [TouchCalibration.Sample]
        /// 校正前的平均誤差（mm；面板尺寸未知時以正規化座標 × 1000 記錄）
        public var errorBefore: Double
        /// 校正後的平均誤差（單位同 `errorBefore`）
        public var errorAfter: Double
        /// 校正的時間
        public var date: Date

        /// 建立一筆紀錄（`date` 預設為現在）
        public init(device: Device, displayEDID: String?, displayName: String?, calibration: TouchCalibration,
                    samples: [TouchCalibration.Sample], errorBefore: Double, errorAfter: Double, date: Date = Date()) {
            self.device = device
            self.displayEDID = displayEDID
            self.displayName = displayName
            self.calibration = calibration
            self.samples = samples
            self.errorBefore = errorBefore
            self.errorAfter = errorAfter
            self.date = date
        }

        func matches(_ info: MultiTouchDeviceInfo) -> Bool {
            device.vendorID == info.vendorID && device.productID == info.productID
                && (device.serialNumber.isEmpty || info.serialNumber.isEmpty || device.serialNumber == info.serialNumber)
        }
    }

    private struct File: Codable {
        var version = 1
        var entries: [Entry]
    }

    /// ~/Library/Application Support/MultiTouchKit/calibration.json（所有使用 MultiTouchKit 的程式共用）
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MultiTouchKit/calibration.json")
    }

    /// 讀寫的校正檔
    public let url: URL

    /// 只記錄路徑，不會讀取或建立檔案
    public init(url: URL = TouchCalibrationStore.defaultURL) {
        self.url = url
    }

    /// 所有紀錄；檔案不存在或格式錯誤時為空
    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(File.self, from: data))?.entries ?? []
    }

    /// 這個裝置的校正紀錄（同 VID／PID 有多筆時優先相同 LocationID）
    public func entry(for device: MultiTouchDeviceInfo) -> Entry? {
        let candidates = entries().filter { $0.matches(device) }
        return candidates.first { $0.device.locationID == device.locationID } ?? candidates.first
    }

    /// 儲存（取代同一裝置的舊紀錄），以原子寫入避免讀到一半的檔案
    public func save(_ entry: Entry) throws {
        var list = entries().filter { !($0.device.vendorID == entry.device.vendorID && $0.device.productID == entry.device.productID
                                        && $0.device.serialNumber == entry.device.serialNumber && $0.device.locationID == entry.device.locationID) }
        list.append(entry)
        try write(list)
    }

    /// 移除這個裝置的所有紀錄；回傳移除的筆數
    @discardableResult
    public func remove(for device: MultiTouchDeviceInfo) throws -> Int {
        let list = entries()
        let kept = list.filter { !$0.matches(device) }
        if kept.count != list.count { try write(kept) }
        return list.count - kept.count
    }

    private func write(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(entries: entries)).write(to: url, options: .atomic)
    }

    /// 檔案的修改時間（Manager 以它判斷是否需要重新載入）；不存在時為 nil
    var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
