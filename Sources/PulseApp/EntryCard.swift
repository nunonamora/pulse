import SwiftUI

import PulseCore

// MARK: - Bitmap partilhado

/// Desenha um bitmap de texto do estilo do mascote a qualquer escala.
///
/// O mesmo truque do `WalkingMascot` — os retângulos de cada cor juntos num
/// único caminho — pela mesma razão: preenchidos célula a célula, o antialias
/// abre costuras entre vizinhas quando a célula não assenta em pixels
/// inteiros; num caminho só, cada cor preenche como uma região inteira.
struct PixelBitmap: View {
    let bitmap: [String]
    let fill: Color
    let shade: Color
    var cell: CGFloat

    var body: some View {
        Canvas { context, _ in
            func region(_ include: (Character) -> Bool) -> Path {
                var path = Path()
                for (row, line) in bitmap.enumerated() {
                    for (column, character) in line.enumerated()
                    where character != "." && include(character) {
                        path.addRect(CGRect(
                            x: CGFloat(column) * cell,
                            y: CGFloat(row) * cell,
                            width: cell, height: cell
                        ))
                    }
                }
                return path
            }
            context.fill(region { $0 == "#" }, with: .color(fill))
            context.fill(region { $0 == "+" }, with: .color(shade))
        }
        .frame(
            width: cell * CGFloat(bitmap.first?.count ?? 0),
            height: cell * CGFloat(bitmap.count)
        )
        .accessibilityHidden(true)
    }
}

// MARK: - O aceno

/// A criatura de boas-vindas, com um braço acrescentado ao esqueleto do
/// mascote. É de propósito a MESMA personagem que depois passeia na barra —
/// mesma coroa, mesmo corpo — para que o primeiro encontro ensine a
/// reconhecê-la, não apresente uma mascote de ocasião que nunca mais aparece.
///
/// Dois fotogramas, como o andar: a esta escala dois desenhos alternados
/// leem-se como gesto, e um terceiro seria detalhe que ninguém vê.
private enum WaveArt {
    /// Braço esticado, mão ao alto — também o fotograma parado, porque uma
    /// mão no ar cumprimenta mesmo sem se mexer.
    static let up: [String] = [
        "..#...#...#",
        ".#######..#",
        "##.###.##.#",
        "#########+.",
        ".#######...",
        "..#####....",
        "..+...+....",
        "..+...+....",
    ]
    /// Braço a meio caminho: alternar com o de cima é o aceno.
    static let mid: [String] = [
        "..#...#....",
        ".#######...",
        "##.###.##.#",
        "#########+#",
        ".#######...",
        "..#####....",
        "..+...+....",
        "..+...+....",
    ]
}

private struct WavingCreature: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStaticRender) private var isStaticRender
    @State private var armUp = true

    var body: some View {
        // Um Timer e não um TimelineView: o arnês de retratos não desenha
        // TimelineView, e com movimento reduzido o mesmo caminho parado serve
        // — a mão fica no ar, que cumprimenta na mesma.
        if reduceMotion || isStaticRender {
            sprite
        } else {
            // 0,42 s por fotograma: mais rápido lia-se como tremura, mais
            // lento como duas imagens sem relação. O aceno é pontuação do
            // cartão, não um espetáculo — o painel vazio deve continuar calmo.
            sprite.onReceive(
                Timer.publish(every: 0.42, on: .main, in: .common).autoconnect()
            ) { _ in
                armUp.toggle()
            }
        }
    }

    private var sprite: some View {
        PixelBitmap(
            bitmap: armUp ? WaveArt.up : WaveArt.mid,
            fill: MascotArt.color(.claude),
            shade: MascotArt.shade(.claude),
            // A célula do corpo dá ~32 pt de criatura: maior do que o ícone
            // das linhas (é a protagonista do cartão), menor do que um boneco
            // que empurrasse o texto para fora do painel compacto.
            cell: 3.6
        )
    }
}

// MARK: - Cartão de entrada

/// O que o painel mostra a quem ainda não tem nada — nem sessões, nem
/// histórico.
///
/// Um vazio de primeiro dia não é um vazio: é a primeira conversa da app. A
/// criatura cumprimenta, o texto diz o único passo que existe a seguir, e o
/// atalho fica já ensinado. Quem já tem histórico não passa por aqui — para
/// esse, o vazio volta a ser o aviso discreto de sempre, porque ser recebido
/// duas vezes é ser interrompido.
struct EntryCard: View {
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            WavingCreature()
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Pulse")
                    .font(VITheme.mono(13))
                    .foregroundStyle(.white)
                // A mesma frase útil do estado vazio de sempre: descreve o
                // passo, não o nada — e a 0,52 de opacidade, o contraste
                // medido que texto corrido precisa sobre este painel.
                Text("Start Claude, Codex or OpenCode in a terminal and it shows up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    KeycapChip(label: "⌥⌘A")
                    Text("opens this panel anytime")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.top, 2)
            }
        }
    }
}
