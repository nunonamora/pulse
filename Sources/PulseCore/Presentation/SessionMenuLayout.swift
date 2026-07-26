import Foundation

/// Shared expanded-menu spacing. Keeping these values outside the SwiftUI
/// tree makes the compact horizontal layout explicit and testable.
public enum SessionMenuLayout {
    public static let contentHorizontalInset: CGFloat = 4
    /// Gap between the notch bar — whose wings now hold the header — and the
    /// first session row.
    public static let listTopPadding: CGFloat = 6
    /// Leading inset for the session rows' own content, shared with the
    /// header math below so both columns stay aligned.
    public static let sessionRowLeadingInset: CGFloat = 12
    /// Outer insets for header content living in the expanded bar wings,
    /// chosen so the header columns line up with the session rows below:
    /// leading matches the row's agent icon (8pt centering gutter + 4pt card
    /// inset + 12pt row leading), trailing matches the row's chevron button
    /// (8 + 4 + 12pt chevron trailing).
    public static let expandedHeaderLeadingInset: CGFloat = 24
    public static let expandedHeaderTrailingInset: CGFloat = 24
    public static let cardStackSpacing: CGFloat = 2
    public static let cardBottomPadding: CGFloat = 6
    public static let sessionListBottomPadding: CGFloat = 4
    public static let sessionRowHeight: CGFloat = 52
    /// Uma decisão diz-se numa linha só — ícone, resumo, veredicto e há quanto
    /// tempo —, ao contrário de uma sessão, que tem título e uma linha de
    /// contexto por baixo. Mais baixa, cabem-lhe o dobro das entradas no mesmo
    /// teto de altura, que é fixo e partilhado com a lista.
    public static let decisionRowHeight: CGFloat = 34
    /// Three full rows plus the inline actions fit without shifting the row
    /// that received the click out from under the pointer. Longer lists still
    /// scroll inside the card.
    public static let maximumSessionListHeight: CGFloat = 300
    public static let expandedActionsHeight: CGFloat = 144

    /// The largest card the panel must accommodate: a fitting three-row
    /// expanded list and every vertical inset rendered by `SessionMenuCard`.
    /// The header lives in the bar wings, so it adds no card height.
    public static let maximumCardHeight: CGFloat = listTopPadding
        + maximumSessionListHeight
        + sessionListBottomPadding
        + cardBottomPadding

    public static func sessionListHeight(
        sessionCount: Int,
        hasExpandedActions: Bool
    ) -> CGFloat {
        let count = max(0, sessionCount)
        let rowsHeight = CGFloat(count) * sessionRowHeight
        let actionsHeight = hasExpandedActions ? expandedActionsHeight : 0
        return min(rowsHeight + actionsHeight, maximumSessionListHeight)
    }

    /// O histórico partilha o teto da lista: os dois vivem no mesmo painel, e um
    /// deles a crescer mais do que o outro fazia a bolha saltar de altura só por
    /// se carregar no relógio.
    public static func decisionListHeight(recordCount: Int) -> CGFloat {
        min(CGFloat(max(0, recordCount)) * decisionRowHeight, maximumSessionListHeight)
    }

    /// A scroll affordance belongs only to a list whose expanded content
    /// cannot fit in its assigned viewport. Showing it for a fitting row
    /// makes the pointer target move unnecessarily while the row opens.
    public static func requiresScrolling(
        sessionCount: Int,
        hasExpandedActions: Bool
    ) -> Bool {
        let count = max(0, sessionCount)
        let rowsHeight = CGFloat(count) * sessionRowHeight
        let actionsHeight = hasExpandedActions ? expandedActionsHeight : 0
        return rowsHeight + actionsHeight > maximumSessionListHeight
    }
}
