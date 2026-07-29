import Foundation

public enum CLIError: Error, Equatable, Sendable {
    case invalidArguments([String])
}

public enum CLICommand: Equatable, Sendable {
    case debug
    case install
    case uninstall
    case doctor
    case claudeHook(event: String, processID: Int32)
    case codexNotify(processID: Int32)
    /// O adaptador universal: qualquer ferramenta reporta estado numa linha.
    ///
    ///     pulse report --tool gemini --session abc --status working
    ///     pulse report --tool gemini --session abc --status attention
    ///     pulse report --tool gemini --session abc --status idle|ended
    ///
    /// É o que transforma "N agentes suportados" em "qualquer agente": em vez
    /// de uma integração por CLI da moda — cada uma intestável sem o CLI
    /// instalado — há um contrato público de uma linha que qualquer wrapper,
    /// alias ou hook alheio consegue chamar.
    case report(tool: String, sessionID: String, status: String, cwd: String, processID: Int32)

    public static func parse(arguments: [String]) throws -> CLICommand {
        if arguments == ["debug"] {
            return .debug
        }
        if arguments == ["install"] {
            return .install
        }
        if arguments == ["uninstall"] {
            return .uninstall
        }
        if arguments == ["doctor"] {
            return .doctor
        }
        if arguments.count == 5,
           arguments[0] == "hook",
           arguments[1] == "claude",
           arguments[3] == "--pid",
           let processID = Int32(arguments[4]) {
            return .claudeHook(event: arguments[2], processID: processID)
        }
        if arguments.count == 4,
           arguments[0] == "hook",
           arguments[1] == "codex-notify",
           arguments[2] == "--pid",
           let processID = Int32(arguments[3]) {
            return .codexNotify(processID: processID)
        }
        if arguments.first == "report" {
            var tool: String?, session: String?, status: String?
            var cwd = FileManager.default.currentDirectoryPath
            var pid: Int32 = 0
            var rest = Array(arguments.dropFirst())
            while rest.count >= 2 {
                let flag = rest.removeFirst()
                let value = rest.removeFirst()
                switch flag {
                case "--tool": tool = value
                case "--session": session = value
                case "--status": status = value
                case "--cwd": cwd = value
                case "--pid": pid = Int32(value) ?? 0
                default: throw CLIError.invalidArguments(arguments)
                }
            }
            guard rest.isEmpty, let tool, let session, let status,
                  ["working", "attention", "idle", "ended"].contains(status)
            else { throw CLIError.invalidArguments(arguments) }
            return .report(tool: tool, sessionID: session, status: status, cwd: cwd, processID: pid)
        }
        throw CLIError.invalidArguments(arguments)
    }
}
