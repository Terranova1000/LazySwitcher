#!/usr/bin/env python3
"""Собирает бинарную модель из списка словоформ.

На выходе один файл на язык: словарь в виде DAWG плюс две посимвольные
n-граммные таблицы. Формат описан в docs/05-DATA.md §8.

Сборка обязана быть детерминированной — один и тот же вход даёт побайтово
одинаковый выход. Иначе невозможно проверить, что модель не менялась, и любое
изменение метрик становится необъяснимым.

Часть словоформ откладывается и в модель НЕ попадает: на них потом меряется
качество. Модель, видевшая тестовое слово, покажет точность, которой нет.
"""
import argparse
import hashlib
import math
import struct
import sys
from collections import defaultdict

MAGIC = b"LSM1"
VERSION = 2

# Алфавиты. Индекс 0 — граница слова: и отступ в начале, и терминатор в конце.
# Один символ на обе роли безопасен: после терминатора в обучении никогда ничего
# не идёт, так что контексты не смешиваются, а таблица вчетверо меньше.
# Индекс 0 — граница слова.
#
# В английский алфавит намеренно включены [ ] ; ' , . ` — на этих клавишах в
# ЙЦУКЕН сидят буквы х ъ ж э б ю ё. Примерно треть русских словоформ при наборе
# на латинице содержит такой знак ВНУТРИ слова, и это самый точный признак,
# какой у нас есть: в английских словах знака препинания посреди слова не
# бывает, поэтому сглаживание даёт им заслуженно ничтожную вероятность.
#
# Без них модель на такое слово просто не могла ответить, и раньше это давало
# Λ = +∞ (замена с бесконечной уверенностью по неверной причине), а после
# исправления — честное «не знаю», то есть потерю признака. Правильный ответ —
# третий: пусть модель их знает и оценивает как невозможные.
ALPHABETS = {
    "ru": "\0абвгдежзийклмнопрстуфхцчшщъыьэюяё",
    # Знаки в конце — не украшение: на этих клавишах в ЙЦУКЕН сидят буквы
    # х ъ ж э б ю ё, и примерно треть русских словоформ при наборе на латинице
    # содержит такой знак ВНУТРИ слова. В настоящих английских словах знака
    # препинания посреди слова не бывает, поэтому сглаживание даёт таким
    # n-граммам заслуженно ничтожную вероятность — это самый точный признак,
    # какой есть у модели, и он достаётся даром.
    #
    # Набор выведен из данных раскладки системы, а не по памяти: тест
    # KeyMapperTests.testPrintLatinCharactersUsedByCyrillicLetters печатает его.
    # Написанный по памяти список стоил измеримой просадки — «ё» на раскладке
    # «Русская» сидит на \, а не на `, как можно было решить.
    #
    # Заглавные кириллические дают : < > { } | " — они сюда не входят, потому
    # что LanguageModel.normalized сворачивает их к строчным парам: для оценки
    # Ж и ж — одна буква, а значит : и ; — один символ.
    "en": "\0abcdefghijklmnopqrstuvwxyz'[];,.\\",
}
BOUNDARY = 0
ORDER = 4          # модель 4-го порядка = цепь Маркова 3-го порядка
SMOOTHING = 0.5    # add-k; при алфавите в три десятка символов таблица плотная
QUANT_SCALE = 8.0  # шаг 1/8 наты
QUANT_MAX = 255


def held_out(word, fraction):
    """Детерминированное разбиение: одно и то же слово всегда по одну сторону."""
    if fraction <= 0:
        return False
    digest = hashlib.sha256(word.encode("utf-8")).digest()
    return (digest[0] << 8 | digest[1]) < fraction * 65536


# ─────────────────────────── n-граммы ───────────────────────────

def train_ngrams(words, order, size):
    """Считает условные вероятности P(c | предыдущие order-1 символов)."""
    counts = defaultdict(lambda: defaultdict(int))
    context_totals = defaultdict(int)
    pad = (order - 1) * [BOUNDARY]

    for indices in words:
        sequence = pad + indices + [BOUNDARY]     # терминатор обязателен:
        # именно он кодирует «русские слова не кончаются на ъ», а английские
        # почти никогда на q. Без него модель не отличает слово от обрывка.
        for i in range(order - 1, len(sequence)):
            context = tuple(sequence[i - order + 1:i])
            counts[context][sequence[i]] += 1
            context_totals[context] += 1

    return counts, context_totals


def quantise_table(counts, totals, order, size):
    """Плотная таблица u8 с квантованными −ln P.

    Плотная, а не разреженная: индекс считается арифметикой, без поиска на
    горячем пути, размер файла предсказуем, а таблица триграмм целиком
    помещается в кэш первого уровня.
    """
    table = bytearray(size ** order)
    denominator_base = SMOOTHING * size

    for context_index in range(size ** (order - 1)):
        # Разбираем индекс обратно в контекст.
        context = []
        rest = context_index
        for _ in range(order - 1):
            context.append(rest % size)
            rest //= size
        context.reverse()
        key = tuple(context)

        total = totals.get(key, 0)
        observed = counts.get(key, {})
        denominator = total + denominator_base
        base = context_index * size

        for symbol in range(size):
            probability = (observed.get(symbol, 0) + SMOOTHING) / denominator
            quantised = int(round(-math.log(probability) * QUANT_SCALE))
            table[base + symbol] = min(quantised, QUANT_MAX)

    return bytes(table)


# ─────────────────────────── DAWG ───────────────────────────

class Node:
    __slots__ = ("edges", "final", "identifier")
    _next_identifier = 0

    def __init__(self):
        self.edges = {}
        self.final = False
        Node._next_identifier += 1
        self.identifier = Node._next_identifier

    def signature(self):
        return (self.final, tuple(sorted((c, n.identifier) for c, n in self.edges.items())))


class Dawg:
    """Инкрементальная минимизация Дачука. Вход обязан быть отсортирован."""

    def __init__(self):
        self.root = Node()
        self.previous = ""
        self.unchecked = []
        self.minimised = {}

    def insert(self, word):
        if word <= self.previous:
            raise ValueError(f"вход не отсортирован: {word!r} после {self.previous!r}")
        common = 0
        while common < min(len(word), len(self.previous)) and word[common] == self.previous[common]:
            common += 1

        self._minimise(common)
        node = self.unchecked[-1][2] if self.unchecked else self.root
        for char in word[common:]:
            child = Node()
            node.edges[char] = child
            self.unchecked.append((node, char, child))
            node = child
        node.final = True
        self.previous = word

    def finish(self):
        self._minimise(0)
        return self.root

    def _minimise(self, down_to):
        while len(self.unchecked) > down_to:
            parent, char, child = self.unchecked.pop()
            signature = child.signature()
            if signature in self.minimised:
                parent.edges[char] = self.minimised[signature]
            else:
                self.minimised[signature] = child


def serialise_dawg(root, alphabet):
    """Рёбра по 4 байта: символ(6) | следующий(20) | последний(1) | конечный(1)."""
    index = {c: i for i, c in enumerate(alphabet)}
    order, seen = [], set()

    def visit(node):
        if id(node) in seen:
            return
        seen.add(id(node))
        order.append(node)
        for char in sorted(node.edges):
            visit(node.edges[char])

    visit(root)
    offsets, position = {}, 0
    for node in order:
        offsets[id(node)] = position
        position += max(len(node.edges), 1)

    edges = []
    for node in order:
        children = sorted(node.edges.items())
        if not children:
            # У листа рёбер нет, но место под запись зарезервировано, иначе
            # смещения соседей разъедутся. Заглушка обязана быть такой, чтобы
            # поиск на ней останавливался: символ 0 — это граница слова, он
            # никогда не встречается внутри, а бит «последнее ребро» завершает
            # перебор. Нулевое слово здесь было бы дефектом: символ 0, ссылка 0,
            # «последнее» не выставлено — поиск ушёл бы в корень и закольцевался.
            edges.append(1 << 26)
            continue
        for i, (char, child) in enumerate(children):
            symbol = index[char]
            target = offsets[id(child)]
            if target >= (1 << 20):
                raise ValueError("DAWG не помещается в 20 бит на ссылку")
            word = (symbol & 0x3F) | (target << 6)
            if i == len(children) - 1:
                word |= 1 << 26
            if child.final:
                word |= 1 << 27
            edges.append(word)

    return struct.pack(f"<I{len(edges)}I", len(edges), *edges), len(order), len(edges)


# ─────────────────────────── сборка ───────────────────────────

def build(path, language, out, hold_out_fraction, held_out_path):
    alphabet = ALPHABETS[language]
    index = {c: i for i, c in enumerate(alphabet)}
    size = len(alphabet)

    training, evaluation = [], []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            word = line.strip()
            if not word or any(c not in index for c in word):
                continue
            (evaluation if held_out(word, hold_out_fraction) else training).append(word)

    training.sort()
    print(f"{language}: обучение {len(training)}, отложено {len(evaluation)}", file=sys.stderr)

    as_indices = [[index[c] for c in word] for word in training]

    tri_counts, tri_totals = train_ngrams(as_indices, 3, size)
    quad_counts, quad_totals = train_ngrams(as_indices, 4, size)
    tri = quantise_table(tri_counts, tri_totals, 3, size)
    quad = quantise_table(quad_counts, quad_totals, 4, size)
    print(f"{language}: триграммы {len(tri)} Б, 4-граммы {len(quad)} Б", file=sys.stderr)

    dawg = Dawg()
    for word in training:
        dawg.insert(word)
    blob, node_count, edge_count = serialise_dawg(dawg.finish(), alphabet)
    print(f"{language}: DAWG узлов {node_count}, рёбер {edge_count}, {len(blob)} Б", file=sys.stderr)

    # Алфавит лежит в файле, а не в коде читателя. Две копии одного списка
    # символов однажды разойдутся, и модель начнёт молча считать вероятности
    # не тех букв — отказ, который не проявится ни в сборке, ни в тестах кода.
    alphabet_blob = struct.pack(f"<{size}I", *(ord(c) for c in alphabet))

    header = struct.pack("<4sIII", MAGIC, VERSION, ord(language[0]) << 8 | ord(language[1]), size)
    sections = struct.pack("<IIII", len(alphabet_blob), len(blob), len(tri), len(quad))
    with open(out, "wb") as handle:
        handle.write(header + sections + alphabet_blob + blob + tri + quad)
    print(f"{language}: записано {out}", file=sys.stderr)

    if evaluation and held_out_path:
        evaluation.sort()
        held_path = held_out_path
        with open(held_path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(evaluation) + "\n")
        print(f"{language}: отложенные слова → {held_path}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--words", required=True)
    parser.add_argument("--lang", required=True, choices=sorted(ALPHABETS))
    parser.add_argument("--out", required=True)
    parser.add_argument("--hold-out", type=float, default=0.05,
                        help="доля слов, откладываемых для замеров (по умолчанию 5%)")
    parser.add_argument("--held-out-out", default=None,
                        help="куда положить отложенные слова; в Resources им нельзя — "
                             "оттуда всё уезжает в бандл приложения")
    args = parser.parse_args()
    build(args.words, args.lang, args.out, args.hold_out, args.held_out_out)


if __name__ == "__main__":
    main()
