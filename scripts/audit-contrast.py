#!/usr/bin/env python3
"""Mede o contraste do texto nos retratos da interface.

Contraste não é matéria de gosto: ou o texto se lê, ou não se lê. Julgá-lo a
olho num monitor calibrado, de dia, com a app aberta em primeiro plano, é o
caminho mais curto para enviar uma interface que ninguém consegue ler no
comboio. Isto mede-o em números.

    kill -USR2 $(pgrep -x Pulse)      # a app desenha-se para /tmp
    python3 scripts/audit-contrast.py

As faixas de texto são encontradas sozinhas — procuram-se as linhas de pixels
claramente mais claras do que o fundo — para a medição não depender de
coordenadas escritas à mão, que ficam desatualizadas ao primeiro ajuste de
espaçamento e passam a medir o vazio sem se queixarem.

Limiar: 4,5:1, o mínimo do WCAG AA para texto corrido.
"""

import sys
from collections import Counter

try:
    from PIL import Image
except ImportError:
    sys.exit("é preciso Pillow: python3 -m pip install --user pillow")

THRESHOLD = 4.5


def luminance(rgb):
    def linear(channel):
        c = channel / 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = (linear(v) for v in rgb[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    high, low = max(la, lb), min(la, lb)
    return (high + 0.05) / (low + 0.05)


def audit(path, name):
    image = Image.open(path).convert("RGB")
    pixels = image.load()
    width, height = image.size

    brightest = [
        luminance(max((pixels[x, y] for x in range(0, width, 2)), key=luminance))
        for y in range(height)
    ]
    # O fundo é o que ocupa a maior parte da imagem; o primeiro quartil das
    # linhas serve de referência sem precisar de o adivinhar.
    floor = sorted(brightest)[len(brightest) // 4]

    bands, start = [], None
    for y, value in enumerate(brightest):
        hot = value > floor + 0.06
        if hot and start is None:
            start = y
        elif not hot and start is not None:
            if y - start >= 6:      # linhas mais finas do que isto são arestas
                bands.append((start, y))
            start = None

    print(f"— {name}")
    worst = None
    for y0, y1 in bands:
        sample = [pixels[x, y] for y in range(y0, y1) for x in range(0, width, 2)]
        background = Counter(sample).most_common(1)[0][0]
        foreground = max(sample, key=luminance)
        ratio = contrast(foreground, background)
        mark = "ok  " if ratio >= THRESHOLD else "BAIXO"
        print(f"   {mark} y{y0:>4}–{y1:<4} {ratio:5.1f}:1")
        worst = ratio if worst is None else min(worst, ratio)
    return worst


views = [
    ("/tmp/pulse-ui-decision.png", "cartão de decisão"),
    ("/tmp/pulse-ui-list.png", "lista de sessões"),
    ("/tmp/pulse-ui-empty.png", "estado vazio"),
]

failures = 0
for path, name in views:
    try:
        worst = audit(path, name)
    except FileNotFoundError:
        print(f"— {name}: sem retrato. Corre  kill -USR2 $(pgrep -x Pulse)")
        continue
    if worst is not None and worst < THRESHOLD:
        failures += 1

sys.exit(1 if failures else 0)
