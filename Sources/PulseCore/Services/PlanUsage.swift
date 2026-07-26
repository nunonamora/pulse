import Foundation

/// Quanto se queimou do plano na janela corrente de cinco horas.
///
/// A segunda ideia extraída do AgentNotch. Os limites dos planos da Anthropic
/// renovam por janelas de cinco horas, e quem trabalha com vários agentes em
/// paralelo descobre o limite da pior maneira: a meio de uma tarefa. Ver o
/// consumo a subir É o aviso.
///
/// Honestidade primeiro: os tetos exatos de cada plano não são públicos nem
/// estáveis, por isso isto NÃO mostra percentagens de um denominador
/// inventado — mostra o consumo real (respostas e tokens), que é factual e
/// chega para calibrar o instinto de "ainda dá / está quase".
///
/// A fonte são os transcripts locais de todos os projetos. Só ficheiros
/// tocados dentro da janela entram, e cada um é lido de trás para a frente em
/// blocos, parando assim que as linhas saem da janela — 600 MB de histórico
/// não podem custar 600 MB de leitura por espreitadela.
public enum PlanUsage {

    public struct Burn: Equatable, Sendable {
        /// Respostas do assistente na janela — o que mais se aproxima da
        /// contagem que os limites usam.
        public let responses: Int
        /// Tokens novos processados: entrada nova + cache criada + saída.
        /// A cache lida fica de fora — reler cache é quase de graça.
        public let tokens: Int
        /// Sessões distintas que contribuíram.
        public let sessions: Int
    }

    /// O consumo da janela que termina agora.
    public static func currentWindow(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        hours: Double = 5,
        now: Date = Date()
    ) -> Burn {
        let windowStart = now.addingTimeInterval(-hours * 3600)
        var responses = 0, tokens = 0, sessions = 0

        let files = (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for project in files where project.hasDirectoryPath {
            let transcripts = (try? FileManager.default.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for transcript in transcripts where transcript.pathExtension == "jsonl" {
                guard let modified = try? transcript.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate, modified > windowStart else { continue }
                let (r, t) = tally(transcript, since: windowStart)
                if r > 0 {
                    responses += r
                    tokens += t
                    sessions += 1
                }
            }
        }
        return Burn(responses: responses, tokens: tokens, sessions: sessions)
    }

    /// Lê o ficheiro do fim para o princípio, em blocos de 1 MB, e para no
    /// primeiro bloco cujas linhas já estão todas antes da janela. O teto de
    /// 16 MB é a rede de segurança para uma sessão monstruosa: subconta em vez
    /// de bloquear, que é a troca certa para um mostrador.
    private static func tally(_ url: URL, since windowStart: Date) -> (Int, Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (0, 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 1024 * 1024
        let maxChunks = 16

        var responses = 0, tokens = 0
        var end = size
        let boundary = iso8601(windowStart)

        for _ in 0..<maxChunks where end > 0 {
            let start = end > chunk ? end - chunk : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: Int(end - start)) else { break }
            let text = String(decoding: data, as: UTF8.self)
            var sawInside = false

            for line in text.split(separator: "\n") {
                // Comparação de strings ISO-8601: mais barata do que fazer
                // parse de datas em milhares de linhas, e igualmente correta
                // porque o formato ordena lexicograficamente.
                guard let stamp = field(line, "\"timestamp\":\""), stamp > boundary
                else { continue }
                sawInside = true
                guard line.contains("\"usage\""),
                      let object = try? JSONSerialization.jsonObject(
                          with: Data(line.utf8)) as? [String: Any],
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { continue }
                responses += 1
                tokens += (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage["output_tokens"] as? Int ?? 0)
            }

            if !sawInside && start < end { break }   // já saímos da janela
            end = start
        }
        return (responses, tokens)
    }

    private static func field(_ line: Substring, _ key: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...]
        guard let quote = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<quote])
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
