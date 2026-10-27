import Foundation
import IOKit
import IOKit.hid

/// 從 IORegistry 讀取的 HID 介面屬性（不需開啟裝置）
struct HIDServiceInfo {
    var registryID: UInt64
    var vendorID: Int
    var productID: Int
    var locationID: Int
    var manufacturer: String
    var product: String
    var serialNumber: String
    var usagePairs: [(page: Int, usage: Int)]
    var reportDescriptor: [UInt8]
    var maxInputReportSize: Int

    init(service: io_service_t) {
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        registryID = entryID
        vendorID = property(kIOHIDVendorIDKey) as? Int ?? 0
        productID = property(kIOHIDProductIDKey) as? Int ?? 0
        locationID = property(kIOHIDLocationIDKey) as? Int ?? 0
        manufacturer = property(kIOHIDManufacturerKey) as? String ?? ""
        product = property(kIOHIDProductKey) as? String ?? ""
        serialNumber = property(kIOHIDSerialNumberKey) as? String ?? ""
        var pairs: [(Int, Int)] = []
        if let list = property(kIOHIDDeviceUsagePairsKey) as? [[String: Any]] {
            for item in list {
                if let page = item[kIOHIDDeviceUsagePageKey] as? Int, let usage = item[kIOHIDDeviceUsageKey] as? Int {
                    pairs.append((page, usage))
                }
            }
        }
        if pairs.isEmpty, let page = property(kIOHIDPrimaryUsagePageKey) as? Int,
           let usage = property(kIOHIDPrimaryUsageKey) as? Int {
            pairs.append((page, usage))
        }
        usagePairs = pairs
        reportDescriptor = (property(kIOHIDReportDescriptorKey) as? Data).map { [UInt8]($0) } ?? []
        maxInputReportSize = property(kIOHIDMaxInputReportSizeKey) as? Int ?? 64
    }

    var isTouchScreen: Bool {
        usagePairs.contains { $0.page == Int(HIDUsage.digitizerPage) && $0.usage == Int(HIDUsage.touchScreen) }
    }

    /// 同一個實體 USB 裝置的其他 HID 介面
    func isSibling(of other: HIDServiceInfo) -> Bool {
        registryID != other.registryID && vendorID == other.vendorID && productID == other.productID
            && locationID == other.locationID && locationID != 0
    }
}

/// 列出目前所有 HID 介面
func enumerateHIDServices(_ body: (io_service_t) -> Void) {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) == KERN_SUCCESS else {
        return
    }
    defer { IOObjectRelease(iterator) }
    while case let service = IOIteratorNext(iterator), service != 0 {
        body(service)
        IOObjectRelease(service)
    }
}

func hexString(_ value: IOReturn) -> String {
    String(format: "0x%08x", UInt32(bitPattern: value))
}

/// kIOReturnExclusiveAccess：裝置已被其他程式獨占
let ioReturnExclusiveAccess = IOReturn(bitPattern: 0xE000_02C5)
