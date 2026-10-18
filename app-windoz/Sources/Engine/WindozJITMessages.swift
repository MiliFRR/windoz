// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz Converter Exception: see LICENSE-EXCEPTION.md
//
// Ported from Madeira's JITBuiltInMessages.swift (GPL-3.0-or-later, Madeira
// Converter Exception): only the names and item keys are Windoz's. The
// messages are shared with the bundled helper extension (JITHelper/), so this
// file is compiled into both targets.

import Foundation

/// Codable messages shared by Windoz and its JIT helper extension. Each travels as JSON
/// in an extension request's item (userInfo[itemKey]), to the helper and back.
struct WindozJITRequest: Codable, Sendable {
    static let itemKey = "windoz-jit-request"

    enum Operation: String, Codable, Sendable {
        case prepare
        case enable
        case resetDDI
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let scriptBase64: String?

    static func prepare(pairingData: Data) -> WindozJITRequest {
        WindozJITRequest(operation: .prepare, targetPID: nil,
                         pairingData: pairingData, scriptBase64: nil)
    }

    static func enable(targetPID: Int32, pairingData: Data,
                       scriptBase64: String) -> WindozJITRequest {
        WindozJITRequest(operation: .enable, targetPID: targetPID,
                         pairingData: pairingData, scriptBase64: scriptBase64)
    }

    static var resetDDI: WindozJITRequest {
        WindozJITRequest(operation: .resetDDI, targetPID: nil,
                         pairingData: nil, scriptBase64: nil)
    }

    struct Response: Codable, Sendable {
        static let itemKey = "windoz-jit-response"
        let success: Bool
        let message: String
        let txmPresent: Bool?
    }
}
