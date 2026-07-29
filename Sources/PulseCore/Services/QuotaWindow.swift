import Foundation

/// Onde estão as janelas de limite e quanto falta para renovarem.
///
/// Duas coisas muito diferentes vivem aqui, e vale a pena separá-las porque
/// uma é facto e a outra é estimativa.
///
/// **A renovação é facto.** Uma janela de cinco horas não é um intervalo fixo
/// no relógio: abre no primeiro pedido feito depois de a anterior fechar, e
/// dura cinco horas a contar daí. Esse instante está escrito nos transcripts,
/// por isso a conta decrescente é exata — basta caminhar pelos carimbos e
/// deixar a âncora saltar sempre que um pedido cai fora da janela anterior.
///
/// **A percentagem é estimativa,** e é assinalada como tal. Os tetos dos
/// planos da Anthropic não são publicados nem estáveis, portanto o
/// denominador vem de uma escolha explícita de quem usa a app — não de um
/// número inventado aqui dentro. Sem plano escolhido não há percentagem: só o
/// consumo real, que é sempre verdadeiro.
public enum QuotaWindow {

    /// Os planos, com o teto aproximado de tokens por janela de cinco horas.
    /// São ordens de grandeza calibradas por observação, e o nome do tipo
    /// (`estimated`) existe para que ninguém as leia como oficiais.
    public enum Plan: String, CaseIterable, Sendable {
        case none, pro, max5, max20

        public var label: String {
            switch self {
            case .none: return "Sem plano"
            case .pro:  return "Pro"
            case .max5: return "Max 5×"
            case .max20: return "Max 20×"
            }
        }

        /// Teto estimado de tokens na janela de 5 horas.
        public var estimatedFiveHourTokens: Int? {
            switch self {
            case .none:  return nil
            case .pro:   return 4_000_000
            case .max5:  return 20_000_000
            case .max20: return 80_000_000
            }
        }

        /// Teto estimado da janela semanal. Não é sete vezes o de cinco horas
        /// — o limite semanal existe justamente para travar quem esgotaria
        /// todas as janelas curtas seguidas.
        public var estimatedWeeklyTokens: Int? {
            estimatedFiveHourTokens.map { $0 * 12 }
        }
    }

    public struct Window: Equatable, Sendable {
        /// Quando a janela abriu — o primeiro pedido dentro dela.
        public let opened: Date
        /// Quando renova. Facto, não estimativa.
        public let resets: Date
        /// Tokens consumidos dentro da janela.
        public let tokens: Int
        /// Fração do teto estimado, quando há plano escolhido.
        public let fraction: Double?

        public init(opened: Date, resets: Date, tokens: Int, fraction: Double?) {
            self.opened = opened
            self.resets = resets
            self.tokens = tokens
            self.fraction = fraction
        }

        /// "2h14m", "5d16h", "12m" — a forma curta do Vibe Island: duas
        /// unidades no máximo, e a maior primeiro.
        public func countdown(now: Date = Date()) -> String {
            let remaining = max(0, resets.timeIntervalSince(now))
            let days = Int(remaining) / 86400
            let hours = (Int(remaining) % 86400) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            if days > 0 { return "\(days)d\(hours)h" }
            if hours > 0 { return "\(hours)h\(minutes)m" }
            return "\(minutes)m"
        }
    }

    /// A janela corrente de `hours` horas, ancorada nos carimbos reais.
    ///
    /// `timestamps` são os instantes dos pedidos, por ordem crescente. Vêm do
    /// `PlanUsage`, que já percorre os transcripts — não se lê o disco duas
    /// vezes para a mesma pergunta.
    public static func current(
        timestamps: [Date], tokens: Int, hours: Double, plan: Plan,
        weekly: Bool = false, now: Date = Date()
    ) -> Window? {
        let span = hours * 3600
        // A âncora salta para cada pedido que já não cabia na janela aberta
        // pelo anterior. No fim, sobra o início da janela em curso.
        var anchor: Date?
        for stamp in timestamps.sorted() {
            if let current = anchor, stamp.timeIntervalSince(current) < span { continue }
            anchor = stamp
        }
        guard let opened = anchor else { return nil }
        let resets = opened.addingTimeInterval(span)
        // Uma janela já fechada não é a janela corrente: se o último pedido
        // foi há seis horas, não há nada a decorrer para mostrar.
        guard resets > now else { return nil }

        let cap = weekly ? plan.estimatedWeeklyTokens : plan.estimatedFiveHourTokens
        let fraction = cap.map { min(1, Double(tokens) / Double($0)) }
        return Window(opened: opened, resets: resets, tokens: tokens, fraction: fraction)
    }
}
