import XCTest
@testable import Spacie

// MARK: - DevicePollDifferTests

/// Verifies the pure polling-diff rules used by ``KMPDeviceServiceAdapter/observeDevices``.
///
/// The diff logic is the part of the polling loop most likely to regress
/// (transition-only `trustStateChanged`, disconnect drops trust map entry,
/// idempotency on repeated identical ticks). Testing the pure differ lets us
/// exercise every branch without spawning a stub `SpaDeviceServiceApi`.
final class DevicePollDifferTests: XCTestCase {

    // MARK: - Helpers

    private func device(_ udid: String) -> DeviceInfo {
        DeviceInfo(
            udid: udid,
            deviceName: "iPhone-\(udid)",
            productType: "iPhone16,1",
            productVersion: "18.0",
            buildVersion: "22A"
        )
    }

    // MARK: - Connected events

    func testFirstTick_newDevice_yieldsConnectedAndStoresTrust() {
        let result = DevicePollDiffer.diff(
            knownUDIDs: [],
            knownTrustStates: [:],
            currentDevices: [device("U1")],
            trustResults: [("U1", .trusted)]
        )

        XCTAssertEqual(result.events, [.connected(device("U1"))])
        XCTAssertEqual(result.nextKnownUDIDs, ["U1"])
        XCTAssertEqual(result.nextKnownTrustStates["U1"], .trusted)
    }

    func testFirstTick_doesNotEmitTrustStateChanged_evenWhenTrustResultPresent() {
        // Initial observation must not emit `.trustStateChanged` — the connected
        // event itself carries the device payload; views derive initial trust from it.
        let result = DevicePollDiffer.diff(
            knownUDIDs: [],
            knownTrustStates: [:],
            currentDevices: [device("U1")],
            trustResults: [("U1", .trusted)]
        )

        let hasTrustEvent = result.events.contains {
            if case .trustStateChanged = $0 { return true } else { return false }
        }
        XCTAssertFalse(hasTrustEvent, "first observation must not emit trustStateChanged")
    }

    // MARK: - Disconnect

    func testDisconnect_yieldsEventAndDropsTrustMapEntry() {
        let result = DevicePollDiffer.diff(
            knownUDIDs: ["U1"],
            knownTrustStates: ["U1": .trusted],
            currentDevices: [],
            trustResults: []
        )

        XCTAssertEqual(result.events, [.disconnected(udid: "U1")])
        XCTAssertTrue(result.nextKnownUDIDs.isEmpty)
        XCTAssertNil(result.nextKnownTrustStates["U1"], "trust state must be dropped on disconnect")
    }

    func testDisconnect_otherDeviceStays() {
        let result = DevicePollDiffer.diff(
            knownUDIDs: ["U1", "U2"],
            knownTrustStates: ["U1": .trusted, "U2": .notTrusted],
            currentDevices: [device("U2")],
            trustResults: [("U2", .notTrusted)]
        )

        XCTAssertEqual(result.events, [.disconnected(udid: "U1")])
        XCTAssertEqual(result.nextKnownUDIDs, ["U2"])
        XCTAssertEqual(result.nextKnownTrustStates["U2"], .notTrusted)
    }

    // MARK: - Trust state transitions

    func testTrustStateTransition_emitsChangedEvent() {
        let result = DevicePollDiffer.diff(
            knownUDIDs: ["U1"],
            knownTrustStates: ["U1": .notTrusted],
            currentDevices: [device("U1")],
            trustResults: [("U1", .trusted)]
        )

        XCTAssertEqual(result.events, [.trustStateChanged(udid: "U1", state: .trusted)])
        XCTAssertEqual(result.nextKnownTrustStates["U1"], .trusted)
    }

    func testIdenticalTrustState_doesNotEmitEvent() {
        let result = DevicePollDiffer.diff(
            knownUDIDs: ["U1"],
            knownTrustStates: ["U1": .trusted],
            currentDevices: [device("U1")],
            trustResults: [("U1", .trusted)]
        )

        XCTAssertEqual(result.events, [], "identical trust must not emit a change event")
    }

    // MARK: - Idempotency

    func testIdempotency_repeatedTickWithNoChange_emitsNothing() {
        let result = DevicePollDiffer.diff(
            knownUDIDs: ["U1", "U2"],
            knownTrustStates: ["U1": .trusted, "U2": .trusted],
            currentDevices: [device("U1"), device("U2")],
            trustResults: [("U1", .trusted), ("U2", .trusted)]
        )

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.nextKnownUDIDs, ["U1", "U2"])
    }

    // MARK: - Combined transitions

    func testCombined_connectDisconnectAndChange_emitsAllInOrder() {
        let result = DevicePollDiffer.diff(
            knownUDIDs: ["U1"],
            knownTrustStates: ["U1": .notTrusted],
            currentDevices: [device("U1"), device("U2")],
            trustResults: [("U1", .trusted), ("U2", .trusted)]
        )

        // Connected fires for new U2, trustStateChanged for U1 transition,
        // no disconnect (U1 still present).
        XCTAssertTrue(result.events.contains(.connected(device("U2"))))
        XCTAssertTrue(result.events.contains(.trustStateChanged(udid: "U1", state: .trusted)))
        XCTAssertEqual(result.events.count, 2)
    }
}
