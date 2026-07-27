import AppKit
import Observation

/// Há alguém a olhar para o ecrã?
///
/// Quando não há — ecrã bloqueado ou monitores a dormir — animar é queimar
/// bateria para ninguém. O caso real que motivou isto: agentes a trabalhar
/// durante a noite com o Mac bloqueado, e a barra a redesenhar o mascote e o
/// spinner a 10 fps durante horas para um ecrã apagado.
///
/// As fontes são as notificações do sistema, não sondagem: o aviso de
/// bloqueio/desbloqueio chega pelo centro distribuído, o de dormir/acordar
/// pelo NSWorkspace. Custa zero enquanto nada muda.
@MainActor
@Observable
final class DisplayActivity {
    static let shared = DisplayActivity()

    private(set) var isWatchable = true

    private init() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.isWatchable = false } }
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.isWatchable = true } }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.isWatchable = false } }
        workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.isWatchable = true } }
    }
}

// Nota de autópsia: houve aqui um `AnimationClock.origin` partilhado (em
// 2001) para alinhar as fases dos TimelineView. As medições pioraram com ele
// — 3,78% → 4,78% → 7,13%, a crescer com o tempo de vida — compatível com o
// agendador periódico a avançar da origem por passos. Alinhar fases era
// especulação; os números mandaram-na embora.
