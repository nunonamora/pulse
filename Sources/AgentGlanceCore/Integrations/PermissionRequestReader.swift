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
            detailIsMarkdown: described.markdown,
            suggestions: suggestions,
            createdAt: now,
            expiresAt: now.addingTimeInterval(holdSeconds)
        )
    }

    /// O suficiente para decidires sem ir ver o resto.
    private static func describe(
        toolName: String, input: [String: Any]
    ) -> (summary: String, detail: String?, markdown: Bool) {
        switch toolName {
        case "Bash":
            let command = input["command"] as? String ?? ""
            return (input["description"] as? String ?? "Run a command", command, false)
        case "Write":
            let path = (input["file_path"] as? String ?? "") as NSString
            return ("Write \(path.lastPathComponent)", input["content"] as? String, false)
        case "Edit", "NotebookEdit":
            let path = (input["file_path"] as? String ?? "") as NSString
            let old = input["old_string"] as? String ?? ""
            let new = input["new_string"] as? String ?? ""
            return ("Edit \(path.lastPathComponent)", "- \(old)\n+ \(new)", false)
        case "ExitPlanMode":
            // O plano vem em markdown e merece ser lido como tal.
            return ("Approve the plan", input["plan"] as? String, true)
        case "WebFetch":
            return ("Fetch \(input["url"] as? String ?? "a page")", nil, false)
        default:
            let rendered = (try? JSONSerialization.data(
                withJSONObject: input, options: [.prettyPrinted, .sortedKeys]
            )).map { String(decoding: $0, as: UTF8.self) }
            return ("Use \(toolName)", rendered, false)
        }
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
