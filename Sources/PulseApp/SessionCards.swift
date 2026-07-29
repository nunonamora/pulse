import SwiftUI

import PulseCore

/// Os dois cartões aninhados dentro de uma linha de sessão: o plano que o
/// agente escreveu para si próprio, e quem está a trabalhar por baixo dele.
///
/// Vivem em cartões próprios, mais escuros do que a linha que os contém,
/// porque são conteúdo de OUTRA pessoa: a lista é do agente, os subagentes são
/// dele. Achatar isto na linha principal misturaria duas vozes e obrigaria a
/// ler o recuo para saber de quem é cada facto.

// MARK: - Tarefas

struct TaskListCard: View {
    let list: TaskListMeter.List

    /// Quantas tarefas cabem antes de a lista deixar de ser um relance. Cinco
    /// é o ponto onde o cartão passa a ocupar mais altura do que a sessão
    /// toda; o resto conta-se numa linha, que é informação suficiente para
    /// decidir se vale a pena ir ao terminal.
    private static let visibleLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("Tasks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Text("(\(list.summary()))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            ForEach(list.items.prefix(Self.visibleLimit)) { item in
                row(item)
            }
            if list.items.count > Self.visibleLimit {
                Text("+\(list.items.count - Self.visibleLimit) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, 17)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tasks: \(list.summary())")
    }

    private func row(_ item: TaskListMeter.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            marker(for: item.status)
                .frame(width: 10)
            Text(item.title)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(item.status == .completed ? 0.38 : 0.88))
                // O risco por cima do texto concluído é a única marcação que
                // dispensa legenda: toda a gente já riscou uma lista à mão.
                .strikethrough(item.status == .completed, color: .white.opacity(0.3))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// Três marcas com TRÊS formas diferentes, não três cores da mesma forma:
    /// com "Diferenciar sem cor" ligado, ou simplesmente de relance, a forma é
    /// o que se lê primeiro.
    @ViewBuilder
    private func marker(for status: TaskListMeter.Status) -> some View {
        switch status {
        case .inProgress:
            Circle()
                .fill(VITheme.blue)
                .frame(width: 7, height: 7)
        case .pending:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                .frame(width: 9, height: 9)
        case .completed:
            Image(systemName: "checkmark.square")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.38))
        }
    }
}

// MARK: - Agentes

struct AgentRosterCard: View {
    let agents: [SubagentRoster.Agent]
    /// O cabeçalho muda com a origem: subagentes desta sessão ou membros de
    /// uma equipa, que são coisas diferentes e merecem nomes diferentes.
    let team: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: team == nil
                      ? "arrow.triangle.branch" : "person.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(team.map { "Team · \($0)" } ?? "Agents")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Text("(\(agents.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            ForEach(agents) { agent in
                row(agent)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
    }

    private func row(_ agent: SubagentRoster.Agent) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(VITheme.blue)
                    .frame(width: 6, height: 6)
                Text(agent.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                // O tipo entre parênteses e mais apagado: identifica sem
                // competir com o nome, que é o que se procura na lista.
                if !agent.description.isEmpty {
                    Text("(\(agent.description))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                if let elapsed = agent.elapsedLabel {
                    Text(elapsed)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                }
                Spacer(minLength: 6)
                if let model = agent.model.map(SessionMeta.modelLabel) {
                    Text(model)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }
            }
            if let activity = agent.activity {
                HStack(spacing: 4) {
                    // O canto de árvore diz "isto pertence à linha de cima"
                    // sem gastar uma cor nem um ícone com significado próprio.
                    Text("└")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.25))
                    Text(activity)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 12)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(agent.name), \(agent.description)"
            + (agent.elapsedLabel.map { ", running \($0)" } ?? "")
        )
    }
}

// MARK: - Agrupar por origem

extension SubagentRoster {
    /// Os subagentes de um lado, cada equipa do seu — que é como o painel os
    /// desenha, e como quem os lançou pensa neles.
    static func grouped(
        _ agents: [Agent]
    ) -> (subagents: [Agent], teams: [(session: String, agents: [Agent])]) {
        var subagents: [Agent] = []
        var teams: [String: [Agent]] = [:]
        var order: [String] = []
        for agent in agents {
            switch agent.origin {
            case .subagent:
                subagents.append(agent)
            case let .team(session):
                if teams[session] == nil { order.append(session) }
                teams[session, default: []].append(agent)
            }
        }
        return (subagents, order.map { ($0, teams[$0] ?? []) })
    }
}
