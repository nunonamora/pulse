import Foundation

/// Quantos subagentes uma sessão tem a correr neste momento.
///
/// A terceira ideia extraída do AgentNotch — e a que quase ficou de fora por
/// parecer inevitavelmente heurística. Não é: no transcript, cada subagente
/// nasce como um `tool_use` da ferramenta Task e morre quando o seu
/// `tool_result` aparece, emparelhado pelo id. Um `tool_use` sem resultado É
/// um subagente vivo — correspondência exata, não palpite. E como o resultado
/// vem sempre depois do uso, uma cauda que apanhe o uso apanha o resultado se
/// ele existir.
public enum SubagentMeter {

    /// Subagentes por terminar na cauda do transcript. Zero quando o ficheiro
    /// não existe — sessão sem transcript é sessão sem subagentes visíveis.
    public static func liveCount(transcriptPath: String) -> Int {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return 0 }
        defer { try? handle.close() }
        // 512 KB: um turno com subagentes é um turno grande, e a cauda tem de
        // conter o nascimento de todos os que ainda correm.
        let tailBytes: UInt64 = 512 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return 0 }

        var spawned = Set<String>(), finished = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            // O filtro barato primeiro: a maioria das linhas não tem nenhum.
            guard line.contains("\"tool_use\"") || line.contains("\"tool_result\"")
            else { continue }
            guard let object = try? JSONSerialization.jsonObject(
                      with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    if let name = block["name"] as? String,
                       name == "Task" || name == "Agent",
                       let id = block["id"] as? String {
                        spawned.insert(id)
                    }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String {
                        finished.insert(id)
                    }
                default:
                    break
                }
            }
        }
        return spawned.subtracting(finished).count
    }
}
