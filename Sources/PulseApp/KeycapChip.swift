import SwiftUI

/// Um atalho de teclado impresso na interface — ⌘1, ⏎, esc.
///
/// Existia duas vezes com seis propriedades diferentes por um incremento cada:
/// o ⌘N das linhas a 10/rounded/0,45 sobre 0,09 com raio 4, e o ⏎-esc dos
/// botões a 9,5/mono/0,38 sobre 0,09 com raio 3. Nenhuma das diferenças era
/// uma decisão — eram duas escritas da mesma ideia em dias diferentes. Um
/// atalho é um atalho: um só desenho, aprendido uma vez.
struct KeycapChip: View {
    let label: String
    /// Sobre um botão já preenchido, o chip recua um degrau para não competir
    /// com o rótulo; solto numa linha, é ele o sinal e leva o valor pleno.
    var subdued: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(subdued ? 0.38 : 0.45))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.09))
            )
            .accessibilityHidden(true)
    }
}
