import SwiftUI

import PulseCore

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
    var runway: CGFloat = NotchLayout.mascotLaneWidth
    var cell: CGFloat = 2.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Num retrato para ficheiro não há relógio: o `TimelineView` devolveria
    /// vista inválida e levaria a barra inteira com ele. Fica parado, que é o
    /// mesmo caminho que já servia quem pede menos movimento.
    @Environment(\.isStaticRender) private var isStaticRender

    /// Um passo completo por 0,16 s — o suficiente para ler como passada e não
    /// como tremor.
    private static let step: TimeInterval = 0.16
    /// Quanto tempo demora a atravessar o trajeto de uma ponta à outra.
    private static let crossing: TimeInterval = 2.6

    var body: some View {
        // Decorativo por definição: diz QUEM trabalha a quem vê, e o
        // indicador com contagem já o diz a quem ouve. Duas fontes do mesmo
        // facto no VoiceOver seriam ruído, não redundância.
        if reduceMotion || isStaticRender {
            sprite(frame: 0)
                .frame(width: runway, alignment: .center)
                .accessibilityHidden(true)
        } else {
            // 10 fps, não 30. O passeio anda a ~5 pt/s — meio ponto por
            // fotograma a 10 fps, que nenhum olho distingue de contínuo — e o
            // passo troca a cada 0,16 s de qualquer maneira. A 30 fps este
            // TimelineView era o maior consumidor de CPU da app inteira:
            // medido, a barra com mascote custava 10,8% contra 3,4% parada.
            TimelineView(.periodic(from: .now, by: 1.0 / 10)) { timeline in
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
            .accessibilityHidden(true)
        }
    }

    /// Contorno escuro à volta de cada pixel.
    ///
    /// Dentro da faixa preta ele tinha contraste garantido de graça. Por fora
    /// não tem nenhum: sobre um wallpaper alaranjado o coral desaparecia. O
    /// rebordo é o que o torna independente do que estiver por baixo, e a
    /// 0,7 pt lê-se como definição do desenho e não como sombra colada.
    private var rim: CGFloat { 0.7 }

    private var spriteWidth: CGFloat {
        cell * CGFloat(MascotArt.frames(for: tool)[0][0].count) + rim * 2
    }

    private func sprite(frame: Int) -> some View {
        let bitmap = MascotArt.frames(for: tool)[frame % 2]
        return Canvas { context, _ in
            // Uma passagem para o contorno e uma por cor, cada uma num único
            // caminho com todos os seus retângulos.
            //
            // Um `fill` por célula deixava uma grelha escura dentro do corpo: a
            // célula mede 2,2 pt, nunca assenta em pixels inteiros, e cada
            // preenchimento antialiasado punha meia transparência na costura
            // por onde o contorno de baixo aparecia. Juntos no mesmo caminho,
            // os retângulos preenchem como uma região só e não há costura
            // nenhuma para atravessar.
            func region(_ include: (Character) -> Bool, inset: CGFloat) -> Path {
                var path = Path()
                for (row, line) in bitmap.enumerated() {
                    for (column, character) in line.enumerated()
                    where character != "." && include(character) {
                        path.addRect(
                            CGRect(
                                x: rim + CGFloat(column) * cell,
                                y: rim + CGFloat(row) * cell,
                                width: cell, height: cell
                            ).insetBy(dx: inset, dy: inset)
                        )
                    }
                }
                return path
            }

            context.fill(region({ _ in true }, inset: -rim), with: .color(.black.opacity(0.55)))
            context.fill(region({ $0 == "#" }, inset: 0), with: .color(MascotArt.color(tool)))
            context.fill(region({ $0 == "+" }, inset: 0), with: .color(MascotArt.shade(tool)))
        }
        .frame(width: spriteWidth, height: cell * CGFloat(bitmap.count) + rim * 2)
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

    /// Um esqueleto comum: coroa, corpo de seis linhas, duas de pernas.
    ///
    /// Só a coroa e os olhos mudam por ferramenta. A esta escala a silhueta é
    /// quase tudo o que se lê em movimento, e cinco silhuetas diferentes seriam
    /// cinco criaturas sem parentesco — o que muda tem de ser o detalhe, não a
    /// forma.
    ///
    /// Os olhos são buracos, não pixels escuros: sobre a barra preta o fundo
    /// faz-lhes o trabalho. Ficam recuados uma célula da margem. Uma versão
    /// anterior punha-os na borda e abria uma fenda de três células debaixo
    /// deles; ampliada parecia um rosto, ao tamanho real lia-se como uma boca
    /// escancarada e o desenho perdia os olhos.
    private static let claude: [Bitmap] = [
        crown("..#...#..", legs: .stride),   // orelhas
        crown("..#...#..", legs: .passing),
    ]

    private static let codex: [Bitmap] = [
        crown("..#####..", legs: .stride),
        crown("..#####..", legs: .passing),
    ]

    private static let opencode: [Bitmap] = [
        crown(".##...##.", legs: .stride),
        crown(".##...##.", legs: .passing),
    ]

    private static let pi: [Bitmap] = [
        crown("....#....", legs: .stride),   // antena
        crown("....#....", legs: .passing),
    ]

    private static let convoy: [Bitmap] = [
        crown("...###...", legs: .stride),
        crown("...###...", legs: .passing),
    ]

    private enum Legs {
        /// Pernas afastadas: o momento em que um pé assenta.
        case stride
        /// Pernas juntas: o momento em que uma passa pela outra. Alternar entre
        /// as duas, com o corpo a subir um pixel na segunda, é o mínimo que
        /// se lê como andar em vez de deslizar.
        case passing

        var rows: [String] {
            switch self {
            case .stride:  return ["..+...+..", "..+...+.."]
            case .passing: return ["...+.+...", "...+.+..."]
            }
        }
    }

    private static func crown(_ top: String, legs: Legs) -> Bitmap {
        [
            top,
            ".#######.",
            "##.###.##",   // olhos recuados, ombros a sair para fora
            "#########",
            ".#######.",
            "..#####..",
        ] + legs.rows
    }

    private static func rgb(_ tool: AgentTool) -> (Double, Double, Double) {
        switch tool {
        case .claude:   return (0.85, 0.47, 0.34)
        case .codex:    return (0.06, 0.64, 0.50)
        case .opencode: return (0.37, 0.55, 1.00)
        case .pi:       return (0.96, 0.45, 0.71)
        case .convoy:   return (0.18, 0.83, 0.75)
        }
    }

    static func color(_ tool: AgentTool) -> Color {
        let (r, g, b) = rgb(tool)
        return Color(red: r, green: g, blue: b)
    }

    /// As pernas, um pouco mais escuras: dão volume sem competir com o corpo.
    ///
    /// Escurecidas na própria cor e não com opacidade. Translúcidas, deixavam
    /// passar o contorno preto e saíam lamacentas em vez de sombreadas — a
    /// transparência compõe com o que estiver por baixo, e por baixo está
    /// justamente aquilo de que se queriam distinguir.
    static func shade(_ tool: AgentTool) -> Color {
        let (r, g, b) = rgb(tool)
        return Color(red: r * 0.62, green: g * 0.62, blue: b * 0.62)
    }
}
