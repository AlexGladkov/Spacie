import Foundation

// MARK: - DevicePollDiff

/// Pure outcome of one polling tick performed by ``KMPDeviceServiceAdapter/observeDevices``.
///
/// Returned by [DevicePollDiffer.diff]. Lifecycle is:
///   1. Adapter calls `listDevices` + per-device `validateTrust`.
///   2. Result is fed into [DevicePollDiffer.diff] alongside the previous
///      `knownUDIDs` / `knownTrustStates`.
///   3. Adapter yields each event in [events] to the AsyncStream and stores
///      [nextKnownUDIDs] / [nextKnownTrustStates] for the next tick.
///
/// Extracted as a separate, side-effect-free helper so the diffing rules
/// (only emit `.trustStateChanged` on transitions, not initial observation;
/// remove trust state when device disconnects; etc.) are unit-testable in
/// isolation from the KMP bridge.
struct DevicePollDiff: Equatable, Sendable {
    let events: [DeviceEvent]
    let nextKnownUDIDs: Set<String>
    let nextKnownTrustStates: [String: TrustState]
}

// DeviceEvent doesn't synthesize Equatable because of associated values, but
// for tests we only compare structural shape — small Equatable conformance
// scoped to this file is enough.
extension DeviceEvent: Equatable {
    public static func == (lhs: DeviceEvent, rhs: DeviceEvent) -> Bool {
        switch (lhs, rhs) {
        case (.connected(let a), .connected(let b)):
            return a.udid == b.udid
        case (.disconnected(let a), .disconnected(let b)):
            return a == b
        case (.trustStateChanged(let u1, let s1), .trustStateChanged(let u2, let s2)):
            return u1 == u2 && s1 == s2
        case (.error(let a), .error(let b)):
            return (a as NSError) == (b as NSError)
        default:
            return false
        }
    }
}

// MARK: - DevicePollDiffer

enum DevicePollDiffer {

    /// Computes the events that should be emitted from a single polling tick.
    ///
    /// Rules:
    ///  * A UDID present in [currentDevices] but absent from [knownUDIDs]
    ///    yields `.connected`.
    ///  * A UDID in [knownUDIDs] but absent from [currentDevices] yields
    ///    `.disconnected` and is dropped from [nextKnownTrustStates].
    ///  * A trust-state transition (`knownTrustStates[udid] != newState`)
    ///    yields `.trustStateChanged` ONLY when an earlier trust state was
    ///    already observed for that UDID — the first observation is silent,
    ///    matching the contract that views derive initial trust from the
    ///    `.connected` event's device payload.
    static func diff(
        knownUDIDs: Set<String>,
        knownTrustStates: [String: TrustState],
        currentDevices: [DeviceInfo],
        trustResults: [(String, TrustState)]
    ) -> DevicePollDiff {
        var events: [DeviceEvent] = []
        var nextKnownUDIDs = knownUDIDs
        var nextKnownTrustStates = knownTrustStates

        let currentUDIDs = Set(currentDevices.map(\.udid))

        for device in currentDevices where !nextKnownUDIDs.contains(device.udid) {
            nextKnownUDIDs.insert(device.udid)
            events.append(.connected(device))
        }

        for udid in knownUDIDs where !currentUDIDs.contains(udid) {
            nextKnownUDIDs.remove(udid)
            nextKnownTrustStates.removeValue(forKey: udid)
            events.append(.disconnected(udid: udid))
        }

        for (udid, newState) in trustResults {
            let oldState = nextKnownTrustStates[udid]
            if oldState != newState {
                nextKnownTrustStates[udid] = newState
                if oldState != nil {
                    events.append(.trustStateChanged(udid: udid, state: newState))
                }
            }
        }

        return DevicePollDiff(
            events: events,
            nextKnownUDIDs: nextKnownUDIDs,
            nextKnownTrustStates: nextKnownTrustStates
        )
    }
}
