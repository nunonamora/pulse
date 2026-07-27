# Pulse

Os teus agentes de código vigiados no notch do Mac — **com voz em português**,
**decisões de permissão sem sair do editor** e **tudo ao alcance do teclado**.

Pulse é a pulsação: o sinal contínuo e discreto de que há vida — os agentes a
trabalhar, no sítio mais alto do ecrã. Quando um precisa de ti, o sinal muda.

> Derivado do [AgentGlance](https://github.com/Inakitajes/AgentGlance) de Josemi
> Hernandez (MIT). Todo o motor — deteção de sessões, integrações com Claude
> Code, Codex, OpenCode, Pi e Convoy, o painel do notch e o Liquid Glass — é
> trabalho dele. O README original está em `README-agentglance-original.md`.

## O que isto acrescenta ao original

### Voz

Quando um agente termina o turno ou precisa de ti, a app diz **quem** e
**onde** — coisa que um som não consegue.

Cada ferramenta tem um som de assinatura próprio: duas notas, um intervalo
musical, sintetizadas sem ficheiros de áudio. É o som e não a voz que dá a
identidade — com uma só voz portuguesa instalada, as cinco ferramentas soariam
iguais, e o intervalo chega ao ouvido primeiro.

Quando a voz fala, o som do original **não** toca. Os dois juntos seriam
redundantes e mais barulhentos do que qualquer um deles sozinho.

**Cala-se** em Não Incomodar e em modos de Concentração, enquanto o microfone
estiver em uso, e quando estás a olhar para o terminal dessa sessão. No máximo
uma frase a cada quatro segundos; o que se acumula colapsa numa contagem —
*"Três agentes precisam de ti."*

Vem desligada. Liga em **Definições → Voice**, onde há um botão para ouvires as
cinco de seguida.

#### Vozes

Por omissão o macOS traz só a **Joana** (pt-PT, qualidade básica), e com uma
voz só as ferramentas soam quase iguais. Vale a pena descarregar em *Definições
do Sistema → Acessibilidade → Conteúdo falado → Voz do sistema → Gerir vozes*:

| Voz | Idioma | Tamanho |
|---|---|---|
| Catarina | pt-PT | 155 MB |
| Felipe | pt-BR | 128 MB |

A app deteta-as sozinha e redistribui — não é preciso configurar nada. Há um
botão nas definições que te leva lá.

### Decisões de permissão

Quando o Claude Code pede autorização, o cartão aparece no notch com o comando
e os botões — **exceto se já estiveres a olhar para esse terminal**: aí a app
sai da frente, larga o pedido e o diálogo normal aparece onde tens os olhos.
Dois sítios para responder à mesma pergunta obrigavam-te a escolher onde
carregar antes de escolheres o que responder. (Desliga-se nas definições.)

O cartão lê o pedido pela forma que ele tem: um comando sai monoespaçado, um
diff sai em linhas coloridas com as partes iguais cortadas, os argumentos de
uma ferramenta desconhecida saem como campos — nunca JSON com chavetas. Um
sinal de risco (read-only / modifies / destructive) lê-se antes do texto, e um
botão de copiar aparece sobre o comando para o caminho do meio: ir testá-lo à
mão antes de decidir. **Enquanto ele está aberto, o agente está mesmo parado à espera**
— e é por isso que o cartão mostra um prazo a correr.

| | |
|---|---|
| **Allow** | permite desta vez |
| **Deny** | nega, com uma razão que o agente lê |
| **Always allow this** | escreve a mesma regra que o botão do diálogo escreveria |
| **Decide in the terminal** | larga o pedido; o diálogo normal aparece lá |

Passados 150 segundos sem resposta, a app larga o agente por sua iniciativa e o
diálogo aparece no terminal. Nunca se deixa um agente parado à espera de uma app
que podes nem estar a ver.

Cada allow e deny fica registado: o botão de relógio no painel mostra as
últimas decisões, com veredicto e há quanto tempo. As deferências ficam de
fora — não são escolhas de ninguém.

### Teclado

**⌥⌘A** abre e fecha o painel de qualquer app, já com foco de teclado: setas
para escolher, **Enter** salta para o terminal da sessão, **Esc** fecha,
**⌘1–9** saltam direto. Os números aparecem nas linhas enquanto o teclado
manda, e desaparecem quando pegas no rato. No cartão de decisão, **⏎** permite
e **esc** nega — impressos nos próprios botões.

O salto para o terminal acerta no separador e no split exatos dentro do cmux
(pelos ids que o cmux exporta), no Ghostty, iTerm2 e Terminal; nos outros traz
a app certa à frente.

### O mascote

Quando há trabalho a decorrer, um mini agente em pixels passeia ao lado da
barra — a cor diz quem trabalha. Some-se quando não há nada a dizer, e fica
quieto para quem pede menos movimento ao sistema.

## Instalar

```bash
./scripts/install.sh
```

Compila, instala em `/Applications`, liga os hooks, lança e verifica. O mesmo
comando reinstala.

## Como funciona por dentro

### A voz

Pendurada nos `onAttentionRaised` / `onTurnCompleted` que o AgentGlance já
tinha — é por lá que passam todas as transições de estado, e o *acknowledgment*
dele garante que nada se repete a cada ciclo de leitura. Não foi preciso
inventar mecanismo nenhum.

### As decisões

Esta precisou de um canal que não existia. O `StateChangeNotifier` do original é
uma notificação Darwin sem payload e **estritamente unidirecional**: quem
escreve estado avisa, a app ouve. Uma decisão precisa do contrário.

O `PermissionBroker` acrescenta esse canal seguindo o precedente do
`saveEnrichment`, onde a app já escreve um sidecar sobre um documento que
pertence à integração:

```
o hook escreve   ~/.pulse/state/decisions/<id>.request.json
                 e bloqueia, a sondar
a app responde   ~/.pulse/state/decisions/<id>.reply.json
o hook imprime   {"hookSpecificOutput":{…,"decision":{"behavior":"allow"}}}
```

Dois ficheiros por pedido, escrita atómica por `tmp`+`rename`, num subdiretório
próprio. Sem sockets nem portas — mantém o idioma da casa e sobrevive a
reinícios da app sem deixar o agente pendurado.

### Notas de quem lá esteve

- O `PermissionRequest` **não estava registado** no original, e o merger do
  `settings.json` não sabia escrever `timeout` — que é exatamente o que um hook
  bloqueante precisa. Ambos acrescentados.
- O script de hook fazia `>/dev/null 2>&1` e `exit 0` em todos os eventos, por
  desenho. Agora só o `PermissionRequest` devolve stdout; os outros continuam
  fire-and-forget, mais rápidos e sem forma de atrasar um agente.
- O hook segura 150 s mas o `settings.json` regista 180: preferimos largar por
  nossa iniciativa, com uma resposta limpa, a ser cortados a meio.
- O painel tinha **quatro** comportamentos que matavam o cartão — escondia-se
  sem sessões ativas, recolhia meio segundo depois de o rato sair, fechava a um
  clique noutra app (incluindo o clique com que vais ao terminal ver o
  contexto), e fechava se a lista esvaziasse. Todos protegidos, e todos pela
  mesma razão: do outro lado há um agente parado.

## O ícone

Um P cuja haste ondula — a letra feita da coisa que o nome diz. Desenhado em
código (`scripts/make-icon.swift`), um tamanho de cada vez: abaixo de 64 px a
onda sai e a letra engrossa, porque a amplitude cabia em meio pixel e lia-se
como haste torta. A superelipse é a do sistema, a luz vem de cima, e o grão
existe para a superfície não se ler como render.

Sete direções anteriores morreram e ficaram documentadas no ficheiro com o
motivo — de uma torre que se lia como peça de xadrez a um feixe que se lia
como candeeiro. Regenera-se com `./scripts/make-icon.sh`.

## Verificar sem ecrã

A app sabe desenhar-se a si própria: `kill -USR2 $(pgrep -x Pulse)` escreve
retratos das vistas em `/tmp/pulse-ui-*.png` — lista, cartão de decisão,
histórico, estado vazio e as duas apresentações da barra — sem depender do
ecrã, do wallpaper ou de autorizações. `python3 scripts/audit-contrast.py`
mede o contraste do texto sobre esses retratos e falha abaixo de 4,5:1.

Foi assim que a interface foi auditada com o ecrã bloqueado; as falhas que
estas ferramentas apanharam (uma linha repetida em cada sessão, um botão
perigoso com o maior alvo do cartão, texto abaixo do mínimo de contraste)
estão descritas nos commits que as corrigem.

## Estado

Voz, decisões, histórico, teclado e supressão estão implementados e provados:
o hook bloqueia mesmo, os quatro caminhos devolvem o JSON certo, 182 testes
passam e o contraste é medido em vez de julgado.

## Licença

MIT, como o original. O aviso de copyright do AgentGlance está em `LICENSE` e
mantém-se — o motor é dele.
