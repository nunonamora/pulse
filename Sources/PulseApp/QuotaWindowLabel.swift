import SwiftUI

import PulseCore

/// Uma janela de limite no cabeçalho: nome, quanto vai gasto, e quanto falta
/// para renovar — "5h 69% 2h14m".
///
/// A contagem decrescente é o que torna a percentagem acionável. Saber que se
/// gastou 69% não diz nada sozinho: 69% com duas horas pela frente é
/// confortável, 69% com dez minutos é uma sessão que vai bater no limite a
/// meio de uma tarefa. É a segunda metade que muda a decisão.
///
/// Sem plano escolhido não há percentagem — mostra-se o consumo absoluto, que
/// é sempre verdadeiro. Um denominador inventado dava um número bonito e uma
/// falsa sensação de folga, que é exatamente o erro que isto existe para
/// evitar.
struct QuotaWindowLabel: View {
    let name: String
    let window: QuotaWindow.Window?
    /// O que mostrar quando não há janela resolvida nem plano: o consumo cru.
    let fallback: String?

    @Environment(\.isStaticRender) private var isStaticRender

    var body: some View {
        HStack(spacing: 5) {
            Text(name)
                .font(VITheme.mono(12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            if let window {
                if let fraction = window.fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(VITheme.mono(12, weight: .semibold))
                        .foregroundStyle(color(for: fraction))
                } else if let fallback {
                    Text(fallback)
                        .font(VITheme.mono(12, weight: .semibold))
                        .foregroundStyle(VITheme.green)
                }
                // O relógio só precisa de acordar ao minuto, e no retrato
                // fora de ecrã não acorda de todo — um TimelineView sem
                // guarda devolve uma vista que o ImageRenderer recusa.
                Group {
                    if isStaticRender {
                        countdown(at: Date())
                    } else {
                        TimelineView(.everyMinute) { context in
                            countdown(at: context.date)
                        }
                    }
                }
            } else if let fallback {
                Text(fallback)
                    .font(VITheme.mono(12, weight: .semibold))
                    .foregroundStyle(VITheme.green)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func countdown(at date: Date) -> some View {
        Text(window?.countdown(now: date) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
    }

    /// Verde enquanto há folga, laranja a partir de metade, vermelho quando o
    /// limite deixou de ser hipótese. Os cortes são generosos de propósito: um
    /// aviso que aparece cedo demais deixa de ser lido.
    private func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.5:  return VITheme.green
        case ..<0.85: return VITheme.spark
        default:      return Color(red: 0.97, green: 0.38, blue: 0.36)
        }
    }

    private var accessibilityLabel: String {
        guard let window else { return "\(name) window" }
        let used = window.fraction.map { "\(Int($0 * 100)) percent used, " } ?? ""
        return "\(name) window, \(used)resets in \(window.countdown())"
    }
}
