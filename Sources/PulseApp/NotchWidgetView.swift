import AppKit
import Combine
import SwiftUI

import PulseCore

/// Estamos a ser desenhados para um ficheiro, e não para um ecrã.
///
/// Existe por causa do `TimelineView`. Fora de ecrã não há relógio a que ele se
/// agarre, e o `ImageRenderer` responde com o retângulo amarelo de vista
/// inválida — o que tornava impossível retratar exatamente as partes mais
/// visíveis da app, a lista e a barra. Quem depende do tempo pergunta por isto
/// e desenha um instante fixo.
///
/// Só o retrato liga este sinal. O caminho normal não sabe que ele existe.
struct StaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isStaticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

struct NotchPointerSnapshot: Equatable {
    let isInside: Bool
    let revision: UInt
}

/// The AppKit hosting view owns one fixed tracking area for its entire
/// lifetime. SwiftUI observes its normalized result instead of replacing a
/// tracking area every time the hanging card changes height.
@MainActor
final class NotchPointerTracker: ObservableObject {
    @Published private(set) var snapshot = NotchPointerSnapshot(
        isInside: false,
        revision: 0
    )
    let hoverExpansionRequests = PassthroughSubject<DisplayPoint, Never>()
    private var reducer = PointerSampleReducer()

    @discardableResult
    func update(isInside: Bool, location: DisplayPoint) -> DisplayPoint {
        let reduction = reducer.reduce(isInside: isInside, location: location)
        if let containment = reduction.containmentChange {
            snapshot = NotchPointerSnapshot(
                isInside: containment.isInside,
                revision: containment.revision
            )
        }
        return reduction.location
    }

    func requestHoverExpansion(at location: DisplayPoint) {
        hoverExpansionRequests.send(location)
    }
}

/// Cursor de mão sobre o que é clicável.
///
/// Numa janela sem cromado nenhum, o cursor é o único aviso de que uma coisa
/// aceita clique antes de se carregar nela — os botões daqui não têm o
/// desenho de botão do sistema que normalmente faz esse trabalho.
private struct LinkCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

extension View {
    func linkCursor() -> some View { modifier(LinkCursor()) }
}

/// A spring das superfícies interiores do painel (linhas a abrir, scroll até
/// à seleção). A da expansão do painel (0,32/0,86) fica própria: é a única
/// animação que muda a silhueta inteira, e um nadinha mais lenta de propósito.
private let innerSpring = Animation.spring(response: 0.28, dampingFraction: 0.9)

struct NotchWidgetView: View {
    @Bindable var store: StateStore
    @AppStorage("hideWhenEmpty") private var hideWhenEmpty = false
    @AppStorage("skipDecisionWhenTerminalVisible")
    private var skipDecisionWhenTerminalVisible = true
    @AppStorage("glassFrostRadiusNotch") private var notchFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityNotch") private var notchTintOpacity = NotchGlassStyle.defaultTintOpacity
    @AppStorage("glassFrostRadiusPill") private var pillFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityPill") private var pillTintOpacity = NotchGlassStyle.defaultTintOpacity
    @Environment(\.openSettings) private var openSettings
    let layout: NotchLayout
    @ObservedObject var pointerTracker: NotchPointerTracker
    let requestPointerRefresh: () -> Void
    let onInteractiveRegionChange: (HangingNotchInteractionRegion) -> Void
    let onKeyboardFocusChange: (Bool) -> Void
    let onMenuVisibilityChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var rippleTrigger = 0
    @State private var collapseWorkItem: DispatchWorkItem?
    @State private var hoverExpandWorkItem: DispatchWorkItem?
    @State private var isHoveringPanel = false
    @State private var openMenuTrackingCount = 0
    @State private var rowInteractionActive = false
    /// Relógio do prazo do cartão de decisão; só corre enquanto ele existe.
    @State private var decisionClock = Date()
    /// O painel foi aberto por um pedido de permissão? Então é ele que o fecha.
    @State private var openedByDecision = false
    /// O painel está a mostrar o histórico em vez da lista de sessões.
    @State private var showsHistory = false
    /// As decisões lidas do disco, tal como estavam quando abriste o histórico.
    ///
    /// Lidas de uma vez e guardadas aqui, e não perguntadas ao store dentro do
    /// corpo da vista: o corpo redesenha-se dezenas de vezes por segundo — com
    /// o ponteiro, com o relógio do cartão, com cada recarga de estado — e uma
    /// leitura de ficheiro em cada um deles era ir ao disco por nada.
    @State private var decisionHistory: [DecisionRecord] = []
    /// O painel foi aberto pelo teclado e tem o teclado.
    ///
    /// Distinto de estar aberto: aberto com o rato, o painel não é key e as
    /// teclas não lhe chegam. É este estado, e não o `focusable()` da lista,
    /// que decide se se mostram as pistas ⌘N — mostrá-las quando as teclas não
    /// chegam lá seria ensinar um atalho que não funciona.
    @State private var keyboardActive = false
    @State private var outsideClickMonitor: Any?
    @State private var latestMeasuredContentHeight: CGFloat = 0

    var body: some View {
        let summary = SessionStatusSummary(
            sessions: store.sessions,
            acknowledgments: store.acknowledgments
        )
        // Uma decisão pendente segura o painel: escondê-lo deixava um agente
        // parado sem nada visível a dizê-lo. O histórico aberto segura-o pela
        // mesma ordem de razões: estás a ler, e a última sessão a acabar não é
        // motivo para o painel desaparecer debaixo dos olhos.
        let shouldHide = summary.activeSessionCount == 0 && hideWhenEmpty
            && !store.hasPendingDecision && !showsHistory
        let leftEntries = summary.visibleEntries.filter { $0.kind != .blocked }
        let rightEntries = summary.visibleEntries.filter { $0.kind == .blocked }
        let showsIdleMark = summary.activeSessionCount == 0
        // Quem anda na barra é quem está mesmo a trabalhar. Sem trabalho, não
        // há mascote — a barra em repouso volta a ser só a barra.
        //
        // Não entra no cálculo das larguras: anda por FORA da silhueta, e
        // alargar a ala por causa dele só empurrava o preto para cima dele.
        let walker: AgentTool? = store.sessions
            .first { $0.status == .working }?.tool
        let naturalLeftWidth = layout.statusWingWidth(
            side: .left,
            visibleIndicatorCount: leftEntries.count,
            showsIdleMark: showsIdleMark
        )
        let naturalRightWidth = layout.statusWingWidth(
            side: .right,
            visibleIndicatorCount: rightEntries.count,
            showsIdleMark: false
        )
        let wingWidths = layout.balancedStatusWingWidths(
            leftWidth: naturalLeftWidth,
            rightWidth: naturalRightWidth
        )
        let leftWidth = wingWidths.left
        let rightWidth = wingWidths.right
        let barWidth = leftWidth + layout.notchWidth + rightWidth
        let barLeadingOffset = layout.barLeadingOffset(
            leftWidth: leftWidth,
            rightWidth: rightWidth
        )
        let menuWidth = layout.width
        // The notch's straight sides sit a shoulder radius inside the panel,
        // so its card content narrows by the same amount per side to keep
        // the visual margin the bubble gets from its own edges.
        let menuContentWidth = NotchLayout.contentWidth(forExpandedPanelWidth: menuWidth)
            - 2 * layout.expandedContentSideInset
        let headerWings = layout.expandedHeaderWingWidths()
        // O passeio nunca pode sair da janela: o que passasse dela era cortado
        // a meio, e um mascote decapitado ao fim do trajeto é pior do que um
        // trajeto curto. `barLeadingOffset` é exatamente o que há à esquerda.
        let mascotLane = max(0, min(
            NotchLayout.mascotLaneWidth,
            barLeadingOffset - NotchLayout.mascotBarGap - 4
        ))
        let compactInteractiveFrame = DisplayFrame(
            minX: barLeadingOffset,
            minY: layout.topGap,
            width: barWidth,
            height: layout.height
        )

        // One view tree for both presentations: the bar never leaves the
        // hierarchy, so expanding animates the shared silhouette growing out
        // of the notch instead of cross-fading between two layouts. The bar
        // stays pinned to the camera housing the whole time: the outer offset
        // and the row's inner offset always sum to barLeadingOffset.
        ZStack(alignment: .topLeading) {
            if !shouldHide {
                VStack(alignment: .leading, spacing: 0) {
                    // The top row swaps between the compact status bar and the
                    // expanded header living in the wings beside the camera.
                    // Both layers stay resident: each inner offset cancels the
                    // outer animated offset, so every camera cutout remains
                    // pinned over the housing for the whole spring and the
                    // swap reads as a pure cross-fade. Opacity-0 views still
                    // hit-test, hence the explicit gates.
                    ZStack(alignment: .topLeading) {
                        Button(action: openMenu) {
                            barRow(
                                leftEntries: leftEntries,
                                rightEntries: rightEntries,
                                showsIdleMark: showsIdleMark,
                                walker: walker,
                                leftWidth: leftWidth,
                                rightWidth: rightWidth,
                                mascotLane: mascotLane
                            )
                            .contentShape(silhouette)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show active sessions")
                        .frame(width: barWidth, height: layout.height)
                        .offset(x: isExpanded ? barLeadingOffset : 0)
                        .opacity(isExpanded ? 0 : 1)
                        .allowsHitTesting(!isExpanded)

                        expandedHeaderRow(
                            sessionCount: store.sessions.count,
                            wings: headerWings
                        )
                        .frame(width: menuWidth, height: layout.height)
                        .offset(x: isExpanded ? 0 : -barLeadingOffset)
                        .opacity(isExpanded ? 1 : 0)
                        .allowsHitTesting(isExpanded)
                    }
                    if isExpanded, let decision = store.pendingDecision {
                        PermissionDecisionCard(
                            request: decision,
                            now: decisionClock,
                            decide: { store.decide(decision, $0) },
                            reveal: collapseMenu,
                            bandInset: layout.expandedContentSideInset,
                            textInset: SessionMenuLayout.expandedHeaderLeadingInset
                                + layout.expandedContentSideInset
                        )
                        // Largura do painel inteiro, ao contrário da lista: a
                        // faixa escura da decisão vai de bordo a bordo, e para
                        // isso precisa de saber onde os bordos estão.
                        .frame(width: menuWidth)
                        .onAppear { decisionClock = Date() }
                        .onReceive(
                            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
                        ) { decisionClock = $0 }
                    } else if isExpanded, showsHistory {
                        // A seguir ao cartão e não à frente dele: um pedido por
                        // responder tem um agente parado do outro lado, e nada
                        // no painel o pode tapar — muito menos o que já passou.
                        DecisionHistoryCard(records: decisionHistory)
                            .frame(width: menuContentWidth)
                            .frame(width: menuWidth, alignment: .center)
                            .transition(.opacity)
                    } else if isExpanded {
                        SessionMenuCard(
                            sessions: store.sessions,
                            stateDirectoryURL: store.stateDirectoryURL,
                            dismiss: collapseMenu,
                            acknowledge: { store.acknowledge($0) },
                            sessionTitle: { store.displayName(for: $0) },
                            overrideName: { store.nameOverrides.displayName(for: $0) },
                            rename: { store.rename($0, to: $1) },
                            setKeyboardFocus: onKeyboardFocusChange,
                            keyboardActive: keyboardActive,
                            onRowInteractionChange: { isActive in
                                rowInteractionActive = isActive
                                if isActive {
                                    cancelPendingCollapse()
                                } else {
                                    settleAfterDetachedInteraction()
                                }
                            },
                            toggleHistory: toggleHistory
                        )
                        .frame(width: menuContentWidth)
                        .frame(width: menuWidth, alignment: .center)
                        .transition(.opacity)
                    }
                }
                .frame(width: isExpanded ? menuWidth : barWidth, alignment: .topLeading)
                // The pill's expanded bubble has no camera band above the
                // header, so it gains breathing room between its rounded top
                // edge and the title, plus matching room under the last row;
                // collapsed keeps the tight capsule.
                .padding(.top, isExpanded ? layout.expandedHeaderTopPadding : 0)
                .padding(.bottom, isExpanded ? layout.expandedBottomPadding : 0)
                .background(
                    // The band beside the camera stays explicit pure black so
                    // the drop reads as part of the screen edge; below it the
                    // scrim fades into behind-window glass. Pill mode has no
                    // camera to hide and keeps a flat tint over the glass.
                    //
                    // The ripple warps only the scrim: it is pure vector, so
                    // it always rasterizes. The content above holds AppKit-
                    // backed views (the session list's scroll view) that a
                    // layer effect would render blank, and the glass below is
                    // window-server fed and must stay out of any effect.
                    NotchGlassScrim(
                        silhouette: silhouette,
                        barBandHeight: layout.height,
                        presentation: layout.presentation,
                        tintOpacity: layout.presentation == .pill
                            ? pillTintOpacity : notchTintOpacity
                    )
                    .modifier(ExpansionRippleEffect(trigger: rippleTrigger))
                )
                .background(
                    NotchGlassBackdrop(
                        presentation: layout.presentation,
                        frostRadius: layout.presentation == .pill
                            ? pillFrostRadius : notchFrostRadius
                    )
                )
                // Do not clip the compact counters to the curved silhouette:
                // the physical camera already owns the central cutout, while
                // clipping here shaves off the leading spinner before it can
                // reach the safe area beside that cutout.
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: InteractiveHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
                // Gestures live on the silhouette, not the outer frame: the
                // panel is always expanded-height, so the outer frame covers
                // transparent dead space below the visible shape.
                .contentShape(silhouette)
                .contextMenu {
                    SettingsLink {
                        Label("Pulse Settings", systemImage: "gearshape")
                    }
                    Divider()
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit Pulse", systemImage: "power")
                    }
                }
                // A session row's context menu is an NSMenu window outside
                // this view: opening it fires a hover exit that would
                // collapse the panel — and the menu with it — mid-read.
                .onReceive(
                    NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
                ) { _ in
                    openMenuTrackingCount += 1
                    cancelPendingCollapse()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
                ) { _ in
                    openMenuTrackingCount = max(0, openMenuTrackingCount - 1)
                    settleAfterDetachedInteraction()
                }
                // Offset the rendered surface *after* attaching its shape and
                // hover tracking. Applying offset first leaves those later
                // modifiers at the unshifted 720-point panel origin: pill
                // hover then misses entirely and notch hover lands in empty
                // space to the left of the visible bar. The vertical offset
                // floats the pill below the screen edge — further while the
                // bubble is open; the notch keeps zero gap in both states.
                .offset(
                    x: isExpanded ? 0 : barLeadingOffset,
                    y: isExpanded ? layout.expandedTopGap : layout.topGap
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isExpanded)
        .onChange(of: pointerTracker.snapshot) { _, snapshot in
            handlePointerContainmentChange(snapshot)
        }
        .onReceive(pointerTracker.hoverExpansionRequests) { location in
            handleHoverExpansionRequest(location, compactFrame: compactInteractiveFrame)
        }
        .onAppear {
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isExpanded,
                isHidden: shouldHide
            )
            requestPointerRefresh()
            onMenuVisibilityChange(isExpanded)
        }
        .onPreferenceChange(InteractiveHeightPreferenceKey.self) { measuredHeight in
            latestMeasuredContentHeight = measuredHeight
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: measuredHeight,
                isExpanded: isExpanded,
                isHidden: shouldHide
            )
        }
        .onChange(of: isExpanded) { _, isVisible in
            if isVisible, !reduceMotion {
                rippleTrigger += 1
            }
            // Cada abertura começa na lista, e não onde a anterior ficou: abre-se
            // o painel para ver quem está a trabalhar, e reabri-lo no histórico
            // punha o caso raro à frente do de todos os dias.
            //
            // No abrir e não no fechar, de propósito: trocar o conteúdo enquanto
            // a bolha encolhe fazia a lista piscar por cima do histórico a meio
            // da animação de saída.
            if isVisible { showsHistory = false }
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isVisible,
                isHidden: shouldHide
            )
            updateOutsideClickMonitor(menuIsVisible: isVisible)
            onMenuVisibilityChange(isVisible)
        }
        .onChange(of: compactInteractiveFrame) { _, newFrame in
            publishInteractiveRegion(
                compactFrame: newFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isExpanded,
                isHidden: shouldHide
            )
            requestPointerRefresh()
        }
        .onChange(of: shouldHide) { _, isHidden in
            publishInteractiveRegion(
                compactFrame: compactInteractiveFrame,
                measuredContentHeight: latestMeasuredContentHeight,
                isExpanded: isExpanded,
                isHidden: isHidden
            )
        }
        .onDisappear {
            updateOutsideClickMonitor(menuIsVisible: false)
            onMenuVisibilityChange(false)
        }
        .onChange(of: store.sessions.isEmpty) { _, isNowEmpty in
            // Uma decisão pendente sobrevive à lista esvaziar: o pedido é a
            // única coisa no painel e fechá-lo perdia-o. O histórico também: o
            // que ele mostra não depende de haver sessões vivas, e fechar-lhe o
            // painel na cara só porque a última acabou era arrancar-te da leitura.
            if isNowEmpty, !store.hasPendingDecision, !showsHistory { collapseMenu() }
        }
        .onChange(of: store.hasPendingDecision) { _, isPending in
            presentPendingDecision(isPending)
        }
        .onAppear { presentPendingDecision(store.hasPendingDecision) }
        .onReceive(NotificationCenter.default.publisher(for: .pulseToggleMenu)) { _ in
            // O atalho abre E fecha. Um atalho que só abre obriga-te a ir ao
            // rato para o desfazer, que é exatamente o que ele existe para
            // evitar.
            if isExpanded {
                collapseMenu()
            } else {
                // Ativar a app é o que permite ao painel receber teclas. Sem
                // isto abria mudo: via-se a lista e não se podia lá mexer.
                NSApp.activate(ignoringOtherApps: true)
                keyboardActive = true
                onKeyboardFocusChange(true)
                openMenu()
            }
        }
    }

    // MARK: Bar

    private func barRow(
        leftEntries: [SessionStatusSummary.StatusEntry],
        rightEntries: [SessionStatusSummary.StatusEntry],
        showsIdleMark: Bool,
        walker: AgentTool?,
        leftWidth: CGFloat,
        rightWidth: CGFloat,
        mascotLane: CGFloat
    ) -> some View {
        // Wings span the full bar height so the click targets reach the top
        // edge of the screen — the natural place to slam the pointer. Only
        // states with a nonzero count take up a slot. Every indicator is a
        // fixed slot and wing widths add up exactly, so padding stays
        // symmetric on both pill and notch — no slack parked at either end.
        HStack(spacing: 0) {
            Group {
                if leftEntries.isEmpty {
                    if showsIdleMark {
                        // Quiet empty state: the app is awake but no agent
                        // is running.
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.32))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("No active agents")
                    }
                } else {
                    HStack(spacing: 0) {
                        Spacer(minLength: layout.leftStatusWingLeadingPadding)
                        HStack(spacing: NotchLayout.statusIndicatorSpacing) {
                            ForEach(leftEntries) { entry in
                                StatusSummaryIndicator(kind: entry.kind, count: entry.count)
                            }
                        }
                        Spacer(minLength: layout.leftStatusWingTrailingPadding)
                    }
                    .frame(width: leftWidth, height: layout.height, alignment: .leading)
                }
            }
            .frame(width: leftWidth, height: layout.height, alignment: .leading)
            Color.clear
                .frame(width: layout.notchWidth, height: layout.height)
            Group {
                if !rightEntries.isEmpty {
                    HStack(spacing: 0) {
                        Spacer(minLength: layout.rightStatusWingLeadingPadding)
                        HStack(spacing: NotchLayout.statusIndicatorSpacing) {
                            ForEach(rightEntries) { entry in
                                StatusSummaryIndicator(kind: entry.kind, count: entry.count)
                            }
                        }
                        Spacer(minLength: layout.rightStatusWingTrailingPadding)
                    }
                    .frame(width: rightWidth, height: layout.height, alignment: .trailing)
                }
            }
            .frame(width: rightWidth, height: layout.height, alignment: .trailing)
        }
        // O mascote anda À ESQUERDA da barra, por fora do preto.
        //
        // Nada nesta pilha clipa a linha da barra à silhueta, e o painel tem
        // 800 pt centrados no recorte — a barra ocupa uns 350 ao meio, por isso
        // sobra folga larga de cada lado, dentro da janela e por cima de nada.
        //
        // Dentro da faixa preta ele era mais uma coisa arrumada numa régua de
        // indicadores. Fora dela deixa de ter caixa: passeia sobre a menu bar e
        // o wallpaper, e é a única coisa nesta app que não vive num campo.
        //
        // Continua colado ao spinner braille — só do outro lado do bordo. Os
        // dois dizem a mesma coisa por meios diferentes: quem trabalha, e
        // quantos.
        .overlay(alignment: .leading) {
            if let walker {
                WalkingMascot(tool: walker, runway: mascotLane)
                    .offset(x: -(mascotLane + NotchLayout.mascotBarGap))
                    .allowsHitTesting(false)
            }
        }
    }

    /// Expanded replacement for the compact bar row: the menu header claims
    /// the wings beside the camera cutout instead of a row below it, so the
    /// space flanking the housing carries information rather than padding.
    /// Fixed-height frames center the content vertically in both bar heights.
    private func expandedHeaderRow(
        sessionCount: Int,
        wings: (left: CGFloat, right: CGFloat)
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                // O cabeçalho diz sempre o que está por baixo dele. Deixá-lo em
                // "Active sessions" com o histórico aberto era assinar a lista
                // errada, e o número ao lado ficava a contar outra coisa.
                Text(showsHistory ? "Recent decisions" : "Active sessions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
            }
            .padding(
                .leading,
                SessionMenuLayout.expandedHeaderLeadingInset + layout.expandedContentSideInset
            )
            .frame(width: wings.left, height: layout.height, alignment: .leading)
            Color.clear
                .frame(width: layout.notchWidth, height: layout.height)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(showsHistory ? decisionHistory.count : sessionCount, format: .number)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.32))
                // O histórico mora aqui, e não nas definições: é a mesma coisa
                // que a lista — o que os teus agentes andaram a fazer —, só que
                // no passado. Trocar a lista por ele no mesmo painel guarda
                // essa parecença; uma janela à parte perdia-a.
                HeaderIconButton(
                    systemImage: "clock.arrow.circlepath",
                    accessibilityLabel: showsHistory
                        ? "Show active sessions" : "Show decision history",
                    isActive: showsHistory,
                    action: toggleHistory
                )
                // A porta visível para a janela de Definições; o menu do clique
                // direito na silhueta fica como alternativa para quando não há
                // sessões nenhumas e nenhum menu abre.
                HeaderIconButton(systemImage: "gearshape", accessibilityLabel: "Pulse settings") {
                    // The settings window is a normal app window: activate
                    // first so it opens frontmost and key — the notch panel
                    // itself never takes that role.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                    collapseMenu()
                }
            }
            .padding(
                .trailing,
                SessionMenuLayout.expandedHeaderTrailingInset + layout.expandedContentSideInset
            )
            .frame(width: wings.right, height: layout.height, alignment: .trailing)
        }
        .lineLimit(1)
    }

    /// Bar and menu share one silhouette. On a notched display the top
    /// shoulders curve inward from the screen edge while the lower corners
    /// remain circular; the detached pill instead rounds every corner — a
    /// capsule collapsed, a bubble expanded. Compact and expanded use
    /// identical radii; expansion only adds the straight sides between them.
    private var silhouette: HangingNotchShape {
        HangingNotchShape(
            style: layout.cornerStyle,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        )
    }

    // MARK: Menu visibility

    private static let hoverExpandDelay: TimeInterval = 0.15

    private func scheduleExpansion() {
        guard !isExpanded, hoverExpandWorkItem == nil else { return }
        let workItem = DispatchWorkItem {
            isExpanded = true
            hoverExpandWorkItem = nil
        }
        hoverExpandWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverExpandDelay, execute: workItem)
    }

    private func openMenu() {
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
        cancelPendingCollapse()
        isExpanded = true
    }

    private func publishInteractiveRegion(
        compactFrame: DisplayFrame,
        measuredContentHeight: CGFloat,
        isExpanded: Bool,
        isHidden: Bool
    ) {
        let frame = HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: layout.width,
            expandedMaximumHeight: layout.expandedHeight,
            measuredContentHeight: measuredContentHeight,
            isExpanded: isExpanded,
            isHidden: isHidden,
            expandedTopInset: layout.expandedTopGap
        )
        let region = HangingNotchInteractionRegion(
            frame: frame,
            cornerStyle: layout.cornerStyle,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        )
        onInteractiveRegionChange(region)
    }

    /// Troca a lista pelo histórico, e lê o ficheiro na troca.
    ///
    /// Ler aqui e só aqui é o que garante que cada abertura mostra o que está
    /// no disco naquele momento — incluindo a decisão que tomaste há dez
    /// segundos — sem que a vista ande a sondar o ficheiro enquanto está
    /// fechada, que é o tempo quase todo.
    private func toggleHistory() {
        if !showsHistory {
            decisionHistory = store.recentDecisions(limit: Self.historyLength)
        }
        withAnimation(.easeOut(duration: 0.18)) {
            showsHistory.toggle()
        }
    }

    /// Uma dúzia: o suficiente para reencontrar a decisão de que te lembras
    /// vagamente, e pouco para caber num painel que também tem de caber no ecrã.
    private static let historyLength = 12

    private func collapseMenu() {
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
        cancelPendingCollapse()
        isExpanded = false
        // Largar o teclado ao fechar.
        //
        // O painel é key enquanto o atalho o tem aberto. Se ficasse key depois
        // de fechar, continuava a comer as teclas da app que está por baixo —
        // e ninguém liga um painel invisível ao facto de estar a escrever para
        // o vazio.
        if keyboardActive {
            keyboardActive = false
            onKeyboardFocusChange(false)
        }
    }

    private func cancelPendingCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    /// Collapse shortly after the pointer leaves the panel, mirroring how
    /// notch utilities dismiss. Inline row interactions keep it open.
    private func scheduleCollapseOnHoverExit() {
        cancelPendingCollapse()
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
        // Com uma decisão aberta o painel não recolhe: tirar o rato de cima
        // não é uma resposta, e o agente continua à espera.
        guard !store.hasPendingDecision else { return }
        guard HoverInteraction.shouldCollapse(
            isExpanded: isExpanded,
            isHoveringPanel: isHoveringPanel,
            openMenuTrackingCount: openMenuTrackingCount,
            rowInteractionActive: rowInteractionActive
        ) else { return }
        let workItem = DispatchWorkItem {
            guard !store.hasPendingDecision else { return }
            guard HoverInteraction.shouldCollapse(
                isExpanded: isExpanded,
                isHoveringPanel: isHoveringPanel,
                openMenuTrackingCount: openMenuTrackingCount,
                rowInteractionActive: rowInteractionActive
            ) else { return }
            collapseWorkItem = nil
            isExpanded = false
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func handlePointerContainmentChange(_ snapshot: NotchPointerSnapshot) {
        if snapshot.isInside {
            isHoveringPanel = true
            cancelPendingCollapse()
        } else {
            isHoveringPanel = false
            hoverExpandWorkItem?.cancel()
            hoverExpandWorkItem = nil
            scheduleCollapseOnHoverExit()
        }
    }

    private func handleHoverExpansionRequest(
        _ location: DisplayPoint,
        compactFrame: DisplayFrame
    ) {
        guard HoverInteraction.shouldScheduleExpansion(
            pointer: location,
            compactFrame: compactFrame,
            panelOriginX: layout.originX,
            panelTopY: layout.originY + layout.height,
            isExpanded: isExpanded,
            cornerStyle: layout.cornerStyle,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ) else { return }
        scheduleExpansion()
    }

    private func settleAfterDetachedInteraction() {
        guard !rowInteractionActive else { return }
        requestPointerRefresh()
        DispatchQueue.main.async {
            if isHoveringPanel {
                cancelPendingCollapse()
            } else {
                scheduleCollapseOnHoverExit()
            }
        }
    }

    /// Um pedido de permissão abre o painel por si. Do outro lado há um
    /// processo bloqueado — esperar que passes o rato por cima seria esperar
    /// por acaso.
    ///
    /// E fecha-o quando o pedido se resolve, se tiver sido ele a abri-lo. Sem
    /// isto o painel ficava aberto para sempre depois de decidires: quem o
    /// fecha normalmente é a saída do rato, e o rato nunca lá esteve.
    private func presentPendingDecision(_ isPending: Bool) {
        if isPending {
            if deferToVisibleTerminal() { return }
            openedByDecision = !isExpanded
            openMenu()
        } else if openedByDecision {
            openedByDecision = false
            guard !isHoveringPanel else { return }
            collapseMenu()
        }
    }

    /// Se já tens o painel do agente à frente, o cartão não aparece.
    ///
    /// Do outro lado do hook, `defer` faz o Claude Code desenhar o diálogo dele
    /// no terminal — que é onde já estás a olhar. Mostrar o cartão além disso
    /// dava-te dois sítios para responder à mesma pergunta, e obrigava-te a
    /// escolher onde carregar antes de escolheres o que responder.
    ///
    /// Só dispara com identidade do painel confirmada. Um "sim" errado deixava
    /// o agente parado num diálogo fora do ecrã até ao fim do prazo; um "não"
    /// errado custa um cartão a mais.
    private func deferToVisibleTerminal() -> Bool {
        guard skipDecisionWhenTerminalVisible, let request = store.pendingDecision,
              let session = store.sessions.first(where: { $0.sessionID == request.sessionID }),
              TerminalVisibility.isOnScreen(session)
        else { return false }
        store.decide(request, .defer_)
        return true
    }

    private func updateOutsideClickMonitor(menuIsVisible: Bool) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        guard menuIsVisible else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            // Com uma decisão aberta, clicar fora não fecha: é precisamente
            // assim que vais ao terminal ver o contexto antes de decidir.
            guard !store.hasPendingDecision else { return }
            collapseMenu()
        }
    }

}

struct HangingNotchShape: Shape {
    var style: HangingNotchCornerStyle = .hangingNotch
    var topShoulderRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topShoulderRadius, bottomCornerRadius) }
        set {
            topShoulderRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(HangingNotchGeometry.path(
            in: rect,
            style: style,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        ))
    }
}

private struct InteractiveHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Status indicators

private extension SessionStatusSummary.StatusEntry.Kind {
    var accessibilityName: String {
        switch self {
        case .running: "running"
        case .waiting: "waiting"
        case .blocked: "blocked"
        }
    }
}

/// User-facing status vocabulary shared by the bar and the session rows.
/// Mirrors the README "Session states" table so VoiceOver reads the same
/// words the compact indicators announce, instead of the snake-case rawValue.
private extension SessionStatus {
    var accessibilityName: String {
        switch self {
        case .working: "running"
        case .idle: "waiting"
        case .needsAttention: "blocked"
        case .ended: "ended"
        }
    }
}

/// One compact status counter. Zero-count states never reach this view —
/// the summary filters them out — so every glyph on the bar earns its
/// space. Waiting and blocked share the same dot size: green marks an idle
/// session ready for input, while red remains reserved for attention.
private struct StatusSummaryIndicator: View {
    let kind: SessionStatusSummary.StatusEntry.Kind
    let count: Int
    /// "Diferenciar sem cor", da Acessibilidade. Verde-parado e
    /// vermelho-precisa-de-ti são a mesma bola para quem não separa os dois:
    /// com a preferência ativa, quem precisa de ti ganha FORMA — um triângulo
    /// — e a cor passa a redundância em vez de canal único.
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    /// Só um destes estados te pede alguma coisa.
    ///
    /// Antes os três pesavam o mesmo: três sessões paradas e uma à tua espera
    /// liam-se igual. Agora quem precisa de ti tem ponto maior, halo e número
    /// a peso cheio; quem está parado recua.
    ///
    /// A hierarquia é toda estática. Um pulsar resolveria isto num instante e
    /// custaria caro: a barra de menus é visão periférica, e variação de brilho
    /// aí é o mecanismo da fadiga — a mesma razão por que o anel das linhas
    /// gira a luminância constante em vez de piscar.
    private var needsYou: Bool { kind.indicatorStyle == .redDot }

    var body: some View {
        HStack(spacing: 3) {
            switch kind.indicatorStyle {
            case .spinner:
                WorkingPixelSpinner()
            case .greenDot, .redDot, .mutedDot:
                if differentiateWithoutColor && needsYou {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(indicatorColor(for: kind.indicatorStyle))
                } else {
                    Circle()
                        .fill(indicatorColor(for: kind.indicatorStyle))
                        .frame(width: needsYou ? 9 : 7, height: needsYou ? 9 : 7)
                        .background {
                            if needsYou {
                                Circle()
                                    .fill(indicatorColor(for: kind.indicatorStyle).opacity(0.22))
                                    .frame(width: 18, height: 18)
                            }
                        }
                }
            }
            Text(count, format: .number)
                .font(.system(
                    size: 12,
                    weight: needsYou ? .semibold : .regular,
                    design: .rounded
                ))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(needsYou ? 1 : 0.55))
        // Fixed slot: the wing-width formula in NotchLayout adds up to
        // exactly the rendered bar, preserving each side's intended padding.
        .frame(width: NotchLayout.statusIndicatorSlotWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(kind.accessibilityName) sessions")
    }
}

/// O anel de contexto: enche no sentido do relógio e muda de cor quando o
/// assunto passa de informação a aviso.
private struct ContextGauge: View {
    let reading: ContextMeter.Reading

    private var tint: Color {
        switch reading.fraction {
        case ..<0.7:  return .white.opacity(0.45)
        case ..<0.9:  return Color(red: 0.98, green: 0.71, blue: 0.30)
        default:      return Color(red: 0.97, green: 0.38, blue: 0.36)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.14), lineWidth: 2)
            Circle()
                .trim(from: 0, to: reading.fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel("Context \(Int(reading.fraction * 100)) percent full")
    }
}

/// The classic braille dot-matrix spinner used across CLI tools (ora,
/// Convoy's own progress indicator) — several dots lit per frame rather
/// than one pixel chasing itself. Monochrome by design so the green and red
/// dots remain easy to distinguish from active work.
private struct WorkingPixelSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStaticRender) private var isStaticRender
    private static let stepInterval: TimeInterval = 0.08
    private static let frames: [Character] = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    var body: some View {
        if reduceMotion || isStaticRender {
            frame(Self.frames[0])
        } else {
            TimelineView(.periodic(from: .now, by: Self.stepInterval)) { timeline in
                let step = Int(timeline.date.timeIntervalSinceReferenceDate / Self.stepInterval)
                frame(Self.frames[step % Self.frames.count])
            }
        }
    }

    private func frame(_ character: Character) -> some View {
        Text(String(character))
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 11, height: 11)
    }
}

/// Shared colors for compact and per-session status dots.
private func indicatorColor(for style: StatusIndicatorStyle) -> Color {
    switch style {
    case .spinner: .white
    case .mutedDot: .gray
    case .greenDot: .green
    case .redDot: .red
    }
}

// MARK: - Brand icons

/// SVG brand marks bundled in PulseCore; NSImage renders SVG natively
/// on macOS 11+ so no rasterized assets are needed.
private enum AgentIcons {
    static let byTool: [AgentTool: NSImage] = Dictionary(
        uniqueKeysWithValues: AgentTool.allCases.compactMap { tool in
            NSImage(contentsOf: BundledResources.iconURL(for: tool)).map { (tool, $0) }
        }
    )
}

private struct AgentIconView: View {
    let tool: AgentTool

    var body: some View {
        if let image = AgentIcons.byTool[tool] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            Text(String(tool.rawValue.prefix(1)).uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Session menu

private struct SessionMenuCard: View {
    let sessions: [AgentSession]
    let stateDirectoryURL: URL
    let dismiss: () -> Void
    let acknowledge: (AgentSession) -> Void
    let sessionTitle: (AgentSession) -> String
    let overrideName: (AgentSession) -> String?
    let rename: (AgentSession, String) -> Void
    let setKeyboardFocus: (Bool) -> Void
    /// O painel tem mesmo o teclado. Sem isto, o `focusable()` da lista dizia
    /// que sim mesmo com o painel aberto pelo rato, que nunca é key.
    let keyboardActive: Bool
    let onRowInteractionChange: (Bool) -> Void
    /// A tecla H entrega aqui; quem sabe trocar de vista é a vista-mãe.
    var toggleHistory: () -> Void = {}
    @State private var errorMessage: String?
    // At most one row shows its inline actions; opening another closes it.
    @State private var actionsSessionID: String?
    /// A linha sob o teclado.
    ///
    /// Separada do hover de propósito: o rato e o teclado podem estar em
    /// linhas diferentes, e obrigar um a seguir o outro faz a lista saltar
    /// debaixo dos dedos de quem está a escrever.
    @State private var selectedID: String?
    /// `focusable()` torna a lista elegível para foco; não lho dá. Sem pedir o
    /// foco explicitamente, o painel abria pelo atalho e as teclas iam parar a
    /// lado nenhum — o painel era key, mas dentro dele ninguém escutava.
    @FocusState private var listFocused: Bool
    @State private var branchCoordinator = GitBranchResolutionCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: SessionMenuLayout.cardStackSpacing) {
            if sessions.isEmpty {
                // Um ecrã vazio diz o que fazer a seguir. "No active sessions"
                // descrevia o nada e deixava quem chega aqui pela primeira vez
                // sem saber se a app está avariada ou apenas à espera.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing running")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Start Claude, Codex or OpenCode in a terminal and it shows up here.")
                        .font(.system(size: 11))
                        // 0,52 e não 0,42. Medido sobre o retrato: a 0,42 dava
                        // 4,1:1 de contraste, abaixo do 4,5 que texto corrido
                        // precisa. É a única frase da app que alguém lê de
                        // primeira vez, e era a menos legível de todas.
                        .foregroundStyle(.white.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 12 e não 14: com o contentor a 4 e o gutter a 22, é o que
                // alinha este texto na coluna dos 38 pt das outras superfícies.
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            } else {
                // The list owns the extra height from inline actions. Once
                // several sessions are visible it scrolls instead of growing
                // past the panel and clipping the lower controls.
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        // `VStack` e não `LazyVStack`: o ganho da versão
                        // preguiçosa mede-se em centenas de linhas, e aqui
                        // nunca há mais do que uma mão cheia de sessões. Em
                        // troca, uma pilha normal desenha-se fora de ecrã, o
                        // que permite retratar a lista sem depender do ecrã.
                        VStack(spacing: 0) {
                            ForEach(sessions) { session in
                                row(for: session)
                                    .id(session.id)
                            }
                        }
                    }
                    .frame(height: SessionMenuLayout.sessionListHeight(
                        sessionCount: sessions.count,
                        hasExpandedActions: actionsSessionID != nil
                    ))
                    .onChange(of: actionsSessionID) { _, sessionID in
                        guard let sessionID else { return }
                        DispatchQueue.main.async {
                            withAnimation(innerSpring) {
                                proxy.scrollTo(sessionID, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: selectedID) { _, sessionID in
                        guard let sessionID else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(sessionID, anchor: .center)
                        }
                    }
                }
                .padding(.bottom, SessionMenuLayout.sessionListBottomPadding)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, SessionMenuLayout.contentHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SessionMenuLayout.listTopPadding)
        .padding(.bottom, SessionMenuLayout.cardBottomPadding)
        // Conduzir a lista sem tocar no rato.
        //
        // O atalho global abria o painel com foco de teclado e não havia nada
        // para conduzir com ele: via-se a lista e a única forma de lá mexer era
        // ir buscar o rato — que é exatamente o que o atalho existe para
        // evitar. Setas movem, Enter salta para o terminal, Escape fecha.
        .focusable()
        .focused($listFocused)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { activateSelection(); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        // H de histórico. Só aqui, com a lista focada: fora do foco de teclado
        // uma letra solta a mudar vistas seria uma armadilha para quem escreve.
        .onKeyPress(KeyEquivalent("h")) { toggleHistory(); return .handled }
        // ⌘1..9 salta direto, sem contar setas. Acima de nove sessões deixa de
        // haver dígito, e a essa altura as setas são mais rápidas de qualquer
        // maneira.
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard press.modifiers.contains(.command),
                  let digit = Int(String(press.characters)), digit >= 1,
                  digit <= min(9, sessions.count)
            else { return .ignored }
            selectedID = sessions[digit - 1].id
            activateSelection()
            return .handled
        }
        // Abrir já com a primeira escolhida: sem isto a primeira seta não
        // move, escolhe — e quem carrega em Enter à espera de saltar não salta.
        .onAppear {
            if selectedID == nil { selectedID = sessions.first?.id }
            if keyboardActive { listFocused = true }
        }
        .onChange(of: keyboardActive) { _, active in listFocused = active }
        .onChange(of: sessions.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = ids.first }
        }
        // The whole panel can collapse while a row interaction is open;
        // the interaction lock must not outlive the card.
        .onDisappear { onRowInteractionChange(false) }
    }

    private func move(_ delta: Int) {
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex { $0.id == selectedID } ?? -1
        // Sem dar a volta: numa lista curta, saltar do fim para o princípio
        // perde-se de vista e obriga a reencontrar onde se está.
        let next = min(max(current + delta, 0), sessions.count - 1)
        selectedID = sessions[next].id
    }

    private func activateSelection() {
        guard let session = sessions.first(where: { $0.id == selectedID }) else { return }
        focusSession(session)
    }

    private func row(for session: AgentSession) -> some View {
        SessionRow(
            session: session,
            title: sessionTitle(session),
            renamePrefill: overrideName(session) ?? "",
            isActionsExpanded: actionsSessionID == session.id,
            isSelected: selectedID == session.id,
            shortcutDigit: shortcutDigit(for: session),
            toggleActions: { toggleActions(for: session) },
            focus: focusSession,
            rename: rename,
            kill: killSession,
            setKeyboardFocus: setKeyboardFocus,
            branchCoordinator: branchCoordinator
        )
    }

    /// Só as nove primeiras, e só com o teclado a mandar.
    private func shortcutDigit(for session: AgentSession) -> Int? {
        guard keyboardActive, listFocused, let index = sessions.firstIndex(where: { $0.id == session.id }),
              index < 9
        else { return nil }
        return index + 1
    }

    private func toggleActions(for session: AgentSession) {
        withAnimation(innerSpring) {
            actionsSessionID = actionsSessionID == session.id ? nil : session.id
        }
        onRowInteractionChange(actionsSessionID != nil)
    }

    /// The kill waits up to two grace periods; keep it off the main thread.
    /// The state document needs no cleanup here: the scheduler's exit
    /// watcher sees the death and the reaper removes it on its tick.
    private func killSession(_ session: AgentSession) {
        Task.detached(priority: .userInitiated) {
            do {
                try TerminationService.terminate(session)
            } catch {
                await MainActor.run {
                    errorMessage = "Could not kill this session."
                }
            }
        }
    }

    private func focusSession(_ session: AgentSession) {
        // FocusService shells out to osascript/tmux, which can take
        // hundreds of milliseconds; keep it off the main thread so the
        // menu stays responsive.
        Task.detached(priority: .userInitiated) {
            do {
                let latest = try StateRepository(directoryURL: stateDirectoryURL)
                    .loadSessions()
                    .first { $0.id == session.id }
                guard let latest else { throw FocusError.sessionUnavailable }
                try FocusService.focus(latest)
                await MainActor.run {
                    acknowledge(latest)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Could not focus this terminal session."
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let title: String
    let renamePrefill: String
    let isActionsExpanded: Bool
    /// Escolhida pelo teclado. Desenha-se como o hover porque é a mesma ideia
    /// — "é esta" — e duas linguagens para a mesma ideia obrigavam a aprender
    /// duas.
    let isSelected: Bool
    /// O dígito de ⌘N desta linha, ou nada quando o teclado não manda na lista.
    let shortcutDigit: Int?
    let toggleActions: () -> Void
    let focus: (AgentSession) -> Void
    let rename: (AgentSession, String) -> Void
    let kill: (AgentSession) -> Void
    let setKeyboardFocus: (Bool) -> Void
    let branchCoordinator: GitBranchResolutionCoordinator
    @Environment(\.isStaticRender) private var isStaticRender

    /// Sub-modes of the inline action area: the button strip, the rename
    /// field, or the kill confirmation. All live inside the row itself so
    /// nothing ever floats outside the notch silhouette.
    private enum ActionMode { case menu, renaming, confirmingKill }

    /// Quanto tempo o "Copied" fica no lugar do rótulo. Curto o bastante para
    /// não parecer que a linha ficou presa, longo o bastante para ser lido por
    /// quem olhou para o outro lado no instante do clique.
    private static let copyFeedbackDuration: TimeInterval = 1.2

    @State private var isHovered = false
    @State private var branchName: String?
    /// A última medição de contexto, lida da cauda do transcript.
    @State private var contextReading: ContextMeter.Reading?
    @State private var mode: ActionMode = .menu
    @State private var renameDraft = ""
    /// O feedback da cópia vive aqui, na linha, pela mesma razão que o
    /// `confirmingKill`: é a resposta a um gesto desta linha e ninguém de fora
    /// ganha nada em saber que aconteceu.
    @State private var didCopyPath = false
    /// Cada cópia carimba o seu temporizador. Sem carimbo, fechar e reabrir a
    /// linha dentro do segundo de feedback deixava o temporizador da cópia
    /// anterior fechar um menu que o utilizador tinha acabado de abrir.
    @State private var copyFeedbackStamp = 0
    @FocusState private var renameFieldIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    focus(session)
                } label: {
                    mainRow.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The chevron sits beside — not inside — the focus button,
                // so each click has exactly one unambiguous target.
                chevronButton
                    .padding(.trailing, 12)
            }
            // A right (or control) click also expands the actions inline;
            // the catcher passes every other event through.
            // Fora do retrato: é uma vista AppKit, e o `ImageRenderer` recusa
            // desenhar qualquer árvore que embrulhe AppKit — devolvia o
            // retângulo amarelo de vista inválida e levava a linha inteira com
            // ele. Não pinta nada, só apanha cliques, por isso a sua ausência
            // num ficheiro não muda uma única cor.
            .overlay {
                if !isStaticRender {
                    RightClickCatcher(onRightClick: toggleActions)
                }
            }
            if isActionsExpanded {
                actionArea
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .background(
            // Hover reads on both extremes of the background — near-solid
            // black at the top, translucent glass below — via a hairline
            // border plus a whisper of light fill; a heavy wash in either
            // direction fails on one of the two. The opened state gets the
            // dark smoke instead, where the grown row needs separation.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isActionsExpanded
                        ? Color.black.opacity(0.55)
                        : Color.white.opacity(isHovered || isSelected ? 0.05 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            .white.opacity(isHovered || isSelected || isActionsExpanded ? 0.12 : 0),
                            lineWidth: 0.5
                        )
                )
                .padding(.horizontal, 6)
        )
        .onHover { isHovered = $0 }
        .onChange(of: isActionsExpanded) { _, _ in
            endRenameKeyboard()
            mode = .menu
            // A linha que reabre começa limpa, e o carimbo novo tira o comando
            // ao temporizador de uma cópia que já não interessa a ninguém.
            didCopyPath = false
            copyFeedbackStamp &+= 1
        }
        .onDisappear { endRenameKeyboard() }
        // Lazy rows request branch data only while visible. Disappearance
        // cancels queued work through the coordinator; the menu-scoped cache
        // is discarded on close so a later open sees branch switches.
        .task(id: session.updatedAt) { [path = session.transcriptPath] in
            guard let path else { return }
            let reading = await Task.detached(priority: .utility) {
                ContextMeter.reading(transcriptPath: path)
            }.value
            guard !Task.isCancelled else { return }
            contextReading = reading
        }
        .task(id: session.currentStep == nil ? session.cwd : nil) { [cwd = session.cwd] in
            branchName = nil
            guard session.currentStep == nil else { return }
            let resolved = await branchCoordinator.branchName(forWorkingDirectory: cwd)
            guard !Task.isCancelled else { return }
            branchName = resolved
        }
        .accessibilityLabel("\(title), \(session.status.accessibilityName)")
    }

    /// No retrato não há ciclo de execução para o `.task`: lê-se em linha.
    /// Na app nunca — um stat de ficheiro por fotograma seria pagar I/O no
    /// caminho de desenho.
    private var effectiveReading: ContextMeter.Reading? {
        if isStaticRender, let path = session.transcriptPath {
            return ContextMeter.reading(transcriptPath: path)
        }
        return contextReading
    }

    /// A pasta acrescenta alguma coisa ao que o título já diz?
    ///
    /// Não acrescenta quando são a mesma palavra, que é o caso por omissão:
    /// o título de uma sessão por renomear É o nome da pasta.
    private var showsFolder: Bool {
        title.caseInsensitiveCompare(session.projectName) != .orderedSame
    }

    private func elapsed(to date: Date) -> some View {
        Text(SessionDurationFormatter.string(from: session.startedAt, to: date))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.45))
            // Largura fixa: "3m" e "2h 8m" têm larguras diferentes, e sem uma
            // coluna própria empurravam os ⌘N para posições diferentes em cada
            // linha. Uma coluna de atalhos que dança não se lê como coluna.
            .frame(width: 46, alignment: .trailing)
    }

    private var mainRow: some View {
        HStack(spacing: 12) {
            AgentIconView(tool: session.tool)
            if session.status.indicatorStyle == .spinner {
                WorkingPixelSpinner()
            } else {
                Circle()
                    .fill(indicatorColor(for: session.status.indicatorStyle))
                    .frame(width: 9, height: 9)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                // The title belongs to the tab now, so the directory keeps
                // the project context here, followed by the pipeline step —
                // which outranks the branch: convoy targets worktrees whose
                // directory name already carries it — or the git branch.
                //
                // A pasta só aparece quando acrescenta alguma coisa. Sem esta
                // condição, o caso mais comum — o título ser o nome da pasta —
                // dava duas linhas a dizer a mesma palavra: "pulse" e, por
                // baixo, "pulse". Uma linha inteira por linha, a não informar
                // nada, em todas as sessões que nunca foram renomeadas.
                HStack(spacing: 3) {
                    if showsFolder {
                        Image(systemName: "folder")
                            .font(.system(size: 9, weight: .semibold))
                        Text(SessionTitleFormatter.truncate(session.projectName, to: 30))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    if let currentStep = session.currentStep {
                        if showsFolder { Text("·") }
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.system(size: 9, weight: .semibold))
                        Text(currentStep)
                            .font(.system(size: 11, design: .monospaced))
                    } else if let branch = branchName {
                        if showsFolder { Text("·") }
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9, weight: .semibold))
                        Text(branch)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            // O medidor de contexto: um anel que enche com a janela do agente.
            //
            // Ideia vista no AgentNotch e adotada porque é a única informação
            // acionável sobre uma sessão que nada no ecrã dá: um agente a 85%
            // vai compactar em breve, e sabê-lo ANTES muda o que se lhe pede.
            // Só aparece quando há transcript e leitura — zero inventado seria
            // pior do que nada.
            if let reading = effectiveReading {
                ContextGauge(reading: reading)
                    .help(String(
                        format: "Context %d%% — %dk of %dk tokens",
                        Int(reading.fraction * 100),
                        reading.tokens / 1000, reading.window / 1000
                    ))
            }
            // O número do atalho, só enquanto o teclado tem a lista.
            //
            // Ensina ⌘N exatamente quando ele serve, e desaparece assim que se
            // pega no rato. Uma legenda fixa no rodapé dizia o mesmo, ocupava
            // altura para sempre e continuava a ser lida por ninguém.
            if let shortcutDigit {
                KeycapChip(label: "⌘\(shortcutDigit)")
                    .transition(.opacity)
            }
            // The system wakes this view on minute boundaries while the
            // row is on screen — no timers, no polling while collapsed.
            Group {
                if isStaticRender {
                    elapsed(to: Date())
                } else {
                    TimelineView(.everyMinute) { context in elapsed(to: context.date) }
                }
            }
        }
        .padding(.leading, SessionMenuLayout.sessionRowLeadingInset)
        .padding(.trailing, 10)
        .frame(height: SessionMenuLayout.sessionRowHeight)
    }

    private var chevronButton: some View {
        Button(action: toggleActions) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered || isActionsExpanded ? 0.65 : 0.32))
                .rotationEffect(.degrees(isActionsExpanded ? 180 : 0))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(isActionsExpanded ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Session actions")
    }

    @ViewBuilder
    private var actionArea: some View {
        switch mode {
        case .menu:
            VStack(spacing: 1) {
                ActionListRow(label: "Rename Session", systemImage: "pencil") {
                    beginRename()
                }
                // O rótulo é a própria confirmação. Copiar não deixa rasto
                // visível em lado nenhum, e sem esta troca ficava sempre a
                // dúvida de se o clique chegou a valer alguma coisa.
                ActionListRow(
                    label: didCopyPath ? "Copied" : "Copy Project Path",
                    systemImage: didCopyPath ? "checkmark" : "doc.on.doc"
                ) {
                    copyProjectPath()
                }
                ActionListRow(label: "Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: session.cwd)]
                    )
                    toggleActions()
                }
                ActionListRow(
                    label: "Kill Session",
                    systemImage: "xmark.octagon",
                    isDestructive: true
                ) {
                    mode = .confirmingKill
                }
            }
        case .renaming:
            HStack(spacing: 6) {
                TextField(session.projectName, text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.92))
                    .focused($renameFieldIsFocused)
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.1))
                    )
                iconButton("checkmark", accessibilityLabel: "Save name", action: commitRename)
                iconButton("xmark", accessibilityLabel: "Cancel rename", action: cancelRename)
            }
        case .confirmingKill:
            HStack(spacing: 8) {
                Text("Kill the process and close its pane?")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
                ActionListRow(
                    label: "Kill",
                    systemImage: "xmark.octagon",
                    isDestructive: true,
                    fillsWidth: false
                ) {
                    kill(session)
                    toggleActions()
                }
                ActionListRow(label: "Cancel", systemImage: "arrow.uturn.backward", fillsWidth: false) {
                    mode = .menu
                }
            }
        }
    }

    private func iconButton(
        _ systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Copia a diretoria do projeto e só depois arruma a linha.
    ///
    /// As outras ações fecham o menu no mesmo instante em que agem, e nesta
    /// isso apagava a confirmação no fotograma em que ela nascia — copiar não
    /// tem consequência visível nenhuma para servir de recibo. Por isso o
    /// "Copied" fica primeiro e o fecho vem a seguir, já com a resposta dada.
    private func copyProjectPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.cwd, forType: .string)
        didCopyPath = true
        copyFeedbackStamp &+= 1
        let stamp = copyFeedbackStamp
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copyFeedbackDuration) {
            // Só o disparo mais recente manda: qualquer abrir ou fechar pelo
            // meio já invalidou este carimbo.
            guard copyFeedbackStamp == stamp else { return }
            didCopyPath = false
            toggleActions()
        }
    }

    private func beginRename() {
        renameDraft = renamePrefill
        mode = .renaming
        // The panel refuses key status except during this edit; grant it
        // first, then focus the field once the window can accept it.
        setKeyboardFocus(true)
        DispatchQueue.main.async { renameFieldIsFocused = true }
    }

    private func commitRename() {
        rename(session, renameDraft)
        endRenameKeyboard()
        toggleActions()
    }

    private func cancelRename() {
        endRenameKeyboard()
        mode = .menu
    }

    private func endRenameKeyboard() {
        guard mode == .renaming else { return }
        renameFieldIsFocused = false
        setKeyboardFocus(false)
    }
}

// MARK: - Histórico de decisões

/// O que autorizaste e o que recusaste, do mais recente para trás.
///
/// Ocupa o lugar da lista de sessões, com as mesmas margens e o mesmo teto de
/// altura: é a mesma gaveta a mostrar outra coisa, e não um segundo painel.
private struct DecisionHistoryCard: View {
    let records: [DecisionRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: SessionMenuLayout.cardStackSpacing) {
            if records.isEmpty {
                // O vazio diz o que o vai encher, como o "Nothing running" da
                // lista: quem chega aqui antes da primeira decisão fica a saber
                // que a app não está avariada, está só à espera.
                VStack(alignment: .leading, spacing: 3) {
                    Text("No decisions yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Allow or deny a permission request and it lands here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.52))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 12 e não 14: com o contentor a 4 e o gutter a 22, é o que
                // alinha este texto na coluna dos 38 pt das outras superfícies.
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            } else {
                ScrollView(showsIndicators: false) {
                    // `VStack` e não `LazyVStack`, pela mesma razão da lista: são
                    // uma dúzia de linhas, e uma pilha normal desenha-se fora de
                    // ecrã — o que permite retratá-la sem depender do ecrã.
                    VStack(spacing: 0) {
                        ForEach(records) { DecisionHistoryRow(record: $0) }
                    }
                }
                .frame(height: SessionMenuLayout.decisionListHeight(recordCount: records.count))
                .padding(.bottom, SessionMenuLayout.sessionListBottomPadding)
            }
        }
        .padding(.horizontal, SessionMenuLayout.contentHorizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SessionMenuLayout.listTopPadding)
        .padding(.bottom, SessionMenuLayout.cardBottomPadding)
    }
}

/// Uma decisão numa linha: quem pediu, o quê, o que respondeste e há quanto
/// tempo.
///
/// Sem fundo de hover e sem ação nenhuma, ao contrário das linhas de sessão:
/// não há nada para fazer a uma decisão já tomada, e desenhá-la como se houvesse
/// prometia um clique que não existe.
private struct DecisionHistoryRow: View {
    let record: DecisionRecord
    @Environment(\.isStaticRender) private var isStaticRender

    var body: some View {
        HStack(spacing: 12) {
            AgentIconView(tool: record.tool)
            // O resumo cortado à largura da linha e não a um número de letras:
            // é a frase que identifica a decisão, e o veredicto à direita é que
            // não pode ceder espaço nenhum.
            Text(record.summary)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            // Verde e vermelho, a mesma dupla dos pontos de estado: aqui o
            // vermelho continua a querer dizer "parei o agente".
            Text(record.decision.verdictLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(record.decision.verdictColor.opacity(0.9))
            // O sistema acorda esta vista às voltas do minuto enquanto ela está
            // no ecrã — sem temporizadores, e sem nada a girar com o painel
            // fechado.
            Group {
                if isStaticRender {
                    elapsed(to: Date())
                } else {
                    TimelineView(.everyMinute) { context in elapsed(to: context.date) }
                }
            }
        }
        .padding(.leading, SessionMenuLayout.sessionRowLeadingInset)
        // 12 e não 10: põe a coluna do tempo a acabar onde acaba o botão de
        // ação das linhas de sessão — e onde acabam os botões do cabeçalho —,
        // por isso a margem direita do painel não muda ao trocar de vista.
        .padding(.trailing, 12)
        .frame(height: SessionMenuLayout.decisionRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(record.toolName) \(record.decision.verdictLabel), \(record.summary), in \(record.projectName)"
        )
    }

    private func elapsed(to date: Date) -> some View {
        Text(SessionDurationFormatter.string(from: record.decidedAt, to: date))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.45))
            // A mesma coluna fixa das linhas de sessão: "3m" e "2h 8m" têm
            // larguras diferentes e sem coluna própria puxavam o veredicto para
            // posições diferentes em cada linha.
            .frame(width: 46, alignment: .trailing)
    }
}

private extension PermissionDecision {
    /// O particípio e não o imperativo: "allow" é o botão que carregaste, e o
    /// que o histórico conta é o que ficou feito.
    var verdictLabel: String {
        switch self {
        case .allow: "allowed"
        case .allowAlways: "always"
        case .deny: "denied"
        case .defer_: "deferred"
        }
    }

    /// `defer_` nunca chega ao registo — o `DecisionLog` deixa-o de fora —, mas
    /// se um dia chegar sai cinzento: não foi uma escolha tua.
    var verdictColor: Color {
        switch self {
        case .allow, .allowAlways: .green
        case .deny: .red
        case .defer_: .gray
        }
    }
}

/// Um botão da ala direita do cabeçalho: as definições, o histórico.
///
/// Um tipo para os dois, e não um por botão. São o mesmo objeto — um glifo
/// discreto que acende ao passar o rato — e tê-los escritos em sítios
/// diferentes era garantir que um dia se afastavam num ponto de opacidade.
///
/// Ligado, o glifo fica quase branco e ganha um disco por baixo: um botão que
/// alterna tem de dizer em qual dos dois estados está, e com hover a 0,75 e
/// ligado a 0,75 não dizia nada.
private struct HeaderIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isActive = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isActive ? 0.95 : (isHovered ? 0.75 : 0.35)))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(isActive ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
    }
}

/// One entry of the inline action list: icon, label, hover highlight — the
/// look of a menu item, rendered inside the row instead of a floating menu.
/// The metrics line up optically with the roomier session row above while
/// preserving a broad click target and rounded hover treatment.
/// Interno e não privado: o cartão de decisão reutiliza-o, e ter dois botões
/// com o mesmo aspeto desenhados em sítios diferentes era garantir que um dia
/// divergiam.
struct ActionListRow: View {
    let label: String
    let systemImage: String
    var isDestructive = false
    /// List entries span the row; the kill-confirmation buttons keep their
    /// natural width so the question stays on the same line.
    var fillsWidth = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                if fillsWidth {
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(
                isDestructive
                    ? Color.red.opacity(isHovered ? 1 : 0.85)
                    : Color.white.opacity(isHovered ? 0.95 : 0.8)
            )
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundOpacity)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .linkCursor()
        .onHover { isHovered = $0 }
    }

    private var backgroundOpacity: Color {
        if isDestructive && isHovered {
            return .red.opacity(0.18)
        }
        let restingOpacity = fillsWidth ? 0.0 : 0.08
        return .white.opacity(isHovered ? 0.1 : restingOpacity)
    }
}

/// Claims right and control clicks for the inline action toggle and lets
/// every other event — left clicks, hover, scroll — fall through to the
/// SwiftUI row underneath.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> RightClickForwardingView {
        let view = RightClickForwardingView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: RightClickForwardingView, context: Context) {
        view.onRightClick = onRightClick
    }
}

private final class RightClickForwardingView: NSView {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is the trackpad spelling of a right click.
        if event.modifierFlags.contains(.control) {
            onRightClick?()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)),
              let event = NSApp.currentEvent else {
            return nil
        }
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            return self
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return self
        default:
            return nil
        }
    }
}

// MARK: - Retrato das vistas, sem ecrã

/// Desenha as vistas do painel para PNG, sem depender do ecrã.
///
/// Existe porque a fotografia do ecrã não serve sempre: com o Mac bloqueado o
/// sistema devolve o wallpaper e mais nada, e é justamente aí que se perde a
/// única forma de olhar para o próprio trabalho. `ImageRenderer` desenha a
/// árvore de vistas em CPU e não pede ecrã nenhum.
///
/// O que isto NÃO vê, e porquê:
///
///  - **O vidro.** O backdrop é alimentado pelo servidor de janelas e sai em
///    branco. Serve para geometria — alinhamento, medidas, tipos, o que cabe e
///    o que transborda — e não para julgar material.
///  - **O movimento.** O mascote e o tempo decorrido saem parados: quem
///    depende do relógio pergunta por `isStaticRender` e desenha um instante
///    fixo, porque um `TimelineView` sem ecrã devolve vista inválida e levava
///    a barra inteira com ele.
///
///     kill -USR2 $(pgrep -x Pulse)
///
/// escreve /tmp/pulse-ui-*.png.
@MainActor
enum UIRender {

    static func writeAll(to directory: String = "/tmp") -> String {
        let fixtures = sampleSessions()
        var written: [String] = []

        // Fundo cinzento médio e não transparente: sobre transparente não se vê
        // se um texto claro tem contraste, e é isso que se está a verificar.
        func render(_ view: some View, width: CGFloat, name: String) {
            let framed = view
                .frame(width: width)
                .background(Color(white: 0.10))
                .padding(16)
                .background(Color(white: 0.42))
            let renderer = ImageRenderer(content: framed.environment(\.isStaticRender, true))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return }
            let path = "\(directory)/pulse-ui-\(name).png"
            try? png.write(to: URL(fileURLWithPath: path))
            written.append(name)
        }

        // As linhas, desenhadas fora da `ScrollView` que as embrulha na app: o
        // `ImageRenderer` não desenha conteúdo de scroll views, e é a geometria
        // das linhas que interessa auditar, não a da moldura que as faz rolar.
        render(
            VStack(spacing: 0) {
                ForEach(Array(fixtures.enumerated()), id: \.element.id) { index, session in
                    SessionRow(
                        session: session, title: session.projectName, renamePrefill: "",
                        isActionsExpanded: false, isSelected: index == 1,
                        shortcutDigit: index + 1, toggleActions: {}, focus: { _ in },
                        rename: { _, _ in }, kill: { _ in }, setKeyboardFocus: { _ in },
                        branchCoordinator: GitBranchResolutionCoordinator()
                    )
                }
            },
            width: 760, name: "list"
        )

        render(
            SessionMenuCard(
                sessions: [], stateDirectoryURL: URL(fileURLWithPath: "/tmp"),
                dismiss: {}, acknowledge: { _ in }, sessionTitle: { $0.projectName },
                overrideName: { _ in nil }, rename: { _, _ in }, setKeyboardFocus: { _ in },
                keyboardActive: false, onRowInteractionChange: { _ in }
            ),
            width: 760, name: "empty"
        )

        let now = Date()
        render(
            PermissionDecisionCard(
                request: PermissionRequest(
                    id: "x", sessionID: "s", tool: .claude,
                    cwd: "/Users/você/coding/pulse", toolName: "Bash",
                    summary: "Limpar a pasta de build e forçar o push",
                    detail: "rm -rf build/ && git push --force origin main",
                    detailKind: .command,
                    suggestions: [AnyCodable(["behavior": "allow"])],
                    createdAt: now, expiresAt: now.addingTimeInterval(96)
                ),
                now: now, decide: { _ in }, reveal: {},
                bandInset: 14, textInset: 28
            ),
            width: 800, name: "decision"
        )

        // O histórico com os desfechos que sabe desenhar, para se poder ver o
        // contraste do verde e do vermelho sem esperar por decisões reais.
        //
        // As linhas soltas e não o cartão inteiro, pela mesma razão da lista: o
        // `ImageRenderer` não desenha o conteúdo de uma `ScrollView`, e o cartão
        // com registos embrulha-as numa — saía uma moldura vazia.
        render(
            VStack(spacing: 0) {
                ForEach(sampleDecisions(now: now)) { DecisionHistoryRow(record: $0) }
            },
            width: 760, name: "history"
        )

        // A barra fechada, com a geometria verdadeira de um ecrã com recorte.
        //
        // Precisa de um `StateStore` a sério — as sessões dele são só de
        // leitura de fora —, por isso escreve-se as de exemplo num diretório
        // temporário e deixa-se o repositório carregá-las como carregaria as
        // reais. É o mesmo caminho de dados que a app usa a correr.
        let sandbox = URL(fileURLWithPath: "\(directory)/pulse-ui-fixtures")
        try? FileManager.default.removeItem(at: sandbox)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let repository = StateRepository(directoryURL: sandbox)
        for session in fixtures { try? repository.save(session) }
        let store = StateStore(repository: repository)
        try? store.reload()

        // As medidas do MacBook Pro de 14 polegadas: 1800 pt de largo, recorte
        // de 220 pt ao meio, 38 pt de área segura em cima.
        let layout = NotchLayout(
            screenMinX: 0, screenWidth: 1800, screenMaxY: 1169,
            safeAreaTop: 38, leftNotchEdgeX: 790, rightNotchEdgeX: 1010,
            menuBarHeight: 39
        )
        // E a mesma barra num ecrã SEM recorte, que é a apresentação que
        // nunca ninguém olhou: um monitor externo cai sempre nesta.
        let pill = NotchLayout(
            screenMinX: 0, screenWidth: 1800, screenMaxY: 1169,
            safeAreaTop: 0, leftNotchEdgeX: nil, rightNotchEdgeX: nil,
            menuBarHeight: 24
        )
        for (name, geometry) in [("bar", layout), ("bar-pill", pill)] {
            render(
                NotchWidgetView(
                    store: store, layout: geometry,
                    pointerTracker: NotchPointerTracker(),
                    requestPointerRefresh: {}, onInteractiveRegionChange: { _ in },
                    onKeyboardFocusChange: { _ in }, onMenuVisibilityChange: { _ in }
                )
                .frame(width: geometry.width, height: geometry.height + geometry.topGap),
                width: geometry.width, name: name
            )
        }

        // As Definições ficam de fora com conhecimento de causa: o Form
        // nativo é AppKit por dentro e sai um retângulo branco daqui — e
        // reescrevê-lo em SwiftUI puro para o arnês o ver seria piorar a app
        // para melhorar a ferramenta. A janela usa o idioma do sistema; o que
        // há para auditar nela é a copy, e essa lê-se no código.

        return written.isEmpty ? "não desenhou nada" : "ok: \(written.joined(separator: ", "))"
    }

    /// Decisões de exemplo, uma por desfecho que o histórico sabe desenhar.
    private static func sampleDecisions(now: Date) -> [DecisionRecord] {
        [
            DecisionRecord(
                id: "d1", sessionID: "s1", tool: .claude, projectName: "pulse",
                toolName: "Bash", summary: "swift build -c release",
                decision: .allow, decidedAt: now.addingTimeInterval(-180)
            ),
            DecisionRecord(
                id: "d2", sessionID: "s2", tool: .codex, projectName: "hermes",
                toolName: "Bash", summary: "rm -rf build/ && git push --force origin main",
                decision: .deny, decidedAt: now.addingTimeInterval(-2_700)
            ),
            DecisionRecord(
                id: "d3", sessionID: "s3", tool: .opencode, projectName: "siva",
                toolName: "Edit", summary: "Escrever Sources/PulseCore/State/StateStore.swift",
                decision: .allowAlways, decidedAt: now.addingTimeInterval(-9_000)
            ),
        ]
    }

    /// Sessões de exemplo que cobrem os estados que a lista sabe desenhar.
    /// Sessões de exemplo, incluindo transcripts de amostra para o medidor de
    /// contexto: um vermelho (92%), um âmbar (76%), um branco (30%).
    private static func sampleSessions() -> [AgentSession] {
        let now = Date()
        func transcript(_ name: String, tokens: Int) -> String {
            let path = "/tmp/pulse-ui-fixtures-\(name).jsonl"
            let line = #"{"message":{"model":"claude-opus-5","usage":{"input_tokens":2,"cache_read_input_tokens":\#(tokens),"cache_creation_input_tokens":0,"output_tokens":10}}}"#
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }
        func make(
            _ tool: AgentTool, _ name: String, _ status: SessionStatus,
            _ reason: AttentionReason? = nil, minutes: Double, tokens: Int? = nil
        ) -> AgentSession {
            AgentSession(
                tool: tool, sessionID: name, pid: 1, status: status,
                attentionReason: reason, cwd: "/Users/você/coding/\(name)",
                startedAt: now.addingTimeInterval(-minutes * 60), updatedAt: now,
                transcriptPath: tokens.map { transcript(name, tokens: $0) }
            )
        }
        return [
            make(.claude, "pulse", .needsAttention, .permission, minutes: 3, tokens: 184_000),
            make(.claude, "hermes", .working, minutes: 42, tokens: 152_000),
            make(.codex, "siva", .idle, minutes: 128),
            make(.opencode, "um-projeto-com-nome-comprido", .idle, minutes: 7, tokens: 61_000),
        ]
    }
}
