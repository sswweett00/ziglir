# SEL — Sparse Eikonal Ledger

LIR dili ile yazılmış, **sıfır bağımlılıklı** bir öğrenme çekirdeği.

```lir
import "ai/src/ledger.lir"

fn main() -> i64 {
    let h = block_new(2, 24, 2, 3)     // 2 girdi -> 24 gizli, K=2 seyrek
    let o = block_new(24, 1, 24, 5)    // 24 -> 1 çıktı
    // ... ileri geçiş + eikonal güncelleme
}
```

## Durum

**Uygulanmış ve test edilmiş.** Beş test, üç backend'de (native, VM, C)
birebir aynı sonucu veriyor: **15/15**.

| test | ne kanıtlar | sonuç |
|---|---|---|
| `01_fixed_point` | Q32.32 aritmetiği doğru (mul, div, sqrt, doygunluk) | 9 değer birebir |
| `02_learn` | öğrenme enerjiyi gerçekten düşürüyor | 2^17 = 131.000x |
| `03_xor` | doğrusal olmayan problem çözülüyor | **4/4** |
| `04_search` | ters indeks + sıralama | belge 4, sonra 3 |
| `05_math` | gcd, mod_pow, mod_inv, is_prime, fpow | 8 değer birebir |
| `06_codec` | tokenizer'sız kodlama + kod imzası | 5/5 |
| `07_translate` | hizalama defteri (çeviri) yakınsıyor | 2/2 |
| `08_agent` | araç yönlendirici doğru aracı seçiyor | 2/2 |

**8 test × 3 backend = 24/24.**

```bash
export PATH=/tmp/zv13/ziglang:$PATH
zig build -Doptimize=ReleaseFast
python3 ai/run_tests.py          # 24/24
python3 ai/bench/run.py          # ölçüm tablosu
```

## Tasarım

Tam belge: [`docs/DESIGN.md`](docs/DESIGN.md).

**Yeni mimari (v0.1, uygulanmadı):** [`docs/NOEMA.md`](docs/NOEMA.md) — SEL'i
alt-bileşen olarak kapsayan, muhakeme-öncelikli, analog-doğal + tamsayı-emülasyon
tasarımı; kapı ölçümleri (K0–K10) tanımlı.

- **Sayı formatı:** Q32.32 sabit nokta, tamamen `i64`. Float yok, 16-bit yok,
  bit tabanlı yok.
- **Öğrenme kuralı:** eikonal (NLMS) güncelleme — gradyan yok, momentum yok,
  Adam yok. Her kenar tek bir `tau` tamsayısı taşır.
- **Mimari:** seyrek "ledger" katmanı — her nöron sabit `K` kenar taşır,
  bellek `O(n·K)`.
- **Tokenizasyon yok:** girdi sürekli bir vektör.

## Ölçülen hız

| iş | önce | sonra | kazanç |
|---|---:|---:|---:|
| `b_train` (3 katman, K=8, 5000 adım) | 496.7 ms | **227.5 ms** | **2.18x** |
| `b_forward` | 45.3 ms | **16.8 ms** | **2.70x** |
| `b_learn` | 118.6 ms | **51.6 ms** | **2.30x** |
| `b_net3` | 96.5 ms | **40.9 ms** | **2.36x** |
| `b_matmul` 96³ | 12.7 ms | **3.9 ms** | **3.25x** |
| XOR eğitimi | 37.1 ms | **21.3 ms** | **1.75x** |
| 19 iş yükü toplamı | 1903.6 ms | **1438.8 ms** | **1.32x** |

Farkın kaynağı ölçüldü: LIR'in `@read_u64`/`@write_u64` builtin'leri her
erişimde sınır kontrolü yapıyordu. Derleyici artık bunları sayaçlı
döngülerin dışına taşıyor (hoisting) ve Q32.32 yardımcılarını (`mul`,
`sat_add`, `fabs`) gerçekten gövdeye alıyor (leaf-closure inlining).
Ayrıntı ve ölçümler: `docs/DESIGN.md` §5.5.

**C karşılaştırması — düzeltilmiş.** Eski tabloda **20.6x** yazıyordu; o
karşılaştırma hatalıydı, çünkü C ikizi (`bench/c_twin.c`) yalnızca `forward`
yapıyor, `learn` hiç yok, LIR tarafı ise ikisini birden çalıştırıyordu. Aynı
işi yapan `bench/c_twin_train.c` ile ölçülen gerçek oran **9.6x**'tir
(227.5 ms / 23.7 ms). Kalan farkın dağılımı DESIGN.md §5.5'te ölçülmüştür.

**Rust ölçümü yoktur**; bu ortamda Rust çalıştırılamıyor. Karşılaştırma
yalnızca C ile ve öyle etiketlenerek yapılmıştır.

## Akış hattı (sınırlı bellek)

`ai/src/stream.lir` — `---` ayırıcılı TXT kayıtlarını **parça parça** okuyan
akış okuyucusu. Kayıt biçimi: `---` yalnızca satır başında ve ardından
LF/CRLF/EOF gelen üç tiredir; kayıt ayırıcıyı ve önündeki tek satır sonunu
içermez. Bellek bütçesi `chunk_cap + rec_cap + seen_cap*8` ile sabittir;
veri kümesi RAM'i aşsa bile çalışır. Kayıt başına: artımlı UTF-8 doğrulama,
boş/aşırı-uzun/geçersiz kayıt atlama (sayaçla raporlanır), FNV-1a tabanlı
tekilleştirme (tablo dolunca `dedup_full`, akış durmaz).

Uçtan uca demo (ölçüldü, bu makine, native backend):

```bash
./zig-out/bin/lir run ai/gen_stream_corpus.lir --backend=native   # 5.5 MB, 62.608 kayıt
./zig-out/bin/lir run ai/train_stream.lir --backend=native
```

Sonuç: 33.479 tekil kayıt online eğitildi, 29.129 mükerrer atlandı,
5.542.417 bayt **172 ms**'de okundu (~32 MB/s, ~195k kayıt/sn), train/dev
doğruluğu %97.2 / %96.7. VmHWM 148→2296 kB — tepe bellek veri boyutundan
bağımsız (parça 64 KiB + kayıt 8 KiB + dedup 2 MiB + model). Parser+dedup
maliyeti ölçülen eğitim adımının yanında küçük; thread prefetch bu
2 çekirdekli ortamda `pool.lir` ölçümleri gereği kazandırmıyor, bu yüzden
okuyucu tek iş parçacıklıdır.

Test: `ai/tests/46_stream_reader.lir` — parça sınırı, UTF-8, CRLF, boş/
mükerrer/aşırı-uzun/geçersiz kayıt, satır-içi `---`, EOF son kayıt;
native+VM+C backend'lerinde birebir.

## Düşük bellek eğitim desenleri

SEL mimarisi, veri boyutundan bağımsız bellek kullanımı için üç desen kullanır:

1. **Akış okuyucu** (`stream.lir`): Veri kümesi RAM'e yüklenmez. Tek bir
   `chunk` tamponu (varsayılan 64 KiB) dosyadan artımlı okur; kayıtlar
   `---` ile ayrılır ve `rec` tamponuna (varsayılan 8 KiB) iner. Dedup
   tablosu sabit boyutludur; dolunca `dedup_full` bayrağı ile sonraki
   mükerrerler raporlanır ama akış durmaz.

2. **Tekil tamponlar (`train_stream.lir`)**: Özellik vektörü (`DIM*8`),
   hedef vektörü (`NCLASS*8`) ve model çıkış tamponu eğitim döngüsü
   dışında BİR KEZ tahsis edilir; her kayıt bu tamponların üzerine yazar.
   Per-kayıt `@malloc` yoktur (önceki sürümde `text_len_cell` her kayıt
   için tahsis ediliyordu — kaldırıldı).

3. **Model parametreleri**: Kenar tablosu (`nout * K * 4 * 8`), bias
   (`nout * 8`) ve çıkış (`nout * 8`) blok oluşturma sırasında BİR KEZ
   tahsis edilir; güncellemeler yerinde (`in-place`) yapılır, copy-on-write
   yoktur.

Bu desenlerle RAM sınırlı olduğunda da büyük veri kümeleri işlenebilir:
tek bellek artışı, model boyutuyla sınırlıdır, veri boyutuyla değil.

## Ne değildir

Bu, GPT/Gemini/Claude ile yarışan bir model değildir ve olduğu iddia
edilmiyor. GPT seviyesi, mimariden değil **veri ve hesaplama ölçeğinden**
gelir. Buradaki şey, o ölçeğe çıkabilecek *mekanizmanın* kendisi: taşınabilir,
deterministik, sıfır bağımlılıklı bir eğitim çekirdeği.

## Yetenek katmanları

| istenen yetenek | bu depodaki karşılığı | durum |
|---|---|---|
| matematik | `src/math.lir` — gcd, mod_pow, mod_inv, is_prime, fpow | çalışıyor, test 05 |
| arama | `src/search.lir` — ters indeks, top-k | çalışıyor, test 04 |
| kod | `src/codec.lir` — rotation-encode + yapısal imza | çalışıyor, test 06 |
| çeviri | `src/translate.lir` — hizalama defteri (NLMS matris) | çalışıyor, test 07 |
| araç kullanımı | `src/agent.lir` — öğrenilmiş araç yönlendirici | çalışıyor, test 08 |
| sohbet | çekirdek + yönlendirici; diyalog verisi gerekir | mekanizma var |

Sohbet, diğerlerinden farklı: bir mekanizma sorunu değil, **veri** sorunu.
Çekirdek (ledger + eikonal + kodlama) hazır; diyalog kalitesi, bu depoda
bulunmayan bir veri kümesini gerektirir. Bunu abartmıyorum.
