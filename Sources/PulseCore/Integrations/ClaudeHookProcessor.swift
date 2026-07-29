import Foundation

public enum ClaudeHookError: Error, Equatable, Sendable {
    case unsupportedEvent(String)
    case unsupportedNotification(String?)
}

public struct ClaudeHookProcessor: Sendable {
    private struct Payload: Decodable {
        let sessionID: String
        let cwd: String
        let notificationType: String?
        let transcriptPath: String?
        let toolName: String?
        let toolInput: AskInput?

        struct AskInput: Decodable {
            let questions: [Question]?
            struct Question: Decodable {
                let question: String
                let options: [Option]?
                struct Option: Decodable { let label: String }
            }
        }

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case cwd
            case notificationType = "notification_type"
            case transcriptPath = "transcript_path"
            case toolName = "tool_name"
            case toolInput = "tool_input"
        }
    }

    private let repository: StateRepository

    public init(repository: StateRepository) {
        self.repository = repository
    }

    public func process(
        event: String,
        payload: Data,
        environment: [String: String],
        processID: Int32,
        now: Date = Date(),
        /// O PermissionRequest não traz `notification_type`, mas significa
        /// exatamente o mesmo que um `permission_prompt`: força-se o tipo para
        /// a linha do painel entrar em "precisa de ti" pelo caminho que já
        /// existe, em vez de acrescentar um estado novo.
        notificationTypeOverride: String? = nil
    ) throws {
        let input = try JSONDecoder().decode(Payload.self, from: payload)
        let existing = try repository.loadLifecycleSessions().first {
            $0.sessionID == input.sessionID
        }
        // O AskUserQuestion é o único tool-use com tratamento próprio: a
        // pergunta e as opções vão para o notch. O PostToolUse — respondida,
        // aqui ou no terminal — tira-a de lá; o fim da sessão também.
        let questions = QuestionBox(stateDirectory: repository.directoryURL)
        if event == "PreToolUse", input.toolName == "AskUserQuestion",
           let asked = input.toolInput?.questions?.first {
            try? questions.post(AgentQuestion(
                sessionID: input.sessionID,
                tool: .claude,
                question: asked.question,
                options: (asked.options ?? []).map(\.label),
                askedAt: now
            ))
        }
        if event == "PostToolUse" || event == "Stop" || event == "SessionEnd" {
            questions.clear(sessionID: input.sessionID)
        }

        let state = try state(
            for: event,
            notificationType: notificationTypeOverride ?? input.notificationType,
            existing: existing
        )
        let session = AgentSession(
            tool: .claude,
            sessionID: input.sessionID,
            pid: processID,
            status: state.status,
            attentionReason: state.reason,
            cwd: input.cwd,
            startedAt: existing?.startedAt ?? now,
            updatedAt: now,
            // Completa o que já se sabia em vez de o descartar ou de o manter
            // congelado. Era `existing?.terminal ?? …`: uma sessão registada
            // uma vez nunca mais reavaliava o terminal, e todo o campo que o
            // Pulse aprendesse a capturar depois disso só chegava a
            // sessões novas. Foi o que aconteceu aos ids do cmux.
            terminal: terminalContext(for: input.cwd, environment: environment)
                .completing(existing?.terminal),
            transcriptPath: input.transcriptPath ?? existing?.transcriptPath
        )
        try repository.save(session)
    }

    private func state(
        for event: String,
        notificationType: String?,
        existing: AgentSession?
    ) throws -> (status: SessionStatus, reason: AttentionReason?) {
        switch event {
        case "SessionStart":
            // Fires on launch but also mid-conversation (resume, /clear,
            // /compact, auto-compaction), so it carries no signal about
            // activity: keep whatever status the session already has, and
            // treat a brand-new session as sitting idle at the prompt.
            return (existing?.status ?? .idle, existing?.attentionReason)
        case "Notification" where notificationType == "permission_prompt":
            return (.needsAttention, .permission)
        case "Notification" where notificationType == "idle_prompt":
            // Claude Code nudges "still waiting for your input" a minute
            // after the turn ends. The row already shows amber for exactly
            // that; escalating to red (and chiming) would drown the real
            // needs-you signal, so the nudge carries no status change.
            return (existing?.status ?? .idle, existing?.attentionReason)
        case "Notification":
            throw ClaudeHookError.unsupportedNotification(notificationType)
        case "UserPromptSubmit":
            return (.working, nil)
        case "PreToolUse", "PostToolUse":
            // Só chegam cá com o matcher AskUserQuestion; a sessão está a
            // trabalhar em ambos os lados da pergunta.
            return (.working, nil)
        case "Stop":
            return (.idle, nil)
        case "SessionEnd":
            return (.ended, nil)
        default:
            throw ClaudeHookError.unsupportedEvent(event)
        }
    }

    private func terminalContext(
        for cwd: String,
        environment: [String: String]
    ) -> TerminalContext {
        TerminalContext(
            termProgram: environment["TERM_PROGRAM"],
            itermSessionID: environment["ITERM_SESSION_ID"],
            // O cmux publica os dois com nomes duplicados; qualquer um serve.
            cmuxSurfaceID: environment["CMUX_SURFACE_ID"] ?? environment["CMUX_PANEL_ID"],
            cmuxTabID: environment["CMUX_TAB_ID"] ?? environment["CMUX_WORKSPACE_ID"],
            wezTermPane: environment["WEZTERM_PANE"],
            kittyWindowID: environment["KITTY_WINDOW_ID"],
            kittyListenOn: environment["KITTY_LISTEN_ON"],
            tmuxPane: environment["TMUX_PANE"],
            tty: environment["PULSE_TTY"],
            windowTitleHint: "\(URL(fileURLWithPath: cwd).lastPathComponent) — claude"
        )
    }
}
