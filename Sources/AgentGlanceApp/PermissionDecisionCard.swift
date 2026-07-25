import SwiftUI

import AgentGlanceCore

/// O cartão que te deixa decidir sem sair do editor.
///
/// Enquanto está aberto, do outro lado há um processo de hook bloqueado e um
/// agente parado à espera desta resposta — daí a barra de prazo. É a única
/// superfície da app onde o tempo corre contra ti, e por isso é a única que
/// o mostra.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let detail = request.detail, !detail.isEmpty {
                payload(detail)
            }
            actions
            deadline
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(spacing: 8) {
            Text(request.summary)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(remaining)s")
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(remaining <= 20 ? Color.orange : .white.opacity(0.35))
        }
        .overlay(alignment: .bottomLeading) {
            Text("\(request.projectName) · \(request.toolName)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)
                .offset(y: 15)
        }
        .padding(.bottom, 14)
    }

    // MARK: - Corpo

    /// O comando, o diff ou o plano. Literal e em monoespaçado, porque um
    /// comando mal lido é um comando mal aprovado.
    private func payload(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
        }
        .frame(maxHeight: 92)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }

    // MARK: - Ações

    private var actions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ActionListRow(label: "Allow", systemImage: "checkmark", fillsWidth: true) {
                    decide(.allow)
                }
                ActionListRow(
                    label: "Deny", systemImage: "xmark",
                    isDestructive: true, fillsWidth: true
                ) {
                    decide(.deny)
                }
            }
            if hasAlwaysOption {
                ActionListRow(
                    label: "Always allow this", systemImage: "checkmark.circle", fillsWidth: true
                ) {
                    decide(.allowAlways)
                }
            }
            ActionListRow(
                label: "Decide in the terminal", systemImage: "terminal", fillsWidth: true
            ) {
                decide(.defer_)
                reveal()
            }
        }
    }

    // MARK: - Prazo

    /// Quanto falta até o hook largar o agente por sua iniciativa. Encolhe da
    /// direita para a esquerda e fica âmbar nos últimos vinte segundos.
    private var deadline: some View {
        GeometryReader { geo in
            let total = request.expiresAt.timeIntervalSince(request.createdAt)
            let fraction = total > 0
                ? max(0, request.expiresAt.timeIntervalSince(now) / total)
                : 0
            Capsule()
                .fill(remaining <= 20 ? Color.orange : .white.opacity(0.28))
                .frame(width: max(0, geo.size.width * fraction))
                .animation(.linear(duration: 1), value: fraction)
        }
        .frame(height: 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
