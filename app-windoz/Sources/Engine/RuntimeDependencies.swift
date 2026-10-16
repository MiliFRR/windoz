import Foundation

/// A Windows runtime a game may need. Windoz never ships Microsoft's runtime
/// binaries in a redistributed form; it downloads them on-device from Microsoft
/// when the user asks, or relies on the ones the engine already stages into the
/// prefix.
enum RuntimeComponent: String, CaseIterable, Identifiable {
    case vcrun
    case dotnet
    case directx

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vcrun: return "Microsoft Visual C++ runtime"
        case .dotnet: return ".NET runtime"
        case .directx: return "DirectX (legacy D3DX)"
        }
    }

    var detail: String {
        switch self {
        case .vcrun:
            return "Most games need the VC++ 2015–2022 runtime. Windoz's engine already stages an x64 copy into a new prefix."
        case .dotnet:
            return "Only needed by games built on .NET (some indie and Unity titles)."
        case .directx:
            return "Only needed by very old games that use the D3DX helper libraries."
        }
    }

    /// Official Microsoft download, or nil when Microsoft publishes no stable
    /// direct link (the user then supplies the installer).
    var downloadURL: URL? {
        switch self {
        case .vcrun: return URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")
        case .dotnet: return URL(string: "https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe")
        case .directx: return nil
        }
    }

    /// Files that indicate the runtime is present in a prefix.
    var probeFiles: [String] {
        switch self {
        case .vcrun: return ["msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"]
        case .dotnet: return ["mscoree.dll"]
        case .directx: return ["d3dx9_43.dll", "d3dcompiler_47.dll"]
        }
    }
}

enum RuntimeState: Equatable {
    case unknown
    case present
    case missing
    case downloading(Double)
    case staged(String)
    case failed(String)

    var isSatisfied: Bool { if case .present = self { return true }; return false }
}

/// Detects and (where Microsoft permits a direct download) fetches the runtimes
/// a game may need. Installation into the prefix runs the vendor's own installer
/// through the engine, so it happens at first game launch; a download that is
/// only staged is reported honestly as "staged", never as "installed".
final class RuntimeInstaller: ObservableObject {
    static let shared = RuntimeInstaller()

    @Published private(set) var states: [RuntimeComponent: RuntimeState] = [:]

    private let staging = URL.documentsDirectory.appendingPathComponent("windoz-runtimes", isDirectory: true)

    func refresh(prefix: PrefixManager) {
        let system32 = prefix.windowsPath.appendingPathComponent("system32")
        let system32x86 = prefix.windowsPath.appendingPathComponent("syswow64")
        for component in RuntimeComponent.allCases {
            var found = false
            for file in component.probeFiles {
                if FileManager.default.fileExists(atPath: system32.appendingPathComponent(file).path)
                    || FileManager.default.fileExists(atPath: system32x86.appendingPathComponent(file).path) {
                    found = true
                    break
                }
            }
            if found {
                states[component] = .present
            } else if let staged = stagedPath(for: component) {
                states[component] = .staged(staged.lastPathComponent)
            } else {
                states[component] = .missing
            }
        }
    }

    private func stagedPath(for component: RuntimeComponent) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.lowercased().hasPrefix(component.rawValue) }
    }

    /// Queue the official installer download. Returns a plain-language result.
    @discardableResult
    func download(_ component: RuntimeComponent) -> String {
        guard let url = component.downloadURL else {
            states[component] = .failed("Microsoft publishes no stable direct link for this one. Download it on a PC and copy it into the game folder.")
            return "No direct official download is available for \(component.title)."
        }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            states[component] = .failed(error.localizedDescription)
            return "The download folder could not be created."
        }
        let ext = url.pathExtension.isEmpty ? "exe" : url.pathExtension
        let destination = staging.appendingPathComponent("\(component.rawValue)-installer.\(ext)")
        DownloadManager.shared.enqueue(title: component.title, url: url, destination: destination, storeID: "runtime")
        states[component] = .staged(destination.lastPathComponent)
        return "\(component.title) is downloading. Windoz will run the vendor's installer inside the Windows environment once a game session can be hosted — that is the remaining engine port."
    }
}
