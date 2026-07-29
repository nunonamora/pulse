import Foundation

/// A quota do Codex, dita pelo próprio fornecedor.
///
/// Os rollouts do Codex CLI incluem eventos `token_count` com um bloco
/// `rate_limits` — percentagem usada, janela e instante de reset, calculados
/// pela OpenAI. Ao contrário do plano da Anthropic, aqui a percentagem É
/// honesta: não há denominador inventado porque o denominador vem de quem
/// cobra.
///
/// Lê-se o rollout mais recente pela cauda; a última linha com `rate_limits`
/// é o estado mais atual que existe em disco.
public enum CodexQuota {

    public struct Snapshot: Equatable, Sendable {
        /// 0–100, como o fornecedor a reporta.
        public let usedPercent: Double
        /// A janela a que a percentagem se refere, em minutos.
        public let windowMinutes: Int
        /// "free", "plus"…
        public let planType: String?
        /// Quando o rollout que continha isto foi escrito pela última vez —
        /// para o mostrador poder dizer "há 3 h" em vez de fingir tempo real.
        public let observedAt: Date
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// A observação mais recente, ou `nil` se o Codex nunca correu por aqui.
    public static func latest(
        sessionsDirectory: URL = defaultDirectory(),
        maxAge: TimeInterval = 7 * 24 * 3600,
        now: Date = Date()
    ) -> Snapshot? {
        guard let newest = newestRollout(in: sessionsDirectory) else { return nil }
        guard let modified = try? newest.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate, now.timeIntervalSince(modified) < maxAge
        else { return nil }
        return read(newest, observedAt: modified)
    }

    /// O `.jsonl` mais recente, procurando só nos ramos ano/mês/dia mais
    /// novos — a árvore inteira pode ter milhares de ficheiros de meses.
    private static func newestRollout(in directory: URL) -> URL? {
        func newestEntry(_ url: URL, directoriesOnly: Bool) -> URL? {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            return entries
                .filter { entry in
                    let isDirectory = (try? entry.resourceValues(
                        forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return directoriesOnly ? isDirectory : entry.pathExtension == "jsonl"
                }
                .max { $0.lastPathComponent < $1.lastPathComponent }
        }
        // ano → mês → dia, todos nomeados por números que ordenam por nome.
        guard let year = newestEntry(directory, directoriesOnly: true),
              let month = newestEntry(year, directoriesOnly: true),
              let day = newestEntry(month, directoriesOnly: true)
        else { return nil }
        // Dentro do dia, o nome do rollout começa pelo timestamp.
        return newestEntry(day, directoriesOnly: false)
    }

    private static func read(_ url: URL, observedAt: Date) -> Snapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let tailBytes: UInt64 = 128 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard line.contains("\"rate_limits\""),
                  let object = try? JSONSerialization.jsonObject(
                      with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any],
                  let primary = limits["primary"] as? [String: Any],
                  let used = primary["used_percent"] as? Double
            else { continue }
            return Snapshot(
                usedPercent: used,
                windowMinutes: primary["window_minutes"] as? Int ?? 0,
                planType: limits["plan_type"] as? String,
                observedAt: observedAt
            )
        }
        return nil
    }
}
