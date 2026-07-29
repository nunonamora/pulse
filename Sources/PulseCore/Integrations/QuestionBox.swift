import Foundation

/// Uma pergunta do agente, com as opções, à espera de resposta.
///
/// A peça central do Vibe Island — as escolhas do `AskUserQuestion` como
/// linhas ⌘1/⌘2/⌘3 no notch — vista na página deles e reconstruída sobre o
/// nosso canal: o `PreToolUse` traz a pergunta e as opções, o `PostToolUse`
/// diz que foi respondida (aqui ou no terminal, tanto faz — o cartão sai),
/// e escolher uma opção é o ReplyService a escrever o número no painel.
public struct AgentQuestion: Codable, Equatable, Sendable {
    public let sessionID: String
    public let tool: AgentTool
    public let question: String
    public let options: [String]
    public let askedAt: Date

    public init(sessionID: String, tool: AgentTool, question: String,
                options: [String], askedAt: Date) {
        self.sessionID = sessionID
        self.tool = tool
        self.question = question
        self.options = options
        self.askedAt = askedAt
    }
}

/// Persistência das perguntas em curso — um ficheiro por sessão, no mesmo
/// idioma do resto do estado: JSON atómico num subdiretório privado.
public struct QuestionBox: Sendable {
    public static let directoryName = "questions"
    private let directory: URL

    public init(stateDirectory: URL) {
        directory = stateDirectory.appendingPathComponent(
            Self.directoryName, isDirectory: true)
    }

    public func post(_ question: AgentQuestion) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(question)
        let final = url(for: question.sessionID)
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temporary, options: [])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(final, withItemAt: temporary)
    }

    public func clear(sessionID: String) {
        try? FileManager.default.removeItem(at: url(for: sessionID))
    }

    public func pending(now: Date = Date(), maxAge: TimeInterval = 3600) -> [AgentQuestion] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(AgentQuestion.self, from: Data(contentsOf: $0)) }
            // Uma pergunta de há uma hora já foi respondida no terminal ou
            // morreu com a sessão; mostrá-la seria assombrar.
            .filter { now.timeIntervalSince($0.askedAt) < maxAge }
            .sorted { $0.askedAt < $1.askedAt }
    }

    private func url(for sessionID: String) -> URL {
        let safe = Data(sessionID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent("\(safe).json")
    }
}
