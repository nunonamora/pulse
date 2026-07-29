import Foundation

/// O modelo e o esforço com que uma sessão está a correr.
///
/// A informação mais barata de mostrar e das mais úteis: dois agentes lado a
/// lado num Opus e num Haiku não são a mesma coisa, e o esforço de raciocínio
/// explica sozinho porque é que um demora cinco vezes mais. Ambos estão no
/// transcript e nenhum precisa de ser adivinhado — o `effort` é um campo de
/// topo de cada linha, o modelo vem em cada resposta do assistente.
public enum SessionMeta {

    public struct Reading: Equatable, Sendable {
        /// "Opus 5", "Sonnet 5", "Haiku 4.5" — já em forma de etiqueta.
        public let model: String?
        /// "XHigh", "High", "Medium", "Low".
        public let effort: String?

        public init(model: String?, effort: String?) {
            self.model = model
            self.effort = effort
        }

        /// A linha do chip: modelo e esforço separados pelo ponto médio, ou
        /// só o que existir.
        public var chip: String? {
            switch (model, effort) {
            case let (model?, effort?): return "\(model) · \(effort)"
            case let (model?, nil):     return model
            case let (nil, effort?):    return effort
            case (nil, nil):            return nil
            }
        }
    }

    public static func reading(transcriptPath: String) -> Reading? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        let tailBytes: UInt64 = 128 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var model: String?
        var effort: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            if effort == nil, let raw = field(line, "\"effort\":\"") {
                effort = effortLabel(raw)
            }
            if model == nil, let raw = field(line, "\"model\":\""),
               raw != "<synthetic>" {
                model = modelLabel(raw)
            }
            if model != nil && effort != nil { break }
        }
        guard model != nil || effort != nil else { return nil }
        return Reading(model: model, effort: effort)
    }

    /// De `claude-opus-5` para `Opus 5`. Os identificadores versionam com data
    /// no fim (`claude-haiku-4-5-20251001`) e o que interessa mostrar é a
    /// família — o resto é ruído numa linha de dezoito pontos.
    public static func modelLabel(_ identifier: String) -> String {
        var parts = identifier.split(separator: "-").map(String.init)
        // Fora o fornecedor à cabeça e a data de compilação à cauda.
        if let first = parts.first, ["claude", "anthropic"].contains(first.lowercased()) {
            parts.removeFirst()
        }
        if let last = parts.last, last.count == 8, Int(last) != nil {
            parts.removeLast()
        }
        guard let family = parts.first else { return identifier }
        let version = parts.dropFirst().joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    /// De `xhigh` para `XHigh`: a maiúscula no meio é a que o olho procura.
    public static func effortLabel(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "xhigh":  return "XHigh"
        case "high":   return "High"
        case "medium": return "Medium"
        case "low":    return "Low"
        case "max":    return "Max"
        case "":       return nil
        default:       return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    private static func field(_ line: Substring, _ key: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...]
        guard let quote = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<quote])
        return value.isEmpty ? nil : value
    }
}
