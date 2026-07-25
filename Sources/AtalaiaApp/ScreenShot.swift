import AppKit
import ScreenCaptureKit

/// Fotografa a faixa de topo do ecrã, a partir de dentro da app.
///
/// Tem de ser a app a disparar: a autorização de Gravação de Ecrã é dada ao
/// pacote, e o binário `atalaia` que vive em `~/.atalaia/bin` é uma
/// cópia fora dele — teria identidade diferente e seria recusado.
///
/// Existe para se poder ver o resultado de mudanças na barra sem depender de
/// alguém tirar a fotografia à mão. Dispara-se com:
///
///     kill -USR1 $(pgrep -x Atalaia)
///
/// e escreve em /tmp/atalaia-shot.png.
@MainActor
enum ScreenShot {

    nonisolated static let defaultPath = "/tmp/atalaia-shot.png"

    static func captureTop(height: CGFloat = 560, to path: String = defaultPath) async -> String {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            return "sem autorização de gravação de ecrã"
        }

        let screen = NSScreen.screens.first { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(n.uint32Value) == 1
        } ?? NSScreen.main
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return "não encontrei o ecrã" }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.displayID == number.uint32Value })
                    ?? content.displays.first
            else { return "não encontrei o display" }

            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []),
                configuration: config
            )

            // Só a faixa de topo: é onde a barra vive, e uma imagem do ecrã
            // inteiro esconderia o detalhe que interessa.
            let crop = CGRect(x: 0, y: 0,
                              width: CGFloat(image.width),
                              height: min(CGFloat(image.height), height * scale))
            let cropped = image.cropping(to: crop) ?? image

            guard let png = NSBitmapImageRep(cgImage: cropped)
                .representation(using: .png, properties: [:]) else {
                return "falhou a codificar o PNG"
            }
            try png.write(to: URL(fileURLWithPath: path))
            return "ok"
        } catch {
            return "falhou: \(error.localizedDescription)"
        }
    }
}
