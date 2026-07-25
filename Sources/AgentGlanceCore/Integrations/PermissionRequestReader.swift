import Foundation

/// Lê um payload `PermissionRequest` do Claude Code e devolve a decisão no
/// formato que ele espera.
public enum PermissionRequestReader {

    /// Quanto tempo o hook segura o agente à espera de ti.
    ///
    /// Abaixo do timeout registado no settings.json, de propósito: preferimos
    /// largar por nossa iniciativa, com uma resposta limpa, a ser cortados a
    /// meio pelo Claude Code.
    public static let holdSeconds: TimeInterval = 150

    /// Constrói o pedido a partir do payload do hook.
    public static func makeRequest(
        payload: Data,
        tool: AgentTool = .claude,
        now: Date = Date()
    ) -> PermissionRequest? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }

        let sessionID = json["session_id"] as? String ?? UUID().uuidString
        let cwd = json["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        let toolName = json["tool_name"] as? String ?? "uma ação"
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let described = describe(toolName: toolName, input: input)
        let suggestions = (json["permission_suggestions"] as? [Any] ?? []).map(AnyCodable.init)

        return PermissionRequest(
            id: "\(sessionID)-\(Int(now.timeIntervalSince1970 * 1000))",
            sessionID: sessionID,
            tool: tool,
            cwd: cwd,
            toolName: toolName,
            summary: described.summary,
            detail: described.detail,
            detailKind: described.kind,
            suggestions: suggestions,
            createdAt: now,
            expiresAt: now.addingTimeInterval(holdSeconds)
        )
    }

    /// O suficiente para decidires sem ir ver o resto.
    ///
    /// Cada ferramenta tem a sua forma, e dar a mesma forma a todas era o que
    /// enchia o cartão de coisas estranhas: um `Edit` chegava como
    /// `- velho\n+ novo` numa linha só, e qualquer ferramenta fora desta lista
    /// chegava como JSON impresso com indentação — chavetas, aspas e vírgulas
    /// a ocupar o espaço que a decisão precisava.
    private static func describe(
        toolName: String, input: [String: Any]
    ) -> (summary: String, detail: String?, kind: PermissionDetailKind) {
        switch toolName {
        case "Bash":
            let command = input["command"] as? String ?? ""
            return (input["description"] as? String ?? "Run a command", command, .command)

        case "Write":
            let path = (input["file_path"] as? String ?? "") as NSString
            return ("Write \(path.lastPathComponent)", input["content"] as? String, .content)

        case "Edit", "NotebookEdit":
            let path = (input["file_path"] as? String ?? "") as NSString
            let old = input["old_string"] as? String ?? ""
            let new = input["new_string"] as? String ?? ""
            return ("Edit \(path.lastPathComponent)", diff(from: old, to: new), .diff)

        case "ExitPlanMode":
            // O plano vem em markdown e merece ser lido como tal.
            return ("Approve the plan", input["plan"] as? String, .plan)

        case "WebFetch":
            return ("Fetch \(input["url"] as? String ?? "a page")", input["prompt"] as? String, .content)

        default:
            return ("Use \(toolName)", fields(from: input), .fields)
        }
    }

    /// Linhas `-` e `+`, uma por linha de verdade.
    ///
    /// As pontas comuns são cortadas: numa troca de uma palavra no meio de uma
    /// função, mostrar a função inteira duas vezes esconde a alteração dentro
    /// de vinte linhas idênticas.
    private static func diff(from old: String, to new: String) -> String {
        var before = old.components(separatedBy: "\n")
        var after = new.components(separatedBy: "\n")

        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] {
            prefix += 1
        }
        before.removeFirst(prefix)
        after.removeFirst(prefix)

        var suffix = 0
        while suffix < before.count, suffix < after.count,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }
        before.removeLast(suffix)
        after.removeLast(suffix)

        let removed = before.map { "-\($0)" }
        let added = after.map { "+\($0)" }
        let body = (removed + added).joined(separator: "\n")
        // Corte total significa que só mudou espaço em branco. Dizê-lo é mais
        // útil do que mostrar um painel vazio.
        return body.isEmpty ? "(whitespace only)" : body
    }

    /// Os argumentos como campos, um por linha: `chave  valor`.
    ///
    /// Ordenados, com os valores longos cortados. É a mesma informação que o
    /// JSON tinha, sem a pontuação que não é para ler.
    private static func fields(from input: [String: Any]) -> String? {
        guard !input.isEmpty else { return nil }
        return input.keys.sorted().map { key in
            var value: String
            switch input[key] {
            case let text as String: value = text
            case let number as NSNumber: value = number.stringValue
            case let list as [Any]: value = list.map { "\($0)" }.joined(separator: ", ")
            case let nested as [String: Any]: value = nested.keys.sorted().joined(separator: ", ")
            case .none: value = ""
            case let other?: value = "\(other)"
            }
            value = value.replacingOccurrences(of: "\n", with: " ")
            if value.count > 240 { value = String(value.prefix(240)) + "…" }
            return "\(key)\t\(value)"
        }.joined(separator: "\n")
    }

    /// A resposta que o Claude Code lê do stdout do hook.
    ///
    /// `defer` devolve um objeto vazio de propósito: sem decisão, o diálogo
    /// normal aparece no terminal, que é o comportamento certo quando ninguém
    /// respondeu.
    public static func output(
        for decision: PermissionDecision,
        request: PermissionRequest
    ) -> String {
        var body: [String: Any] = [:]
        switch decision {
        case .allow:
            body = ["behavior": "allow"]
        case .allowAlways:
            body = ["behavior": "allow"]
            // Ecoar uma das sugestões recebidas equivale a carregar no
            // "permitir sempre" do diálogo — escreve a mesma regra.
            let allowSuggestions = request.suggestions.compactMap { $0.jsonObject }
                .filter { ($0 as? [String: Any])?["behavior"] as? String == "allow" }
            if let first = allowSuggestions.first {
                body["updatedPermissions"] = [first]
            }
        case .deny:
            body = ["behavior": "deny", "message": "Denied from AgentGlance."]
        case .defer_:
            return "{}"
        }

        let root: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": body,
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
