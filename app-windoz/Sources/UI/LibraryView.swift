import SwiftUI
import UniformTypeIdentifiers

/// The library: every installed game plus the store connections.
struct LibraryView: View {
    @EnvironmentObject private var library: GameLibrary
    @State private var importing = false
    @State private var importMessage: String?
    @State private var selection: InstalledGame?

    @ObservedObject private var registry = StoreRegistry.shared
    @ObservedObject private var steamStore = StoreRegistry.shared.steam
    @ObservedObject private var epicStore = StoreRegistry.shared.epic

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        let _ = BootTrace.once("library body")
        ZStack {
            ConsoleBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    gamesSection
                    storesSection
                }
                .padding(20)
            }
        }
        .navigationTitle("Library")
        .navigationDestination(item: $selection) { GameDetailView(gameID: $0.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { importing = true } label: { Label("Add game", systemImage: "plus") }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert("Add game", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } })
        ) {
            Button("OK") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
        .sheet(isPresented: $steamStore.showingSignIn) { SteamSignInView() }
        .sheet(isPresented: $steamStore.showingLibrary) { SteamLibrarySheet(store: steamStore) }
        .sheet(isPresented: $epicStore.showingSignIn) { EpicSignInSheet(store: epicStore) }
        .sheet(isPresented: $epicStore.showingLibrary) { EpicSheet(store: epicStore) }
        .task {
            BootTrace.mark("library task: steamStore.start()")
            steamStore.start()
            BootTrace.mark("library task: epicStore.start()")
            epicStore.start()
            BootTrace.mark("library task: done")
        }
    }

    // MARK: - Games

    @ViewBuilder private var gamesSection: some View {
        SectionHeader(title: "My games")
        if library.games.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing installed").font(.headline).foregroundStyle(.white)
                    Text("Use the + button to import a game, or connect a store below.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.6))
                }
            }
        } else {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(library.games) { game in
                    Button { selection = game } label: { tile(game) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                library.remove(id: game.id)
                            } label: { Label("Remove from library", systemImage: "trash") }
                        }
                }
            }
        }
    }

    private func tile(_ game: InstalledGame) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverArtView(title: game.title, imagePath: game.coverArtPath)
                .frame(height: 200)
            Text(game.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            HStack(spacing: 6) {
                Badge(text: game.compatibility.title, tint: compatTint(game.compatibility))
                if let ac = game.antiCheat {
                    Badge(text: ac.kind.title, systemImage: "shield.lefthalf.filled", tint: Theme.warn)
                }
            }
        }
    }

    // MARK: - Stores

    @ViewBuilder private var storesSection: some View {
        let _ = BootTrace.once("library stores section")
        SectionHeader(title: "Stores")
        ForEach(registry.summaries) { summary in
            StoreRow(summary: summary, registry: registry,
                     extraAction: extraAction(for: summary))
        }
        Text("Windoz uses your own accounts with each store and follows their terms. Steam signs in natively (password + Steam Guard or a QR code) and downloads owned depots into the Windows prefix. Epic signs in with a device code — you approve it on Epic's own site, no password ever typed into the app — and lists your owned library; its chunked downloads are the next piece. The remaining stores are meant to run the vendor's official launcher inside Wine once the game-session host is ported; until then they report themselves as not implemented.")
            .font(.caption2).foregroundStyle(.white.opacity(0.4))
    }

    /// The per-store row button that opens the store's own sheet, when signing
    /// in bought one. Everything else keeps the plain Sign in / Sign out row.
    private func extraAction(for summary: StoreSummary) -> (title: String, handler: () -> Void)? {
        guard summary.authState.isSignedIn else { return nil }
        switch summary.id {
        case .steam:
            return (title: "Steam library", handler: { steamStore.showingLibrary = true })
        case .epic:
            return (title: "Epic library", handler: { epicStore.showingLibrary = true })
        default:
            return nil
        }
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let game = try importGame(from: url)
                importMessage = "Added \(game.title).\(game.antiCheat.map { " \($0.kind.title) detected — see the game page." } ?? "")"
            } catch {
                importMessage = error.localizedDescription
            }
        }
    }

    private func importGame(from url: URL) throws -> InstalledGame {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDirectory)

        // Copy the game's folder into the app container so it is not tied to the
        // Files provider's security scope.
        let sourceFolder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        let imported = AppContainer.importedGames
        try fm.createDirectory(at: imported, withIntermediateDirectories: true)
        var destination = imported.appendingPathComponent(sourceFolder.lastPathComponent, isDirectory: true)
        var suffix = 1
        while fm.fileExists(atPath: destination.path) {
            destination = imported.appendingPathComponent("\(sourceFolder.lastPathComponent)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fm.copyItem(at: sourceFolder, to: destination)

        let executable: URL
        if isDirectory.boolValue {
            executable = try findExecutable(in: destination)
        } else {
            executable = destination.appendingPathComponent(url.lastPathComponent)
        }
        return try LocalFolderStore().importExecutable(at: executable)
    }

    private func findExecutable(in folder: URL) throws -> URL {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else {
            throw StoreError.network("The folder could not be read.")
        }
        var first: URL?
        for case let item as URL in enumerator where item.pathExtension.lowercased() == "exe" {
            first = first ?? item
            if item.deletingPathExtension().lastPathComponent.lowercased() == folder.lastPathComponent.lowercased() {
                return item
            }
        }
        if let first { return first }
        throw StoreError.network("No .exe was found in that folder.")
    }

    private func compatTint(_ status: CompatibilityStatus) -> Color {
        switch status {
        case .verified: return Theme.ok
        case .playable: return Theme.accent
        case .runsPoorly: return Theme.warn
        case .unsupported: return Theme.bad
        case .unknown: return .gray
        }
    }
}

/// One store row: what it supports, and its sign-in state.
struct StoreRow: View {
    let summary: StoreSummary
    let registry: StoreRegistry
    /// A store-specific action (e.g. "Steam library") shown next to sign-in.
    var extraAction: (title: String, handler: () -> Void)? = nil

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: summary.symbolName)
                        .foregroundStyle(Theme.accent)
                    Text(summary.title).font(.headline).foregroundStyle(.white)
                    Spacer()
                    authBadge
                }
                Text(summary.summary)
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 8) {
                    Badge(text: "Library", systemImage: "books.vertical",
                          tint: summary.capability.library ? Theme.ok : .gray)
                    Badge(text: "Downloads: \(summary.capability.downloads.title)",
                          systemImage: "arrow.down.circle",
                          tint: summary.capability.downloads == .native ? Theme.ok : Theme.warn)
                    if summary.capability.runtimeLauncherNeeded {
                        Badge(text: "Launcher in Wine", systemImage: "shippingbox", tint: Theme.warn)
                    }
                }
                HStack(spacing: 16) {
                    if summary.capability.signIn != .none {
                        Button(summary.authState.isSignedIn ? "Sign out" : "Sign in") {
                            if summary.authState.isSignedIn { registry.signOut(summary.id) }
                            else { registry.signIn(summary.id) }
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    if let extraAction {
                        Button(extraAction.title, action: extraAction.handler)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }

    @ViewBuilder private var authBadge: some View {
        switch summary.authState {
        case .signedOut: Badge(text: "Signed out", tint: .gray)
        case .signingIn(let what): Badge(text: what, tint: Theme.accent)
        case .signedIn(let who): Badge(text: who, systemImage: "person.crop.circle", tint: Theme.ok)
        case .error(let why): Text(why).font(.caption2).foregroundStyle(Theme.warn).lineLimit(3)
        }
    }
}
