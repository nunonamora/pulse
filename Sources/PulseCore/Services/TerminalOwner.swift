import Darwin
import Foundation

/// Descobre a aplicação que é dona de um terminal, a partir do seu tty.
///
/// O `FocusPlanner` só sabe apontar a Ghostty, o iTerm2, o Terminal.app e
/// painéis tmux. Qualquer outra coisa — o cmux, o terminal integrado do Cursor,
/// o WezTerm, o kitty — não tinha alvo nenhum e a app respondia com um erro em
/// vermelho, o que é a pior resposta possível: não faz nada e ainda te diz que
/// falhou.
///
/// O tty, esse, existe quase sempre. A partir dele sobe-se a árvore de
/// processos até encontrar um que pertença a uma aplicação com interface, e
/// traz-se essa à frente. Não acerta no separador certo — mas pôr-te à frente
/// da janela certa é muito melhor do que uma linha vermelha.
public enum TerminalOwner {

    /// PID da aplicação com interface que aloja este tty, se houver.
    public static func applicationPID(forTTY tty: String) -> pid_t? {
        guard let leaders = processes(onTTY: tty), !leaders.isEmpty else { return nil }
        for leader in leaders {
            var pid: pid_t? = leader
            // Oito saltos chegam: shell → login → app. Mais do que isso e já
            // saímos para o launchd, que não é dono de nada.
            for _ in 0..<8 {
                guard let current = pid else { break }
                if isApplication(current) { return current }
                pid = parent(of: current)
            }
        }
        return nil
    }

    /// Sobe a partir de um processo qualquer até à aplicação que o aloja.
    public static func applicationPID(ofDescendant pid: pid_t) -> pid_t? {
        var current: pid_t? = pid
        for _ in 0..<8 {
            guard let value = current else { break }
            if isApplication(value) { return value }
            current = parent(of: value)
        }
        return nil
    }

    /// Processos ligados a um tty, do mais antigo para o mais recente.
    private static func processes(onTTY tty: String) -> [pid_t]? {
        // O `ps` aceita o tty sem o /dev/ à frente.
        let name = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard let output = shell("/bin/ps", ["-t", name, "-o", "pid="]) else { return nil }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        guard let output = shell("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"]),
              let value = pid_t(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 1
        else { return nil }
        return value
    }

    /// É um processo de uma aplicação com interface?
    ///
    /// O caminho do executável dentro de um `.app` é o sinal, e é fiável sem
    /// depender do AppKit — isto vive no Core, que também corre no CLI.
    private static func isApplication(_ pid: pid_t) -> Bool {
        guard let path = executablePath(pid) else { return false }
        return path.contains(".app/Contents/MacOS/")
    }

    public static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func shell(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
