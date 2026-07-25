import AVFoundation

import AgentGlanceCore

enum EarconState {
    case done
    case needsDecision
    case waiting
    case failed
}

/// Assinaturas sonoras de duas notas, sintetizadas — sem ficheiros de áudio.
///
/// É o earcon, e não a voz, que diz quem está a falar. Só há uma voz portuguesa
/// instalada na maioria dos sistemas, e cinco ferramentas com a mesma voz são
/// cinco ferramentas indistinguíveis. O intervalo musical chega ao ouvido em
/// milissegundos, reconhece-se como um toque por contacto, e tapa exatamente o
/// arranque do sintetizador.
///
/// Intervalos e não alarmes: sobe uma quarta, sobe uma quinta, desce uma
/// quarta. A terceira nota só existe quando alguém precisa de ti — é o que
/// torna um pedido audivelmente diferente de um "acabei".
@MainActor
final class Earcons {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var running = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.55
    }

    func start() {
        guard !running else { return }
        do {
            try engine.start()
            player.play()
            running = true
        } catch {
            running = false
        }
    }

    func play(tool: AgentTool, state: EarconState) {
        start()
        guard running else { return }
        let key = "\(tool.rawValue)-\(state)"
        let buffer = cache[key] ?? render(notes(tool, state))
        cache[key] = buffer
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    private func notes(_ tool: AgentTool, _ state: EarconState) -> [Double] {
        var base: [Double]
        switch tool {
        case .claude:   base = [392.00, 523.25]   // G4 → C5, quarta acima
        case .codex:    base = [523.25, 783.99]   // C5 → G5, quinta acima
        case .opencode: base = [329.63, 493.88]   // E4 → B4
        case .pi:       base = [739.99, 554.37]   // F#5 → C#5, a descer
        case .convoy:   base = [261.63, 392.00]   // C4 → G4, grave
        }
        switch state {
        case .needsDecision:
            base.append(base[1] * 1.122)          // + um tom: pergunta em aberto
        case .failed:
            base = [base[0], base[0] * 0.8409]    // terça menor a descer
        case .waiting:
            base = [base[0], base[0]]             // repetida, neutra
        case .done:
            break
        }
        return base
    }

    /// Senos com um sobretom na oitava e decaimento exponencial: soa a
    /// instrumento e não a bip de sistema. O ataque de 8 ms evita o clique.
    private func render(_ notes: [Double]) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let perNote = Int(sampleRate * 0.11)
        let total = perNote * notes.count

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        guard let channel = buffer.floatChannelData?[0] else { return buffer }

        let attack = Int(sampleRate * 0.008)
        for (index, frequency) in notes.enumerated() {
            let offset = index * perNote
            for i in 0..<perNote {
                let t = Double(i) / sampleRate
                let progress = Double(i) / Double(perNote)
                let wave = sin(2 * .pi * frequency * t) + 0.18 * sin(4 * .pi * frequency * t)
                let rise = i < attack ? Double(i) / Double(attack) : 1
                channel[offset + i] = Float(wave * rise * exp(-5.5 * progress) * 0.32)
            }
        }
        return buffer
    }
}

// MARK: - Catálogo de vozes

struct VoiceProfile {
    var voice: AVSpeechSynthesisVoice?
    var rate: Float
    var pitch: Float
}

/// Escolhe uma voz por ferramenta a partir do que existe mesmo no sistema.
///
/// Por omissão o macOS traz só a Joana (pt-PT, qualidade básica). Vale a pena
/// descarregar a Catarina (pt-PT) e o Felipe (pt-BR) em Definições do Sistema →
/// Acessibilidade → Conteúdo falado → Gerir vozes; assim que aparecerem, isto
/// distribui-as sozinho.
@MainActor
final class VoiceCatalog {
    static let shared = VoiceCatalog()

    private(set) var portuguese: [AVSpeechSynthesisVoice] = []
    private var assignment: [AgentTool: AVSpeechSynthesisVoice] = [:]

    private init() { refresh() }

    func refresh() {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("pt") }
        portuguese = all.sorted { a, b in
            func score(_ v: AVSpeechSynthesisVoice) -> Int {
                var s = 0
                switch v.quality {
                case .premium:  s += 400
                case .enhanced: s += 300
                default:        s += 100
                }
                if v.language == "pt-PT" { s += 50 }
                // As Eloquence são robóticas: último recurso, não escolha.
                if v.identifier.contains("eloquence") { s -= 200 }
                return s
            }
            return score(a) > score(b)
        }

        assignment.removeAll()
        guard !portuguese.isEmpty else { return }
        for (i, tool) in AgentTool.allCases.enumerated() {
            assignment[tool] = portuguese[i % portuguese.count]
        }
    }

    func voice(for tool: AgentTool) -> AVSpeechSynthesisVoice? {
        if let override = UserDefaults.standard.string(forKey: "voice.\(tool.rawValue)"),
           let v = AVSpeechSynthesisVoice(identifier: override) {
            return v
        }
        return assignment[tool] ?? portuguese.first
    }

    /// Ritmo e pitch por ferramenta. Entre 0.90 e 1.10 de propósito: mais do
    /// que isto deixa de soar a pessoa diferente e passa a soar a efeito.
    func profile(for tool: AgentTool) -> VoiceProfile {
        let tuning: (rate: Float, pitch: Float)
        switch tool {
        case .claude:   tuning = (0.46, 1.00)
        case .codex:    tuning = (0.50, 1.10)
        case .opencode: tuning = (0.48, 0.94)
        case .pi:       tuning = (0.52, 1.06)
        case .convoy:   tuning = (0.44, 0.90)
        }
        return VoiceProfile(voice: voice(for: tool), rate: tuning.rate, pitch: tuning.pitch)
    }

    /// Está tudo em qualidade básica? Então vale a pena descarregar vozes.
    var needsBetterVoices: Bool {
        portuguese.filter { $0.quality != .default }.isEmpty
    }
}
