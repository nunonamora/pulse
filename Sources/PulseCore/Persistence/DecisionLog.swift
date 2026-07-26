import Foundation

/// Uma decisão tua, tal como ficou escrita.
///
/// É uma cópia e não uma referência ao pedido: o `PermissionRequest` original é
/// apagado do disco pelo hook mal recebe a resposta, e um registo que apontasse
/// para ele ficava a apontar para nada segundos depois. Por isso guarda já o
/// nome do projeto resolvido — quem lê o ficheiro daqui a uma semana não tem
/// como voltar a resolvê-lo.
public struct DecisionRecord: Codable, Identifiable, Equatable, Sendable {
    /// O identificador do pedido que a originou: é único e serve de chave para
    /// cruzar uma linha do registo com o que os logs do agente dizem dela.
    public let id: String
    public let sessionID: String
    public let tool: AgentTool
    public let projectName: String
    /// A ferramenta que o agente queria usar: Bash, Edit, WebFetch…
    public let toolName: String
    public let summary: String
    public let decision: PermissionDecision
    public let decidedAt: Date

    public init(
        id: String, sessionID: String, tool: AgentTool, projectName: String,
        toolName: String, summary: String, decision: PermissionDecision, decidedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.tool = tool
        self.projectName = projectName
        self.toolName = toolName
        self.summary = summary
        self.decision = decision
        self.decidedAt = decidedAt
    }

    public init(_ request: PermissionRequest, _ decision: PermissionDecision, decidedAt: Date = Date()) {
        self.init(
            id: request.id,
            sessionID: request.sessionID,
            tool: request.tool,
            projectName: request.projectName,
            toolName: request.toolName,
            summary: request.summary,
            decision: decision,
            decidedAt: decidedAt
        )
    }
}

/// O que autorizaste e o que recusaste.
///
/// Sem isto, uma decisão não deixava rasto nenhum: o pedido some-se do disco
/// mal o hook lhe pega, e a pergunta que fica é sempre a mesma — "eu deixei
/// mesmo o agente correr aquilo?". O registo responde a isso, e é a única
/// memória que a app tem do que passou pelo painel.
///
/// JSON Lines e não um array de JSON: cada decisão é uma linha acrescentada ao
/// fim, e um `append` nunca pode estragar o que já lá estava. Reescrever um
/// documento inteiro a cada decisão punha o histórico todo em risco de cada vez
/// — e, de caminho, uma linha por decisão lê-se com `tail -f`, que é
/// exatamente como se olha para um registo.
public struct DecisionLog: Sendable {
    /// Vive FORA do diretório de estado, ao lado dele: o `StateStore` observa
    /// esse diretório e o repositório tenta descodificar tudo o que lá está.
    /// Um ficheiro nosso lá dentro fazia a app recarregar por causa da própria
    /// escrita, a cada decisão.
    public static let fileName = "decisions.log.jsonl"

    /// Um teto, e não um prazo.
    ///
    /// A pergunta que se faz a um registo destes é sempre sobre o passado
    /// recente — "o que é que eu deixei passar hoje?" —, e umas centenas de
    /// linhas cobrem semanas de uso. O teto também é o que mantém a leitura
    /// barata: nada aqui cresce sem limite, por isso ler o ficheiro inteiro é
    /// sempre um custo fixo.
    public static let maximumRecords = 200

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Escrita

    /// Escreve a decisão que acabaste de tomar.
    ///
    /// `defer_` fica de fora de propósito: não é uma decisão tua, é a app a sair
    /// da frente quando já tens o terminal à vista. E é o desfecho mais comum de
    /// todos — registá-lo enterrava as decisões verdadeiras debaixo de dezenas
    /// de linhas a dizer que ninguém decidiu nada.
    public func record(_ request: PermissionRequest, _ decision: PermissionDecision) {
        guard decision != .defer_ else { return }
        append(DecisionRecord(request, decision))
    }

    /// Falhar a escrever custa uma linha de histórico; nunca pode custar a
    /// resposta ao agente, que é o que está do outro lado de quem chama isto.
    /// Daí engolir o erro depois de o deixar no log do sistema.
    public func append(_ record: DecisionRecord) {
        guard var line = try? JSONEncoder.pulse.encode(record) else { return }
        line.append(0x0A)
        do {
            try appendLine(line)
            try compactIfNeeded()
        } catch {
            NSLog("Pulse could not record a decision: %@", String(describing: error))
        }
    }

    private func appendLine(_ data: Data) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            try manager.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // 0600 como o resto do que a app escreve: isto tem os comandos que
            // os teus agentes pediram para correr, e mais ninguém tem que os ler.
            manager.createFile(
                atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
            )
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Corta pela cabeça quando o ficheiro passa do teto.
    ///
    /// Reler o ficheiro a cada escrita parece caro e não é: o teto garante que
    /// ele nunca passa de umas dezenas de kB, e uma decisão acontece à
    /// velocidade a que um humano carrega num botão. Guardar contadores para
    /// evitar esta leitura era arranjar estado que pode divergir do disco, para
    /// poupar o que não custa.
    private func compactIfNeeded() throws {
        let lines = storedLines()
        guard lines.count > Self.maximumRecords else { return }
        let kept = lines.suffix(Self.maximumRecords).joined(separator: "\n")
        try Data((kept + "\n").utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )
    }

    // MARK: - Leitura

    /// As últimas decisões, da mais recente para trás — a ordem por que se
    /// procura uma decisão, que é sempre a partir de agora.
    ///
    /// Uma linha que não descodifique é saltada em silêncio: um registo escrito
    /// por uma versão anterior da app não pode apagar do painel tudo o resto que
    /// está lá bom.
    public func recent(limit: Int = 12) -> [DecisionRecord] {
        guard limit > 0 else { return [] }
        let records = storedLines().compactMap { line -> DecisionRecord? in
            try? JSONDecoder.pulse.decode(DecisionRecord.self, from: Data(line.utf8))
        }
        return records.suffix(limit).reversed()
    }

    private func storedLines() -> [String] {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
