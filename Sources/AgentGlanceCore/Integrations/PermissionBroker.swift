import Foundation

/// Um pedido de permissão à espera de resposta.
public struct PermissionRequest: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let tool: AgentTool
    public let cwd: String
    /// A ferramenta que o agente quer usar: Bash, Edit, WebFetch…
    public let toolName: String
    /// Uma linha legível: o comando, o ficheiro, o que for.
    public let summary: String
    /// O corpo por inteiro — comando, diff ou plano.
    public let detail: String?
    /// Verdadeiro quando o corpo é um plano e se lê como markdown.
    public let detailIsMarkdown: Bool
    /// As opções de "permitir sempre" que o diálogo do terminal mostraria.
    public let suggestions: [AnyCodable]
    public let createdAt: Date
    public let expiresAt: Date

    public var projectName: String { URL(fileURLWithPath: cwd).lastPathComponent }

    public init(
        id: String, sessionID: String, tool: AgentTool, cwd: String,
        toolName: String, summary: String, detail: String?, detailIsMarkdown: Bool,
        suggestions: [AnyCodable], createdAt: Date, expiresAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.tool = tool
        self.cwd = cwd
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
        self.detailIsMarkdown = detailIsMarkdown
        self.suggestions = suggestions
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// O que o utilizador decidiu.
public enum PermissionDecision: String, Codable, Sendable {
    case allow
    case allowAlways
    case deny
    /// Larga o pedido sem decidir: o diálogo normal aparece no terminal.
    case defer_ = "defer"
}

/// Caixa para JSON de forma arbitrária — as `permission_suggestions` do Claude
/// Code têm forma livre e são para ecoar de volta tal e qual, não para
/// interpretar.
public struct AnyCodable: Codable, Equatable, Sendable {
    public let value: Data

    public init(_ json: Any) {
        value = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("null".utf8)
    }

    public init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(Data.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var jsonObject: Any? {
        try? JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])
    }
}

/// O canal entre o processo do hook e a app.
///
/// O AgentGlance não tinha nada neste sentido: o `StateChangeNotifier` é uma
/// notificação Darwin sem payload e estritamente unidirecional — quem escreve
/// estado avisa, a app ouve. Para uma decisão é preciso o contrário, e é isso
/// que isto acrescenta.
///
/// O desenho segue o precedente do `saveEnrichment`, onde a app já escreve um
/// sidecar sobre um documento que pertence à integração: dois ficheiros por
/// pedido, num diretório próprio, com escrita atómica por tmp+rename. Nada de
/// sockets nem portas — mantém-se o idioma da casa e sobrevive a reinícios da
/// app sem deixar o agente pendurado.
public struct PermissionBroker: Sendable {

    public static let directoryName = "decisions"

    private let directory: URL

    public init(stateDirectory: URL) {
        directory = stateDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private func requestURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).request.json")
    }

    private func replyURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).reply.json")
    }

    public func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - Lado do hook

    /// Publica o pedido e espera pela decisão.
    ///
    /// Bloqueia o processo do hook, que é exatamente o que faz o Claude Code
    /// esperar. O prazo é a rede de segurança: passado ele, devolve `defer_` e
    /// o diálogo normal aparece no terminal. Nunca se deixa um agente parado à
    /// espera de uma app que pode nem estar a correr.
    public func submitAndWait(_ request: PermissionRequest, pollInterval: TimeInterval = 0.1) throws -> PermissionDecision {
        try prepareDirectory()
        let data = try JSONEncoder.agentGlance.encode(request)
        try writeAtomically(data, to: requestURL(request.id))
        StateChangeNotifier.post()

        defer { cleanUp(request.id) }

        while Date() < request.expiresAt {
            if let decision = readReply(request.id) { return decision }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return .defer_
    }

    private func readReply(_ id: String) -> PermissionDecision? {
        guard let data = try? Data(contentsOf: replyURL(id)),
              let reply = try? JSONDecoder.agentGlance.decode(Reply.self, from: data)
        else { return nil }
        return reply.decision
    }

    private func cleanUp(_ id: String) {
        try? FileManager.default.removeItem(at: requestURL(id))
        try? FileManager.default.removeItem(at: replyURL(id))
    }

    // MARK: - Lado da app

    /// Os pedidos por responder, os mais antigos primeiro.
    ///
    /// Pedidos cujo prazo já passou são varridos: pertencem a hooks que já
    /// desistiram, e mostrá-los seria oferecer uma decisão que não chega a
    /// lado nenhum.
    public func pendingRequests(now: Date = Date()) -> [PermissionRequest] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }

        var requests: [PermissionRequest] = []
        for name in names where name.hasSuffix(".request.json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder.agentGlance.decode(PermissionRequest.self, from: data)
            else { continue }
            if request.expiresAt <= now {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            requests.append(request)
        }
        return requests.sorted { $0.createdAt < $1.createdAt }
    }

    /// Responde. O hook está a sondar e apanha isto dentro de uma centena de
    /// milissegundos.
    public func reply(to id: String, decision: PermissionDecision) throws {
        try prepareDirectory()
        let data = try JSONEncoder.agentGlance.encode(Reply(decision: decision))
        try writeAtomically(data, to: replyURL(id))
    }

    private struct Reply: Codable {
        let decision: PermissionDecision
    }

    // MARK: - Escrita

    /// tmp + rename, como o resto do estado: um leitor nunca apanha metade de
    /// um ficheiro.
    private func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

// MARK: - Codificação

extension JSONEncoder {
    static let agentGlance: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let agentGlance: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
