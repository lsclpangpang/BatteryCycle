import Foundation
#if canImport(XCTest) && !POWER_TELEMETRY_STANDALONE
import XCTest
@testable import BatteryCycle
typealias PowerTestCase = XCTestCase
#elseif POWER_TELEMETRY_STANDALONE
class PowerTestCase {}
private var powerFailures = 0
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "") {
    if lhs != rhs { powerFailures += 1; print("FAIL: \(lhs) != \(rhs) \(message)") }
}
private func XCTAssertNil<T>(_ value: T?) {
    if value != nil { powerFailures += 1; print("FAIL: expected unavailable, got \(value!)") }
}
@main
struct PowerTelemetryTestRunner {
    static func main() {
        let tests = PowerTelemetryTests()
        tests.testSixDisplayScenarios()
        tests.testMissingAndMalformedBooleansStayUnknown()
        tests.testSignedAndUnsignedNegativeCurrent()
        tests.testElectricalUnitsAndRatedPowerAreSeparate()
        tests.testInvalidNumbersDoNotBecomeWatts()
        tests.testContradictoryDirectionAndSourceStayUnknown()
        tests.testUndocumentedBatteryPowerCannotOverrideSourceMeasurements()
        tests.testObservedChargingSnapshotKeepsBatteryInput()
        tests.testOnlyLiveInputFieldsCanSupplyInputWatts()
        tests.testAverageCurrentFallbackAndMissingBatteryReadings()
        tests.testSmallResidualInputDoesNotClaimExternalSupply()
        tests.testInputConversionRejectsUnderflowAndPreservesMeasuredZero()
        tests.testReadOnlyHardwareSampleWhenRequested()
        print("PowerTelemetry: 12 checks, \(powerFailures) failures")
        if powerFailures > 0 { exit(1) }
    }
}
#endif

#if canImport(XCTest) || POWER_TELEMETRY_STANDALONE
final class PowerTelemetryTests: PowerTestCase {
    private func snapshot(external: Bool = true, charging: Bool = false,
                          current: Any = 0, input: Any? = 20_000) -> [String: Any] {
        var telemetry: [String: Any] = [:]
        telemetry["SystemPowerIn"] = input
        return ["ExternalConnected": external, "IsCharging": charging,
                "ExternalChargeCapable": true, "Voltage": 12_000,
                "InstantAmperage": current, "Amperage": current,
                "AdapterDetails": ["Watts": 60], "PowerTelemetryData": telemetry]
    }

    func testSixDisplayScenarios() {
        XCTAssertEqual(PowerTelemetryReader.decode(properties: snapshot(charging: true, current: 1_000)).source, .charging)
        XCTAssertEqual(PowerTelemetryReader.decode(properties: snapshot()).source, .external)
        XCTAssertEqual(PowerTelemetryReader.decode(properties: snapshot(external: false, current: -1_000, input: 0)).source, .battery)
        XCTAssertEqual(PowerTelemetryReader.decode(properties: snapshot(current: -1_000, input: 5_000)).source, .hybrid)
        // An attached/available adapter may be idle while the battery powers the Mac.
        XCTAssertEqual(PowerTelemetryReader.decode(properties: snapshot(current: -1_000, input: 100)).source, .battery)
        XCTAssertEqual(PowerTelemetryReader.decode(properties: [:]), .unavailable)
    }

    func testMissingAndMalformedBooleansStayUnknown() {
        for key in ["ExternalConnected", "IsCharging"] {
            for value: Any? in [nil, "false", NSNumber(value: 0), NSNumber(value: 1)] {
                var data = snapshot()
                data[key] = value
                let parsed = PowerTelemetryReader.decode(properties: data)
                XCTAssertEqual(parsed.source, .unknown, key)
                if key == "ExternalConnected" { XCTAssertNil(parsed.externalConnected) }
                if key == "IsCharging" { XCTAssertNil(parsed.isCharging) }
            }
        }
    }

    func testSignedAndUnsignedNegativeCurrent() {
        let values: [Any] = [Int(-1_250), NSNumber(value: UInt64(bitPattern: -1_250)),
                             NSNumber(value: UInt32(bitPattern: -1_250))]
        for value in values {
            let parsed = PowerTelemetryReader.decode(properties: snapshot(external: false, current: value, input: 0))
            XCTAssertEqual(parsed.batteryWatts, -15)
            XCTAssertEqual(parsed.source, .battery)
        }
    }

    func testElectricalUnitsAndRatedPowerAreSeparate() {
        var data = snapshot(charging: true, current: 2_000, input: 60_000)
        data["AdapterDetails"] = ["Watts": 96]
        let parsed = PowerTelemetryReader.decode(properties: data)
        XCTAssertEqual(parsed.batteryWatts, 24)
        XCTAssertEqual(parsed.inputWatts, 60)
        XCTAssertEqual(parsed.adapterRatedWatts, 96)
        XCTAssertEqual(parsed.source, .charging)
    }

    func testInvalidNumbersDoNotBecomeWatts() {
        let invalid: [Any] = [Double.nan, Double.infinity, true, "12000", -1, 1_000_000]
        for value in invalid {
            var data = snapshot()
            data["Voltage"] = value
            let parsed = PowerTelemetryReader.decode(properties: data)
            XCTAssertNil(parsed.batteryWatts)
            XCTAssertEqual(parsed.source, .unknown)
        }
        for value: Any in [Double.nan, Double.infinity, true, "1000", 1_000_000, 1.5] {
            let parsed = PowerTelemetryReader.decode(properties: snapshot(current: value))
            XCTAssertNil(parsed.batteryWatts)
        }
        for value: Any in [Double.nan, Double.infinity, true, "20000", -1, 100_000_000] {
            let parsed = PowerTelemetryReader.decode(properties: snapshot(input: value))
            XCTAssertNil(parsed.inputWatts)
            XCTAssertEqual(parsed.source, .unknown)
        }
    }

    func testContradictoryDirectionAndSourceStayUnknown() {
        let contradictions = [
            snapshot(charging: true, current: -1_000),
            snapshot(charging: false, current: 1_000),
            snapshot(external: false, charging: true, current: 1_000, input: 0),
            snapshot(charging: true, current: 1_000, input: 0),
            snapshot(charging: true, current: 2_000, input: 5_000),
            snapshot(external: false, current: -1_000, input: 20_000),
        ]
        for data in contradictions { XCTAssertEqual(PowerTelemetryReader.decode(properties: data).source, .unknown) }
    }

    func testUndocumentedBatteryPowerCannotOverrideSourceMeasurements() {
        for raw: Any in [12_000, -12_000, Double.nan, NSNumber(value: UInt64.max)] {
            for (external, charging, current, input, expected) in [
                (true, true, 1_000, 20_000, PowerFlowState.charging),
                (true, false, -1_000, 20_000, PowerFlowState.hybrid),
                (false, false, -1_000, 0, PowerFlowState.battery),
                (true, false, 0, 20_000, PowerFlowState.external)
            ] {
                var data = snapshot(external: external, charging: charging, current: current, input: input)
                data["PowerTelemetryData"] = ["SystemPowerIn": input, "BatteryPower": raw]
                let parsed = PowerTelemetryReader.decode(properties: data)
                XCTAssertEqual(parsed.source, expected)
                XCTAssertEqual(parsed.batteryWatts, Double(current) * 0.012)
            }
        }
    }

    func testObservedChargingSnapshotKeepsBatteryInput() {
        // Captured during confirmed charging on 2026-10-25. BatteryPower is
        // negative here despite IsCharging=true, positive current and rising capacity.
        let data: [String: Any] = [
            "ExternalConnected": true, "IsCharging": true,
            "ExternalChargeCapable": true, "BatteryInstalled": true,
            "Voltage": 11_948, "InstantAmperage": 3_183, "Amperage": 3_183,
            "PowerTelemetryData": ["SystemPowerIn": 58_511, "BatteryPower": -27_506, "SystemLoad": 86_017]
        ]
        let parsed = PowerTelemetryReader.decode(properties: data)
        XCTAssertEqual(parsed.source, .charging)
        XCTAssertEqual(parsed.inputWatts, 58.511)
        XCTAssertEqual(parsed.batteryWatts, 11_948.0 * 3_183 / 1_000_000)
    }

    func testOnlyLiveInputFieldsCanSupplyInputWatts() {
        var data = snapshot(input: nil)
        data["AdapterDetails"] = ["Watts": 60, "AdapterVoltage": 20_000, "Current": 3_000]
        let absent = PowerTelemetryReader.decode(properties: data)
        XCTAssertNil(absent.inputWatts)
        XCTAssertEqual(absent.adapterRatedWatts, 60)
        XCTAssertEqual(absent.source, .unknown)
        data["PowerTelemetryData"] = ["SystemVoltageIn": 20_000, "SystemCurrentIn": 500]
        let livePair = PowerTelemetryReader.decode(properties: data)
        XCTAssertEqual(livePair.inputWatts, 10)
        XCTAssertEqual(livePair.source, .external)
    }

    func testAverageCurrentFallbackAndMissingBatteryReadings() {
        var data = snapshot(external: false, current: -1_000, input: 0)
        data.removeValue(forKey: "InstantAmperage")
        XCTAssertEqual(PowerTelemetryReader.decode(properties: data).batteryWatts, -12)
        data.removeValue(forKey: "Amperage")
        let missing = PowerTelemetryReader.decode(properties: data)
        XCTAssertNil(missing.batteryWatts)
        XCTAssertEqual(missing.source, .unknown)
    }

    func testSmallResidualInputDoesNotClaimExternalSupply() {
        var data = snapshot(external: false, current: -777, input: 331)
        data["Voltage"] = 11_322
        let parsed = PowerTelemetryReader.decode(properties: data)
        XCTAssertEqual(parsed.source, .battery)
        XCTAssertNil(parsed.inputWatts)
        XCTAssertEqual(parsed.externalConnected, false)
        XCTAssertEqual(parsed.adapterRatedWatts, 60)
    }

    func testInputConversionRejectsUnderflowAndPreservesMeasuredZero() {
        XCTAssertNil(PowerTelemetryReader.decode(properties: snapshot(input: Double.leastNonzeroMagnitude)).inputWatts)
        XCTAssertEqual(PowerTelemetryReader.decode(properties: snapshot(input: 0)).inputWatts, 0)
        XCTAssertEqual(PowerTelemetryReader.decode(properties: snapshot(input: -0.0)).inputWatts, 0)
        let smallMilliwatts = Double.leastNormalMagnitude
        XCTAssertEqual(PowerTelemetryReader.decode(properties: snapshot(input: smallMilliwatts)).inputWatts,
                       smallMilliwatts / 1000)

        var data = snapshot(input: nil)
        for value in [Double.leastNonzeroMagnitude, Double.leastNormalMagnitude] {
            data["PowerTelemetryData"] = ["SystemVoltageIn": value, "SystemCurrentIn": value]
            XCTAssertNil(PowerTelemetryReader.decode(properties: data).inputWatts)
        }
        data["PowerTelemetryData"] = ["SystemVoltageIn": Double.leastNonzeroMagnitude, "SystemCurrentIn": 10_000]
        XCTAssertNil(PowerTelemetryReader.decode(properties: data).inputWatts)
        data["PowerTelemetryData"] = ["SystemVoltageIn": Double.leastNormalMagnitude, "SystemCurrentIn": 0]
        XCTAssertEqual(PowerTelemetryReader.decode(properties: data).inputWatts, 0)
        data["PowerTelemetryData"] = ["SystemVoltageIn": 0, "SystemCurrentIn": Double.leastNormalMagnitude]
        XCTAssertEqual(PowerTelemetryReader.decode(properties: data).inputWatts, 0)
        data["PowerTelemetryData"] = ["SystemVoltageIn": 0.5, "SystemCurrentIn": 0.5]
        XCTAssertEqual(PowerTelemetryReader.decode(properties: data).inputWatts, 0.00000025)
    }

    func testReadOnlyHardwareSampleWhenRequested() {
        guard ProcessInfo.processInfo.environment["BATTERYCYCLE_TEST_LIVE_POWER"] == "1" else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let value = PowerTelemetryReader.read()
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print("POWER_READ ms=\(elapsed) state=\(value.source) inputW=\(String(describing: value.inputWatts)) batteryW=\(String(describing: value.batteryWatts)) externalConnected=\(String(describing: value.externalConnected)) ratedW=\(String(describing: value.adapterRatedWatts))")
    }
}
#endif
