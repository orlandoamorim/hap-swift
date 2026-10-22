// HAPPermission.swift
// Copyright 2026 Monagle Pty Ltd

public enum HAPPermission: String, Sendable, Codable {
    case read = "pr"
    case write = "pw"
    case notify = "ev"
    /// The controller may ask for a value back in the write response (`"r": true`).
    case writeResponse = "wr"
}
