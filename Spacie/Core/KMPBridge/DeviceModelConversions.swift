import Foundation
import SpacieKit

// MARK: - SpaDeviceInfo → DeviceInfo

extension SpaDeviceInfo {

    func toSwift() -> DeviceInfo {
        DeviceInfo(
            udid: udid,
            deviceName: deviceName,
            productType: productType,
            productVersion: productVersion,
            buildVersion: buildVersion
        )
    }
}

// MARK: - SpaAppInfo → AppInfo

extension SpaAppInfo {

    func toSwift() -> AppInfo {
        let safeipaSize: UInt64?
        if let boxed = ipaSize {
            let raw = boxed.int64Value
            safeipaSize = raw >= 0 ? UInt64(raw) : nil
        } else {
            safeipaSize = nil
        }

        let iconBytes: Data?
        if let ba = iconData {
            let count = Int(ba.size)
            var bytes = [UInt8](repeating: 0, count: count)
            for idx in 0 ..< count {
                bytes[idx] = UInt8(bitPattern: ba.get(index: Int32(idx)))
            }
            iconBytes = Data(bytes)
        } else {
            iconBytes = nil
        }

        return AppInfo(
            bundleID: bundleID,
            displayName: displayName,
            version: version,
            shortVersion: shortVersion,
            ipaSize: safeipaSize,
            iconData: iconBytes
        )
    }
}

// MARK: - SpaTrustState → TrustState

extension SpaTrustState {

    func toSwift() -> TrustState {
        switch name {
        case "TRUSTED":      return .trusted
        case "DIALOG_SHOWN": return .dialogShown
        default:             return .notTrusted
        }
    }
}

// MARK: - SpaDependencyStatus → DependencyStatus

extension SpaDependencyStatus {

    func toSwift() -> DependencyStatus {
        if self is SpaDependencyStatus.SpaDependencyStatusPackageManagerMissing {
            return .homebrewMissing
        }

        if let missing = self as? SpaDependencyStatus.SpaDependencyStatusMissing {
            return .missing(tools: missing.tools)
        }

        if let ready = self as? SpaDependencyStatus.SpaDependencyStatusReady {
            let paths = ready.toolPaths
            let toolPaths = ToolPaths(
                ideviceId: paths["idevice_id"] ?? "",
                ideviceInfo: paths["ideviceinfo"] ?? "",
                ideviceinstaller: paths["ideviceinstaller"] ?? "",
                idevicepair: paths["idevicepair"] ?? "",
                brew: paths["brew"] ?? "",
                ipatool: paths["ipatool"] ?? ""
            )
            return .ready(toolPaths)
        }

        return .homebrewMissing
    }
}
