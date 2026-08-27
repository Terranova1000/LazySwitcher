#!/usr/bin/env python3
"""Раскрывает hunspell-словарь в полный список словоформ.

Почему не `unmunch` из комплекта hunspell: он не справляется с UTF-8 и не со
всеми типами флагов, а `ru_RU.aff` — это `SET UTF-8` и полторы тысячи правил.
Плюс его вывод не детерминирован, а нам нужно, чтобы одинаковый вход давал
побайтово одинаковый выход — иначе нельзя проверить, что модель не менялась.

Разбор файлов делает spylls (питоновская реализация hunspell), применение
правил — этот скрипт. Он сознательно проще полного hunspell: генерирует
одноуровневые аффиксы и их перекрёстные произведения, чего для русского и
английского словарей LibreOffice достаточно (проверено: в ru_RU нет ни
префиксов, ни суффиксов с собственными флагами).
"""
import argparse
import sys
import unicodedata

from spylls.hunspell import Dictionary


def apply_suffix(stem, entry, fullstrip):
    if not entry.cond_regexp.search(stem):
        return None
    if entry.strip:
        if not stem.endswith(entry.strip):
            return None
        base = stem[: -len(entry.strip)]
    else:
        base = stem
    if not base and not fullstrip:
        return None
    return base + entry.add


def apply_prefix(stem, entry, fullstrip):
    if not entry.cond_regexp.search(stem):
        return None
    if entry.strip:
        if not stem.startswith(entry.strip):
            return None
        base = stem[len(entry.strip):]
    else:
        base = stem
    if not base and not fullstrip:
        return None
    return entry.add + base


def is_plain_word(form, alphabet):
    """Только буквы целевого алфавита. Отбрасываем дефисы, точки, цифры и
    составные записи: n-граммной модели они портят статистику, а словарю
    ничего не дают — такие строки всё равно зарезаны VetoGate'ом."""
    if not form:
        return False
    return all(ch in alphabet for ch in form)


def expand(path, alphabet, limit=None):
    dictionary = Dictionary.from_files(path)
    aff = dictionary.aff
    fullstrip = bool(aff.FULLSTRIP)
    forbidden = aff.FORBIDDENWORD
    needaffix = aff.NEEDAFFIX

    forms = set()
    words = dictionary.dic.words
    if limit:
        words = words[:limit]

    for word in words:
        stem = word.stem
        flags = word.flags or set()

        if forbidden and forbidden in flags:
            continue

        # NEEDAFFIX means the stem is not a word on its own.
        if not (needaffix and needaffix in flags):
            forms.add(stem)

        suffixed = []
        for flag in flags:
            for entry in aff.SFX.get(flag, ()):
                produced = apply_suffix(stem, entry, fullstrip)
                if produced:
                    forms.add(produced)
                    if entry.crossproduct:
                        suffixed.append(produced)

        for flag in flags:
            for entry in aff.PFX.get(flag, ()):
                produced = apply_prefix(stem, entry, fullstrip)
                if produced:
                    forms.add(produced)
                    if entry.crossproduct:
                        # Prefix over each cross-product suffix form.
                        for base in suffixed:
                            both = apply_prefix(base, entry, fullstrip)
                            if both:
                                forms.add(both)

    # Normalise once: lowercase, NFC, drop anything that is not plain letters.
    cleaned = set()
    for form in forms:
        low = unicodedata.normalize("NFC", form).lower()
        if is_plain_word(low, alphabet):
            cleaned.add(low)
    return cleaned


ALPHABETS = {
    "ru": set("абвгдежзийклмнопрстуфхцчшщъыьэюяё"),
    "en": set("abcdefghijklmnopqrstuvwxyz'"),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", help="путь без расширения, например .../ru_RU")
    parser.add_argument("--lang", required=True, choices=sorted(ALPHABETS))
    parser.add_argument("--out", required=True)
    parser.add_argument("--limit", type=int, default=None)
    args = parser.parse_args()

    forms = expand(args.path, ALPHABETS[args.lang], args.limit)
    # Sorted output: the whole pipeline must be reproducible byte for byte.
    with open(args.out, "w", encoding="utf-8") as handle:
        for form in sorted(forms):
            handle.write(form + "\n")
    print(f"{args.lang}: {len(forms)} словоформ → {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
