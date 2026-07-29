import Foundation
import Observation
import Darwin
import CoreFoundation

public struct StateObservationLayers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let darwinNotification = StateObservationLayers(rawValue: 1 << 0)
    public static let fileSystem = StateObservationLayers(rawValue: 1 << 1)
    public static let polling = StateObservationLayers(rawValue: 1 << 2)
    public static let all: StateObservationLayers = [
        .darwinNotification,
        .fileSystem,
        .polling,
    ]
}

private let stateStoreNotificationCallback: CFNotificationCallback = {
    _, observer, _, _, _ in
    guard let observer else { return }
    let store = Unmanaged<StateStore>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async { store.scheduleCoalescedReload() }
}

@Observable
public final class StateStore {
    public private(set) var sessions: [AgentSession] = []
    public private(set) var lastErrorDescription: String?
    public private(set) var acknowledgments = AttentionAcknowledgments()
    /// Pedidos de permissão à espera de resposta tua.
    ///
    /// Do outro lado de cada um está um processo de hook bloqueado, e com ele
    /// o agente. Por isso isto é lido no mesmo ciclo que as sessões: chegam
    /// pela mesma notificação e pelo mesmo observador de diretório.
    public private(set) var pendingDecisions: [PermissionRequest] = []
    public private(set) var nameOverrides = SessionNameOverrides()

    /// Invoked from `reload()` with the sessions that just transitioned into
    /// `.needsAttention` — at most once per reload, never on the baseline
    /// load. The app layer hangs the alert chime on it.
    public var onAttentionRaised: (([AgentSession]) -> Void)?

    /// Invoked from `reload()` with the sessions that just went from
    /// `.working` to `.idle` — the agent handed the conversation back. A
    /// session born idle, or leaving `.needsAttention` (the user was already
    /// interacting), announces nothing.
    public var onTurnCompleted: (([AgentSession]) -> Void)?

    private let repository: StateRepository
    private let nameOverridesFileURL: URL?
    // nil until the first reload establishes the baseline.
    private var previousStatusesBySessionID: [String: SessionStatus]?
    private var pollingTimer: Timer?
    private var directorySource: DispatchSourceFileSystemObject?
    private var observesDarwinNotifications = false
    private var isObserving = false
    private var observationGeneration = 0
    private var reloadScheduled = false

    /// The overrides file must live outside the repository's directory: the
    /// store watches that directory for session changes, and the repository
    /// decode-attempts every `.json` in it.
    public init(repository: StateRepository, nameOverridesFileURL: URL? = nil) {
        self.repository = repository
        self.nameOverridesFileURL = nameOverridesFileURL
        if let nameOverridesFileURL,
           let data = try? Data(contentsOf: nameOverridesFileURL),
           let stored = try? JSONDecoder().decode(SessionNameOverrides.self, from: data) {
            nameOverrides = stored
        }
    }

    /// Focus resolves against the latest on-disk lifecycle and enrichment,
    /// rather than the value captured when SwiftUI rendered a row.
    public var stateDirectoryURL: URL { repository.directoryURL }

    public var pendingDecision: PermissionRequest? { pendingDecisions.first }
    public var hasPendingDecision: Bool { !pendingDecisions.isEmpty }

    // MARK: - Sessões remotas

    /// Diretorios de estado adicionais — tipicamente um `~/.pulse/state`
    /// remoto montado por SSHFS ou sincronizado (ver scripts/pulse-remote.sh).
    ///
    /// É o "agentes em servidores remotos" feito à maneira da casa: o
    /// protocolo inteiro já era ficheiros com escrita atómica, e ficheiros
    /// montam-se. As sessões de lá aparecem aqui; as aprovações escrevem-se
    /// no MESMO diretório e o hook remoto apanha-as quando o sync as levar.
    /// A reconexão automática pertence ao transporte (sshfs -o reconnect, ou
    /// o loop do script), não a esta app — cada um faz o seu ofício.
    public static let remoteDirectoriesKey = "remoteStateDirs"

    private var remoteRepositories: [StateRepository] {
        let raw = UserDefaults.standard.stringArray(forKey: Self.remoteDirectoriesKey) ?? []
        return raw
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty }
            .map { StateRepository(directoryURL: URL(fileURLWithPath: $0, isDirectory: true)) }
    }

    /// Ids das sessões vindas de diretórios remotos — as linhas usam isto para
    /// o distintivo e para não prometer um salto de foco que não existe cá.
    public private(set) var remoteSessionIDs: Set<String> = []

    /// Perguntas do agente em curso — as opções do AskUserQuestion, para o
    /// cartão ⌘1/⌘2/⌘3.
    public private(set) var pendingQuestions: [AgentQuestion] = []

    /// De que diretório veio cada pedido pendente: a resposta tem de voltar
    /// para o MESMO sítio, senão o hook remoto nunca a vê.
    private var pendingDecisionOrigins: [String: URL] = [:]

    public func isRemote(_ session: AgentSession) -> Bool {
        remoteSessionIDs.contains(session.id)
    }

    private var broker: PermissionBroker { PermissionBroker(stateDirectory: repository.directoryURL) }

    /// O registo do que decidiste, ao lado do diretório de estado e nunca lá
    /// dentro — a mesma razão dos nomes das sessões: este store observa esse
    /// diretório, e escrever nele a cada decisão punha-o a recarregar por causa
    /// da própria escrita.
    ///
    /// Derivado do repositório em vez de injetado como o `nameOverridesFileURL`:
    /// aquele é uma escolha da app, este é uma consequência de `decide` — se
    /// fosse opcional, bastava alguém esquecer-se de o passar para as decisões
    /// deixarem de deixar rasto sem ninguém dar por isso.
    private var decisionLog: DecisionLog {
        DecisionLog(
            fileURL: repository.directoryURL
                .deletingLastPathComponent()
                .appendingPathComponent(DecisionLog.fileName)
        )
    }

    /// Responde ao pedido. O hook está a sondar e apanha isto em menos de um
    /// décimo de segundo.
    public func decide(_ request: PermissionRequest, _ decision: PermissionDecision) {
        // A resposta volta para o diretório de onde o pedido veio — num pedido
        // remoto, é o sync que a leva até ao hook do outro lado.
        let origin = pendingDecisionOrigins[request.id] ?? repository.directoryURL
        try? PermissionBroker(stateDirectory: origin).reply(to: request.id, decision: decision)
        decisionLog.record(request, decision)
        pendingDecisions.removeAll { $0.id == request.id }
    }

    /// Tira a pergunta do ecrã e do disco — respondida daqui, o PostToolUse
    /// só viria confirmar o que já se sabe.
    public func dismissQuestion(_ question: AgentQuestion) {
        QuestionBox(stateDirectory: repository.directoryURL)
            .clear(sessionID: question.sessionID)
        pendingQuestions.removeAll { $0.sessionID == question.sessionID }
    }

    /// As últimas decisões, para o histórico do painel.
    ///
    /// Passa pelo store para que a interface não tenha de saber onde o ficheiro
    /// mora — quem sabe onde vive o estado é quem o guarda.
    public func recentDecisions(limit: Int = 12) -> [DecisionRecord] {
        decisionLog.recent(limit: limit)
    }

    /// Reloading is strictly a read: ended sessions are filtered from the UI
    /// but their files stay on disk for the reaper to delete on its own
    /// queue. A reload that writes would re-trigger this store's directory
    /// observation and feed back into itself.
    public func reload() throws {
        // Os pedidos chegam pelo mesmo ciclo que as sessões: o hook faz post na
        // notificação Darwin depois de escrever, e o observador de diretório
        // apanha o ficheiro. Não é preciso um segundo mecanismo.
        var decisions = broker.pendingRequests()
        var origins: [String: URL] = [:]
        for request in decisions { origins[request.id] = repository.directoryURL }

        var merged = try repository.loadSessions()
        var remoteIDs: Set<String> = []
        for remote in remoteRepositories {
            // Um remoto avariado (montagem caída, sync parado) não pode
            // derrubar a lista local: o que se perde é a visibilidade DELE.
            guard let sessions = try? remote.loadSessions() else { continue }
            for session in sessions {
                merged.append(session)
                remoteIDs.insert(session.id)
            }
            let remoteBroker = PermissionBroker(stateDirectory: remote.directoryURL)
            for request in remoteBroker.pendingRequests() {
                decisions.append(request)
                origins[request.id] = remote.directoryURL
            }
        }
        pendingDecisions = decisions
        pendingQuestions = QuestionBox(
            stateDirectory: repository.directoryURL).pending()
        pendingDecisionOrigins = origins
        remoteSessionIDs = remoteIDs
        sessions = merged
            .filter { $0.status != .ended }
            .sorted(by: Self.precedes)
        acknowledgments.prune(keeping: sessions)
        raiseStatusTransitions()
        let prunedOverrides = {
            var overrides = nameOverrides
            overrides.prune(keeping: sessions)
            return overrides
        }()
        if prunedOverrides != nameOverrides {
            nameOverrides = prunedOverrides
            persistNameOverrides()
        }
    }

    public func sessions(for tool: AgentTool) -> [AgentSession] {
        sessions.filter { $0.tool == tool }
    }

    /// Marks a waiting session as visited so the bar semaphore goes quiet
    /// until the session shows new activity.
    public func acknowledge(_ session: AgentSession) {
        acknowledgments.acknowledge(session)
    }

    /// Renames a session for display; a blank name restores the project name.
    public func rename(_ session: AgentSession, to name: String) {
        nameOverrides.rename(session, to: name)
        persistNameOverrides()
    }

    /// Row title precedence: a manual rename always wins, then the cleaned
    /// live tab title (the reaper refreshes `windowTitleHint` from the
    /// Ghostty scan each tick), then the directory name.
    private func raiseStatusTransitions() {
        let statusesBySessionID = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, $0.status) }
        )
        defer { previousStatusesBySessionID = statusesBySessionID }
        guard let previousStatusesBySessionID else { return }
        let newlyRaised = sessions.filter {
            $0.status == .needsAttention
                && previousStatusesBySessionID[$0.id] != .needsAttention
        }
        if !newlyRaised.isEmpty {
            onAttentionRaised?(newlyRaised)
        }
        let newlyCompleted = sessions.filter {
            $0.status == .idle && previousStatusesBySessionID[$0.id] == .working
        }
        if !newlyCompleted.isEmpty {
            onTurnCompleted?(newlyCompleted)
        }
    }

    /// Drops every custom session name, in memory and on disk — the reset
    /// offered from Settings.
    public func clearAllSessionNames() {
        nameOverrides = SessionNameOverrides()
        persistNameOverrides()
    }

    public func displayName(for session: AgentSession) -> String {
        nameOverrides.displayName(for: session)
            ?? SessionTitleFormatter.rowTitle(
                tabTitle: session.terminal.windowTitleHint,
                fallback: session.projectName
            )
    }

    /// Persistence failures only cost the custom names on the next launch;
    /// they must never take down reload or rename, so they are logged and
    /// swallowed here.
    private func persistNameOverrides() {
        guard let nameOverridesFileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(nameOverrides).write(to: nameOverridesFileURL, options: .atomic)
        } catch {
            NSLog(
                "Pulse could not persist session names: %@",
                String(describing: error)
            )
        }
    }

    public func startObserving(
        pollInterval: TimeInterval? = 5,
        layers: StateObservationLayers = .all
    ) throws {
        stopObserving()
        try repository.prepareDirectory()
        isObserving = true
        do {
            // Arm event capture before reading the baseline. A write during
            // that read is then either present in the snapshot or schedules a
            // follow-up reload; there is no unobserved gap between the two.
            if layers.contains(.darwinNotification) {
                startDarwinObservation()
            }
            if layers.contains(.fileSystem) {
                try startDirectoryObservation()
            }
            try reload()
            if layers.contains(.polling), let pollInterval {
                let pollingGeneration = observationGeneration
                let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
                    [weak self] _ in
                    guard let self,
                          self.isObserving,
                          self.observationGeneration == pollingGeneration else { return }
                    self.reloadRecordingError()
                }
                // Polling is only a safety net behind the event-driven layers;
                // tolerance lets the kernel coalesce the wakeup with other timers.
                timer.tolerance = pollInterval / 5
                pollingTimer = timer
            }
        } catch {
            stopObserving()
            throw error
        }
    }

    public func stopObserving() {
        observationGeneration += 1
        isObserving = false
        reloadScheduled = false
        pollingTimer?.invalidate()
        pollingTimer = nil
        directorySource?.cancel()
        directorySource = nil
        if observesDarwinNotifications {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(StateChangeNotifier.notificationName as CFString),
                nil
            )
            observesDarwinNotifications = false
        }
    }

    private func startDarwinObservation() {
        guard !observesDarwinNotifications else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            stateStoreNotificationCallback,
            StateChangeNotifier.notificationName as CFString,
            nil,
            .deliverImmediately
        )
        observesDarwinNotifications = true
    }

    private func startDirectoryObservation() throws {
        guard directorySource == nil else { return }
        let descriptor = Darwin.open(repository.directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleCoalescedReload() }
        source.setCancelHandler { Darwin.close(descriptor) }
        directorySource = source
        source.resume()
    }

    /// Coalesces bursts of directory events into one reload per 150ms window
    /// so that an aggressive writer — another process, or a misbehaving
    /// integration — can never storm the main thread with reloads.
    fileprivate func scheduleCoalescedReload() {
        guard isObserving, !reloadScheduled else { return }
        reloadScheduled = true
        let scheduledGeneration = observationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  self.isObserving,
                  self.observationGeneration == scheduledGeneration else { return }
            self.reloadScheduled = false
            self.reloadRecordingError()
        }
    }

    package func reloadRecordingError() {
        do {
            try reload()
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = String(describing: error)
        }
    }

    private static func precedes(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        let rank: [SessionStatus: Int] = [.needsAttention: 0, .working: 1, .idle: 2, .ended: 3]
        let leftRank = rank[lhs.status, default: 3]
        let rightRank = rank[rhs.status, default: 3]
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}
