import SwiftUI

import AgentGlanceCore

/// O cartão que te deixa decidir sem sair do editor.
///
/// Enquanto está aberto, do outro lado há um processo de hook bloqueado e um
/// agente parado à espera desta resposta.
///
/// Desenhado para o orçamento de altura do painel (`maximumCardHeight`, 316 pt)
/// e para a métrica da casa: os mesmos tamanhos de tipo das linhas de sessão,
/// os mesmos recuos, os mesmos botões. Um cartão que se lê como outra app é um
/// cartão que parece um remendo.
struct PermissionDecisionCard: View {
    let request: PermissionRequest
    let now: Date
    var decide: (PermissionDecision) -> Void
    var reveal: () -> Void

    private var remaining: Int {
        max(0, Int(request.expiresAt.timeIntervalSince(now)))
    }

    private var hasAlwaysOption: Bool {
        request.suggestions.contains {
            ($0.jsonObject as? [String: Any])?["behavior"] as? String == "allow"
        }
    }

    /// O poço do comando encolhe para caber o botão de "permitir sempre"
    /// quando ele existe — o orçamento é fixo e alguma coisa tem de ceder.
    private var payloadHeight: CGFloat { hasAlwaysOption ? 104 : 144 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            deadline
            header
            if let detail = request.detail, !detail.isEmpty {
                payload(detail)
            }
            actions
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(
            // Opaco, e não translúcido como o resto do painel. Uma decisão é a
            // única coisa nesta app que EXIGE leitura: o comando tem de se ler
            // sobre qualquer wallpaper, e o vidro não garante isso — sobre um
            // fundo claro o texto desaparecia.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.055, green: 0.055, blue: 0.065))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, SessionMenuLayout.contentHorizontalInset + 6)
        .padding(.bottom, 6)
    }

    // MARK: - Cabeçalho

    /// Os mesmos dois níveis de uma linha de sessão: o que é, e onde.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(request.summary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(remaining)s")
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(remaining <= 20 ? Color.orange : .white.opacity(0.32))
            }

            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 9.5))
                Text(request.projectName)
                Text("·")
                Text(request.toolName)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
        }
    }

    // MARK: - Corpo

    /// O comando, literal e em monoespaçado: um comando mal lido é um comando
    /// mal aprovado.
    private func payload(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.95))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: payloadHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.07))
        )
    }

    // MARK: - Ações

    /// Permitir e negar lado a lado, em largura natural — é o idioma que o
    /// `confirmingKill` já usa nesta app. A largura total por botão fazia-os
    /// flutuar em campos vazios e afastava-os um do outro.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ActionListRow(
                    label: "Allow", systemImage: "checkmark", fillsWidth: false
                ) { decide(.allow) }

                ActionListRow(
                    label: "Deny", systemImage: "xmark",
                    isDestructive: true, fillsWidth: false
                ) { decide(.deny) }

                Spacer(minLength: 0)

                Button {
                    decide(.defer_)
                    reveal()
                } label: {
                    Text("Decide in the terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }

            if hasAlwaysOption {
                ActionListRow(
                    label: "Always allow this",
                    systemImage: "checkmark.circle",
                    fillsWidth: true
                ) { decide(.allowAlways) }
            }
        }
    }

    // MARK: - Prazo

    /// Quanto falta até o hook largar o agente por sua iniciativa.
    ///
    /// Fio de 2 pt no topo do cartão. Estava em baixo e a toda a largura, e
    /// sobre um fundo claro lia-se como uma laje cinzenta entre os botões —
    /// mais pesada do que a informação que carrega.
    private var deadline: some View {
        GeometryReader { geo in
            let total = request.expiresAt.timeIntervalSince(request.createdAt)
            let fraction = total > 0
                ? max(0, request.expiresAt.timeIntervalSince(now) / total)
                : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                Capsule()
                    .fill(remaining <= 20 ? Color.orange : Color.white.opacity(0.30))
                    .frame(width: max(0, geo.size.width * fraction))
                    .animation(.linear(duration: 1), value: fraction)
            }
        }
        .frame(height: 2)
    }
}
