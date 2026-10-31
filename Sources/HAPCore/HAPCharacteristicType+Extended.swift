// HAPCharacteristicType+Extended.swift
// Copyright 2026 Monagle Pty Ltd

// MARK: - Lightbulb

extension HAPCharacteristicType {
    public static let on = HAPCharacteristicType(rawValue: "25")
    public static let brightness = HAPCharacteristicType(rawValue: "8")
    public static let hue = HAPCharacteristicType(rawValue: "13")
    public static let saturation = HAPCharacteristicType(rawValue: "2F")
    public static let colorTemperature = HAPCharacteristicType(rawValue: "CE")
}

// MARK: - Outlet

extension HAPCharacteristicType {
    public static let outletInUse = HAPCharacteristicType(rawValue: "26")
}

// MARK: - Fan v2

extension HAPCharacteristicType {
    public static let active = HAPCharacteristicType(rawValue: "B0")
    public static let rotationSpeed = HAPCharacteristicType(rawValue: "29")
    public static let rotationDirection = HAPCharacteristicType(rawValue: "28")
    public static let swingMode = HAPCharacteristicType(rawValue: "B6")
}

// MARK: - Door Lock

extension HAPCharacteristicType {
    public static let lockCurrentState = HAPCharacteristicType(rawValue: "1D")
    public static let lockTargetState = HAPCharacteristicType(rawValue: "1E")
}

// MARK: - Window Covering

extension HAPCharacteristicType {
    public static let currentPosition = HAPCharacteristicType(rawValue: "6D")
    public static let targetPosition = HAPCharacteristicType(rawValue: "7C")
    public static let positionState = HAPCharacteristicType(rawValue: "72")
}

// MARK: - Thermostat

extension HAPCharacteristicType {
    public static let currentTemperature = HAPCharacteristicType(rawValue: "11")
    public static let targetTemperature = HAPCharacteristicType(rawValue: "35")
    public static let currentHeatingCoolingState = HAPCharacteristicType(rawValue: "F")
    public static let targetHeatingCoolingState = HAPCharacteristicType(rawValue: "33")
    public static let currentRelativeHumidity = HAPCharacteristicType(rawValue: "10")
}

// MARK: - Sensors

extension HAPCharacteristicType {
    public static let motionDetected = HAPCharacteristicType(rawValue: "22")
    public static let occupancyDetected = HAPCharacteristicType(rawValue: "71")
    public static let contactSensorState = HAPCharacteristicType(rawValue: "6A")
    public static let leakDetected = HAPCharacteristicType(rawValue: "70")
    public static let smokeDetected = HAPCharacteristicType(rawValue: "76")
    public static let carbonMonoxideDetected = HAPCharacteristicType(rawValue: "69")
}

// MARK: - Speaker

extension HAPCharacteristicType {
    public static let mute = HAPCharacteristicType(rawValue: "11A")
    public static let volume = HAPCharacteristicType(rawValue: "119")
}

// MARK: - Camera

extension HAPCharacteristicType {
    public static let supportedVideoStreamConfiguration = HAPCharacteristicType(rawValue: "114")
    public static let supportedAudioStreamConfiguration = HAPCharacteristicType(rawValue: "115")
    public static let supportedRTPConfiguration = HAPCharacteristicType(rawValue: "116")
    public static let selectedRTPStreamConfiguration = HAPCharacteristicType(rawValue: "117")
    public static let setupEndpoints = HAPCharacteristicType(rawValue: "118")
    public static let streamingStatus = HAPCharacteristicType(rawValue: "120")
}

// MARK: - Camera Recording (HomeKit Secure Video)

extension HAPCharacteristicType {
    public static let supportedCameraRecordingConfiguration = HAPCharacteristicType(rawValue: "205")
    public static let supportedVideoRecordingConfiguration = HAPCharacteristicType(rawValue: "206")
    public static let supportedAudioRecordingConfiguration = HAPCharacteristicType(rawValue: "207")
    public static let selectedCameraRecordingConfiguration = HAPCharacteristicType(rawValue: "209")
    public static let recordingAudioActive = HAPCharacteristicType(rawValue: "226")
    public static let homeKitCameraActive = HAPCharacteristicType(rawValue: "21B")
    public static let cameraOperatingModeIndicator = HAPCharacteristicType(rawValue: "21D")
    public static let eventSnapshotsActive = HAPCharacteristicType(rawValue: "223")
    public static let periodicSnapshotsActive = HAPCharacteristicType(rawValue: "225")
    public static let supportedDataStreamTransportConfiguration = HAPCharacteristicType(rawValue: "130")
    public static let setupDataStreamTransport = HAPCharacteristicType(rawValue: "131")
}

// MARK: - Shared

extension HAPCharacteristicType {
    public static let statusActive = HAPCharacteristicType(rawValue: "75")
    public static let batteryLevel = HAPCharacteristicType(rawValue: "68")
}
