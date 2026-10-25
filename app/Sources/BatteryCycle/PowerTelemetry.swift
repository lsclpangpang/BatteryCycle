import Foundation
import IOKit

enum PowerFlowState: Equatable, Sendable {
    case charging, external, battery, hybrid, unknown
}

struct PowerTelemetry: Equatable, Sendable {
    static let unavailable = PowerTelemetry()

    let source: PowerFlowState
    /// Measured adapter input, never AdapterDetails.Watts or its PD limit.
    let inputWatts: Double?
    /// Positive is power entering the battery; negative is power leaving it.
    let batteryWatts: Double?
    /// Apple's ExternalConnected flag, not physical cable-presence detection.
    let externalConnected: Bool?
    /// Adapter rating/capability. This dictionary can remain after disconnection.
    let adapterRatedWatts: Double?
    let isCharging: Bool?
    let externalChargeCapable: Bool?

    init(source: PowerFlowState = .unknown, inputWatts: Double? = nil,
         batteryWatts: Double? = nil, externalConnected: Bool? = nil,
         adapterRatedWatts: Double? = nil, isCharging: Bool? = nil,
         externalChargeCapable: Bool? = nil) {
        self.source = source
        self.inputWatts = inputWatts
        self.batteryWatts = batteryWatts
        self.externalConnected = externalConnected
        self.adapterRatedWatts = adapterRatedWatts
        self.isCharging = isCharging
        self.externalChargeCapable = externalChargeCapable
    }
}

/// Reads one IORegistry property-table snapshot without opening a hardware user
/// client. PowerTelemetryData is undocumented and may be absent on other Macs.
enum PowerTelemetryReader {
    // Small standby readings persist while this Mac deliberately uses its battery.
    // This deadband affects direction classification, not the displayed measurements.
    private static let directionThreshold = 0.5

    static func read() -> PowerTelemetry {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .unavailable }
        defer { IOObjectRelease(service) }
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = raw?.takeRetainedValue() as? [String: Any] else { return .unavailable }
        // decode reads only these electrical/status properties. No identifiers,
        // serial numbers or complete raw dictionaries are logged or retained.
        return decode(properties: properties)
    }

    static func decode(properties: [String: Any]) -> PowerTelemetry {
        let external = boolean(properties["ExternalConnected"])
        let charging = boolean(properties["IsCharging"])
        let chargeCapable = boolean(properties["ExternalChargeCapable"])
        let telemetry = properties["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = properties["AdapterDetails"] as? [String: Any] ?? [:]
        let rated = scalar(adapter["Watts"], within: 1...1_000)
        let input = inputPower(telemetry)

        // Apple documents Voltage in mV and Amperage in signed mA:
        // https://github.com/apple-oss-distributions/xnu/blob/main/iokit/IOKit/pwr_mgt/IOPMPowerSource.h
        // The battery driver sign-extends its signed current measurements:
        // https://github.com/apple-oss-distributions/PowerManagement/blob/main/AppleSmartBatteryManager/AppleSmartBattery.cpp
        let voltage = scalar(properties["Voltage"], within: 1_000...30_000)
        let currentValue = properties["InstantAmperage"] ?? properties["Amperage"]
        let current = signedInteger(currentValue, maximumMagnitude: 50_000)
        var battery: Double?
        if let voltage, let current {
            let watts = voltage * current / 1_000_000
            if abs(watts) <= 500 { battery = watts }
        }
        if boolean(properties["BatteryInstalled"]) == false { battery = nil }

        // Do not use undocumented PowerTelemetryData.BatteryPower as a second
        // signed battery measurement. On the observed Mac it stays negative
        // during confirmed charging with positive current and rising capacity.
        // Source flags and signed current are checked together in classify().

        let source = classify(external: external, charging: charging, chargeCapable: chargeCapable,
                              input: input, battery: battery)
        return PowerTelemetry(source: source,
                              // The telemetry dictionary can contain stale/residual
                              // input readings after ExternalConnected turns false.
                              inputWatts: external == true ? input : nil,
                              batteryWatts: battery, externalConnected: external,
                              adapterRatedWatts: rated, isCharging: charging,
                              externalChargeCapable: chargeCapable)
    }

    private static func classify(external: Bool?, charging: Bool?, chargeCapable: Bool?,
                                 input: Double?, battery: Double?) -> PowerFlowState {
        guard let external, let charging, let battery else { return .unknown }
        if !external {
            // A substantial input contradicts the system's source flag. A small
            // residual (observed at 0.331 W) is not evidence of shared supply.
            guard !charging, input.map({ $0 <= directionThreshold }) ?? true else { return .unknown }
            return battery < -directionThreshold ? .battery : .unknown
        }
        if charging {
            guard chargeCapable != false, battery > directionThreshold else { return .unknown }
            if let input {
                guard input > directionThreshold,
                      battery <= input + max(1, input * 0.1) else { return .unknown }
            }
            return .charging
        }
        guard battery <= directionThreshold, let input else { return .unknown }
        if battery < -directionThreshold {
            return input > directionThreshold ? .hybrid : .battery
        }
        return input > directionThreshold ? .external : .unknown
    }

    private static func inputPower(_ telemetry: [String: Any]) -> Double? {
        // Measured SystemPowerIn is mW. Only these live rail measurements may
        // serve as a fallback; adapter voltage/current describe capability.
        // https://github.com/darrylmorley/whatport/blob/main/Sources/WhatPortIOKit/PowerReader.swift
        if let raw = telemetry["SystemPowerIn"] {
            guard let milliwatts = scalar(raw, within: 0...1_000_000) else { return nil }
            let watts = milliwatts / 1_000
            // A positive malformed value can underflow during conversion. That
            // is unavailable telemetry, not a measured zero-watt input.
            return milliwatts == 0 || watts > 0 ? watts : nil
        }
        guard let millivolts = scalar(telemetry["SystemVoltageIn"], within: 0...60_000),
              let milliamps = scalar(telemetry["SystemCurrentIn"], within: 0...20_000) else { return nil }
        let watts = millivolts * milliamps / 1_000_000
        guard watts <= 1_000,
              millivolts == 0 || milliamps == 0 || watts > 0 else { return nil }
        return watts
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func scalar(_ value: Any?, within range: ClosedRange<Double>) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && range.contains(value) ? value : nil
    }

    private static func signedInteger(_ value: Any?, maximumMagnitude: Double) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let floating = number.doubleValue
        guard floating.isFinite, floating.rounded() == floating else { return nil }
        let encoding = String(cString: number.objCType)
        if encoding == "f" || encoding == "d" {
            return abs(floating) <= maximumMagnitude ? floating : nil
        }
        // IORegistry exports negative currents as either signed integers or
        // unsigned two's-complement 32/64-bit values. Never use abs() on raw data.
        var signed = number.int64Value
        if signed > Int64(Int32.max), signed <= Int64(UInt32.max) {
            signed = Int64(Int32(bitPattern: UInt32(signed)))
        }
        let decoded = Double(signed)
        return abs(decoded) <= maximumMagnitude ? decoded : nil
    }
}
