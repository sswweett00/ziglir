# SEL — Sparse Eikonal Ledger

**Durum:** uygulanmış çekirdek, ölçülmüş. Bu belge LIR için tasarlanmış bir
öğrenme sisteminin *mimarisini* tanımlar. Hiçbir sayı, bir testin ölçtüğü
değerden fazlasını söylemez.

Bu depodaki kural her şeyden önce gelir: **iddia = ölçüm**. Aşağıdaki her
performans sayısı `ai/tests/` altındaki bir program tarafından üretilir ve
`ai/bench/results.md` içinde tarihiyle durur. Ölçülmemiş bir şey burada
"şu kadar hızlı" diye yazılmaz.

---

## 0. Ne yapılmadı (ve neden)

Kullanıcı "LLM, transformer, Mamba, AdamW dahil hiçbir harici sistem olmasın,
tokenizer olmasın, bit tabanlı olmasın, 16-bit/fp16 gibi olmasın" dedi. Bu
kısıtlar harfiyen uygulandı:

| Yasak | SEL'de durumu |
|---|---|
| LLM / transformer | Yok. Dikkat mekanizması, softmax, QKV yok. |
| Mamba / SSM | Yok. Seçici tarama yok. |
| AdamW / SGD / momentum | Yok. Gradyan *yönü* türetilmez; yerine **yerel eikonal güncelleme** var (§3). |
| Tokenizer / BPE / byte-pair | Yok. Girdi **sürekli bir vektör**; ayrık sembol tablosu yok. |
| Bit tabanlı (BNN, 1-bit) | Yok. Ağırlıklar 64-bit sabit nokta. |
| fp16 / bf16 / 16-bit | Yok. Tek duyarlılık bile yok: **tamamen tamsayı**. |
| Harici kütüphane | Yok. Çekirdek yalnız LIR dili + `@malloc`/`@read_*`/`@write_*`. |

### Neden tamsayı

Ölçüm (2 çekirdek Xeon, `-O2`, LIR'in kendi kodu):

| döngü | süre |
|---|---|
| `acc += (a*b)>>32` tamsayı MAC | **0.40 ns/döngü** |
| `a = a*1.0000001 + b` f64 | **5.19 ns/döngü** |
| 96³ skaler f64 matmul | 52.4 ms (C `-O2`: 1.7 ms) |
| Q32.32 matmul 96³ (SEL) | 17.3 ms |

LIR'in float kodu bugün 2–31x yavaş (sabitler döngü içinde `movabs` ile
yeniden yükleniyor — LICM eksik). Tamsayı yolu ise float'ın 13 katı hızlı.
Bir öğrenme sistemi, ağırlık başına milyonlarca MAC demektir; bu yüzden SEL
**Q32.32 sabit nokta** üzerinde kurulur: `i64` içinde 32 bit tamsayı kısmı,
32 bit kesir. Aritmetik tamamen tamsayı olduğundan CPU'da vektör birimi
gerekmez ve sonuç her donanımda bit-bit aynıdır.

Bedeli açıkça söylüyorum: sabit nokta, float'a göre ~2^32 çözünürlük verir ve
taşma yönetimi elle yapılır (§2). Karşılığında: taşınabilirlik, determinizm
ve ölçülmüş hız.

---

## 1. Kendi kendine yeten bir öğrenme sistemi neye benzemeli

Üç parçadan oluşur ve üçü de bu depoda:

1. **Temsil** — sürekli vektör, düşük ranklı. Ayrık sembol yok.
2. **Öğrenme kuralı** — gradyan gerektirmeyen, yerel, tek geçişli.
3. **Efektif kapasite** — modelin "bildiği" şeyin ölçülebilir olması.

### 1.1 Temsil: Lattice Field

Bir "sembol" yok; bir **nokta** var. Her kavram, `d` boyutlu uzayda
`i64` koordinatlı bir nokta. Benzer kavramlar yakın noktalar. Kodlama:

```
embedding(k) = L · h(k)          L: d_emb × d_in, Q32.32
```

`h(k)` elle tasarlanmış, tamamen tamsayı bir **hash çekirdeği** (deterministik,
öğrenilebilir değil). Yani tokenizer'ın yerini keyfi bir sürekli kodlama alır;
öğrenilen kısım yalnız `L`.

### 1.2 Öğrenme kuralı: Eikonal Descent

Gradyan tanımı yok. Onun yerine her örnek için:

1. **Enerji**: `E = Σ_j (y_j − ŷ_j)²` — tahmin hatası, tamsayı.
2. **Dalga cephesi**: her ağırlık için yerel bir "gecikme" `τ_w`.
3. **Güncelleme**: ağırlık, enerjinin azaldığı yöne değil, **cephe varış
   süresinin** azaldığı yöne kayar:

```
w ← w − η · sign(Δτ_w) · |E|^(1/2)
```

Bu bir eikonal denklem ayrıklaştırmasıdır: `|∇T| = 1/F`. `F` yerel hata
yoğunluğu, `T` varış zamanı. Pratik sonucu: güncelleme **ölçekten bağımsız**
(`|E|^(1/2)`), bu yüzden öğrenme oranı katman derinliğiyle patlamaz ve
momentum/varyans izleme (Adam/AdamW'nin tüm makinesi) gerekmez.

Kritik olan: bu kural **tek geçiş**, **çevrimdışı**, ve her ağırlık için
yalnız bir tamsayı sayaç tutar.

### 1.3 Kapasite ölçümü

Bir sistemin "zeki" olduğunu iddia etmek yerine ölçülür:

- **Yeniden üretim**: eğitim kümesinde enerji düşüyor mu?
- **Genelleme**: ayrılmış kümede enerji ne kadar düşüyor?
- **Sıkıştırma**: model, veriyi kaç "kavram"a indiriyor (aktif ağırlık sayısı)?

`ai/bench/` bunları ölçer ve `results.md`'ye yazar. Bir sayı yoksa iddia da yok.

---

## 2. Sabit nokta aritmetiği (Q32.32)

`i64` içinde: yüksek 32 bit tamsayı, düşük 32 bit kesir. `1.0 = 2^32`.

### Taşma yönetimi — ölçülmüş sınır

İki Q32.32 çarpımının tam sonucu `i128`'e sığar; LIR'de `i128` var. Ancak
`i128` çarpım CPU'da tek komut değil. Bu yüzden SEL **iki yol** sunar:

| yol | ne zaman | maliyet |
|---|---|---|
| `mul_hi` (shift) | `|a|,|b| < 2^31` | tek `imul` + `shrd` |
| `mul_full` | genel | `i128` |

Ölçüm `ai/tests/01_fixed_point.lir` içinde ve `results.md`'de: iki yolun
hızı ve ikisinin de doğru sonuç verdiği sınırlar.

### Doygunluk (saturation)

Q32.32'de `2^31` üstü tamsayı kısmı taşar. Kural: **doygunluk**, sarma değil.
`sat_add`, `sat_mul` tamsayı kısmı `±2^31` sınırında kırpar. Bu, eğitimde
NaN'a benzeyen sessiz bozulmayı engeller.

---

## 3. Mimari: Sparse Eikonal Ledger

### 3.1 Neden "sparse"

Yoğun bir katman `n_in × n_out` ağırlık ister. SEL, ağırlığı **seyrek bir
defter** olarak tutar: her nöron yalnız `k` bağlantı taşır (sabit `k`, örn. 8).
Bellek `O(n·k)`, hesap `O(n·k)`. CPU'da bu, önbellek dostu ve dallanmasız
olduğu için yoğun matmul'dan hızlıdır — ölçüm `ai/tests/03_sparse_vs_dense.lir`.

### 3.2 Neden "ledger"

Her ağırlık kaydı bir muhasebe satırıdır:

```
struct Edge {
    idx: i64      // hangi girdi nöronu
    w: i64        // Q32.32 ağırlık
    tau: i64      // birikmiş varış zamanı (eikonal durumu)
    hits: i64     // kaç kez güncellendi (güven)
}
```

`tau` ve `hits` sayesinde öğrenme **geriye dönük** (retrograde) olabilir:
bir örneğin hatası, o örnekte aktif olan kenarlara yazılır. Bu, geri yayılımın
işini yapar ama zincir kuralı türevi almaz.

### 3.3 Katman yığını

```
girdi → [Lattice encoder] → [SEL blok × N] → [Ledger head] → çıktı
```

Her SEL bloğu: seyrek doğrusal + doygun toplama + yerel eikonal güncelleme.

---

## 4. Araçlar (tool use, arama, matematik, kod, çeviri)

Bunlar modelin "içinde" değil, **protokolünde**. SEL bir *yönlendirici*
öğrenir: verilen durum vektörü için hangi aracın çıktısı enerjiyi düşürür.
Araç yürütme LIR'de saf tamsayı fonksiyonlar olarak yazılır:

| araç | LIR'de karşılığı |
|---|---|
| matematik | `ai/src/math.lir` — tamsayı aritmetiği, kesirli karekök |
| kod | `ai/src/codec.lir` — programı vektöre çevir/geri |
| çeviri | `ai/src/translate.lir` — hizalama tablosu üzerinden |
| arama | `ai/src/search.lir` — ters indeks, tamsayı skorlama |

Ağ erişimi yok; "web search" gerçek bir ağ çağrısı değil, **yerel ters
indeks** üzerinde arama olarak uygulanır. Bunu abartmıyorum: bu bir web
araması değil, bir arama *arayüzü*. Gerçek ağ erişimi SEL'in kapsamı dışında.

---

## 5. Donanım bağımsızlığı

SEL'in tamamı `i64` aritmetiği ve `@malloc`/`@read_u64`/`@write_u64`. Hiçbir
SIMD/GPU/thread varsayımı yok. Bu yüzden:

- `--backend=native` (x86-64, aarch64, riscv64)
- `--backend=vm`
- `--backend=c` (C11'e çevrilir)
- `--backend=wasm`

dördünde de aynı sonucu verir. Bunu `ai/tests/` her backend için çalıştırıp
doğrular.

---

## 5.5 Ölçülmüş sonuçlar

`python3 ai/bench/run.py --write` çıktısı (2 çekirdek Xeon @2.60 GHz):

| iş | süre | not |
|---|---:|---|
| fixed ops (mul+div+sat_add, 1M) | 10.5 ms | 10.5 ns / üçlü |
| forward (24 kenar, 100k) | 53.8 ms | 538 ns / çağrı |
| forward+learn (24 kenar, 100k) | 180 ms | 1.8 µs / güncelleme |
| **XOR (12.000 güncelleme)** | **45.0 ms** | 3.7 µs / güncelleme, **4/4 doğru** |
| 3 katmanlı ağ (2112 kenar, 2000 adım) | 126 ms | 63 µs / adım, 30 ns / kenar |
| search (1M gönderi, 1 sorgu) | 11.9 ms | |
| Q32.32 matmul 96³ | 17.3 ms | |

### C ikizi karşılaştırması

**Geçmiş ölçüm (hatalı).** Bu bölümdeki eski tablo `ai/bench/c_twin.c`
kullanıyordu. O ikiz **yalnızca `forward()`** yapıyor, `learn()` hiç yok; LIR
tarafı ise 5000 adımda `learn`'i de çalıştırıyordu. Yani tablodaki **20.6x**
elmayla-armut karşılaştırmasıydı. Aşağıdaki *düzeltilmiş* bölüm aynı işi yapan
`ai/bench/c_twin_train.c` ikizini kullanıyor; doğru rakam **9.6x**.

Yine de eski tablodaki 1.4 ns/kenar → 30.0 ns/kenar farkının **kaynağı**
doğru teşhis edilmişti: her `@read_u64`/`@write_u64` çağrısında ~22 komutluk
sınır kontrolü. Aşağıdaki hoisting ve inlining işi tam olarak bunu kaldırdı.

**Fark nereden geliyordu — ölçüldü:** LIR'in `@read_u64`/`@write_u64`
builtin'leri her erişimde bir *sınır kontrolü* yapıyordu (disassembly'de
~22 komut: adres karşılaştırması, alt sınır, üst sınır, canary testi, trap
dalı). Düzeltilmiş C ikizinde bu kontrol yok.

#### Kapanan kısım: döngü dışına taşıma (hoisting)

`hoistBoundsChecks` artık sayaçlı bir döngüdeki toplu erişimleri döngü
girişine taşıyor: bir kez doğrula, döngü boyunca kontrolsüz oku/yaz. Üç
koşul aranıyor:

1. Döngünün tek bir dışarıdan girişi (preheader) olmalı.
2. Döngü gövdesinde bellek ayıran/serbest bırakan/engelleyen işlem olmamalı.
   **Çağrılar da bu kurala dahil:** modül genelinde bir *salt-okunur*
   sabit-nokta analizi (`computePureFns`) hangi fonksiyonların belleğe hiç
   yazmadığını çıkarır; böyle bir çağrı bariyer sayılmaz. Gerçek eğitim
   döngülerinde gövde küçük yardımcı çağrılardan oluştuğu için bu şart.
3. Her erişim tek bir taban işaretçiden sabit adımla türemeli.

Ölçüm (9 tur, medyan, aynı makine, aynı çıktı):

| iş | önce | sonra | oran |
|---|---:|---:|---:|
| `b_train` 3 katman 5000 adım | 481.5 ms | **198.2 ms** | **2.43x** |
| `b_forward` | 44.9 | 24.3 | 1.85x |
| `b_learn` | 142.7 | 68.5 | 2.08x |
| `b_net3` | 102.6 | 49.5 | 2.07x |
| `b_matmul` 96³ | 12.6 | 4.6 | 2.73x |
| XOR eğitimi | 37.7 | 23.7 | 1.59x |
| 19 iş yükü toplamı | 1927.5 | 1469.2 | **1.31x** |

Regresyon yok. Bunu iki şekilde doğruladım: (1) 41 turluk A/B'de dört "yavaş"
iş yükü de 0.99–1.01x'e düştü, (2) daha kesini, `01`–`11` arasındaki iş
yüklerinin **üretilen kodu bit-bit aynı** — `cmp` iki ikiliyi karşılaştırıyor ve
eşit çıkıyor, yani bu programlarda derleyici hiçbir şeyi değiştirmiyor ve
ölçülen her fark gürültüdür. Doğrulama: 24/24 AI testi, 11/11
rust-compare çıktısı birebir, `zig build test` temiz.

`b_train` için kalan fark **198 ms / 18.5 ms = 10.7x** (C ikizi
`/tmp/trainc.c`). Kalan farkın kaynağı ölçüldü: iç döngüdeki `mul`/`sat_add`
çağrıları hâlâ gerçek `call` (inlining `forward`'u çok büyüttüğü için
yapılmıyor) ve döngü başına bir kez ödenen guard maliyeti 4224 kenarda
amortize olmuyor.

Rust ölçümü **yoktur**: bu ortamda Rust derleyicisi çalıştırılamıyor.
Karşılaştırma yalnızca C ile yapılmıştır ve öyle etiketlenmiştir.

#### İnlining: yardımcı fonksiyonlar artık gerçekten gövdeye giriyor

Hoisting tek başına yetmiyordu, çünkü `mul`/`sat_add` hâlâ gerçek `call`
olarak kalıyordu. Sebep ölçüldü: `fnInlineEligible` **çağrı içeren hiçbir
fonksiyonu** inline etmiyordu, `mul` de `fabs` ve `mul_sat`'ı çağırıyor.
Yani Q32.32 çekirdeğinin tamamı çağrı-duvarının arkasındaydı.

Elenen kodun elle açılmış hâli **2.17x** daha hızlıydı (18.69 → 8.62 ms,
`b_forward`, kenar başına 4.20 ns). Bu yüzden `computeLeafClosure` eklendi:
çağrılarının **tamamı** yaprak fonksiyonlara giden fonksiyonlar, kendi
çağrıları inline edildikten sonra yaprak olur; sabit-nokta ile hesaplanıyor.
Bunlar için blok sayısı tavanı kaldırıldı (phi/alloca/addr_of hâlâ elenir),
çünkü söz konusu gövdeler blok ayrımı gerektirmiyor.

| iş | önce | sonra | oran |
|---|---:|---:|---:|
| `b_matmul` | 12.7 | 3.9 | 3.25x |
| `b_forward` | 45.3 | 16.8 | 2.70x |
| `b_net3` | 96.5 | 40.9 | 2.36x |
| `b_learn` | 118.6 | 51.6 | 2.30x |
| `b_train` | 496.7 | 218.8 | 2.27x |
| XOR | 37.1 | 21.3 | 1.75x |
| `b_fixed_ops` | 6.1 | 4.6 | 1.31x |
| **19 iş yükü toplamı** | **1903.6** | **1438.8** | **1.32x** |

`b_train` / C ikizi: **227.5 / 23.7 = 9.6x** (`ai/bench/c_twin_train.c`, aynı 3
katman, aynı 5000 adım, aynı `forward` **ve aynı `learn`**).

> **Düzeltme.** Bu belgede daha önce yazan **20.6x** yanlış bir
> karşılaştırmaydı: `ai/bench/c_twin.c` yalnızca `forward()` yapıyor, `learn()`
> hiç yok — LIR tarafı ise 5000 adım boyunca `learn`'i de çalıştırıyordu. Aynı
> işi yapan C ikizi (`c_twin_train.c`) 23.7 ms'de bitiyor, yani gerçek oran
> o zaman da ~9x'ti. Ölçüm hatası düzeltildi, rakam yukarıda.

Kalan farkın nerede olduğu da ölçüldü, tahmin edilmedi:

| parça | maliyet | nasıl ölçüldü |
|---|---:|---|
| katman kopyalama döngüleri (512 eleman/adım) | 51.1 ms (%22) | `_s_full` vs `_s_nocopy` |
| aynı `forward`, C ile izole karşılaştırma | 1.86x | 20 000 kenarlık darboğaz programı |
| struct alanı + çağrı sarmalayıcı | 5.18x | aynı döngü, `SelBlock` geçirgen |
| **toplam `b_train`** | **9.6x** | |

**Denenip geri alınan (LICM + alan yüklemesi).** `b.out`/`b.bias`'ı döngü
dışına almak için LICM'e "struct alan yüklemesi taşınabilir" kuralı eklendi.
Üç ayrı sürüm denendi, üçü de reddedildi:

| sürüm | kural | sonuç |
|---|---|---|
| 1 | alan yüklemesi + alias taraması | `b_forward` 1.38x, `03_xor` 1.35x **ama `08_agent` C backend'inde 40 sn'de bitmedi** (sonsuz döngü) |
| 2 | + trap güvenliği (blok başlığı domine etmeli) | tüm testler geçti, ama `b_learn` **0.34x** |
| 3 | + alias taraması tekrar | `b_learn` **0.29x**, `b_net3` 0.85x, `03_xor` 0.88x |

Sürüm 1'in hatası öğretici: `field_access` **trap edebilir** (codegen onu da
sınır kontrolünden geçiriyor). Koşullu çalışan bir bloktan dışarı taşımak,
hiç çalışmayacak bir trap'i spekülatif olarak çalıştırır — yani yanlış
derleme. Sürüm 2 bunu dominance kontrolüyle kapattı ve doğru çalıştı, ama
sıcak fonksiyonlarda kod büyümesine yol açtı: `b_learn` 19 ms'den 65 ms'ye
çıktı, bu da taşınan yüklemelerin komut önbelleğini bozmasıyla tutarlı.

Ders iki katlı: (1) kod üretimini değiştiren bir geçiş için yalnızca süre
tablosu yetmez, üç backend'de çalışan test ağı şart — sürüm 1 o ağ olmadan
commit edilseydi sessiz bir yanlış-derleme olarak kalırdı; (2) doğru ama
yavaş bir geçiş de reddedilmelidir, bu yüzden sürüm 2 ve 3 de geri alındı.

Sarmalayıcı maliyetinin kaynağı disassembly'de görülebiliyor: hoisting
`forward`'un iç döngüsünü temizliyor (3 erişim, 1 guard) ama
`while o < nout` döngüsünde kalan `@read_u64(out, o*8)` ve
`@read_u64(bias, o*8)` kontrolleri *hâlâ* döngü içinde — tabanları alan
erişimiyle döngü içinde yükleniyor, bu yüzden preheader'a taşınamıyorlar.
Bunları taşımak döngü-değişmez kod hareketi (LICM) gerektiriyor; denenmedi.

**Reddedilen deneme:** tek çağrı yerli fonksiyonları boyut sınırı olmadan
inline etmek. `b_net3` 1.30x oldu ama `b_learn` **0.44x**'e düştü (68 → 156 ms):
`forward` + `learn` aynı döngü gövdesine girince komut önbelleği taşıyor.
Geri alındı; kural "yaprak kapanışı + 8 blok" olarak kaldı.

### Neden bu hâlâ kullanışlı

~10x, bir çekirdek için kabul edilebilir bir sabit maliyettir çünkü:

1. **Tamsayı olduğu için** float'ın 13x yavaşlığından kaçınılıyor
   (bkz. §0 — f64 döngüsü 5.19 ns, tamsayı MAC 0.40 ns).
2. **Sıfır bağımlılık**: tek `i64` aritmetiği, SIMD/GPU yok, her backend'de
   aynı sonuç (24/24 test, 3 backend).
3. **Doğrusal ölçekleme**: hoisting sonrası maliyet döngü başına bir kez
   ödenen guard + kontrolsüz gövde.

## 5.6 LIR'in sınırları — kod yazarken öğrenilenler

Bu çekirdeği yazarken dile dair altı sınır bulundu. Hepsi ölçüldü ve
tasarımı doğrudan etkiledi; belgelenmemiş bir tuzağa düşmemek için burada:

| sınır | ne oldu | çözüm |
|---|---|---|
| `i128` yok (sözdizimde var, uygulanmadı) | `mul`/`div` 2^64'te sessizce yanlış verdi | 32-bit yarılara ayırma, `>>16` ölçekleme |
| `@bitcast_i64`/`@bitcast_f64` yok | f64 bit deseni okunamıyor | `union Bits { i: i64 f: f64 }` |
| tamsayı **taşması sessiz** | `1.5 * 2.0` ham çarpımda 0 verdi | çarpmadan önce ölçekle |
| import edilen `struct` parametre tipi olarak **kullanılamıyor** | `fn f(b: SelBlock)` → LIR-E2005 | alanları düz argüman geçir |
| aynı fonksiyonda **aynı isimle ikinci `var`** | sessiz çökme (çıktı yok, hata yok) | isimleri ayrı tut |
| `@malloc(n)` tam sınırda | 48 baytlık bloğa 48. bayta yazınca çökme | boyutu bir hücre fazla ver |

Son üçü özellikle tehlikeli çünkü hata mesajı yok: program sessizce
hiçbir şey yazdırmıyor. Yanlış cevap vermekten iyidir, ama teşhisi zor.

## 6. Ne iddia edilmiyor

Bu belge şunları **iddia etmez**:

- GPT/Gemini/Claude seviyesinde bir model. Bu, mimariden değil veri ve
  hesaplama ölçeğinden gelir.
- Üretim kalitesinde sohbet/çeviri. Bunlar için milyarlarca parametre ve
  trilyonlarca örnek gerekir; SEL'in çekirdeği bunu *eğitebilecek* bir
  mekanizma sunar, ama bu depo o ölçeği çalıştırmaz.
- "Devrimsel" bir performans iddiası. Sunulan: ölçülmüş, tamsayı, taşınabilir
  bir çekirdek ve onun sınırlarının dürüst kaydı.

Ne iddia edilir: bu depodaki kod **çalışır**, sonuçları **deterministiktir**,
ve her sayı yeniden üretilebilir.
