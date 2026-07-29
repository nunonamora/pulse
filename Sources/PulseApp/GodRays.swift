import SwiftUI

/// Feixes de luz a abrir do recorte quando o painel se expande.
///
/// O vocabulário visual do Vibe Island, feito à maneira da casa: SwiftUI puro,
/// sem Metal — um shader não se pode retratar fora de ecrã, e o que não se vê
/// não se entrega. Sete feixes determinísticos (nada de aleatório: o mesmo
/// abrir tem de produzir a mesma luz), em `plusLighter` para somarem como luz
/// e não como tinta.
///
/// A vida do efeito é uma badalada: cresce com o seno do progresso e morre com
/// ele. Luz que ficasse acesa seria decoração; a acender e apagar é pontuação
/// do gesto de abrir.
struct GodRays: View {
    /// 0…1 ao longo da expansão; a intensidade segue sin(π·progress).
    var progress: Double
    /// De onde os feixes nascem, em coordenadas da própria vista.
    var origin: CGPoint

    var body: some View {
        Canvas { context, size in
            let strength = sin(.pi * min(max(progress, 0), 1))
            guard strength > 0.01 else { return }
            // A mistura vive no contexto do Canvas e não na árvore de vistas:
            // um blendMode de vista obriga a compositing que o ImageRenderer
            // recusa em silêncio — e efeito que não se retrata não se entrega.
            context.blendMode = .plusLighter

            let rayCount = 7
            let spread = Angle.degrees(96)
            let reach = max(size.width, size.height) * 0.9

            for index in 0..<rayCount {
                let t = Double(index) / Double(rayCount - 1)
                let angle = Angle.degrees(90) - spread / 2 + spread * t
                // Larguras alternadas: feixes iguais leem-se como leque de
                // papel; a variação é o que os faz ler como luz.
                let halfWidth = Angle.degrees(index.isMultiple(of: 2) ? 2.4 : 1.3)
                let alpha = strength * (index.isMultiple(of: 2) ? 0.10 : 0.055)

                var path = Path()
                path.move(to: origin)
                path.addLine(to: point(from: origin, angle: angle - halfWidth, distance: reach))
                path.addLine(to: point(from: origin, angle: angle + halfWidth, distance: reach))
                path.closeSubpath()

                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            .white.opacity(alpha),
                            .white.opacity(alpha * 0.35),
                            .clear,
                        ]),
                        startPoint: origin,
                        endPoint: point(from: origin, angle: angle, distance: reach)
                    )
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func point(from origin: CGPoint, angle: Angle, distance: CGFloat) -> CGPoint {
        CGPoint(
            x: origin.x + cos(angle.radians) * distance,
            y: origin.y + sin(angle.radians) * distance
        )
    }
}

/// Dispara os feixes uma vez por expansão, ao lado do ripple.
struct GodRayEffect: ViewModifier {
    let trigger: Int
    /// O centro do recorte, em X, dentro da largura do painel.
    let originX: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if !reduceMotion {
                // O mesmo relógio do ripple: keyframes que só avançam
                // enquanto o efeito vive; fora disso o overlay é um Canvas
                // com strength 0, que desenha nada.
                KeyframeRays(trigger: trigger, originX: originX)
            }
        }
    }
}

private struct KeyframeRays: View {
    let trigger: Int
    let originX: CGFloat

    var body: some View {
        GeometryReader { geo in
            KeyframeAnimator(
                initialValue: 0.0, trigger: trigger
            ) { progress in
                GodRays(
                    progress: trigger == 0 ? 0 : progress,
                    origin: CGPoint(x: originX, y: 0)
                )
                .frame(width: geo.size.width, height: geo.size.height)
            } keyframes: { _ in
                MoveKeyframe(0)
                LinearKeyframe(1.0, duration: 0.7)
            }
        }
        .allowsHitTesting(false)
    }
}
