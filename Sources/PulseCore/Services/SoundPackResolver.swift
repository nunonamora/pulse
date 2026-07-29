import Foundation

/// Resolve que ficheiro de som toca para um evento, se o utilizador tiver
/// instalado um pack.
///
/// Paridade com o Vibe Island, que deixa importar packs de sons. O contrato é
/// uma pasta de ficheiros com nomes previsíveis — sem manifesto, sem formato
/// próprio: quem sabe copiar ficheiros sabe fazer um pack.
///
/// Ordem de resolução, da mais específica para a mais geral:
///
///     <tool>-<event>.<ext>     claude-needs-decision.wav
///     <event>.<ext>            needs-decision.aiff
///
/// Extensões aceites: wav, aiff, mp3, m4a, caf. Sem ficheiro, a app volta à
/// síntese — um pack incompleto personaliza só o que quis personalizar.
public enum SoundPackResolver {

    public static let extensions = ["wav", "aiff", "mp3", "m4a", "caf"]

    /// A pasta do pack: `~/.pulse/sounds/`.
    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pulse/sounds", isDirectory: true)
    }

    public static func resolve(
        tool: String, event: String,
        in directory: URL = defaultDirectory()
    ) -> URL? {
        for name in ["\(tool)-\(event)", event] {
            for ext in extensions {
                let candidate = directory
                    .appendingPathComponent(name)
                    .appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
