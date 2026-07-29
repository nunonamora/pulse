import Foundation

/// A lista de tarefas que o agente escreveu para si próprio.
///
/// É a informação mais próxima de "onde é que ele vai" que existe sem lhe
/// perguntar: um agente que mantém uma lista está a declarar o plano dele, e
/// ver três tarefas por fazer diz mais sobre o tempo que falta do que qualquer
/// barra de progresso inventada.
///
/// Duas ferramentas escrevem estas listas, e a app tem de aceitar as duas
/// porque coexistem consoante a versão do Claude Code:
/// - `TodoWrite` reescreve a lista inteira a cada chamada — a última chamada É
///   o estado, e o resto do transcript não interessa;
/// - `TaskCreate`/`TaskUpdate` são incrementais — cada criação acrescenta,
///   cada atualização muda um estado, e é preciso somar a história toda.
///
/// Ler as duas custa uma passagem única e evita que a lista simplesmente não
/// apareça para metade das pessoas.
public enum TaskListMeter {

    public enum Status: String, Sendable, Equatable {
        case pending, inProgress, completed

        init?(raw: String) {
            switch raw.lowercased().replacingOccurrences(of: "_", with: "") {
            case "pending", "open", "todo":       self = .pending
            case "inprogress", "active", "doing": self = .inProgress
            case "completed", "done", "closed":   self = .completed
            default: return nil
            }
        }
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let status: Status

        public init(id: String, title: String, status: Status) {
            self.id = id
            self.title = title
            self.status = status
        }
    }

    public struct List: Equatable, Sendable {
        public let items: [Item]

        public init(items: [Item]) { self.items = items }

        public var completed: Int { items.filter { $0.status == .completed }.count }
        public var inProgress: Int { items.filter { $0.status == .inProgress }.count }
        public var pending: Int { items.filter { $0.status == .pending }.count }

        /// "1 done, 1 in progress, 1 open" — só as parcelas que existem, que
        /// um "0 done" é ruído a ocupar a linha.
        public func summary(
            done: String = "done", doing: String = "in progress", open: String = "open"
        ) -> String {
            var parts: [String] = []
            if completed > 0 { parts.append("\(completed) \(done)") }
            if inProgress > 0 { parts.append("\(inProgress) \(doing)") }
            if pending > 0 { parts.append("\(pending) \(open)") }
            return parts.joined(separator: ", ")
        }
    }

    /// A lista corrente da sessão. `nil` quando o agente nunca escreveu uma —
    /// e nesse caso não se mostra cartão nenhum, que uma lista vazia diria
    /// "não há trabalho" quando o que há é "não há lista".
    public static func list(transcriptPath: String) -> List? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        // 1 MB: as criações podem estar bem atrás na conversa, e perder uma
        // criação faz desaparecer uma tarefa que ainda está aberta.
        let tailBytes: UInt64 = 1024 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var todoSnapshot: [Item]?          // TodoWrite: a última chamada ganha
        var created: [(id: String, title: String)] = []
        var statuses: [String: Status] = [:]
        var sawIncremental = false

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard line.contains("TodoWrite")
                    || line.contains("TaskCreate")
                    || line.contains("TaskUpdate")
            else { continue }
            guard let object = try? JSONSerialization.jsonObject(
                      with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }

            for block in content where block["type"] as? String == "tool_use" {
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "TodoWrite":
                    guard let todos = input["todos"] as? [[String: Any]] else { continue }
                    todoSnapshot = todos.enumerated().compactMap { index, todo in
                        guard let title = (todo["content"] as? String)
                                ?? (todo["subject"] as? String),
                              let status = Status(raw: todo["status"] as? String ?? "")
                        else { return nil }
                        return Item(id: "todo-\(index)", title: title, status: status)
                    }
                case "TaskCreate":
                    guard let title = (input["subject"] as? String)
                            ?? (input["content"] as? String)
                    else { continue }
                    sawIncremental = true
                    // Os ids são sequenciais a partir de 1 e é assim que o
                    // TaskUpdate lhes chama; numerar pela ordem de criação
                    // reproduz isso sem depender do texto do resultado.
                    created.append((String(created.count + 1), title))
                case "TaskUpdate":
                    guard let id = input["taskId"] as? String,
                          let status = Status(raw: input["status"] as? String ?? "")
                    else { continue }
                    sawIncremental = true
                    statuses[id] = status
                default:
                    break
                }
            }
        }

        // O TodoWrite ganha quando existe: é uma fotografia completa, e uma
        // fotografia vale mais do que uma soma de fragmentos que podem ter
        // começado antes da cauda que se leu.
        if let todoSnapshot, !todoSnapshot.isEmpty { return List(items: todoSnapshot) }
        guard sawIncremental, !created.isEmpty else { return nil }
        let items = created.map {
            Item(id: $0.id, title: $0.title, status: statuses[$0.id] ?? .pending)
        }
        return List(items: items)
    }
}
