import AppKit
import SwiftUI

/// O tema do clone: as cores e a tipografia do Vibe Island, e as molas do Arc.
///
/// Uma app "exatamente igual" começa por um sítio único onde a identidade
/// vive. Cores lidas das capturas reais do painel deles; a fonte é a mesma
/// que eles usam — Departure Mono, de Helena Zhang, SIL OFL, obtida do
/// repositório oficial da autora e distribuída com a licença ao lado.
enum VITheme {

    // MARK: Cores, medidas das capturas

    /// O preto do painel. Chapado: o VI não tem vidro.
    static let panel = Color(red: 0.04, green: 0.04, blue: 0.045)
    /// Verde das percentagens e do "tudo bem".
    static let green = Color(red: 0.19, green: 0.78, blue: 0.35)
    /// Azul da linha de atividade viva.
    static let blue = Color(red: 0.35, green: 0.55, blue: 0.98)
    /// Laranja da faísca da quota.
    static let spark = Color(red: 0.98, green: 0.63, blue: 0.25)
    /// Teal do "Claude asks".
    static let teal = Color(red: 0.20, green: 0.85, blue: 0.78)
    /// Fundo dos chips.
    static let chip = Color.white.opacity(0.12)

    // MARK: Tipografia

    private static let fontName = "Departure Mono"
    private static var registered = false

    /// Regista a OTF empacotada uma vez. Falhar não pode partir nada: sem a
    /// fonte, tudo cai no monospaced do sistema e a app continua legível.
    static func registerFonts() {
        guard !registered else { return }
        registered = true
        guard let url = Bundle.module.url(
            forResource: "Fonts/DepartureMono-Regular", withExtension: "otf")
            ?? Bundle.module.url(forResource: "DepartureMono-Regular", withExtension: "otf",
                                 subdirectory: "Fonts")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// A voz tipográfica do clone. Departure Mono se registada; senão o
    /// monospaced do sistema com o mesmo corpo.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: fontName, size: size) != nil {
            return .custom(fontName, size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Molas à Arc

    /// A mola das superfícies: saltitona q.b. — o overshoot pequeno é a
    /// assinatura do Arc, movimento com personalidade sem virar desenho
    /// animado.
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.72)
    /// A mola dos elementos pequenos (linhas, cartões): mais curta, mesmo
    /// feitio.
    static let pop = Animation.spring(response: 0.28, dampingFraction: 0.68)
}
