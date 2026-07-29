// Desenha o fundo da janela do instalador (.dmg) da Pulse.
//
// Gerado em código, como o ícone (scripts/make-icon.swift), e pelo mesmo
// motivo: o fundo não é uma fotografia, é uma peça da identidade. Desenhá-lo
// com as mesmas primitivas — a superfície do painel, o P de onda, o grão —
// garante que o instalador e a app são visivelmente a mesma coisa, e permite
// afinar posições ao ponto, porque as coordenadas daqui têm de casar com as
// posições dos ícones que o make-dmg.sh define via Finder.
//
// A geometria é pensada para uma janela de 660×420 pt com dois ícones de
// 128 px centrados a x=165 (a app) e x=495 (a pasta Applications), ambos a
// y=185 do topo. Tudo o que se desenha ou evita desenhar respeita esses dois
// lugares: o P é um fantasma ATRÁS do sítio da app, a seta vive no vão entre
// os dois ícones, o texto fica abaixo das legendas do Finder.
//
// Uso: swift scripts/make-dmg-background.swift [saída.png]

import AppKit
import CoreText

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "assets/dmg-background.png"

// 660×420 pt desenhados a @2x. O Finder lê o tamanho em pontos do pHYs do
// PNG — é o `rep.size` lá em baixo que faz um bitmap de 1320×840 ocupar
// 660 pt na janela em vez de sair a dobrar num ecrã Retina.
let pointW: CGFloat = 660, pointH: CGFloat = 420
let scale: CGFloat = 2

let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(
    data: nil, width: Int(pointW * scale), height: Int(pointH * scale),
    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.scaleBy(x: scale, y: scale)  // daqui em diante, coordenadas em pontos
context.setAllowsAntialiasing(true)
context.interpolationQuality = .high

// Os dois lugares dos ícones, em coordenadas CG (origem em baixo).
// y = 420 − 185: o AppleScript posiciona a partir do topo, o CG a partir da base.
let appSpot = CGPoint(x: 165, y: pointH - 185)
let folderSpot = CGPoint(x: 495, y: pointH - 185)

// MARK: - Superfície

// O preto do painel (#0A0A0B, o `VITheme.panel`), com um gradiente quase
// impercetível a clarear o topo. Um preto chapado numa janela grande lê-se
// como buraco; dois por cento de luz no topo lê-se como superfície.
let backdrop = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(red: 0.075, green: 0.075, blue: 0.086, alpha: 1),
    CGColor(red: 0.039, green: 0.039, blue: 0.043, alpha: 1),
] as CFArray, locations: [0, 1])!
context.drawLinearGradient(
    backdrop, start: CGPoint(x: 0, y: pointH), end: CGPoint(x: 0, y: 0), options: []
)

// Um halo ténue por baixo de cada ícone. Os ícones não fazem parte desta
// imagem — o Finder pousa-os por cima — mas os halos marcam-lhes o lugar e
// assentam-nos no fundo, em vez de os deixar a flutuar num preto uniforme.
for spot in [appSpot, folderSpot] {
    let halo = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.05),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(
        halo, startCenter: spot, startRadius: 0,
        endCenter: spot, endRadius: 118, options: []
    )
}

// MARK: - O P de onda

/// O mesmo P do ícone (make-icon.swift, estilo 10): haste cuja linha central
/// ondula, bojo em anel do mesmo peso. As proporções são as do ícone,
/// referidas a um corpo virtual em que a letra ocupa 62% — mudá-las aqui
/// tornaria este P um primo do da app em vez de ser o mesmo.
func wavyP(center: CGPoint, height h: CGFloat) -> CGPath {
    let bodyW = h / 0.62
    let top = center.y + h / 2
    let thickness = bodyW * 0.125
    let stemX = center.x - bodyW * 0.185 + bodyW * 0.045
    let amplitude = bodyW * 0.021
    let cycles: CGFloat = 1.15

    func wave(_ t: CGFloat) -> CGFloat {
        stemX + amplitude * sin(t * .pi * 2 * cycles)
    }
    let steps = 160
    let spine = CGMutablePath()
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let point = CGPoint(x: wave(t), y: top - h * t)
        i == 0 ? spine.move(to: point) : spine.addLine(to: point)
    }
    let ribbon = spine.copy(strokingWithWidth: thickness, lineCap: .round,
                            lineJoin: .round, miterLimit: 10)

    let bowlR = h * 0.235
    let bowlCX = wave(0.10) + bowlR * 0.60
    let bowlCY = top - bowlR * 0.98
    let arc = CGMutablePath()
    arc.addArc(center: CGPoint(x: bowlCX, y: bowlCY), radius: bowlR,
               startAngle: .pi * 0.62, endAngle: -.pi * 0.62, clockwise: true)
    let ring = arc.copy(strokingWithWidth: thickness, lineCap: .round,
                        lineJoin: .round, miterLimit: 10)

    let path = CGMutablePath()
    path.addPath(ribbon)
    path.addPath(ring)
    return path
}

// Fantasma, não figura. O ícone da app — que já é este P — vai pousar em
// cima deste sítio; um P a cheio por baixo competia com ele. A 6% de alfa e
// maior do que o ícone, lê-se como uma sombra da marca a atravessar o lado
// esquerdo, e desaparece atrás do ícone sem lhe roubar contraste.
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
context.addPath(wavyP(center: appSpot, height: 300))
context.fillPath()

// MARK: - A seta

// A seta vive no vão entre os dois ícones, alinhada com os centros deles.
// A haste ondula de leve — a mesma onda da letra, um ciclo completo para as
// pontas caírem na horizontal — porque uma régua reta ao lado de um P de onda
// parecia vinda de outro instalador.
let arrowY = appSpot.y
let arrowStart: CGFloat = 268, arrowTip: CGFloat = 394
let arrowInk = CGColor(red: 1, green: 1, blue: 1, alpha: 0.40)

let shaft = CGMutablePath()
let shaftSteps = 100
for i in 0...shaftSteps {
    let t = CGFloat(i) / CGFloat(shaftSteps)
    let x = arrowStart + (arrowTip - 10 - arrowStart) * t
    let y = arrowY + 3.5 * sin(t * .pi * 2)
    i == 0 ? shaft.move(to: CGPoint(x: x, y: y)) : shaft.addLine(to: CGPoint(x: x, y: y))
}
context.addPath(shaft)
context.setStrokeColor(arrowInk)
context.setLineWidth(5)
context.setLineCap(.round)
context.setLineJoin(.round)
context.strokePath()

// A ponta: duas pernas soltas em vez de um triângulo cheio, para manter o
// peso da seta igual ao do traço — uma ponta maciça pesava mais do que tudo
// o resto do desenho junto.
let head = CGMutablePath()
head.move(to: CGPoint(x: arrowTip - 14, y: arrowY + 10))
head.addLine(to: CGPoint(x: arrowTip, y: arrowY))
head.addLine(to: CGPoint(x: arrowTip - 14, y: arrowY - 10))
context.addPath(head)
context.setStrokeColor(arrowInk)
context.setLineWidth(5)
context.strokePath()

// MARK: - O texto

// SF Mono via monospacedSystemFont: pede-se a fonte ao sistema em vez de a
// procurar por nome, porque o nome PostScript muda entre versões do macOS e
// falhar aqui deixava o texto em Helvetica sem ninguém dar por isso.
// Fica abaixo da linha das legendas dos ícones (que acabam por volta de
// y=155 do fundo), para nunca lhes passar por baixo.
let label = "Drag to Applications"
let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
let attributed = NSAttributedString(string: label, attributes: [
    .font: font,
    .foregroundColor: NSColor(white: 1, alpha: 0.55),
    .kern: 2,
])
let line = CTLineCreateWithAttributedString(attributed)
let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
context.textPosition = CGPoint(x: (pointW - lineWidth) / 2, y: 56)
CTLineDraw(line, context)

// MARK: - Grão

// O mesmo grão determinístico do ícone: uma superfície digital perfeitamente
// lisa lê-se como render, um grão fino a menos de 3% lê-se como material.
// Determinístico para o PNG sair byte a byte igual em cada regeneração — o
// ficheiro está commitado e um diff sem mudança de desenho seria ruído.
var seed: UInt64 = 0x9E3779B97F4A7C15
context.setBlendMode(.plusLighter)
let grain: CGFloat = 1.5
var gy: CGFloat = 0
while gy < pointH {
    var gx: CGFloat = 0
    while gx < pointW {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let n = CGFloat((seed >> 33) % 1000) / 1000
        if n > 0.62 {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1,
                                         alpha: (n - 0.62) * 0.05))
            context.fill(CGRect(x: gx, y: gy, width: grain, height: grain))
        }
        gx += grain
    }
    gy += grain
}
context.setBlendMode(.normal)

// MARK: - Saída

let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
// É isto que grava os 144 dpi no PNG: o bitmap tem 1320×840 px mas mede
// 660×420 pt. Sem isto o Finder mostrava o fundo a dobrar do tamanho.
rep.size = NSSize(width: pointW, height: pointH)
let png = rep.representation(using: .png, properties: [:])!
let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(
    at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: outURL)
print("escrito \(outPath) (\(Int(pointW))×\(Int(pointH)) pt @\(Int(scale))x)")
