import Foundation

/// Escreve uma resposta no painel do terminal de uma sessão — o "responder ao
/// agente sem sair do notch" do Vibe Island.
///
/// Sem Acessibilidade e sem teclado sintético: o cmux expõe `input text` no
/// dicionário de scripting, dirigido ao terminal exato por id. É o mesmo canal
/// que o salto de foco já usa, com a mesma identidade (`CMUX_SURFACE_ID`).
/// Terminais sem esse canal não têm este botão — mostrar um campo de resposta
/// que ia falhar seria pior do que não o mostrar.
public enum ReplyService {

    public enum ReplyError: Error, Equatable {
        case unsupportedTerminal
        case emptyReply
    }

    /// A sessão consegue receber respostas daqui?
    public static func canReply(to session: AgentSession) -> Bool {
        guard let surface = session.terminal.cmuxSurfaceID else { return false }
        return !surface.isEmpty
    }

    /// O AppleScript que entrega o texto, com Enter no fim quando pedido.
    ///
    /// Gerado à parte da execução para poder ser testado sem disparar: o
    /// escaping é a única parte perigosa disto, e testa-se com hostilidade —
    /// aspas, barras e quebras de linha na resposta não podem escapar da
    /// string do AppleScript.
    public static func script(
        reply: String, surfaceID: String, pressEnter: Bool
    ) throws -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReplyError.emptyReply }
        let payload = pressEnter ? trimmed + "\n" : trimmed
        let escaped = payload
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let surface = surfaceID
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "")
        return """
        tell application "cmux"
          set matches to every terminal whose id is "\(surface)"
          if (count of matches) is not 1 then error "Pulse could not find that terminal"
          input text "\(escaped)" to item 1 of matches
        end tell
        """
    }

    /// Entrega a resposta. Erros sobem: quem carrega no botão merece saber que
    /// não foi, em vez de um silêncio que parece sucesso.
    public static func send(
        reply: String, to session: AgentSession, pressEnter: Bool = true
    ) throws {
        guard let surface = session.terminal.cmuxSurfaceID, !surface.isEmpty else {
            throw ReplyError.unsupportedTerminal
        }
        let source = try script(reply: reply, surfaceID: surface, pressEnter: pressEnter)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReplyError.unsupportedTerminal
        }
    }
}
