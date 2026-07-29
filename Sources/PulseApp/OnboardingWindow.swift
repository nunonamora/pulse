import AppKit
import SwiftUI

import PulseCore

// MARK: - Passos

/// Os três passos do primeiro arranque, pela ordem em que a app faz sentido:
/// primeiro quem somos, depois ligar os fios, por fim como se fala connosco.
/// Três e não mais: cada passo responde a uma pergunta que o utilizador ainda
/// não sabia que ia fazer, e à quarta pergunta já ninguém está a ler.
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case hooks
    case usage
}

// MARK: - Janela

/// Uma janela borderless não recebe teclado por omissão. Sem isto, o ⏎ do
/// botão principal não funcionava — na mesma janela cujo último passo ensina
/// atalhos de teclado.
final class OnboardingKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// O dono da janela de boas-vindas.
///
/// Sem cromado de propósito: o onboarding não é um documento que se arruma
/// numa barra de título, é um cartaz que se lê uma vez. Os cantos redondos e
/// o fundo vêm da vista; a janela limita-se a ser transparente à volta deles.
@MainActor
final class OnboardingWindowController {
    private var window: OnboardingKeyWindow?

    /// Só na primeira execução. A marca fica em UserDefaults e não num
    /// ficheiro de estado: sobrevive a reinstalar hooks e a limpar sessões,
    /// que é o comportamento certo — reinstalar não te torna outra vez novo.
    static func presentIfNeeded() -> OnboardingWindowController? {
        guard !UserDefaults.standard.bool(forKey: "didOnboard") else { return nil }
        let controller = OnboardingWindowController()
        controller.present()
        return controller
    }

    private func present() {
        let window = OnboardingKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        // Sem barra de título, arrastar pelo fundo é a única pega que existe.
        window.isMovableByWindowBackground = true
        // A app é .accessory: não tem Dock nem menu por onde reencontrar uma
        // janela que abra atrás das outras. Flutuar é o que garante que a
        // primeira impressão acontece à primeira.
        window.level = .floating
        window.contentView = NSHostingView(
            rootView: OnboardingView { [weak self] in self?.finish() }
        )
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        // A marca escreve-se no fim e não no início: quem fechar a app a meio
        // do onboarding ainda não foi recebido, e merece a receção completa no
        // arranque seguinte em vez de meio caminho perdido.
        UserDefaults.standard.set(true, forKey: "didOnboard")
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - Vista

struct OnboardingView: View {
    @State private var step: OnboardingStep
    /// O que acontece ao "Start watching" — fechar a janela é decisão de quem
    /// a abriu, não desta vista; no retrato do arnês não acontece nada.
    var finish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStaticRender) private var isStaticRender

    init(step: OnboardingStep = .welcome, finish: @escaping () -> Void = {}) {
        _step = State(initialValue: step)
        self.finish = finish
    }

    /// Movimento desligado por escolha do utilizador ou por estarmos a
    /// desenhar para ficheiro: nos dois casos tudo aparece já no lugar.
    private var motionless: Bool { reduceMotion || isStaticRender }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome:
                    OnboardingWelcomeStep()
                        .transition(stepTransition)
                case .hooks:
                    OnboardingHooksStep()
                        .transition(stepTransition)
                case .usage:
                    OnboardingUsageStep()
                        .transition(stepTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(motionless ? nil : VITheme.spring, value: step)
            footer
        }
        .padding(28)
        .frame(width: 560, height: 420)
        .background(VITheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        // O fio claro no bordo é o que separa o painel preto de um buraco no
        // ecrã quando a janela pousa sobre um wallpaper igualmente escuro.
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
    }

    /// Entra pela direita, sai pela esquerda: os passos têm ordem e a
    /// transição conta-a. Com movimento reduzido não há viagem — o passo
    /// seguinte aparece onde o anterior estava.
    private var stepTransition: AnyTransition {
        motionless ? .identity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private var footer: some View {
        HStack {
            // Pontos e não títulos: dizem "onde estou" sem competir com o
            // conteúdo, e não são clicáveis — o caminho é sempre para a frente,
            // que é o que mantém três passos curtos em vez de um labirinto.
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { candidate in
                    Circle()
                        .fill(.white.opacity(candidate == step ? 0.85 : 0.22))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)"
            )
            Spacer(minLength: 0)
            OnboardingButton(
                label: step == .usage ? "Start watching" : "Continue",
                prominent: true,
                action: advance
            )
            .keyboardShortcut(.defaultAction)
        }
    }

    private func advance() {
        switch step {
        case .welcome: step = .hooks
        case .hooks:   step = .usage
        case .usage:   finish()
        }
    }
}

// MARK: - Passo 1: boas-vindas

private struct OnboardingWelcomeStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStaticRender) private var isStaticRender
    /// Vira verdadeiro ao aparecer; é o gatilho da entrada escalonada.
    @State private var arrived = false

    /// As cinco criaturas com integração nativa. A .other fica de fora: não
    /// tem identidade própria, e apresentá-la seria prometer um sexto agente.
    private static let cast: [AgentTool] = [.claude, .codex, .opencode, .pi, .convoy]

    private var motionless: Bool { reduceMotion || isStaticRender }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            // O elenco entra um a um, como quem sobe ao palco. É a única
            // animação de apresentação da app inteira, e é aqui porque é a
            // única vez em que as cinco criaturas aparecem juntas — na barra
            // só se vê a que estiver a trabalhar.
            HStack(alignment: .bottom, spacing: 26) {
                ForEach(Array(Self.cast.enumerated()), id: \.element) { index, tool in
                    creature(tool, index: index)
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("PULSE")
                    .font(VITheme.mono(28))
                    .kerning(6)
                    .foregroundStyle(.white)
                Text("Your agents, in the corner of your eye.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(
                    "Pulse lives by the notch and watches Claude, Codex, "
                    + "OpenCode, Pi and Convoy — who is working, who finished, "
                    + "and who is stuck waiting for you."
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.52))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onAppear { arrived = true }
    }

    private func creature(_ tool: AgentTool, index: Int) -> some View {
        // Com movimento reduzido — ou num retrato, onde o onAppear não conta
        // uma história a ninguém — o elenco já está em palco.
        let visible = arrived || motionless
        return VStack(spacing: 7) {
            PixelBitmap(
                bitmap: MascotArt.frames(for: tool)[0],
                fill: MascotArt.color(tool),
                shade: MascotArt.shade(tool),
                cell: 5
            )
            Text(tool.chipName)
                .font(VITheme.mono(9))
                .foregroundStyle(.white.opacity(0.45))
        }
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 22)
        // A mesma mola das superfícies, desfasada por criatura: 0,12 s de
        // intervalo é o que separa "entram por ordem" de "entram atrasadas".
        .animation(
            motionless ? nil : VITheme.spring.delay(Double(index) * 0.12),
            value: visible
        )
    }
}

// MARK: - Passo 2: ligar os hooks

private struct OnboardingHooksStep: View {
    /// O ciclo de vida da ligação. `done` guarda o diagnóstico e não um "ok"
    /// nosso: o Doctor lê o disco depois do install, e mostrar o que ele viu
    /// vale mais do que a palavra de quem acabou de instalar.
    private enum Phase: Equatable {
        case idle
        case running
        case done([DoctorCheck])
        case failed(String)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Phase = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect the hooks")
                .font(VITheme.mono(19))
                .foregroundStyle(.white)
            Text(
                "Pulse listens through each tool's own hook points — Claude "
                + "Code settings, the Codex notify hook, an OpenCode plugin, a "
                + "Pi extension. Everything stays on this Mac."
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.52))
            .fixedSize(horizontal: false, vertical: true)

            switch phase {
            case .idle:
                OnboardingButton(label: "Connect hooks", prominent: true) {
                    connect()
                }
                .padding(.top, 4)
            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .padding(.top, 4)
            case .done(let checks):
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(checks, id: \.title) { check in
                        checkRow(check)
                    }
                    if checks.contains(where: { !$0.passed }) {
                        // Um ✗ aqui quase nunca é avaria: é uma ferramenta que
                        // este Mac não tem. Dizê-lo evita que o primeiro ecrã
                        // da app termine com um falso alarme.
                        Text("✗ usually means that tool isn't installed — Pulse works without it.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.top, 3)
                    }
                }
                .padding(.top, 2)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.97, green: 0.38, blue: 0.36))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 18)
        .animation(reduceMotion ? nil : VITheme.pop, value: phase)
    }

    private func checkRow(_ check: DoctorCheck) -> some View {
        HStack(spacing: 7) {
            Text(check.passed ? "✓" : "✗")
                .font(VITheme.mono(11))
                .foregroundStyle(
                    check.passed
                        ? VITheme.green
                        : Color(red: 0.97, green: 0.38, blue: 0.36)
                )
            Text(check.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        // O caminho completo fica no tooltip: o que se decide aqui é binário —
        // ligou ou não ligou — e seis linhas de caminhos não cabem no cartaz.
        .help(check.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.title): \(check.passed ? "connected" : "not connected")")
    }

    private func connect() {
        // O binário que os hooks vão invocar. No pacote .app vive em
        // Resources/bin; num `swift run` de desenvolvimento é irmão do
        // executável da app. O executável da própria app não serve: cada
        // evento de hook lançaria a interface gráfica outra vez.
        guard let cli = Self.cliExecutableURL() else {
            phase = .failed(
                "The pulse CLI is missing from this build. "
                + "Run `pulse install` from a terminal instead."
            )
            return
        }
        phase = .running
        // Fora do fio principal: o install copia ficheiros e funde JSON —
        // pouco, mas o suficiente para a janela engasgar no clique se for
        // feito onde o clique vive.
        Task.detached(priority: .userInitiated) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let outcome: Phase
            do {
                try Installer(homeDirectoryURL: home, executableURL: cli).install()
                outcome = .done(InstallationDoctor(homeDirectoryURL: home).diagnose())
            } catch {
                outcome = .failed(String(describing: error))
            }
            await MainActor.run { phase = outcome }
        }
    }

    private static func cliExecutableURL() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("bin/pulse"))
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(
                executable.deletingLastPathComponent().appendingPathComponent("pulse")
            )
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: - Passo 3: como usar

private struct OnboardingUsageStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How to use it")
                .font(VITheme.mono(19))
                .foregroundStyle(.white)
            Text("The panel opens when you move the pointer to the notch. The shortcuts keep your hands on the keyboard.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.52))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                shortcutRow(keys: ["⌥⌘A"], text: "Open or close the panel from anywhere.")
                shortcutRow(
                    keys: ["⏎", "esc"],
                    text: "Answer a permission card — approve with return, deny with escape."
                )
                shortcutRow(keys: ["⌘1…9"], text: "Jump straight to a session's terminal.")
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 18)
    }

    private func shortcutRow(keys: [String], text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    KeycapChip(label: key)
                }
            }
            // Coluna fixa: as explicações alinham à esquerda umas com as
            // outras, e a lista lê-se como tabela em vez de três frases soltas.
            .frame(width: 86, alignment: .leading)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        // Os chips são desenho; a frase inteira é o que o VoiceOver deve ler.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys.joined(separator: ", ")): \(text)")
    }
}

// MARK: - Botão

/// O botão do onboarding: a mesma cápsula de vidro dos botões de decisão,
/// sem ícone nem atalho impresso — aqui só há um caminho, e é para a frente.
private struct OnboardingButton: View {
    let label: String
    var prominent: Bool = false
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(prominent ? 1 : 0.85))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(LinearGradient(
                            colors: prominent
                                ? [.white.opacity(isHovering ? 0.30 : 0.22),
                                   .white.opacity(isHovering ? 0.16 : 0.10)]
                                : [.white.opacity(isHovering ? 0.16 : 0.10),
                                   .white.opacity(isHovering ? 0.09 : 0.05)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .overlay(
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(isHovering ? 0.38 : 0.26),
                                             .white.opacity(0.06)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                        )
                )
        }
        .buttonStyle(PressableButtonStyle())
        .linkCursor()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
