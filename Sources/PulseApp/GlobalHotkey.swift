import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    /// O atalho global pediu o painel. Não é o `AppDelegate` a abri-lo: quem
    /// sabe se ele está aberto, e com que animação abre, é a vista.
    static let pulseToggleMenu = Notification.Name("pulse.toggleMenu")
}

/// Um atalho que funciona esteja o que estiver à frente.
///
/// Sem isto, chegar às sessões exige o rato: apontar a um alvo de 38 pt colado
/// à berma de cima do ecrã, que é o gesto mais lento que a app pede. Com isto,
/// o painel abre de onde quer que estejas — e como abre já com foco de teclado,
/// dá para escolher a sessão e saltar para ela sem tirar as mãos das teclas.
///
/// Usa `RegisterEventHotKey` e não um monitor global de eventos: um monitor
/// exigiria autorização de Acessibilidade, que é um preço alto de mais para um
/// atalho. O Carbon regista no servidor de eventos e não vê mais nada do que a
/// combinação que pediu.
@MainActor
final class GlobalHotkey {

    /// A combinação, guardada como o par que o Carbon entende.
    struct Combination: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// ⌥⌘A. Escolhido por eliminação: ⌥⌘ está livre com quase todas as
        /// letras nas apps da Apple, e A é a inicial da app.
        static let `default` = Combination(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(optionKey | cmdKey)
        )

        /// Como se escreve numa legenda ou num menu.
        var displayString: String {
            var text = ""
            if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
            return text + (Self.names[keyCode] ?? "?")
        }

        private static let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_Space): "Space",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_J): "J",
        ]
    }

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private(set) var combination: Combination?

    /// Um identificador só nosso, para o handler distinguir este atalho de
    /// qualquer outro que a app venha a registar.
    private static let signature: OSType = 0x41544C41   // 'ATLA'
    private static let identifier: UInt32 = 1

    /// O handler do Carbon é uma função C: não captura contexto, por isso o
    /// alvo vive aqui e é encontrado por identificador.
    private static var registry: [UInt32: GlobalHotkey] = [:]

    func register(_ combination: Combination, action: @escaping () -> Void) {
        unregister()
        self.action = action
        self.combination = combination
        Self.registry[Self.identifier] = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id
                )
                let target = id.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { GlobalHotkey.registry[target]?.action?() }
                }
                return noErr
            },
            1, &eventType, nil, &handler
        )

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        RegisterEventHotKey(
            combination.keyCode, combination.modifiers,
            hotKeyID, GetApplicationEventTarget(), 0, &reference
        )
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
        combination = nil
        Self.registry[Self.identifier] = nil
    }

    deinit {
        // `deinit` não é isolado ao ator; libertar aqui as referências do
        // Carbon é seguro porque nenhuma delas toca em estado partilhado.
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
