import Foundation

public enum BundledResources {
    public static let captureContextScriptURL = resourceURL(
        named: "capture-context",
        extension: "sh",
        subdirectory: "Resources/hooks"
    )
    public static let claudeHookScriptURL = resourceURL(
        named: "claude-hook",
        extension: "sh",
        subdirectory: "Resources/hooks"
    )
    public static let codexNotifyScriptURL = resourceURL(
        named: "codex-notify",
        extension: "sh",
        subdirectory: "Resources/hooks"
    )
    public static let opencodePluginURL = resourceURL(
        named: "pulse",
        extension: "js",
        subdirectory: "Resources/opencode"
    )
    public static let piExtensionURL = resourceURL(
        named: "pulse",
        extension: "ts",
        subdirectory: "Resources/pi"
    )

    /// Official brand marks (Anthropic's Claude spark, sst/opencode's glyph,
    /// OpenAI's knot for Codex) — see NOTICE for trademark attribution.
    public static func iconURL(for tool: AgentTool) -> URL? {
        // O caso genérico não tem marca — é qualquer ferramenta que se
        // reporte pelo adaptador universal. Pedir aqui o SVG dele batia na
        // asserção de recurso em falta e MATAVA a app na primeira linha que o
        // desenhasse; foi exatamente o crash que este guard encerra. `nil`
        // deixa a vista cair no distintivo de letra, que já existia.
        guard tool != .other else { return nil }
        return resourceURL(named: tool.rawValue, extension: "svg", subdirectory: "Resources/icons")
    }

    private static func resourceURL(
        named name: String,
        extension fileExtension: String,
        subdirectory: String
    ) -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) else {
            fatalError("Pulse resource is missing: \(name).\(fileExtension)")
        }
        return url
    }
}
