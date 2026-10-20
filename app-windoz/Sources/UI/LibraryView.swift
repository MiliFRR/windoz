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

    @State private var query = ""
    @State private var filter: LibraryFilter = .all

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12)]

    /// One chip per shelf the library can be narrowed to. Everything else
    /// (search, count) is computed from `library.games`.
    private enum LibraryFilter: String, CaseIterable, Identifiable {
        case all, imported, steam, epic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .imported: return "Imported"
            case .steam: return "Steam"
            case .epic: return "Epic"
            }
        }
        var store: StoreID? {
            switch self {
            case .all: return nil
            case .imported: return .local
            case .steam: return .steam
            case .epic: return .epic
            }
        }
    }

    private var filteredGames: [InstalledGame] {
        var games = library.games
        if let store = filter.store {
            games = games.filter { $0.storeID == store.rawValue }
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            games = games.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
        }
        return games
    }

    var body: some View {
        let _ = BootTrace.once("library body")
        ZStack {
            ConsoleBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    gamesSection
                    storesSection
                }
                .padding(Metrics.pagePadding)
            }
        }
        .navigationTitle("Library")
        .searchable(text: $query, prompt: "Search games")
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
        .sheet(isPresented: $steamStore.showingSignIn) {
            SteamSignInView().presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $steamStore.showingLibrary) {
            SteamLibrarySheet(store: steamStore).presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $epicStore.showingSignIn) {
            EpicSignInSheet(store: epicStore).presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $epicStore.showingLibrary) {
            EpicSheet(store: epicStore).presentationDetents([.large]).presentationDragIndicator(.visible)
        }
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
        SectionHeader(title: "Games")
        if library.games.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing installed").font(.headline)
                    Text("Use the + button to import a game, or connect a store below.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else {
            filterRow
            let shown = filteredGames
            if shown.isEmpty {
                GlassCard {
                    Text("No games match. Clear the search or pick another filter.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(shown) { game in
                        Button { open(game) } label: { tile(game) }
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
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { option in
                    Button { filter = option } label: {
                        Chip(title: option.title, selected: filter == option)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(option.title) games")
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    private func tile(_ game: InstalledGame) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            CoverArtView(title: game.title, imagePath: game.coverArtPath)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
            Text(game.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(game.compatibility.title)
                .font(.caption2)
                .foregroundStyle(compatTint(game.compatibility))
                .lineLimit(1)
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
        Text("Steam signs in natively, installs owned games into the Windows environment, and shows each game's achievements and friends on its page. Epic signs in with a device code you approve on Epic's own site - no password ever touches the app - and its library uses the launcher sign-in. EA games that ship their own 64-bit executable can be added with Add EA game; EA Desktop itself cannot be installed because its official installer is 32-bit and this Windows layer is 64-bit-only. Rockstar's launcher pipeline is not in this build yet; the row says so.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    /// The per-store row button that opens the store's own sheet, when signing
    /// in bought one. Everything else keeps the plain Sign in / Sign out row.
    private func extraAction(for summary: StoreSummary) -> (title: String, symbol: String, handler: () -> Void)? {
        // EA's client is not installable here, but an EA game that ships its
        // own 64-bit executable is a normal local import. Give it a named
        // button instead of leaving the store row as a dead end.
        if summary.id == .ea {
            return ("Add EA game", "plus.circle.fill", { importing = true })
        }
        guard summary.authState.isSignedIn else { return nil }
        switch summary.id {
        case .steam:
            return ("Steam library", "books.vertical.fill", { steamStore.showingLibrary = true })
        case .epic:
            return ("Epic library", "books.vertical.fill", { epicStore.showingLibrary = true })
        default:
            return nil
        }
    }

    // MARK: - Import

    /// One push per tap: a second tap while the first push is animating could
    /// stack another game page on top of it.
    private func open(_ game: InstalledGame) {
        guard selection == nil else { return }
        selection = game
    }

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
    var extraAction: (title: String, symbol: String, handler: () -> Void)? = nil

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    StoreIcon(id: summary.id, size: 30)
                    Text(summary.title).font(.headline)
                    Spacer()
                    authBadge
                }
                Text(summary.summary)
                    .font(.footnote).foregroundStyle(.secondary)
                Text(capabilityLine)
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if let extraAction, summary.authState.isSignedIn || summary.id == .ea {
                        Button(action: extraAction.handler) {
                            Label(extraAction.title, systemImage: extraAction.symbol)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if summary.capability.signIn != .none, !summary.authState.isSignedIn {
                        Button("Sign in") { registry.signIn(summary.id) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    Spacer()
                    if summary.authState.isSignedIn {
                        // Sign-out lives one level down, under the ellipsis:
                        // easy to find when wanted, out of the way otherwise.
                        Menu {
                            Button("Sign out of \(summary.title)", role: .destructive) {
                                registry.signOut(summary.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.body)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(summary.title) account actions")
                    }
                }
            }
        }
    }

    private var capabilityLine: String {
        if summary.id == .ea {
            return "Local import only - EA Desktop is not installable in this 64-bit engine"
        }
        var parts = [summary.capability.library ? "Library" : "No library"]
        parts.append("Downloads: \(summary.capability.downloads.title)")
        if summary.capability.runtimeLauncherNeeded { parts.append("Launcher in Wine") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var authBadge: some View {
        if summary.id == .ea {
            Badge(text: "Import only", tint: .gray)
        } else {
            switch summary.authState {
            case .signedOut: Badge(text: "Signed out", tint: .gray)
            case .signingIn(let what): Badge(text: what, tint: Theme.accent)
            case .signedIn(let who): Badge(text: who, systemImage: "person.crop.circle", tint: Theme.ok)
            case .error(let why): Text(why).font(.caption2).foregroundStyle(Theme.warn).lineLimit(3)
            }
        }
    }
}
