// AccessoryInfo.swift
// Copyright 2026 Monagle Pty Ltd

public struct AccessoryInfo: Sendable {
    public let name: String
    public let manufacturer: String
    public let model: String
    public let serialNumber: String
    public let firmwareRevision: String
    /// Adds a writable ConfiguredName to Accessory Information, so a later rename
    /// reaches the Home app (Name is only read when the accessory is added).
    public let configuredName: String?

    public init(
        name: String,
        manufacturer: String,
        model: String,
        serialNumber: String,
        firmwareRevision: String,
        configuredName: String? = nil
    ) {
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.configuredName = configuredName
    }
}
