import AppKit
import SwiftUI

import PulseCore

@main
struct PulseApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            PulseSettingsView(store: appDelegate.store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkey = GlobalHotkey()
    private var renderSignalSource: DispatchSourceSignal?
    private var panelController: NotchPanelController?
    private(set) var store: StateStore?
    private var observationScheduler: ObservationScheduler?
    private var focusAcknowledgmentObserver: FocusAcknowledgmentObserver?
    private var screenshotSignal: DispatchSourceSignal?
    private var instanceLock: SingleInstanceLock?
    /// Vive aqui e não numa variável local: a janela de boas-vindas fica
    /// aberta muito depois do arranque acabar, e sem dono era recolhida com
    /// ela à vista.
    private var onboarding: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Os sinais primeiro, antes de qualquer coisa que possa demorar.
        //
        // A ação por omissão de USR1/USR2 é TERMINAR o processo. Estavam a ser
        // instalados no fim do arranque, depois do painel e do pré-aquecer da
        // voz — e um sinal disparado nessa janela (um script a pedir um
        // retrato logo a seguir ao install) matava a app sem crash report,
        // sem log, sem nada. Foi exatamente assim que a encontrámos morta.
        installScreenshotSignal()
        installRenderSignal()

        // A identidade tipográfica do clone, antes de qualquer vista nascer.
        VITheme.registerFonts()

        NSApp.setActivationPolicy(.accessory)
        let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pulse/state", isDirectory: true)
        let repository = StateRepository(directoryURL: stateDirectory)
        // Two live instances fight over state and stack duplicate panels.
        // The file lock is atomic across bundled and `swift run` launches;
        // unlike an NSRunningApplication preflight, simultaneous starts
        // cannot both decide that the other process should exit.
        do {
            try repository.prepareDirectory()
            guard let lock = try SingleInstanceLock.acquire(
                at: stateDirectory.appendingPathComponent(".app.lock")
            ) else {
                NSLog("Pulse: another instance owns the application lock; exiting.")
                NSApp.terminate(nil)
                return
            }
            instanceLock = lock
        } catch {
            NSLog("Pulse failed to acquire its application lock: %@", String(describing: error))
            NSApp.terminate(nil)
            return
        }
        // As boas-vindas só depois do trinco: numa corrida de arranques, a
        // instância que perde termina aqui em cima — e era ela mostrar um
        // segundo cartaz por cima do primeiro.
        onboarding = OnboardingWindowController.presentIfNeeded()
        // Session names live next to — never inside — the state directory:
        // the store watches that directory and decode-attempts every .json.
        let store = StateStore(
            repository: repository,
            nameOverridesFileURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pulse/session-names.json")
        )
        self.store = store
        // Two-sound language: the system alert (user-configured sound and
        // volume) means "a session needs you"; the soft Tink means "the
        // agent finished its turn — the conversation is yours".
        UserDefaults.standard.register(defaults: [
            "attentionSoundEnabled": true,
            "turnCompleteSoundEnabled": true,
            "screenSelectionMode": ScreenSelectionMode.pointer.rawValue,
            // A voz. Sem registo aqui, um @AppStorage a true mostra true na
            // interface mas qualquer leitura por bool(forKey:) fora da view
            // devolve false — e a voz nunca falava.
            "voiceEnabled": false,
            "voiceOnTurnComplete": true,
            "voiceOnAttention": true,
            "voiceSilentOnCall": true,
        ])
        // A linguagem de dois sons continua igual; a voz entra por cima dela,
        // e traz o que um som não consegue: QUEM e ONDE. Quando fala, o som
        // fica de fora — os dois juntos seriam redundantes e mais barulhentos.
        store.onAttentionRaised = { sessions in
            let spoke = Voice.shared.announceAttention(sessions)
            guard !spoke, UserDefaults.standard.bool(forKey: "attentionSoundEnabled") else { return }
            NSSound.beep()
        }
        store.onTurnCompleted = { sessions in
            let spoke = Voice.shared.announceTurnComplete(sessions)
            guard !spoke, UserDefaults.standard.bool(forKey: "turnCompleteSoundEnabled") else { return }
            NSSound(named: "Tink")?.play()
        }
        // Capture scheduler sources first, then build Convoy ownership and
        // reconcile persisted state off the main thread. The panel stays
        // hidden until that baseline is ready, so internal OpenCode phases
        // cannot flash as global sessions during cold start.
        let scheduler = ObservationScheduler(repository: repository)
        observationScheduler = scheduler
        scheduler.startWithInitialReconciliation { [weak self, weak scheduler, weak store] in
            guard let self,
                  self.observationScheduler === scheduler,
                  self.store === store else { return }
            guard let store else { return }
            do {
                // Arm event capture before reading the post-reconciliation
                // baseline. Polling is only a 30-second safety heartbeat.
                try store.startObserving(pollInterval: 30)
            } catch {
                store.stopObserving()
                store.reloadRecordingError()
                NSLog("Pulse failed to start state observation: %@", String(describing: error))
            }
            self.panelController = NotchPanelController(store: store)
            self.panelController?.show()
            let focusObserver = FocusAcknowledgmentObserver(store: store)
            self.focusAcknowledgmentObserver = focusObserver
            focusObserver.start()
            // Pré-aquecer só agora: a primeira frase do dia chega uns 300 ms
            // atrasada com o sintetizador frio, e desencontrava-se do som de
            // assinatura que a antecede.
            // Só com a voz ligada: pré-aquecer o sintetizador acorda a pilha
            // de áudio (thread AXSpeech incluída) para uma voz que o
            // utilizador desligou.
            if Voice.shared.isEnabled { Voice.shared.prewarm() }
            // O atalho global. Registado depois do painel existir, para o
            // primeiro toque já encontrar alguém a quem falar.
            if UserDefaults.standard.object(forKey: "hotkeyEnabled") as? Bool ?? true {
                self.hotkey.register(.default) {
                    NotificationCenter.default.post(name: .pulseToggleMenu, object: nil)
                }
            }
        }
    }

    /// `kill -USR1 $(pgrep -x Pulse)` fotografa a faixa de topo do ecrã
    /// para /tmp/pulse-shot.png.
    ///
    /// Tem de ser a app a disparar: a autorização de Gravação de Ecrã é dada ao
    /// pacote, e o binário do CLI vive fora dele — teria identidade diferente e
    /// seria recusado.
    /// `kill -USR2 $(pgrep -x Pulse)` desenha as vistas para /tmp, sem ecrã.
    private func installRenderSignal() {
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let status = UIRender.writeAll()
                try? status.write(toFile: "/tmp/pulse-ui.status",
                                  atomically: true, encoding: .utf8)
            }
        }
        source.resume()
        renderSignalSource = source
        signal(SIGUSR2, SIG_IGN)
    }

    private func installScreenshotSignal() {
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                let result = await ScreenShot.captureTop()
                NSLog("Pulse screenshot: %@", result)
                // Também em ficheiro: o NSLog de uma app de fundo é difícil de
                // apanhar, e sem saber o resultado ficava-se sem diagnóstico.
                try? result.write(
                    toFile: "/tmp/pulse-shot.status",
                    atomically: true, encoding: .utf8
                )
            }
        }
        source.resume()
        signal(SIGUSR1, SIG_IGN)
        screenshotSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        focusAcknowledgmentObserver?.stop()
        observationScheduler?.stop()
        store?.stopObserving()
    }

}
