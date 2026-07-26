import SwiftUI

import PulseCore

/// O cartão que te deixa decidir sem sair do editor.
///
/// Enquanto está aberto, do outro lado há um processo de hook bloqueado e um
/// agente parado à espera desta resposta. Isso governa tudo o resto: a leitura
/// tem de ser rápida, a ação tem de estar a um gesto, e o prazo tem de ser
/// visível sem ser um alarme.
///
/// Só aparece quando não estás a olhar para o terminal — quando estás,
/// `TerminalVisibility` larga o pedido e o diálogo do Claude Code aparece onde
/// já tens os olhos.
struct PermissionDecisionCard: View {
    let request: PermissionRequest
    let now: Date
    var decide: (PermissionDecision) -> Void
    var reveal: () -> Void
    /// Onde começa o bordo visível do painel, medido a partir da moldura.
    ///
    /// A faixa escura tem de encostar aqui e não à moldura: a silhueta recua
    /// um raio de ombro de cada lado, e uma faixa desenhada até à moldura saía
    /// 13,5 pt para lá do vidro — via-se um retângulo a espreitar de fora do
    /// painel de ambos os lados.
    var bandInset: CGFloat
    /// A coluna de texto do painel, a mesma do cabeçalho "Active sessions".
    ///
    /// Sem isto o cartão inventava a sua própria margem e ficava 25 pt à
    /// esquerda de tudo o resto — a única coisa no painel que não começava
    /// onde as outras começam.
    var textInset: CGFloat

    @FocusState private var keyboardFocused: Bool

    private var remaining: Int {
        max(0, Int(request.expiresAt.timeIntervalSince(now)))
    }

    private var isUrgent: Bool { remaining <= 20 }

    private var hasAlwaysOption: Bool {
        request.suggestions.contains {
            ($0.jsonObject as? [String: Any])?["behavior"] as? String == "allow"
        }
    }

    private var risk: CommandRisk { CommandRisk.of(request) }

    /// Teto do poço do corpo. Encolhe para caber o botão de "permitir sempre"
    /// quando ele existe — o orçamento de altura do painel é fixo e alguma
    /// coisa tem de ceder.
    private var payloadHeight: CGFloat { hasAlwaysOption ? 104 : 144 }

    /// Altura real do corpo, medida.
    ///
    /// Uma `ScrollView` ocupa tudo o que lhe derem, por isso um comando de uma
    /// linha ficava a boiar no meio de um poço de 104 pt de nada. Medir o
    /// conteúdo e usar o menor dos dois faz o cartão encolher para o que tem
    /// para dizer, e só rolar quando passa do teto.
    @State private var contentHeight: CGFloat = 0
    /// O rato está sobre o poço do comando — mostra a ferramenta de copiar.
    @State private var isHoveringPayload = false
    /// Acabou de copiar: o ícone confirma durante um instante.
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            deadline
            header
            if let detail = request.detail, !detail.isEmpty {
                payload(detail)
            }
            actions
        }
        .padding(.horizontal, max(0, textInset - bandInset))
        .padding(.vertical, 10)
        // Uma faixa escura de bordo a bordo, sem cantos, sem contorno e sem
        // sombra.
        //
        // Duas tentativas falhadas antes desta. A primeira deu ao cartão
        // superfície própria com contorno e sombra: lia-se como uma caixa
        // dentro do painel, que também é uma caixa. A segunda tirou-lhe a
        // superfície e baixou a tinta do painel para compensar — e nessa o
        // painel inteiro ficou translúcido ao ponto de não se ler nada.
        //
        // O que resolve as duas: escurecer só a altura da decisão, mas de bordo
        // a bordo. Sem aresta lateral não há segunda caixa, e o escuro que a
        // leitura precisa fica onde é preciso em vez de no painel todo.
        // Quase opaca, de propósito. O vidro do painel transmite muito, e num
        // comando a decidir isso não é estilo, é ruído: o wallpaper passava
        // por trás do texto e cada linha tinha de ser lida contra ícones do
        // desktop. O material continua a ler-se nas arestas e no resto do
        // painel, onde nada exige leitura desta.
        .background(Color.black.opacity(0.74))
        .padding(.horizontal, bandInset)
        .padding(.bottom, 6)
        .focusable()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress(.return) { decide(.allow); return .handled }
        .onKeyPress(.escape) { decide(.deny); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.summary), in \(request.projectName)")
    }

    // MARK: - Corpo

    /// Título na primeira linha, contexto na segunda — a mesma estrutura de
    /// uma linha de sessão, para o cartão não parecer outra app.
    ///
    /// O sinal de risco esteve num ícone em coluna própria à esquerda, e isso
    /// empurrava o título 33 pt para dentro: passava a ser a única coisa no
    /// painel que não começava onde tudo o resto começa. Agora vive na linha de
    /// contexto, onde é lido na mesma e não desalinha nada.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(request.summary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 6)

                Text("\(remaining)s")
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    // Um prazo a correr não é metadado. A 0,34 lia-se como
                    // rodapé e só se dava por ele quando ficava laranja — que
                    // é tarde de mais para ser um aviso. 0,5 e não um valor
                    // próprio: é o escalão dos metadados deste cartão, e a
                    // auditoria apanhou 0,48/0,5/0,52 a fingirem ser escalões
                    // diferentes a quinze pontos de distância.
                    .foregroundStyle(isUrgent ? Color.orange : .white.opacity(0.5))
            }

            HStack(spacing: 6) {
                HStack(spacing: 3.5) {
                    Image(systemName: risk.symbol)
                        .font(.system(size: 9, weight: .semibold))
                    Text(risk.label)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(risk.tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    Capsule().fill(risk.tint.opacity(0.14))
                )

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

    /// Cada forma desenhada como o que é.
    ///
    /// Antes vinha tudo como um bloco de texto: o diff numa linha só, e os
    /// argumentos de qualquer ferramenta fora da lista como JSON impresso, com
    /// chavetas e aspas a ocupar o espaço da decisão.
    @ViewBuilder
    private func payload(_ text: String) -> some View {
        // Só rola quando não cabe.
        //
        // Um comando de uma linha dentro de uma scroll view apanha o gesto de
        // scroll do trackpad sem ter para onde o levar, e a barra pisca ao
        // passar por cima. Nada disso serve um bloco de texto que cabe inteiro
        // no sítio onde está.
        let scrolls = contentHeight > payloadHeight
        return Group {
            if scrolls {
                ScrollView(.vertical, showsIndicators: false) { payloadBody(text) }
            } else {
                payloadBody(text)
            }
        }
        .frame(height: contentHeight > 0 ? min(contentHeight, payloadHeight) : nil)
        .frame(maxHeight: payloadHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                )
        )
        // Copiar o corpo sem decidir nada.
        //
        // Há um terceiro caminho entre permitir e negar: ir testar o comando à
        // mão, ou inspecioná-lo com calma. Sem isto, esse caminho era
        // selecionar o texto com o rato dentro de um poço que pode rolar — o
        // gesto mais frágil da app inteira. O botão só aparece com o rato em
        // cima do poço: é uma ferramenta de leitura, não uma quarta decisão.
        .overlay(alignment: .topTrailing) {
            if isHoveringPayload || justCopied {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        justCopied = false
                    }
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(justCopied ? Color.green : .white.opacity(0.55))
                        .padding(5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.white.opacity(0.09))
                        )
                }
                .buttonStyle(.plain)
                .padding(5)
                .transition(.opacity)
                .help("Copy without deciding")
                .accessibilityLabel(justCopied ? "Copied" : "Copy the command")
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHoveringPayload = hovering }
        }
    }

    private func payloadBody(_ text: String) -> some View {
        Group {
                switch request.detailKind {
                case .diff:    diffBody(text)
                case .fields:  fieldsBody(text)
                case .plan:    planBody(text)
                case .command: monospaced(text)
                case .content: monospaced(text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { contentHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, new in contentHeight = new }
            }
        }
    }

    private func monospaced(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.94))
            .textSelection(.enabled)
    }

    /// Removido a vermelho, acrescentado a verde, com a coluna do sinal fora
    /// do texto para as linhas alinharem.
    private func diffBody(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let added = line.hasPrefix("+")
                let removed = line.hasPrefix("-")
                HStack(alignment: .top, spacing: 6) {
                    Text(added ? "+" : (removed ? "−" : " "))
                        .foregroundStyle(added ? Color.green : (removed ? Color.red : .clear))
                    Text(added || removed ? String(line.dropFirst()) : line)
                        .foregroundStyle(.white.opacity(added || removed ? 0.94 : 0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 0.5)
                .background(
                    (added ? Color.green : Color.red)
                        .opacity(added || removed ? 0.10 : 0)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .textSelection(.enabled)
    }

    /// `chave\tvalor` por linha, com a chave numa coluna própria.
    private func fieldsBody(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let parts = line.components(separatedBy: "\t")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(parts.first ?? "")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 76, alignment: .leading)
                    Text(parts.count > 1 ? parts[1] : "")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.94))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func planBody(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.94))
            .textSelection(.enabled)
    }

    // MARK: - Ações

    private var actions: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                DecisionButton(
                    label: "Allow", systemImage: "checkmark",
                    shortcut: "⏎", style: .primary
                ) { decide(.allow) }

                DecisionButton(
                    label: "Deny", systemImage: "xmark",
                    shortcut: "esc", style: .destructive
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
                .help("Leave it to the agent's own prompt and jump to that pane")
            }

            if hasAlwaysOption {
                // Pequeno, e o mais discreto dos três.
                //
                // Era uma barra a toda a largura, o maior alvo do cartão — e é
                // a única decisão daqui que não se desfaz: escreve uma regra
                // que passa a valer para sempre. O peso visual estava ao
                // contrário do peso real.
                Button { decide(.allowAlways) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 9.5))
                        Text("Always allow this command")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("Writes a permission rule. This one does not expire.")
            }
        }
    }

    // MARK: - Prazo

    /// Quanto falta até o hook largar o agente por sua iniciativa.
    ///
    /// Fio de 2 pt encostado ao topo do cartão, por dentro do recorte. Já
    /// esteve em baixo e a toda a largura, e sobre um fundo claro lia-se como
    /// uma laje cinzenta entre os botões — mais pesada do que a informação que
    /// carrega.
    private var deadline: some View {
        GeometryReader { geo in
            let total = request.expiresAt.timeIntervalSince(request.createdAt)
            let fraction = total > 0
                ? max(0, request.expiresAt.timeIntervalSince(now) / total)
                : 0
            Rectangle()
                .fill(isUrgent ? Color.orange : risk.tint.opacity(0.65))
                .frame(width: max(0, geo.size.width * fraction))
                .animation(.linear(duration: 1), value: fraction)
        }
        .frame(height: 2)
    }
}

// MARK: - Botões

/// Um botão de decisão, com o atalho impresso nele.
///
/// O atalho vai no próprio botão e não numa legenda à parte: quem carrega com o
/// rato ignora-o, e quem carrega uma vez aprende que da próxima não precisa do
/// rato. Uma linha de ajuda debaixo dos botões dizia o mesmo e ocupava altura
/// que o comando queria.
private struct DecisionButton: View {
    enum Style { case primary, destructive }

    let label: String
    let systemImage: String
    var shortcut: String?
    var style: Style
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.38))
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.white.opacity(0.09))
                        )
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(isHovering ? 0.22 : 0.12), lineWidth: 0.75)
                    )
            )
        }
        // Reagir ao toque, e não só à passagem do rato.
        //
        // `.plain` não dá estado de pressionado: o botão acendia ao aproximar o
        // rato e depois não acontecia nada visível ao carregar. Num cartão que
        // decide se um comando corre ou não, ver o clique registar-se é o que
        // separa "carreguei" de "acho que carreguei".
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var foreground: Color {
        switch style {
        case .primary:     return .white
        case .destructive: return isHovering ? .white : .white.opacity(0.8)
        }
    }

    private var fill: Color {
        switch style {
        case .primary:     return .white.opacity(isHovering ? 0.24 : 0.16)
        case .destructive: return .red.opacity(isHovering ? 0.34 : 0.20)
        }
    }
}

/// Encolhe e escurece enquanto está a ser carregado.
///
/// 0,96 e não menos: um botão de 28 pt de alto a encolher mais do que isto
/// salta em vez de responder.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }
}

// MARK: - Risco

/// Um sinal de quanto custa enganares-te neste pedido.
///
/// Não é análise de segurança e não tenta ser: é a diferença entre ler um
/// ficheiro e apagar uma árvore de diretorias, dita antes de leres o comando.
/// Erra sempre para o lado de chamar a atenção — um aviso a mais custa meio
/// segundo, um aviso a menos custa o que o comando fizer.
enum CommandRisk: Equatable {
    case routine
    case writes
    case destructive

    var label: String {
        switch self {
        case .routine:     return "read-only"
        case .writes:      return "modifies"
        case .destructive: return "destructive"
        }
    }

    var symbol: String {
        switch self {
        case .routine:     return "terminal"
        case .writes:      return "pencil"
        case .destructive: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .routine:     return Color(red: 0.42, green: 0.62, blue: 0.98)
        case .writes:      return Color(red: 0.98, green: 0.71, blue: 0.30)
        case .destructive: return Color(red: 0.97, green: 0.38, blue: 0.36)
        }
    }

    static func of(_ request: PermissionRequest) -> CommandRisk {
        switch request.toolName {
        case "Write", "Edit", "NotebookEdit": return .writes
        case "WebFetch", "ExitPlanMode":      return .routine
        case "Bash":                          break
        default:                              return .routine
        }

        let command = (request.detail ?? "").lowercased()
        // Padrões que se distinguem por si. Deliberadamente poucos: uma lista
        // longa acerta em mais casos e treina-te a ignorar o ícone.
        let dangerous = [
            "rm -rf", "rm -r", "sudo ", "mkfs", "dd if=", ":(){", "chmod -r 777",
            "git push --force", "git push -f", "git reset --hard", "git clean -fd",
            "drop table", "drop database", "truncate ", "shutdown", "killall",
            "> /dev/", "curl", "wget",
        ]
        if dangerous.contains(where: command.contains) { return .destructive }

        let writing = [
            ">", ">>", "mv ", "cp ", "mkdir", "touch ", "npm i", "pip install",
            "brew install", "git commit", "git checkout", "tee ",
        ]
        if writing.contains(where: command.contains) { return .writes }
        return .routine
    }
}
