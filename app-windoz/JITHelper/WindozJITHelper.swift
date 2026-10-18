// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz Converter Exception: see LICENSE-EXCEPTION.md
//
// Ported from Madeira's MadeiraJITHelper.swift (GPL-3.0-or-later, Madeira
// Converter Exception). This target must stay outside app-windoz/Sources: the
// type-check job compiles Sources with plain swiftc, where `import StikJIT`
// has no module to resolve against; only a real Xcode build links the vendored
// framework.

// Windoz's JIT helper: a classic app extension that Windoz starts by its bundle ID
// (Sources/Engine/JITBuiltInHost.swift), so a sideloader's renamed install still finds
// it. One WindozJITRequest per extension request, answered when the request completes.

import Foundation
#if !targetEnvironment(simulator)
import StikJIT
#endif

#if targetEnvironment(simulator)
private struct DDIPaths {
    static func `default`(in directory: URL) -> DDIPaths { DDIPaths() }
}

private enum StikJIT {
    enum Script { case customBase64(String) }
    struct DeviceSecurityState { let isTXMPresent: Bool? }
    enum PreparationStage { case unavailable }
    enum JITReadiness {
        case unreachable(reason: String)
        case preparationFailed(reason: String)
        case ready(DeviceSecurityState)
    }

    static var isTXMPresent: Bool? { nil }
    static func prepareDevice(pairingFile: URL, paths: DDIPaths,
                              progress: (PreparationStage) -> Void) -> JITReadiness {
        .unreachable(reason: "Built-in JIT is available only on a physical device.")
    }
    static func enableJIT(targetPID: Int32, pairingFile: URL, ddiPaths: DDIPaths,
                          script: Script, forceScript: Bool,
                          preparationProgress: (PreparationStage) -> Void,
                          progress: (String) -> Void) throws {
        throw NSError(domain: "WindozJITHelper", code: 100,
                      userInfo: [NSLocalizedDescriptionKey:
                        "Built-in JIT is available only on a physical device."])
    }
    static func resetCachedDDI(at paths: DDIPaths) throws {}
}
#endif

private enum WindozJITWork {
    /// One request at a time, as the XPC handler ran them before.
    static let queue = DispatchQueue(label: "com.milifrr.windoz.jit-helper")

    static func handle(_ request: WindozJITRequest) -> WindozJITRequest.Response {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true,
                             message: "Developer Disk Image cache reset.",
                             txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "WindozJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file was not provided."])
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL, paths: paths,
                    progress: { NSLog("[WindozJIT] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready(let security):
                    return .init(success: true,
                                 message: "LocalDevVPN is reachable and the Developer Disk Image is ready.",
                                 txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason,
                                 txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false,
                                 message: "StikJIT returned an unknown preparation state.",
                                 txmPresent: StikJIT.isTXMPresent)
                }
            case .enable:
                guard let targetPID = request.targetPID,
                      let scriptBase64 = request.scriptBase64,
                      !scriptBase64.isEmpty else {
                    throw NSError(domain: "WindozJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "The target process or Windoz JIT script was not provided."])
                }
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    script: .customBase64(scriptBase64),
                    forceScript: true,
                    preparationProgress: {
                        NSLog("[WindozJIT] prepare: %@", String(describing: $0))
                    },
                    progress: { NSLog("[WindozJIT] %@", $0) })
                return .init(success: true,
                             message: "Windoz detached cleanly from its built-in JIT helper.",
                             txmPresent: StikJIT.isTXMPresent)
            case .resetDDI:
                preconditionFailure("Handled above")
            }
        } catch {
            return .init(success: false, message: error.localizedDescription,
                         txmPresent: StikJIT.isTXMPresent)
        }
    }
}

/// NSExtensionPrincipalClass (Info.plist). The request arrives as JSON in the first input
/// item; the response goes back as JSON in the item the request completes with. Enable
/// completes only when Windoz's script has detached, so the request, and this process,
/// last as long as the debugger does.
@objc(WindozJITHelperHandler)
final class WindozJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[WindozJITRequest.itemKey] as? Data
        WindozJITWork.queue.async {
            let response: WindozJITRequest.Response
            if let data, let request = try? JSONDecoder().decode(WindozJITRequest.self, from: data) {
                response = WindozJITWork.handle(request)
            } else {
                response = .init(success: false, message: "Windoz's JIT helper received no request.",
                                 txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [WindozJITRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
