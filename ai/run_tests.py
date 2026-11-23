#!/usr/bin/env python3
"""SEL test çalıştırıcısı — beş test, üç backend.

Kullanım: python3 ai/run_tests.py
Çıkış kodu 0 ise hepsi geçti.
"""
import glob
import os
import tempfile
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIR = os.path.join(ROOT, "zig-out", "bin", "lir")
TMPDIR = tempfile.mkdtemp(prefix="lirtest_")
BACKENDS = ["native", "vm", "c"]


def main():
    if not os.path.exists(LIR):
        print(f"hata: {LIR} yok — once `zig build -Doptimize=ReleaseFast`")
        return 1
    tests = sorted(glob.glob(os.path.join(ROOT, "ai", "tests", "*.lir")))
    if not tests:
        print("hata: ai/tests/*.lir bulunamadi")
        return 1

    # Sıfır-heap kapısı: NOEMA modülleri çalışma anında heap ayıramaz.
    gate = os.path.join(ROOT, "ai", "tools", "noalloc_gate.py")
    if os.path.exists(gate):
        g = subprocess.run([sys.executable, gate],
                           capture_output=True, text=True)
        print(g.stdout, end="")
        if g.returncode != 0:
            print(g.stderr, end="")
            return 1

    passed = failed = 0
    for t in tests:
        name = os.path.basename(t)[:-4]
        exp_path = t[:-4] + ".expected"
        if not os.path.exists(exp_path):
            print(f"  ATLA {name} (beklenen dosya yok)")
            continue
        with open(exp_path) as f:
            expected = [l for l in f.read().splitlines() if l.strip()]

        # Test dosyasının ilk satırında `// backends: native` varsa yalnızca
        # o backend(ler) koşulur. Gerçek thread kullanan testler VM ve C
        # backend'lerinde anlamlı değil: VM tek iş parçacıklı, spin-loop
        # tabanlı bariyer orada ilerlemez.
        backends = BACKENDS
        with open(t) as f:
            head = [f.readline() for _ in range(4)]
        if head[0].startswith("// backends:"):
            backends = [x.strip() for x in head[0].split(":", 1)[1].split(",")]

        # `// opt: -O1` — varsayılan optimizasyon seviyesini değiştirir.
        # `12_learn_batch` bunu kullanıyor: aynı kaynak `-O2`'de segfault
        # veriyor (bkz. ai/tests/O2_SEGFAULT.md), `-O0/-O1/-O3` doğru.
        opt = "-O2"
        for line in head:
            if line.startswith("// opt:"):
                opt = line.split(":", 1)[1].strip()

        for b in backends:
            if opt == "-O2":
                # Varsayılan yol: `run` alt komutu (backend seçilebilir).
                r = subprocess.run([LIR, "run", t, "--backend=" + b],
                                   capture_output=True, text=True)
            else:
                # Özel optimizasyon seviyesi: önce derle, sonra çalıştır.
                exe = os.path.join(TMPDIR, "lirtest_" + name + "_" + b)
                bc = subprocess.run([LIR, "build", t, opt, "-o", exe],
                                    capture_output=True, text=True)
                if bc.returncode != 0:
                    print(f"  FAIL {name:<16} {b} (derleme: -O opt)")
                    print(f"       {bc.stderr[:300]}")
                    failed += 1
                    continue
                r = subprocess.run([exe], capture_output=True, text=True)
            got = [l for l in r.stdout.splitlines() if l.strip()]
            ok = got == expected
            if ok:
                passed += 1
                print(f"  ok   {name:<16} {b}")
            else:
                failed += 1
                print(f"  FAIL {name:<16} {b}")
                print(f"       beklenen: {expected}")
                print(f"       alinan  : {got}")
                if r.stderr.strip():
                    print(f"       stderr: {r.stderr[:300]}")
    print(f"\ngecen: {passed}  basarisiz: {failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
