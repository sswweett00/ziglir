#!/usr/bin/env python3
"""NOEMA-Φ sıfır-heap derleme kapısı.

ai/src altındaki noema_* modüllerini tarar ve çalışma anı heap ayıran
built-in çağrılarını yasaklar. Tek istisna: dosya başında
`// lir:allow-alloc` işareti taşıyan dosyalar (arena boot modülü) —
bu dosyalar init sırasında TEK seferlik büyük arena tahsisini yapar,
sonrasında hiçbir kod yolu tekrar ayırmaz.

Kullanım:
    python3 ai/tools/noalloc_gate.py [dosya ...]

Çıkış kodu 0 = temiz, 1 = ihlal. Argümansız çağrıda ai/project.manifest
listesi taranır — manifest yalnızca yeni NOEMA-Φ runtime modüllerini
içerir; eski SEL yığını (noema_lm, noema_tensor, ...) bilinçli olarak
kapsam dışıdır çünkü geçiş tamamlanana dek heap kullanabilir.
run_tests.py tarafından test aşamasında otomatik koşulur.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # ai/
AI_DIR = ROOT
MANIFEST = os.path.join(AI_DIR, "project.manifest")

# Heap ayıran / büyüten built-in'ler. @free ve salt-okunur işlemler
# yasak değildir: sıfır-heap ilkesi "çalışma anında yeni tahsis yok"
# demektir; boot tahsisini serbest bırakmak serbesttir.
FORBIDDEN = (
    "@malloc", "@alloc",
    "@array_new", "@array_push", "@array_map", "@array_filter",
    "@map_new", "@map_set",
    "@chan_new",
    "@thread_create",
    "@mutex_create", "@mutex_init",
    "@string_new", "@string_concat", "@string_sub", "@string_slice",
    "@string_split", "@int_to_string", "@float_to_string",
)
ALLOW_MARKER = "lir:allow-alloc"

_CALL_RE = re.compile(r"@([A-Za-z_][A-Za-z0-9_]*)\s*\(")
_COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.DOTALL)


def strip_comments(text: str) -> str:
    return _COMMENT_RE.sub(" ", text)


def allowed(path: str, text: str) -> bool:
    head = text[:4096]
    return ALLOW_MARKER in head


def violations(path: str) -> list:
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    if allowed(path, text):
        return []
    code = strip_comments(text)
    out = []
    for m in _CALL_RE.finditer(code):
        name = "@" + m.group(1)
        if name in FORBIDDEN:
            line = code.count("\n", 0, m.start()) + 1
            out.append((line, name))
    return out


def main() -> int:
    if len(sys.argv) > 1:
        files = sys.argv[1:]
    else:
        files = []
        with open(MANIFEST, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                files.append(os.path.join(AI_DIR, line))
    if not files:
        print("noalloc_gate: project.manifest bos", file=sys.stderr)
        return 1
    bad = 0
    for path in files:
        for line, name in violations(path):
            print(f"NOALLOC {path}:{line}: yasakli heap builtini '{name}'")
            bad += 1
    if bad:
        print(f"noalloc_gate: {bad} ihlal — heap ayirimi yalnizca "
              f"'// {ALLOW_MARKER}' isaretli boot dosyasinda serbesttir",
              file=sys.stderr)
        return 1
    print(f"noalloc_gate: {len(files)} dosya temiz")
    return 0


if __name__ == "__main__":
    sys.exit(main())
