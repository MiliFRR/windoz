import Foundation
import Combine

/// A value snapshot of a provider, so views can render stores without holding an
/// existential object. The registry republishes whenever any provider changes.
struct StoreSummary: Identifiable, Equatable {
    var id: StoreID
    var title: String
    var symbolName: String
    var summary: String
    var capability: StoreCapability
    var authState: StoreAuthState
}

/// The set of stores Windoz knows about. Adding a store is one line here.
///
/// The concrete providers are held directly (not only as existentials) so the
/// registry can observe each one's `objectWillChange` with a concrete type and
/// republish a flat value snapshot for the UI.
final class StoreRegistry: ObservableObject {
    static let shared = StoreRegistry()

    @Published private(set) var summaries: [StoreSummary] = []

    let local = LocalFolderStore()
    let steam = SteamStore()
    let epic = EpicStore()
    let gog = GOGStore()
    let rockstar = LauncherInWineStore(
        id: .rockstar,
        launcherName: "Rockstar Games Launcher",
        installerURL: URL(string: "https://socialclub.rockstargames.com/rockstar-games-launcher"))
    let ea = LauncherInWineStore(id: .ea, launcherName: "EA app", installerURL: nil)

    private var cancellables: [AnyCancellable] = []

    private init() {
        for publisher in [local.objectWillChange.eraseToAnyPublisher(),
                          steam.objectWillChange.eraseToAnyPublisher(),
                          epic.objectWillChange.eraseToAnyPublisher(),
                          gog.objectWillChange.eraseToAnyPublisher(),
                          rockstar.objectWillChange.eraseToAnyPublisher(),
                          ea.objectWillChange.eraseToAnyPublisher()] {
            publisher
                .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }
                .store(in: &cancellables)
        }
        rebuild()
    }

    /// Every provider, as the protocol the rest of the app sees.
    var providers: [StoreProvider] { [local, steam, epic, gog, rockstar, ea] }

    private func rebuild() {
        summaries = providers.map { provider in
            StoreSummary(id: provider.id,
                         title: provider.id.title,
                         symbolName: provider.id.symbolName,
                         summary: provider.capability.summary,
                         capability: provider.capability,
                         authState: provider.authState)
        }
    }

    func provider(_ id: StoreID) -> StoreProvider? {
        providers.first { $0.id == id }
    }

    func signIn(_ id: StoreID) {
        guard let provider = provider(id) else { return }
        Task { await provider.signIn() }
    }

    func signOut(_ id: StoreID) {
        provider(id)?.signOut()
    }
}
