import AVFoundation
import AppKit

import AgentGlanceCore

/// Dá voz às sessões.
///
/// O princípio: a voz é para quando *não* estás a olhar. Se estás, o notch
/// chega. Por isso fala em três momentos apenas — terminou, precisa de
/// permissão, ficou à espera — e cala-se em Não Incomodar, durante chamadas, e
/// quando o próprio terminal está à frente.
///
/// A identidade não vem da voz, vem do som de assinatura que a antecede: com
/// uma só voz portuguesa instalada no sistema, cinco ferramentas soariam
/// iguais. O earcon chega ao ouvido em milissegundos e diz quem é; a voz só
/// traz o conteúdo.
@MainActor
final class Voice {

    static let shared = Voice()

    private let synthesizer = AVSpeechSynthesizer()
    private let earcons = Earcons()
    private var queue: [(AgentTool, String)] = []
    private var speaking = false
    private var lastSpokeAt: Date = .distantPast
    private var suppressed: [(AgentTool, String)] = []
    private var flushTask: Task<Void, Never>?

    /// Uma frase de cada vez, com espaço para respirar.
    private let minimumGap: TimeInterval = 4

    private init() {}

    // MARK: - Preferências

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "voiceEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voiceEnabled") }
    }

    /// Usar a voz do sistema — que pode ser a da Siri.
    ///
    /// As vozes Siri não são expostas ao `AVSpeechSynthesizer`: não aparecem em
    /// `speechVoices()` nem se instanciam por identificador. Mas o comando
    /// `say`, invocado SEM `-v`, usa a voz do sistema — e se ela for a Siri, é
    /// a Siri que fala. Verificado por comparação de áudio: a saída por omissão
    /// não coincide com nenhuma das vozes listadas.
    ///
    /// O que se perde: o timbre deixa de distinguir as ferramentas, porque a
    /// voz do sistema é uma só. Fica o som de assinatura a fazê-lo, mais uma
    /// variação de ritmo por ferramenta. Quem prefere cinco timbres distintos
    /// desliga isto e volta às vozes instaladas.
    var useSystemVoice: Bool {
        get { UserDefaults.standard.object(forKey: "voiceUseSystem") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "voiceUseSystem") }
    }

    var silentOnCall: Bool {
        get { UserDefaults.standard.object(forKey: "voiceSilentOnCall") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voiceSilentOnCall") }
    }

    var mutedUntil: Date? {
        get {
            let raw = UserDefaults.standard.double(forKey: "voiceMutedUntil")
            return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "voiceMutedUntil") }
    }

    var isMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }

    func mute(minutes: Int) { mutedUntil = Date().addingTimeInterval(Double(minutes) * 60) }
    func unmute() { mutedUntil = nil }

    // MARK: - Arranque

    /// Pré-aquece o sintetizador. Sem isto a primeira frase do dia chega uns
    /// 300 ms atrasada e desencontra-se do som de assinatura.
    func prewarm() {
        earcons.start()
        guard let voice = VoiceCatalog.shared.voice(for: .claude) else { return }
        let utterance = AVSpeechUtterance(string: " ")
        utterance.voice = voice
        utterance.volume = 0
        synthesizer.speak(utterance)
    }

    // MARK: - Anunciar

    /// Uma ou mais sessões passaram a precisar de ti.
    ///
    /// Devolve se chegou a falar: quando fala, o chamador não toca o som — os
    /// dois juntos seriam redundantes e mais barulhentos do que qualquer um.
    @discardableResult
    func announceAttention(_ sessions: [AgentSession]) -> Bool {
        guard UserDefaults.standard.bool(forKey: "voiceOnAttention") else { return false }
        return announce(sessions)
    }

    /// Uma ou mais sessões acabaram o turno.
    @discardableResult
    func announceTurnComplete(_ sessions: [AgentSession]) -> Bool {
        guard UserDefaults.standard.bool(forKey: "voiceOnTurnComplete") else { return false }
        return announce(sessions)
    }

    /// Várias sessões podem transitar no mesmo ciclo de leitura. Uma frase por
    /// sessão seria uma matraca; acima de uma, colapsa-se numa contagem.
    @discardableResult
    private func announce(_ sessions: [AgentSession]) -> Bool {
        guard !sessions.isEmpty else { return false }
        let speakable = sessions.filter { canSpeak(about: $0) }
        guard !speakable.isEmpty else { return false }

        if speakable.count == 1, let one = speakable.first {
            return announce(session: one, reason: one.attentionReason)
        }
        earcons.play(tool: speakable[0].tool, state: .needsDecision)
        say("\(Self.spell(speakable.count)) agentes precisam de ti.", tool: speakable[0].tool)
        lastSpokeAt = Date()
        return true
    }

    private func canSpeak(about session: AgentSession) -> Bool {
        isEnabled && !isMuted && !Self.focusActive() && !microphoneInUse() && !isLookingAtIt(session)
    }

    /// Chamado quando uma sessão muda de estado. Decide se vale a pena falar.
    @discardableResult
    func announce(session: AgentSession, reason: AttentionReason?) -> Bool {
        guard canSpeak(about: session) else { return false }

        let phrase = self.phrase(for: session, reason: reason)
        let state: EarconState = {
            switch (session.status, reason) {
            case (.needsAttention, .permission): return .needsDecision
            case (.needsAttention, _):           return .done
            case (.idle, _):                     return .waiting
            default:                             return .done
            }
        }()

        let now = Date()
        if now.timeIntervalSince(lastSpokeAt) < minimumGap {
            suppressed.append((session.tool, phrase))
            scheduleFlush()
            return true
        }
        lastSpokeAt = now
        earcons.play(tool: session.tool, state: state)
        say(phrase, tool: session.tool)
        return true
    }

    /// O que se acumula durante o silêncio sai colapsado: três agentes a falar
    /// por cima uns dos outros não se entende, uma contagem entende-se.
    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(4.2 * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.suppressed.isEmpty else { return }
            let pending = self.suppressed
            self.suppressed.removeAll()
            self.lastSpokeAt = Date()

            if pending.count == 1 {
                self.earcons.play(tool: pending[0].0, state: .done)
                self.say(pending[0].1, tool: pending[0].0)
            } else {
                self.earcons.play(tool: .claude, state: .needsDecision)
                self.say("\(Self.spell(pending.count)) agentes precisam de ti.", tool: .claude)
            }
        }
    }

    // MARK: - Fala

    private func say(_ text: String, tool: AgentTool) {
        guard !text.isEmpty else { return }
        queue.append((tool, text))
        drain()
    }

    func stop() {
        queue.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        sayProcess?.terminate()
        sayProcess = nil
        speaking = false
    }

    /// Fala pelo `say`, que usa a voz do sistema.
    ///
    /// Sem `-v` de propósito: nomear a voz faria o `say` procurá-la na lista
    /// pública, onde a Siri não está, e cair silenciosamente noutra. O ritmo é
    /// o único eixo que resta para separar as ferramentas ao ouvido, já que o
    /// timbre passa a ser um só.
    private func speakWithSystemVoice(_ text: String, tool: AgentTool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", String(rate(for: tool)), text]
        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in
                self?.speaking = false
                self?.sayProcess = nil
                self?.drain()
            }
        }
        speaking = true
        sayProcess = process
        do {
            // Pequeno atraso para o earcon não ser pisado pela primeira sílaba.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 260_000_000)
                try? process.run()
            }
        }
    }

    /// Palavras por minuto. A omissão do macOS anda nos 175; estes valores
    /// ficam à volta disso, o suficiente para se notar sem soar apressado.
    private func rate(for tool: AgentTool) -> Int {
        switch tool {
        case .claude:   return 175
        case .codex:    return 190
        case .opencode: return 170
        case .pi:       return 196
        case .convoy:   return 164
        }
    }

    private var sayProcess: Process?

    private func drain() {
        guard !speaking, !queue.isEmpty else { return }
        let (tool, text) = queue.removeFirst()

        if useSystemVoice {
            speakWithSystemVoice(text, tool: tool)
            return
        }

        let profile = VoiceCatalog.shared.profile(for: tool)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = profile.voice
        utterance.rate = profile.rate
        utterance.pitchMultiplier = profile.pitch
        utterance.volume = 1
        // O earcon dura uns 250 ms; a voz entra logo a seguir, sem buraco.
        utterance.preUtteranceDelay = 0.26

        speaking = true
        synthesizer.speak(utterance)
        // O delegate do sintetizador dava um ciclo de retenção com o singleton;
        // um sondar leve resolve o encadeamento sem isso.
        Task { [weak self] in
            while let self, self.synthesizer.isSpeaking {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            self?.speaking = false
            self?.drain()
        }
    }

    /// Curta de propósito: umas oito palavras. O detalhe vai para o notch, não
    /// para o ouvido.
    private func phrase(for session: AgentSession, reason: AttentionReason?) -> String {
        let who = session.tool.spokenName
        let project = session.projectName.isEmpty ? "" : " no \(session.projectName)"
        switch (session.status, reason) {
        case (.needsAttention, .permission): return "\(who) precisa de permissão\(project)."
        case (.needsAttention, _):           return "\(who) terminou\(project)."
        case (.idle, _):                     return "\(who) está à tua espera\(project)."
        case (.ended, _):                    return "\(who) fechou\(project)."
        default:                             return "\(who)\(project)."
        }
    }

    private static func spell(_ n: Int) -> String {
        switch n {
        case 2: return "Dois"
        case 3: return "Três"
        case 4: return "Quatro"
        case 5: return "Cinco"
        default: return "\(n)"
        }
    }

    // MARK: - Quando NÃO falar

    /// Estás a olhar para o terminal desta sessão? Então já sabes.
    ///
    /// Isto esteve morto durante muito tempo sem dar sinal: a versão anterior
    /// exigia que o id da sessão constasse de um conjunto `focusedSessionIDs`
    /// que se dizia "preenchido pela app" e que nada preenchia. O conjunto
    /// estava sempre vazio, a condição era sempre falsa, e a voz anunciava
    /// alegremente coisas que tinhas à frente dos olhos.
    ///
    /// `TerminalVisibility` responde à mesma pergunta a sério, e com cache —
    /// que é o que a versão anterior queria evitar pagar aqui.
    private func isLookingAtIt(_ session: AgentSession) -> Bool {
        TerminalVisibility.isOnScreen(session)
    }

    /// Não Incomodar e modos de Concentração. Lido do ficheiro de asserções,
    /// que não exige autorização nenhuma — pedir permissão de Focus só para
    /// não falar seria trocar um incómodo por outro.
    static func focusActive() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["data"] as? [[String: Any]]
        else { return false }
        return records.contains { ($0["storeAssertionRecords"] as? [Any])?.isEmpty == false }
    }

    /// Alguma app está a usar o microfone? Então estás numa chamada.
    private func microphoneInUse() -> Bool {
        guard silentOnCall else { return false }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        )
        return session.devices.contains { $0.isInUseByAnotherApplication }
    }

    // MARK: - Teste

    /// Toca a assinatura e a voz de cada ferramenta, espaçadas.
    func demo() {
        for (i, tool) in AgentTool.allCases.enumerated() {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Double(i) * 2.6 * 1_000_000_000))
                self.earcons.play(tool: tool, state: .done)
                self.say("\(tool.spokenName) terminou o teste.", tool: tool)
            }
        }
    }
}

// MARK: - Nomes falados

extension AgentTool {
    /// Como se diz em voz alta. "OpenCode" lido por um sintetizador português
    /// sai "opé-nê-códe"; separado sai certo.
    var spokenName: String {
        switch self {
        case .claude:   return "Claude"
        case .codex:    return "Códex"
        case .convoy:   return "Convoy"
        case .opencode: return "Open Code"
        case .pi:       return "Pi"
        }
    }
}
