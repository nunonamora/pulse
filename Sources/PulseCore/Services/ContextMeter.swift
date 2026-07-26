import Foundation

/// Quanto do contexto do agente já está ocupado.
///
/// A ideia veio de olhar para o AgentNotch, que a chama "context gauge" — e é
/// boa porque é a única informação acionável sobre uma sessão que nada no ecrã
/// dá: um agente a 85% do contexto está prestes a compactar, e saber isso ANTES
/// muda o que lhe pedes a seguir.
///
/// A fonte é o transcript que o Claude Code escreve em disco e cujo caminho os
/// hooks entregam. Cada mensagem do assistente traz o uso de tokens do pedido
/// que a produziu; a última é, por definição, o estado atual da janela. Lê-se
/// só a cauda do ficheiro — um transcript longo passa dos cem megabytes, e o
/// que interessa está sempre no fim.
public enum ContextMeter {

    public struct Reading: Equatable, Sendable {
        /// Tokens no contexto do último pedido: entrada nova + cache lida +
        /// cache criada. A saída fica de fora — ainda não é contexto do
        /// pedido seguinte quando é gerada.
        public let tokens: Int
        /// O tamanho da janela do modelo que produziu a última mensagem.
        public let window: Int

        public var fraction: Double {
            window > 0 ? min(1, Double(tokens) / Double(window)) : 0
        }
    }

    /// Lê a última medição de contexto do transcript. `nil` quando o ficheiro
    /// não existe, não tem mensagens com uso, ou não é legível — todos casos
    /// em que não mostrar nada é mais honesto do que mostrar zero.
    public static func reading(transcriptPath: String) -> Reading? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }

        // 256 KB de cauda: chega para dezenas de mensagens mesmo com tool
        // results grandes, e mantém a leitura barata seja o ficheiro do
        // tamanho que for.
        let tailBytes: UInt64 = 256 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // Da última linha para a primeira: a mensagem mais recente com uso é a
        // resposta, e o resto do ficheiro deixa de interessar.
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"usage\""),
                  let object = try? JSONSerialization.jsonObject(
                      with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            let input = usage["input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreated = usage["cache_creation_input_tokens"] as? Int ?? 0
            let tokens = input + cacheRead + cacheCreated
            guard tokens > 0 else { continue }

            return Reading(
                tokens: tokens,
                window: window(model: message["model"] as? String, tokens: tokens)
            )
        }
        return nil
    }

    /// A janela do modelo. Não há campo para isto no transcript, por isso
    /// deriva-se: 200 mil por omissão, e o escalão acima quando o próprio uso
    /// prova que a janela é maior — um pedido com 600 mil tokens dentro não
    /// veio de uma janela de 200.
    private static func window(model: String?, tokens: Int) -> Int {
        let standard = 200_000
        let long = 1_000_000
        if let model, model.contains("[1m]") || model.hasSuffix("-1m") { return long }
        return tokens > standard ? long : standard
    }
}
