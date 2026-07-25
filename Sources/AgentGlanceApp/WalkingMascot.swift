import SwiftUI

import AgentGlanceCore

/// Um mascote em pixels a andar de um lado para o outro na barra.
///
/// Vive numa faixa própria, ao lado do spinner braille e sem o substituir: os
/// dois dizem coisas diferentes. O spinner conta QUANTAS sessões estão a
/// trabalhar; o mascote diz QUEM está a trabalhar, pela cor e pela forma, e é a
/// única coisa nesta app com direito a personalidade — a única que representa
/// um agente e não um estado.
///
/// Anda só quando há trabalho a decorrer. Em repouso a barra volta a ser só a
/// barra: uma criatura a passear sobre nada seria movimento sem informação, e
/// isso na periferia da visão cansa.
///
/// Desenhado em bitmaps de texto e não em imagens: a esta escala cada célula
/// são dois pontos, e um sprite ficaria borrado onde o desenho a código fica
/// nítido. Também mantém a marca fora de qualquer ficheiro de terceiros.
struct WalkingMascot: View {
    let tool: AgentTool
    /// Largura do trajeto. A criatura vai até à ponta, vira-se e volta.
    var runway: CGFloat = 30
    var cell: CGFloat = 1.6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Um passo completo por 0,16 s — o suficiente para ler como passada e não
    /// como tremor.
    private static let step: TimeInterval = 0.16
    /// Quanto tempo demora a atravessar o trajeto de uma ponta à outra.
    private static let crossing: TimeInterval = 3.2

    var body: some View {
        if reduceMotion {
            sprite(frame: 0)
                .frame(width: runway, alignment: .center)
        } else {
            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // Onda triangular: 0 → 1 → 0, sem salto nas pontas.
                let cycle = (t / Self.crossing).truncatingRemainder(dividingBy: 2)
                let progress = cycle < 1 ? cycle : 2 - cycle
                let facingLeft = cycle >= 1
                let frame = Int(t / Self.step) % 2

                sprite(frame: frame)
                    .scaleEffect(x: facingLeft ? -1 : 1)
                    .offset(
                        x: (runway - spriteWidth) * (progress - 0.5),
                        // Sobe um pixel a cada passada. É o que separa andar
                        // de deslizar.
                        y: frame == 1 ? -1 : 0
                    )
                    .frame(width: runway, alignment: .center)
            }
        }
    }

    private var spriteWidth: CGFloat {
        cell * CGFloat(MascotArt.frames(for: tool)[0][0].count)
    }

    private func sprite(frame: Int) -> some View {
        let bitmap = MascotArt.frames(for: tool)[frame % 2]
        return Canvas { context, _ in
            for (row, line) in bitmap.enumerated() {
                for (column, character) in line.enumerated() where character != "." {
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                            width: cell, height: cell
                        )),
                        with: .color(character == "#" ? MascotArt.color(tool) : MascotArt.shade(tool))
                    )
                }
            }
        }
        .frame(width: spriteWidth, height: cell * CGFloat(bitmap.count))
    }
}

/// Os bitmaps.
///
/// `#` é a cor cheia, `+` é o tom mais escuro das pernas — dois níveis chegam
/// para dar volume sem o desenho virar mancha.
enum MascotArt {

    typealias Bitmap = [String]

    static func frames(for tool: AgentTool) -> [Bitmap] {
        switch tool {
        case .claude:   return claude
        case .codex:    return codex
        case .opencode: return opencode
        case .pi:       return pi
        case .convoy:   return convoy
        }
    }

    /// Corpo cheio com orelhas, olhos e pernas.
    ///
    /// Uma primeira versão desenhava a estrela de oito pontas da marca. Ficava
    /// bonita ampliada e, ao tamanho real, os braços da estrela liam-se como
    /// pixels soltos a flutuar ao lado do corpo — ruído, não desenho. A esta
    /// escala a silhueta é tudo: um corpo fechado com dois olhos lê-se, uma
    /// estrela não.
    private static let claude: [Bitmap] = [
        [
            "..#...#..",
            ".#######.",
            "#########",
            "#.#####.#",
            "#.#...#.#",
            ".#######.",
            "..#####..",
            "...+.+...",
            "..+...+..",
        ],
        [
            "..#...#..",
            ".#######.",
            "#########",
            "#.#####.#",
            "#.#...#.#",
            ".#######.",
            "..#####..",
            "...+++...",
            "...+.+...",
        ],
    ]

    /// Célula hexagonal.
    private static let codex: [Bitmap] = [
        [
            "..#####..",
            ".#.....#.",
            "#..###..#",
            "#.#...#.#",
            "#..###..#",
            ".#.....#.",
            "..#####..",
            "...+.+...",
            "..+...+..",
        ],
        [
            "..#####..",
            ".#.....#.",
            "#..###..#",
            "#.#####.#",
            "#..###..#",
            ".#.....#.",
            "..#####..",
            "...+++...",
            "...+.+...",
        ],
    ]

    private static let opencode: [Bitmap] = [
        [
            ".##...##.",
            "##..#..##",
            "#..###..#",
            "..#####..",
            "#..###..#",
            "##..#..##",
            ".##...##.",
            "...+.+...",
            "..+...+..",
        ],
        [
            ".##...##.",
            "##..#..##",
            "#..###..#",
            ".#######.",
            "#..###..#",
            "##..#..##",
            ".##...##.",
            "...+++...",
            "...+.+...",
        ],
    ]

    private static let pi: [Bitmap] = [
        [
            ".#######.",
            "..#...#..",
            "..#...#..",
            "..#...#..",
            "..#...#..",
            ".##...#..",
            "........",
            "...+.+...",
            "..+...+..",
        ],
        [
            ".#######.",
            "..#...#..",
            "..#...#..",
            "..#...#..",
            "..#...#..",
            ".##...##.",
            "........",
            "...+++...",
            "...+.+...",
        ],
    ]

    private static let convoy: [Bitmap] = [
        [
            "..#####..",
            ".#######.",
            "#.#...#.#",
            "#.......#",
            "#.#...#.#",
            ".#######.",
            "..#####..",
            "...+.+...",
            "..+...+..",
        ],
        [
            "..#####..",
            ".#######.",
            "#.#...#.#",
            "#..###..#",
            "#.#...#.#",
            ".#######.",
            "..#####..",
            "...+++...",
            "...+.+...",
        ],
    ]

    static func color(_ tool: AgentTool) -> Color {
        switch tool {
        case .claude:   return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex:    return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .opencode: return Color(red: 0.37, green: 0.55, blue: 1.00)
        case .pi:       return Color(red: 0.96, green: 0.45, blue: 0.71)
        case .convoy:   return Color(red: 0.18, green: 0.83, blue: 0.75)
        }
    }

    /// As pernas, um pouco mais escuras: dão volume sem competir com o corpo.
    static func shade(_ tool: AgentTool) -> Color {
        color(tool).opacity(0.55)
    }
}
