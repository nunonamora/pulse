import SwiftUI

import PulseCore

/// A pergunta do agente, com as opções prontas a escolher — o cartão central
/// do Vibe Island, desenhado como na página deles: "Claude asks" em teal,
/// opções em cápsulas escuras com o keycap ⌘N à esquerda.
///
/// Escolher uma opção escreve o número dela no painel da sessão pelo
/// ReplyService — o prompt do terminal continua a ser a fonte de verdade, e é
/// por isso que o cartão desaparece quando a pergunta é respondida em
/// QUALQUER dos lados (o PostToolUse limpa-a).
struct QuestionCard: View {
    let question: AgentQuestion
    /// A sessão dona da pergunta, se ainda existir — é dela que vem o canal.
    let session: AgentSession?
    var bandInset: CGFloat
    var textInset: CGFloat
    var dismiss: () -> Void

    /// O teal do Vibe Island, o único sítio da app onde ele fala: este cartão
    /// É o vocabulário deles, e a cor é a assinatura.
    private static let accent = VITheme.teal

    @State private var failed = false
    @FocusState private var keyboardFocused: Bool

    private var canAnswer: Bool {
        session.map(ReplyService.canReply(to:)) ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("\(question.tool.spokenName) asks")
                    .font(VITheme.mono(11, weight: .semibold))
            }
            .foregroundStyle(Self.accent)

            Text(question.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, label in
                    optionRow(index: index, label: label)
                }
            }

            if failed {
                Text("Could not reach that pane — answer in the terminal.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.97, green: 0.38, blue: 0.36))
            } else if !canAnswer {
                Text("Answer in the terminal — this session has no reply channel.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, max(0, textInset - bandInset))
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.74))
        .padding(.horizontal, bandInset)
        .padding(.bottom, 6)
        .focusable()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard press.modifiers.contains(.command),
                  let digit = Int(String(press.characters)),
                  digit >= 1, digit <= question.options.count
            else { return .ignored }
            answer(index: digit - 1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(question.tool.spokenName) asks: \(question.question)")
    }

    private func optionRow(index: Int, label: String) -> some View {
        Button { answer(index: index) } label: {
            HStack(spacing: 8) {
                KeycapChip(label: "⌘\(index + 1)")
                Text(label)
                    .font(VITheme.mono(12))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Self.accent.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Self.accent.opacity(0.22), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(PressableButtonStyle())
        .linkCursor()
        .disabled(!canAnswer)
        .opacity(canAnswer ? 1 : 0.5)
    }

    /// Responder é escrever o número da opção no prompt do terminal — o mesmo
    /// gesto que farias lá, feito daqui.
    private func answer(index: Int) {
        guard let session else { return }
        do {
            try ReplyService.send(reply: "\(index + 1)", to: session)
            dismiss()
        } catch {
            failed = true
        }
    }
}
