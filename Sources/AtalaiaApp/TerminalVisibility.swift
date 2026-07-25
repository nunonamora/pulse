import AppKit

import AtalaiaCore

/// Estás a olhar para o painel desta sessão neste preciso momento?
///
/// Uma pergunta com consequências nos dois sentidos. Se a resposta for sim, o
/// cartão de decisão não deve aparecer: o Claude Code já está a desenhar o
/// diálogo dele no terminal que tens à frente, e sobrepor-lhe um segundo sítio
/// para decidir a mesma coisa é pior do que não mostrar nada — passas a ter de
/// escolher onde carregar antes de escolheres o que responder.
///
/// Se for não, o cartão é a única forma de saberes que alguém está à espera.
///
/// Por isso o erro caro é o falso positivo. Esconder o cartão quando o painel
/// NÃO está visível deixa o agente parado num diálogo que ninguém vê, até ao
/// fim do timeout. Esconder de menos custa um cartão a mais. Daí a regra:
/// só se responde "sim" com identidade do painel confirmada — nunca por
/// suposição a partir da aplicação em primeiro plano.
@MainActor
enum TerminalVisibility {

    /// O painel desta sessão está à vista agora.
    static func isOnScreen(_ session: AgentSession) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return false }

        switch front {
        case "com.cmuxterm.app":
            guard let surface = session.terminal.cmuxSurfaceID, !surface.isEmpty
            else { return false }
            return focusedPane(of: .cmux) == surface

        case "com.mitchellh.ghostty":
            guard let identifier = session.terminal.ghosttyTerminalID, !identifier.isEmpty
            else { return false }
            return focusedPane(of: .ghostty) == identifier

        default:
            // Terminal.app, iTerm2, kitty, Warp: sabemos que a aplicação está à
            // frente, mas não qual dos separadores. Sem isso não há resposta
            // honesta, e a resposta errada por defeito é a que esconde.
            return false
        }
    }

    private enum Host: Equatable {
        case cmux, ghostty

        var script: String {
            switch self {
            case .cmux:
                // `front window` e `selected tab` dão o painel exato sem
                // percorrer nada — e é exatamente o mesmo id que o processo do
                // agente recebeu em `CMUX_SURFACE_ID`.
                return """
                tell application "cmux" to return id of (focused terminal of (selected tab of front window))
                """
            case .ghostty:
                return """
                tell application "Ghostty" to return id of (item 1 of (every terminal whose focused is true))
                """
            }
        }
    }

    /// Guardado por meio segundo.
    ///
    /// Um pedido de permissão pergunta isto uma vez, mas a voz pergunta a cada
    /// anúncio, e um `osascript` custa dezenas de milissegundos no caminho de
    /// uma frase. Meio segundo é curto de mais para o foco mudar sem darmos por
    /// isso e longo de mais para uma rajada de eventos pagar o custo N vezes.
    private static var cache: (host: Host, value: String, at: Date)?

    private static func focusedPane(of host: Host) -> String? {
        if let cache, cache.host == host, Date().timeIntervalSince(cache.at) < 0.5 {
            return cache.value
        }
        guard let value = runAppleScript(host.script) else { return nil }
        cache = (host, value, Date())
        return value
    }

    private static func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        // O erro é esperado e não interessa: um terminal sem janelas, sem
        // autorização de automação, ou fechado a meio da pergunta responde
        // todos da mesma maneira — não sabemos, logo mostramos o cartão.
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
