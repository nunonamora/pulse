import Foundation

public enum InstallationError: Error, Equatable, Sendable {
    case invalidClaudeSettings
    case unsafeInstallationPath(String)
    case existingIntegrationFile(String)
}

public enum ClaudeSettingsMerger {
    private static let events: [(name: String, matcher: String?, timeout: Int?)] = [
        ("SessionStart", nil, nil),
        ("Notification", "permission_prompt|idle_prompt", nil),
        ("UserPromptSubmit", nil, nil),
        ("Stop", nil, nil),
        ("SessionEnd", nil, nil),
        // Este é o único que bloqueia: o processo do hook fica à espera da tua
        // decisão e o Claude Code espera com ele. O timeout é a rede de
        // segurança — passado ele, o diálogo normal aparece no terminal.
        ("PermissionRequest", nil, 180),
    ]

    public static func merge(settingsData: Data, hookCommand: String) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
            throw InstallationError.invalidClaudeSettings
        }
        var allHooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = allHooks[event.name] as? [[String: Any]] ?? []
            let command = command(hookCommand: hookCommand, eventName: event.name)
            if !contains(command: command, in: groups) {
                groups.append(group(command: command, matcher: event.matcher, timeout: event.timeout))
            }
            allHooks[event.name] = groups
        }
        root["hooks"] = allHooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func remove(settingsData: Data, hookCommand: String) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
            throw InstallationError.invalidClaudeSettings
        }
        var allHooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            let command = command(hookCommand: hookCommand, eventName: event.name)
            let groups = allHooks[event.name] as? [[String: Any]] ?? []
            allHooks[event.name] = groups.filter { !contains(command: command, in: [$0]) }
        }
        root["hooks"] = allHooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// True when every lifecycle event already carries the AgentGlance hook —
    /// the read-only counterpart of `merge` used by the installation doctor.
    public static func isInstalled(settingsData: Data, hookCommand: String) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let allHooks = root["hooks"] as? [String: Any] else {
            return false
        }
        return events.allSatisfy { event in
            contains(
                command: command(hookCommand: hookCommand, eventName: event.name),
                in: allHooks[event.name] as? [[String: Any]] ?? []
            )
        }
    }

    private static func contains(command: String, in groups: [[String: Any]]) -> Bool {
        groups.contains { group in
            let hooks = group["hooks"] as? [[String: Any]] ?? []
            return hooks.contains { $0["command"] as? String == command }
        }
    }

    private static func group(command: String, matcher: String?, timeout: Int? = nil) -> [String: Any] {
        var hook: [String: Any] = ["type": "command", "command": command]
        if let timeout {
            hook["timeout"] = timeout
        }
        var group: [String: Any] = ["hooks": [hook]]
        if let matcher {
            group["matcher"] = matcher
        }
        return group
    }

    private static func command(hookCommand: String, eventName: String) -> String {
        "\(shellQuote(hookCommand)) \(shellQuote(eventName))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
