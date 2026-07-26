// Desenha o ícone da Atalaia, um tamanho de cada vez.
//
// Substituiu um SVG único rasterizado para todos os tamanhos. Três coisas que
// um ficheiro estático não dá, e que separam um ícone bom de um ícone certo:
//
//  1. A forma. O contorno de um ícone macOS não é um retângulo de cantos
//     arredondados — é uma superelipse, com curvatura contínua. A diferença
//     não se nomeia à primeira vista, mas ao lado dos ícones do sistema um
//     retângulo arredondado lê-se logo como corpo estranho.
//
//  2. A luz. O feixe precisa de bloom verdadeiro e a aresta de cima precisa de
//     apanhar luz. Um desfoque gaussiano não existe em SVG rasterizado por
//     CoreSVG, e imitá-lo com camadas de opacidade dá bandas.
//
//  3. A escala. A 16 px a seteira entope e o bloom vira sujidade. O que se
//     desenha a 512 não é o que se desenha a 16 — é o mesmo ícone, redesenhado.
//     Um único desenho encolhido serve bem um tamanho e mal todos os outros.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
// Afinação em estudo: largura e profundidade do recorte, e quanto ele recua do
// topo. Passados por argumento para se compararem variantes lado a lado.
let vWidth  = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2])!) : 240
let vDepth  = CommandLine.arguments.count > 3 ? CGFloat(Double(CommandLine.arguments[3])!) : 192
let vInset  = CommandLine.arguments.count > 4 ? CGFloat(Double(CommandLine.arguments[4])!) : 0
let vStyle  = CommandLine.arguments.count > 5 ? Int(CommandLine.arguments[5])! : 9

// MARK: - Forma

/// A superelipse do sistema. `n = 5` é o expoente que põe esta silhueta ao lado
/// das outras na Dock sem se dar por ela.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// O recorte: topo reto encostado à borda de cima, cantos de baixo redondos.
/// É a mesma forma que a app desenha no ecrã, e é o sujeito do ícone.
func notch(width w: CGFloat, depth d: CGFloat, top: CGFloat, centerX cx: CGFloat) -> CGPath {
    let r = min(d * 0.42, w / 2)
    let path = CGMutablePath()
    let left = cx - w / 2, right = cx + w / 2
    let bottom = top - d                    // coordenadas de baixo para cima
    path.move(to: CGPoint(x: left, y: top))
    path.addLine(to: CGPoint(x: left, y: bottom + r))
    path.addQuadCurve(to: CGPoint(x: left + r, y: bottom), control: CGPoint(x: left, y: bottom))
    path.addLine(to: CGPoint(x: right - r, y: bottom))
    path.addQuadCurve(to: CGPoint(x: right, y: bottom + r), control: CGPoint(x: right, y: bottom))
    path.addLine(to: CGPoint(x: right, y: top))
    path.closeSubpath()
    return path
}

/// A silhueta que a app desenha no ecrã: um painel pendurado na berma de cima,
/// com ombros CÔNCAVOS onde encosta ao topo.
///
/// São os ombros que fazem esta forma. Um retângulo de cantos redondos
/// pendurado é uma forma que qualquer app pode ter; a curva a entrar para
/// dentro em vez de sair só acontece em coisas que estão agarradas a uma
/// berma, e é o que torna a silhueta reconhecível a 16 px.
func hangingPanel(
    top: CGFloat, width w: CGFloat, height h: CGFloat,
    shoulder sh: CGFloat, corner r: CGFloat, centerX cx: CGFloat
) -> CGPath {
    let path = CGMutablePath()
    let l = cx - w / 2, rt = cx + w / 2
    let bottom = top - h
    path.move(to: CGPoint(x: l - sh, y: top))
    path.addQuadCurve(to: CGPoint(x: l, y: top - sh), control: CGPoint(x: l, y: top))
    path.addLine(to: CGPoint(x: l, y: bottom + r))
    path.addQuadCurve(to: CGPoint(x: l + r, y: bottom), control: CGPoint(x: l, y: bottom))
    path.addLine(to: CGPoint(x: rt - r, y: bottom))
    path.addQuadCurve(to: CGPoint(x: rt, y: bottom + r), control: CGPoint(x: rt, y: bottom))
    path.addLine(to: CGPoint(x: rt, y: top - sh))
    path.addQuadCurve(to: CGPoint(x: rt + sh, y: top), control: CGPoint(x: rt, y: top))
    path.closeSubpath()
    return path
}

// MARK: - Desenho

/// Um tamanho, desenhado para esse tamanho.
///
/// `px` é o lado em pixels. Tudo o resto deriva daí — não há um desenho grande
/// a ser encolhido, há proporções aplicadas à escala pedida.
func drawIcon(px: Int) -> CGImage {
    let side = CGFloat(px)
    // Abaixo disto o detalhe fino deixa de ter pixels onde assentar: a seteira
    // fecha, o bloom espalha-se e o rim light some-se numa linha cinzenta.
    let detailed = px >= 64
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)

    // A margem do sistema: a arte ocupa 824 de 1024.
    let inset = side * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let shape = squircle(in: body)

    // -- corpo ------------------------------------------------------------
    context.saveGState()
    context.addPath(shape)
    context.clip()

    let backdrop = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.129, green: 0.129, blue: 0.145, alpha: 1),
            CGColor(red: 0.031, green: 0.031, blue: 0.039, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        backdrop,
        start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY),
        options: []
    )

    // ---- P abstrato, em vidro ---------------------------------------------
    if vStyle == 9 {
        // Um P que não é uma letra desenhada: é um eixo de luz e três anéis
        // que o cruzam. Lê-se P à primeira vista e não se parece com nenhuma
        // fonte à segunda, que é o que se pede a uma marca.
        //
        // Os anéis são três e não um. Um anel sozinho fecha o bojo e a coisa
        // volta a ser tipografia; três, com pesos diferentes, leem-se como
        // ondas a sair do eixo — e é a sobreposição delas com a haste, somada
        // em vez de tapada, que dá o brilho onde as partes se encontram.
        let cx = body.midX, cy = body.midY
        let h = body.height * 0.62
        let top = cy + h / 2, bottom = cy - h / 2
        let stemW = body.width * 0.105
        // Deslocado para a direita, porque a peça inteira é assimétrica: a
        // haste está à esquerda e os anéis só crescem para o lado direito.
        // Centrar a haste deixava o conjunto encostado a um lado do quadro.
        let stemX = cx - body.width * 0.20 + body.width * 0.052

        // Halo: separa a peça do fundo sem lhe pôr contorno.
        if detailed {
            let halo = CGGradient(colorsSpace: colorSpace, colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.13),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0),
            ] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(
                halo, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                endCenter: CGPoint(x: cx, y: cy), endRadius: body.width * 0.52, options: []
            )
        }

        context.setBlendMode(.plusLighter)

        // O eixo. Claro em cima, a apagar-se em baixo: é uma coluna de luz e
        // não uma barra pintada.
        context.saveGState()
        context.addPath(CGPath(roundedRect: CGRect(x: stemX, y: bottom, width: stemW, height: h),
                               cornerWidth: stemW / 2, cornerHeight: stemW / 2, transform: nil))
        context.clip()
        let shaft = CGGradient(colorsSpace: colorSpace, colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.96),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.52),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.14),
        ] as CFArray, locations: [0, 0.55, 1])!
        context.drawLinearGradient(shaft, start: CGPoint(x: 0, y: top),
                                   end: CGPoint(x: 0, y: bottom), options: [])
        context.restoreGState()

        // Os anéis do bojo. Raios e pesos diferentes: um conjunto regular
        // lia-se como alvo, este lê-se como uma coisa a abrir.
        let bowlCY = top - h * 0.235
        let radii: [(CGFloat, CGFloat, CGFloat)] = [   // raio, peso, brilho
            (h * 0.235, 0.088, 0.92),
            (h * 0.330, 0.030, 0.42),
            (h * 0.400, 0.014, 0.20),
        ]
        // Os anéis nascem no eixo da haste e crescem só para a direita. Sem
        // este corte, as pontas dos anéis de fora apareciam por cima e à
        // esquerda da haste, como farpas soltas.
        context.saveGState()
        context.clip(to: CGRect(x: stemX + stemW * 0.4, y: body.minY,
                                width: body.maxX - stemX, height: body.height))
        for (radius, weight, glow) in radii {
            let lineWidth = body.width * weight
            let ring = CGMutablePath()
            // Arco aberto do lado da haste: o vazio à esquerda é o que faz o
            // olho fechar a forma como P em vez de como círculo.
            // Passa dos ±90°, para as pontas ficarem escondidas atrás da
            // haste. A ±0,46π caíam à direita dela e a ponta redonda do traço
            // aparecia como uma vírgula pendurada no bojo.
            ring.addArc(center: CGPoint(x: stemX + stemW * 0.4, y: bowlCY),
                        radius: radius, startAngle: -.pi * 0.56, endAngle: .pi * 0.56,
                        clockwise: false)
            context.saveGState()
            context.addPath(ring)
            context.setLineWidth(lineWidth)
            context.setLineCap(.butt)
            context.replacePathWithStrokedPath()
            context.clip()
            let arcLight = CGGradient(colorsSpace: colorSpace, colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: glow),
                CGColor(red: 1, green: 1, blue: 1, alpha: glow * 0.22),
            ] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(
                arcLight,
                start: CGPoint(x: stemX, y: bowlCY + radius),
                end: CGPoint(x: stemX + radius * 1.6, y: bowlCY - radius),
                options: []
            )
            context.restoreGState()
        }
        context.restoreGState()

        context.setBlendMode(.normal)

        // Grão, o mesmo do resto: superfície lisa lê-se como render.
        if detailed {
            var seed: UInt64 = 0x9E3779B97F4A7C15
            context.setBlendMode(.plusLighter)
            let grainSize = max(1, side / 180)
            var gy = body.minY
            while gy < body.maxY {
                var gx = body.minX
                while gx < body.maxX {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let n = CGFloat((seed >> 33) % 1000) / 1000
                    if n > 0.58 {
                        context.setFillColor(CGColor(red: 1, green: 1, blue: 1,
                                                     alpha: (n - 0.58) * 0.06))
                        context.fill(CGRect(x: gx, y: gy, width: grainSize, height: grainSize))
                    }
                    gx += grainSize
                }
                gy += grainSize
            }
            context.setBlendMode(.normal)
        }

        context.restoreGState()
        return context.makeImage()!
    }

    // ---- vidro esculpido --------------------------------------------------
    if vStyle == 8 {
        // Lâminas de vidro sobrepostas, a girar em torno de um centro.
        //
        // A riqueza não vem de mais formas — vem de material. Cada lâmina é
        // translúcida, tem uma aresta acesa do lado por onde a luz entra, e
        // soma-se às que estão por baixo em vez de as tapar. É a soma nas
        // sobreposições que dá a leitura de vidro: onde duas se cruzam fica
        // mais claro, como aconteceria com vidro verdadeiro.
        let blades = 5
        let cx = body.midX, cy = body.midY
        // Folga à volta: a escultura encostada às arestas lia-se como um selo
        // carimbado no quadrado, e não como um objeto pousado nele.
        let outer = body.width * 0.385
        let inner = body.width * 0.092

        // Halo por trás: separa a escultura do fundo sem lhe desenhar contorno.
        if detailed {
            let halo = CGGradient(colorsSpace: colorSpace, colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0),
            ] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(
                halo, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                endCenter: CGPoint(x: cx, y: cy), endRadius: outer * 1.25, options: []
            )
        }

        // Sombra própria, para a escultura assentar no fundo em vez de flutuar.
        if detailed {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -side * 0.012),
                              blur: side * 0.05,
                              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
            context.addEllipse(in: CGRect(x: cx - outer, y: cy - outer,
                                          width: outer * 2, height: outer * 2))
            context.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        context.setBlendMode(.plusLighter)
        for i in 0..<blades {
            let a0 = CGFloat(i) / CGFloat(blades) * 2 * .pi
            let sweep: CGFloat = 2 * .pi / CGFloat(blades) * 1.42
            let a1 = a0 + sweep

            // A lâmina: um sector curvo, mais estreito no interior. O bordo de
            // dentro roda mais do que o de fora, e é essa torção que a faz ler
            // como algo dobrado e não como uma fatia de tarte.
            let twist: CGFloat = 0.62
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: cx, y: cy), radius: outer,
                        startAngle: a0, endAngle: a1, clockwise: false)
            path.addArc(center: CGPoint(x: cx, y: cy), radius: inner,
                        startAngle: a1 + twist, endAngle: a0 + twist, clockwise: true)
            path.closeSubpath()

            context.saveGState()
            context.addPath(path)
            context.clip()
            // A luz entra pelo canto superior esquerdo, como em todo o sistema.
            let mid = (a0 + a1) / 2
            let lit = CGPoint(x: cx + cos(mid) * outer, y: cy + sin(mid) * outer)
            let dark = CGPoint(x: cx - cos(mid) * outer * 0.4, y: cy - sin(mid) * outer * 0.4)
            let facing = max(0, cos(mid - 2.5))          // 2.5 rad ≈ cima-esquerda
            let glass = CGGradient(colorsSpace: colorSpace, colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.16 + facing * 0.44),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.05 + facing * 0.12),
            ] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(glass, start: lit, end: dark, options: [])
            context.restoreGState()

            // A aresta acesa, só no bordo exterior e só do lado da luz.
            context.saveGState()
            context.addPath(path)
            context.setLineWidth(max(0.7, side * 0.006))
            let facingEdge = max(0, cos(mid - 2.5))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1,
                                           alpha: 0.10 + facingEdge * 0.70))
            context.strokePath()
            context.restoreGState()
        }
        context.setBlendMode(.normal)

        // O núcleo: o ponto mais claro do ícone, e o que o olho encontra
        // primeiro a qualquer tamanho.
        let core = CGGradient(colorsSpace: colorSpace, colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.95),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray, locations: [0, 0.45, 1])!
        context.drawRadialGradient(
            core, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
            endCenter: CGPoint(x: cx, y: cy), endRadius: inner * 1.9, options: []
        )

        // Grão. Uma superfície perfeitamente lisa lê-se como render; um grão
        // fino a 3% lê-se como material fotografado. Determinístico, para o
        // ícone sair igual em cada build.
        if detailed {
            var seed: UInt64 = 0x9E3779B97F4A7C15
            context.setBlendMode(.plusLighter)
            let grainSize = max(1, side / 180)
            var gy = body.minY
            while gy < body.maxY {
                var gx = body.minX
                while gx < body.maxX {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let n = CGFloat((seed >> 33) % 1000) / 1000
                    if n > 0.55 {
                        context.setFillColor(CGColor(red: 1, green: 1, blue: 1,
                                                     alpha: (n - 0.55) * 0.07))
                        context.fill(CGRect(x: gx, y: gy, width: grainSize, height: grainSize))
                    }
                    gx += grainSize
                }
                gy += grainSize
            }
            context.setBlendMode(.normal)
        }

        context.restoreGState()
        return context.makeImage()!
    }

    // ---- monogramas geométricos ------------------------------------------
    if vStyle >= 6 {
        // A letra construída, não composta.
        //
        // Nenhuma fonte do sistema: um monograma tirado de uma família que
        // qualquer app pode usar é o oposto de uma marca. Esta é feita de
        // primitivas — barra e anel — com o mesmo peso em toda a letra e uma
        // JUNTA visível onde as partes se encontram. É a junta que a impede de
        // parecer uma letra escrita e a faz parecer uma coisa montada.
        //
        // As partes desenham-se uma a uma, com um `clip` cada. Uma tentativa
        // anterior meteu haste, anel e contra-forma no mesmo caminho com
        // preenchimento par-ímpar: onde a haste cruzava o bojo, as duas formas
        // cancelavam-se e o P saía partido ao meio.
        // O traço tem de deixar contraforma. A 0,150 de largura o anel do P
        // fechava-se: o raio exterior menos o traço dava um buraco de 19 px
        // num desenho de 1024, que se lê como defeito e não como bojo.
        let stroke = body.width * 0.124
        let joint = detailed ? stroke * 0.24 : 0
        let letterHeight = body.height * 0.60
        let top = body.midY + letterHeight / 2
        let bottom = body.midY - letterHeight / 2

        let ink = CGGradient(colorsSpace: colorSpace, colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            CGColor(red: 0.74, green: 0.74, blue: 0.79, alpha: 1),
        ] as CFArray, locations: [0, 1])!

        func paint(_ path: CGPath, rule: CGPathFillRule = .winding) {
            context.saveGState()
            context.addPath(path)
            context.clip(using: rule)
            context.drawLinearGradient(ink, start: CGPoint(x: 0, y: top),
                                       end: CGPoint(x: 0, y: bottom), options: [])
            context.restoreGState()
        }

        if vStyle == 6 {
            // P — barra e anel.
            let stemX = body.midX - body.width * 0.180
            let stem = CGPath(roundedRect: CGRect(
                x: stemX, y: bottom, width: stroke, height: letterHeight
            ), cornerWidth: stroke / 2, cornerHeight: stroke / 2, transform: nil)
            paint(stem)

            let outer = letterHeight * 0.335
            let cxB = stemX + stroke * 0.5 + outer * 0.52
            let cyB = top - outer
            let ring = CGMutablePath()
            ring.addEllipse(in: CGRect(x: cxB - outer, y: cyB - outer,
                                       width: outer * 2, height: outer * 2))
            ring.addEllipse(in: CGRect(x: cxB - outer + stroke, y: cyB - outer + stroke,
                                       width: (outer - stroke) * 2, height: (outer - stroke) * 2))
            paint(ring, rule: .evenOdd)

            // A junta, reposta com o fundo — e não pintada de preto chapado,
            // que sobre um corpo em gradiente se via como um risco.
            if joint > 0 {
                context.saveGState()
                context.clip(to: CGRect(x: stemX + stroke, y: cyB - outer,
                                        width: joint, height: outer * 2))
                context.drawLinearGradient(
                    backdrop,
                    start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY),
                    options: []
                )
                context.restoreGState()
            }
        } else {
            // A — duas pernas e uma travessa, com o ápice cortado a direito. O
            // corte no topo é a junta desta letra: um A fechado em bico é
            // tipografia, um A cortado é construção.
            let halfBase = body.width * 0.215
            let apexHalf = stroke * 0.46
            let legs = CGMutablePath()
            legs.move(to: CGPoint(x: body.midX - halfBase - stroke / 2, y: bottom))
            legs.addLine(to: CGPoint(x: body.midX - apexHalf, y: top))
            legs.addLine(to: CGPoint(x: body.midX + apexHalf, y: top))
            legs.addLine(to: CGPoint(x: body.midX + halfBase + stroke / 2, y: bottom))
            legs.addLine(to: CGPoint(x: body.midX + halfBase - stroke / 2, y: bottom))
            legs.addLine(to: CGPoint(x: body.midX, y: top - stroke * 1.4))
            legs.addLine(to: CGPoint(x: body.midX - halfBase + stroke / 2, y: bottom))
            legs.closeSubpath()
            paint(legs)

            let barY = bottom + letterHeight * 0.28
            paint(CGPath(rect: CGRect(
                x: body.midX - halfBase * 0.74, y: barY,
                width: halfBase * 1.48, height: stroke * 0.86
            ), transform: nil))
        }

        context.restoreGState()
        return context.makeImage()!
    }

    // ---- direções abstratas em estudo ------------------------------------
    if vStyle >= 3 {
        switch vStyle {
        case 3:
            // VÓRTICE. Superelipses encaixadas, a encolher e a rodar. A rotação
            // constante por passo é o que transforma uma pilha de molduras num
            // túnel: sem ela lê-se como alvo, com ela puxa para dentro.
            let rings = detailed ? 14 : 7
            for i in 0..<rings {
                let t = CGFloat(i) / CGFloat(rings)
                let scaleF = 1 - t * 0.86
                let angle = t * .pi * 0.62
                let alpha = 0.10 + pow(t, 1.6) * 0.90
                let w = body.width * scaleF
                context.saveGState()
                context.translateBy(x: body.midX, y: body.midY)
                context.rotate(by: angle)
                context.addPath(squircle(in: CGRect(x: -w / 2, y: -w / 2, width: w, height: w)))
                context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
                context.setLineWidth(max(0.8, side * 0.0075))
                context.strokePath()
                context.restoreGState()
            }

        case 4:
            // CAMPO DESLOCADO. Linhas paralelas empurradas por uma massa
            // invisível ao centro. O que se vê é a massa, e nunca se desenha —
            // é a deformação das linhas que a torna presente.
            let lines = detailed ? 22 : 9
            let radius = body.width * 0.34
            context.setLineCap(.round)
            for i in 0..<lines {
                let t = (CGFloat(i) + 0.5) / CGFloat(lines)
                let y = body.minY + body.height * t
                let path = CGMutablePath()
                let steps = 120
                for stepIndex in 0...steps {
                    let u = CGFloat(stepIndex) / CGFloat(steps)
                    let x = body.minX + body.width * u
                    let dx = x - body.midX
                    let dy = y - body.midY
                    let d = sqrt(dx * dx + dy * dy)
                    // Empurra para fora do centro, com queda suave.
                    let push = d < radius * 2.2
                        ? cos(min(1, d / (radius * 2.2)) * .pi / 2) * radius * 0.62
                        : 0
                    let sign: CGFloat = dy >= 0 ? 1 : -1
                    let py = y + sign * push
                    stepIndex == 0 ? path.move(to: CGPoint(x: x, y: py))
                                   : path.addLine(to: CGPoint(x: x, y: py))
                }
                context.addPath(path)
                let fade = 0.28 + 0.62 * (1 - abs(t - 0.5) * 2)
                context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: fade))
                context.setLineWidth(max(0.9, side * 0.009))
                context.strokePath()
            }

        default:
            // LENTE. Dois discos que se cruzam; só a interseção acende. A forma
            // que fica não é nenhum dos dois — é o que eles têm em comum.
            let r = body.width * 0.40
            let offset = r * 0.52
            context.saveGState()
            context.addEllipse(in: CGRect(x: body.midX - offset - r, y: body.midY - r,
                                          width: r * 2, height: r * 2))
            context.clip()
            context.addEllipse(in: CGRect(x: body.midX + offset - r, y: body.midY - r,
                                          width: r * 2, height: r * 2))
            context.clip()
            let lens = CGGradient(colorsSpace: colorSpace, colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                CGColor(red: 0.72, green: 0.72, blue: 0.76, alpha: 1),
            ] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(lens, start: CGPoint(x: 0, y: body.maxY),
                                       end: CGPoint(x: 0, y: body.minY), options: [])
            context.restoreGState()
            // Os dois arcos exteriores, ténues: dizem de onde a lente veio.
            for sign in [-1.0, 1.0] as [CGFloat] {
                context.addEllipse(in: CGRect(x: body.midX + sign * offset - r, y: body.midY - r,
                                              width: r * 2, height: r * 2))
                context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
                context.setLineWidth(max(0.9, side * 0.007))
                context.strokePath()
            }
        }
        context.restoreGState()
        return context.makeImage()!
    }

    if vStyle > 0 {
        // O painel suspenso, em branco, agarrado ao topo.
        let panelW = body.width * 0.52
        let panelH = body.height * 0.50
        let panel = hangingPanel(
            top: body.maxY + side * 0.01,
            width: panelW, height: panelH,
            shoulder: side * 0.075, corner: side * 0.055,
            centerX: body.midX
        )
        context.addPath(panel)
        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1))
        context.fillPath()

        // Os pontos de estado, que é o que a barra mostra mesmo. Só existem
        // onde há pixels para os separar: a 32 px encostam-se e viram borrão.
        if vStyle == 2 && detailed {
            let d = side * 0.058
            let gap = d * 1.75
            let y = body.maxY - panelH * 0.55
            for i in -1...1 {
                let rect = CGRect(x: body.midX + CGFloat(i) * gap - d / 2, y: y - d / 2,
                                  width: d, height: d)
                context.addEllipse(in: rect)
            }
            context.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1))
            context.fillPath()
        }
        context.restoreGState()
        return context.makeImage()!
    }

    // -- o olhar ----------------------------------------------------------
    //
    // Desenhado numa camada própria e desfocado antes de entrar: é o que lhe
    // dá o ar de luz em vez de triângulo cinzento. O desfoque é proporcional
    // ao tamanho, senão a 512 fica duro e a 128 fica uma nódoa.
    let notchWidth = side * vWidth / 1024
    let notchDepth = side * vDepth / 1024
    let notchTop = body.maxY - side * vInset / 1024
    let notchBottom = notchTop - notchDepth
    let cx = body.midX

    let beamLayer = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let beam = CGMutablePath()
    beam.move(to: CGPoint(x: cx - notchWidth * 0.36, y: notchBottom + side * 0.004))
    beam.addLine(to: CGPoint(x: cx + notchWidth * 0.36, y: notchBottom + side * 0.004))
    beam.addLine(to: CGPoint(x: cx + side * 0.30, y: body.minY - side * 0.06))
    beam.addLine(to: CGPoint(x: cx - side * 0.30, y: body.minY - side * 0.06))
    beam.closeSubpath()
    beamLayer.addPath(beam)
    beamLayer.clip()
    let light = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.92),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 0.34, 0.88]
    )!
    beamLayer.drawLinearGradient(
        light,
        start: CGPoint(x: 0, y: notchBottom), end: CGPoint(x: 0, y: body.minY - side * 0.06),
        options: []
    )

    if let raw = beamLayer.makeImage() {
        let blurred: CGImage
        if detailed {
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = CIImage(cgImage: raw)
            filter.radius = Float(side * 0.012)
            let ci = CIContext(options: [.useSoftwareRenderer: true])
            blurred = filter.outputImage
                .flatMap { ci.createCGImage($0, from: CIImage(cgImage: raw).extent) } ?? raw
        } else {
            blurred = raw
        }
        context.draw(blurred, in: CGRect(x: 0, y: 0, width: side, height: side))
    }

    // -- o recorte --------------------------------------------------------
    let notchPath = notch(
        width: notchWidth, depth: notchDepth,
        top: vInset > 0 ? notchTop : notchTop + side * 0.01,
        centerX: cx
    )
    context.addPath(notchPath)
    context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1))
    context.fillPath()

    // A seteira. É o que separa isto de um candeeiro: sem ela o recorte é uma
    // mancha a iluminar, com ela é uma abertura a olhar.
    if detailed {
        let slitWidth = notchWidth * 0.60
        let slitHeight = max(1, side * 0.033)
        let slit = CGPath(
            roundedRect: CGRect(
                x: cx - slitWidth / 2,
                y: notchTop - notchDepth * 0.42 - slitHeight / 2,
                width: slitWidth, height: slitHeight
            ),
            cornerWidth: slitHeight / 2, cornerHeight: slitHeight / 2, transform: nil
        )
        context.addPath(slit)
        context.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1))
        context.fillPath()
    }

    context.restoreGState()

    // -- aresta -----------------------------------------------------------
    //
    // A luz vem de cima, por isso a aresta de cima acende e a de baixo não.
    // Uma linha igual em todo o contorno lê-se como traço desenhado; esta
    // lê-se como um objeto sob uma luz.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.addPath(shape)
    context.setLineWidth(max(1, side * 0.004))
    let rim = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.04),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(
        rim,
        start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY),
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()

    return context.makeImage()!
}

// MARK: - Saída

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for variant in variants {
    let image = drawIcon(px: variant.pixels)
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try png.write(to: outputDirectory.appendingPathComponent("\(variant.name).png"))
}
print("desenhados \(variants.count) tamanhos")
