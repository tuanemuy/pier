import CitadelAdapter
import Foundation
import KeychainAdapter
import Observation
import PersistenceAdapter
import PierApplication
import PierDomain

@MainActor @Observable
final class AppContainer {
    let transport: any TransportPort & FileTransferPort
    let logger: any PierLogger
    let terminalStore: TerminalStore
    private let gateway: TmuxGateway
    let sessionCoordinator: SessionCoordinator
    let clock: any Clock
    let identifierGenerator: any IdentifierGenerator
    let remoteFileEditor: any RemoteFileEditor
    let settings: AppSettings
    let listHosts: ListHosts
    let resolveHost: ResolveHost
    let registerHost: RegisterHost
    let removeHost: RemoveHost
    let listKeys: ListKeys
    let generateKey: GenerateKey
    let renameKey: RenameKey
    let removeKey: RemoveKey

    init(
        hostRepository: any HostRepositoryPort,
        keyStore: any KeyStorePort,
        transport: any TransportPort & FileTransferPort,
        logger: any PierLogger,
        clock: any Clock,
        identifierGenerator: any IdentifierGenerator,
        commandJournal: any CommandJournalPort = NullCommandJournal(),
        remoteFileEditor: any RemoteFileEditor
    ) {
        self.transport = transport
        self.logger = logger
        self.clock = clock
        self.identifierGenerator = identifierGenerator
        self.remoteFileEditor = remoteFileEditor
        listHosts = ListHosts(repository: hostRepository)
        resolveHost = ResolveHost(repository: hostRepository)
        registerHost = RegisterHost(repository: hostRepository)
        removeHost = RemoveHost(repository: hostRepository)
        listKeys = ListKeys(keyStore: keyStore)
        generateKey = GenerateKey(keyStore: keyStore)
        renameKey = RenameKey(keyStore: keyStore)
        removeKey = RemoveKey(keyStore: keyStore)
        terminalStore = TerminalStore()
        gateway = TmuxGateway(transport: transport, renderer: terminalStore, logger: logger)
        sessionCoordinator = SessionCoordinator(
            gateway: gateway,
            clock: clock,
            identifierGenerator: identifierGenerator,
            logger: logger,
            commandJournal: commandJournal
        )
        settings = AppSettings()
    }

    static func live() -> AppContainer {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pier")
        let keys = SecureEnclaveKeyStore()
        let knownHosts = KnownHostStore()
        let repository: any HostRepositoryPort
        do {
            repository = try PersistenceFactory.live()
        } catch {
            repository = FileHostRepository(fileURL: root.appending(path: "hosts.json"))
        }
        let transport = CitadelTransport(
            keyProvider: { id in try await keys.signingCapability(using: id) },
            hostKeyVerifier: { host, key in try await knownHosts.verify(host: host, key: key) }
        )
        return AppContainer(
            hostRepository: repository,
            keyStore: keys,
            transport: transport,
            logger: SystemLogger(),
            clock: SystemClock(),
            identifierGenerator: SystemIdentifierGenerator(),
            commandJournal: FileCommandJournal(fileURL: root.appending(path: "command-journal.json")),
            remoteFileEditor: LiveRemoteFileEditor(transfer: transport)
        )
    }

    static func preview() -> AppContainer {
        let hosts: [PierDomain.Host] = switch PierDomain.Host.parse(
            id: HostID(rawValue: "preview"),
            name: "Preview Server",
            address: "preview.local",
            username: "pier",
            keyID: KeyID(rawValue: "preview")
        ) {
        case let .success(host):
            [host]
        case .failure:
            []
        }
        return AppContainer(
            hostRepository: InMemoryHostRepository(hosts: hosts),
            keyStore: InMemoryKeyStore(),
            transport: PreviewTransport(files: ["/tmp/example.txt": Data("日本語を編集できます。\n".utf8)]),
            logger: RecordingLogger(),
            clock: SystemClock(),
            identifierGenerator: SystemIdentifierGenerator(),
            commandJournal: InMemoryCommandJournal(),
            remoteFileEditor: InMemoryRemoteFileEditor(files: ["/tmp/example.txt": "日本語を編集できます。\n"])
        )
    }

    static func test(_ dependencies: AppContainerTestDependencies) -> AppContainer {
        AppContainer(
            hostRepository: dependencies.hostRepository,
            keyStore: dependencies.keyStore,
            transport: dependencies.transport,
            logger: RecordingLogger(),
            clock: dependencies.clock,
            identifierGenerator: dependencies.identifierGenerator,
            commandJournal: dependencies.commandJournal,
            remoteFileEditor: dependencies.remoteFileEditor
        )
    }
}

struct AppContainerTestDependencies {
    let hostRepository: any HostRepositoryPort
    let keyStore: any KeyStorePort
    let transport: any TransportPort & FileTransferPort
    let clock: any Clock
    let identifierGenerator: any IdentifierGenerator
    let commandJournal: any CommandJournalPort
    let remoteFileEditor: any RemoteFileEditor

    init(
        hostRepository: any HostRepositoryPort,
        keyStore: any KeyStorePort,
        transport: any TransportPort & FileTransferPort,
        clock: any Clock,
        identifierGenerator: any IdentifierGenerator,
        commandJournal: any CommandJournalPort = InMemoryCommandJournal(),
        remoteFileEditor: any RemoteFileEditor
    ) {
        self.hostRepository = hostRepository
        self.keyStore = keyStore
        self.transport = transport
        self.clock = clock
        self.identifierGenerator = identifierGenerator
        self.commandJournal = commandJournal
        self.remoteFileEditor = remoteFileEditor
    }
}
