import Foundation

/// Quem são os agentes vivos de uma sessão — não quantos.
///
/// O `SubagentMeter` conta; isto identifica. A diferença importa porque um
/// número ("2 subagents") não diz se o trabalho está a andar nem qual deles
/// está preso, e é essa a pergunta de quem lança agentes em paralelo. Cada
/// agente aqui traz nome, tipo, há quanto tempo corre e o que está a fazer.
///
/// **Porque é que a contagem antiga estava errada.** O `SubagentMeter` conta
/// `tool_use` sem `tool_result`, e isso é correto para agentes síncronos: o
/// resultado só chega quando o agente acaba. Para os que correm em segundo
/// plano — hoje a maioria — o resultado chega no instante do lançamento, a
/// dizer apenas "lançado". Pelo critério antigo, um agente em segundo plano
/// nasce e morre no mesmo instante, e a contagem dá sempre zero. Descobriu-se
/// isto a correr o algoritmo contra uma sessão que tinha dois agentes vivos e
/// obter "por terminar: 0".
///
/// **Os sinais certos**, ambos exatos e nenhum heurístico:
/// - *nascimento*: o `tool_result` do lançamento traz o id do agente;
/// - *morte*: chega ao transcript uma notificação com esse id e um estado.
///
/// Um id nascido e ainda não anunciado como terminado está vivo.
public enum SubagentRoster {

    /// De onde vem o agente. O Vibe Island separa-os em dois cartões e tem
    /// razão: um subagente é trabalho que esta sessão delegou, um agente de
    /// equipa é alguém que vive numa sessão partilhada e continua lá quando
    /// esta fechar. Misturá-los esconderia essa diferença.
    public enum Origin: Equatable, Sendable {
        case subagent
        /// Membro de uma equipa, com o identificador da sessão partilhada.
        case team(session: String)
    }

    public struct Agent: Equatable, Sendable, Identifiable {
        public let id: String
        /// O nome dado a quem o lançou ("feat-onboarding"), ou o tipo quando
        /// não foi nomeado.
        public let name: String
        /// O tipo registado ("general-purpose"), que aparece entre parênteses.
        public let type: String
        /// A descrição curta da tarefa.
        public let description: String
        public let origin: Origin
        /// Há quanto tempo corre, em segundos. `nil` quando o transcript dele
        /// ainda não existe — acabado de nascer.
        public let elapsed: TimeInterval?
        /// O que está a fazer agora, já em legenda: "$ swift build",
        /// "Read: VITheme.swift".
        public let activity: String?
        /// O modelo da última resposta dele — os agentes podem correr num
        /// modelo diferente do pai, e ver isso explica metade das lentidões.
        public let model: String?

        public init(
            id: String, name: String, type: String, description: String,
            origin: Origin, elapsed: TimeInterval?, activity: String?, model: String?
        ) {
            self.id = id
            self.name = name
            self.type = type
            self.description = description
            self.origin = origin
            self.elapsed = elapsed
            self.activity = activity
            self.model = model
        }

        /// "7m 48s" — a forma curta do tempo a correr.
        public var elapsedLabel: String? {
            guard let elapsed, elapsed >= 1 else { return nil }
            let total = Int(elapsed)
            if total < 60 { return "\(total)s" }
            if total < 3600 { return "\(total / 60)m \(total % 60)s" }
            return "\(total / 3600)h \((total % 3600) / 60)m"
        }
    }

    /// Os agentes vivos desta sessão, pela ordem por que foram lançados — que
    /// é a ordem por que quem os lançou pensa neles.
    public static func roster(
        transcriptPath: String, now: Date = Date()
    ) -> [Agent] {
        let transcript = URL(fileURLWithPath: transcriptPath)
        guard let data = tail(transcript, bytes: 1024 * 1024) else { return [] }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")

        // Passagem única: lançamentos por id de ferramenta, ids anunciados
        // pelos resultados, e ids já dados como terminados.
        var spawns: [String: Spawn] = [:]          // toolUseID -> lançamento
        var born: [(id: String, spawn: Spawn)] = []
        var dead = Set<String>()

        for line in lines {
            if line.contains("task-notification") {
                dead.formUnion(finishedIDs(in: line))
            }
            guard line.contains("\"tool_use\"") || line.contains("\"tool_result\"")
            else { continue }
            guard let object = try? JSONSerialization.jsonObject(
                      with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }

            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    guard let tool = block["name"] as? String,
                          tool == "Agent" || tool == "Task",
                          let toolID = block["id"] as? String,
                          let input = block["input"] as? [String: Any]
                    else { continue }
                    spawns[toolID] = Spawn(
                        name: input["name"] as? String,
                        type: input["subagent_type"] as? String ?? "agent",
                        description: input["description"] as? String ?? ""
                    )
                case "tool_result":
                    guard let toolID = block["tool_use_id"] as? String,
                          let spawn = spawns[toolID],
                          let id = agentID(in: block)
                    else { continue }
                    born.append((id, spawn))
                default:
                    break
                }
            }
        }

        let directory = transcript.deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)

        return born.filter { !dead.contains($0.id) }.map { id, spawn in
            let child = readChild(directory: directory, id: id, now: now)
            return Agent(
                id: id,
                name: spawn.name ?? spawn.type,
                type: spawn.type,
                description: spawn.description,
                origin: origin(of: id),
                elapsed: child?.elapsed,
                activity: child?.activity,
                model: child?.model
            )
        }
    }

    // MARK: - Ler o lançamento

    private struct Spawn {
        let name: String?
        let type: String
        let description: String
    }

    /// Os agentes de equipa identificam-se `nome@sessão`; os subagentes têm
    /// só um id opaco. A forma do identificador É a origem.
    public static func origin(of id: String) -> Origin {
        guard let at = id.firstIndex(of: "@") else { return .subagent }
        return .team(session: String(id[id.index(after: at)...]))
    }

    /// O id que o resultado do lançamento anuncia. Duas grafias em uso —
    /// `agentId:` para agentes em segundo plano, `agent_id:` para os de
    /// equipa — e não custa nada aceitar as duas.
    public static func agentID(in block: [String: Any]) -> String? {
        var text = ""
        if let direct = block["content"] as? String {
            text = direct
        } else if let blocks = block["content"] as? [[String: Any]] {
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        for key in ["agentId:", "agent_id:"] {
            guard let range = text.range(of: key) else { continue }
            let value = text[range.upperBound...]
                .prefix { $0 != "\n" }
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Os ids dados como terminados numa linha de notificação. Qualquer estado
    /// serve — concluído, morto ou falhado, todos significam "já não corre".
    public static func finishedIDs(in line: Substring) -> Set<String> {
        var found = Set<String>()
        var rest = Substring(line)
        while let open = rest.range(of: "<task-id>"),
              let close = rest.range(of: "</task-id>", range: open.upperBound..<rest.endIndex) {
            let id = String(rest[open.upperBound..<close.lowerBound])
            // O JSON escapa as marcas; o id nunca as contém.
            if !id.isEmpty, !id.contains("<") { found.insert(id) }
            rest = rest[close.upperBound...]
        }
        return found
    }

    // MARK: - Ler o transcript do filho

    private struct Child {
        let elapsed: TimeInterval
        let activity: String?
        let model: String?
    }

    private static func readChild(
        directory: URL, id: String, now: Date
    ) -> Child? {
        // O ficheiro tem o nome do id, e os ids de equipa trazem um `@` que
        // não pertence a nome de ficheiro nenhum — corta-se na origem.
        let file = directory.appendingPathComponent(
            "agent-\(id.split(separator: "@").first.map(String.init) ?? id).jsonl")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              !data.isEmpty
        else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard let first = lines.first,
              let head = try? JSONSerialization.jsonObject(
                  with: Data(first.utf8)) as? [String: Any],
              let started = timestamp(head["timestamp"] as? String)
        else { return nil }

        var activity: String?
        var model: String?
        // De trás para a frente: a última ferramenta usada é o que ele está a
        // fazer, e o último modelo visto é o modelo dele.
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(
                      with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any]
            else { continue }
            if model == nil, let name = message["model"] as? String,
               name != "<synthetic>" {
                model = name
            }
            if activity == nil, let content = message["content"] as? [[String: Any]] {
                for block in content.reversed()
                where block["type"] as? String == "tool_use" {
                    activity = label(
                        tool: block["name"] as? String ?? "",
                        input: block["input"] as? [String: Any] ?? [:]
                    )
                    break
                }
            }
            if activity != nil && model != nil { break }
        }
        return Child(
            elapsed: max(0, now.timeIntervalSince(started)),
            activity: activity, model: model
        )
    }

    /// A legenda de uma ferramenta: o que a pessoa quer ler, não o JSON.
    /// Comandos levam `$` como no terminal; ficheiros mostram só o nome, que
    /// o caminho completo não cabe e a pasta raramente é a dúvida.
    public static func label(tool: String, input: [String: Any]) -> String? {
        func file(_ key: String) -> String? {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        switch tool {
        case "Bash", "BashOutput":
            guard let command = input["command"] as? String, !command.isEmpty
            else { return "$" }
            return "$ " + command.replacingOccurrences(of: "\n", with: " ")
        case "Read":       return file("file_path").map { "Read: \($0)" }
        case "Edit":       return file("file_path").map { "Edit: \($0)" }
        case "Write":      return file("file_path").map { "Write: \($0)" }
        case "Grep":       return (input["pattern"] as? String).map { "Grep: \($0)" }
        case "Glob":       return (input["pattern"] as? String).map { "Glob: \($0)" }
        case "WebFetch":   return (input["url"] as? String).map { "Fetch: \($0)" }
        case "WebSearch":  return (input["query"] as? String).map { "Search: \($0)" }
        case "":           return nil
        default:           return tool
        }
    }

    private static func tail(_ url: URL, bytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        return data
    }

    private static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
