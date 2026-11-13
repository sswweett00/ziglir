import {runInWorker} from '../../../runtime/browser/worker-client.mjs';
import {fields, parseInputs, validateInputs, formatInput, variants, decodeReport} from './model.mjs';
const $ = id => document.getElementById(id);
const money = cents => new Intl.NumberFormat('tr-TR', {style: 'currency', currency: 'TRY', maximumFractionDigits: 2}).format(cents / 100);
const compact = cents => new Intl.NumberFormat('tr-TR', {notation: 'compact', maximumFractionDigits: 1}).format(cents / 100) + ' ₺';
const storageKey = 'lir-finance-scenarios-v1';
let saved = [], current = null, controller, request = 0;
let wasm;
function status(text, error = false) { $('status').textContent = text; $('status').classList.toggle('error', error); }
try {
  const value = JSON.parse(localStorage.getItem(storageKey) || '[]');
  if (Array.isArray(value)) saved = value.slice(0, 10).filter(item =>
    item && validateInputs(item.inputs) && typeof item.date === 'string' && !Number.isNaN(Date.parse(item.date)));
} catch { status('Yerel kayıt okunamadı. Hesaplama kullanılabilir.', true); }
function persist() {
  try { localStorage.setItem(storageKey, JSON.stringify(saved)); return true; }
  catch { status('Tarayıcı kayıt alanı kullanılamıyor. JSON raporu indirebilirsiniz.', true); return false; }
}
function renderSaved() {
  $('saved-list').replaceChildren();
  if (!saved.length) {
    const p = document.createElement('p'); p.className = 'empty';
    p.textContent = 'Henüz bir senaryo kaydetmediniz. İlk olasılığınızı keşfedin.';
    $('saved-list').append(p);
  }
  saved.forEach((item, i) => {
    const row = document.createElement('div'); row.className = 'saved-row';
    const title = document.createElement('div');
    title.textContent = `Senaryo ${i + 1} · ${item.inputs[7]} ay`;
    const sub = document.createElement('small');
    sub.textContent = `${new Date(item.date).toLocaleString('tr-TR')} · Gelir ${money(item.inputs[0])}`;
    title.append(sub);
    const actions = document.createElement('div');
    const load = document.createElement('button'); load.textContent = 'Yükle';
    load.onclick = () => { fields.forEach((key, k) => { $(key).value = formatInput(item.inputs[k], k); }); void calculate(); };
    const remove = document.createElement('button'); remove.textContent = 'Sil';
    remove.setAttribute('aria-label', `Senaryo ${i + 1} sil`);
    remove.onclick = () => {
      const previous = saved; saved = saved.filter((_, k) => k !== i);
      if (!persist()) saved = previous;
      renderSaved();
    };
    actions.append(load, remove); row.append(title, actions); $('saved-list').append(row);
  });
}
function drawChart(report, input) {
  const rows = [{month: 0, assets: input[2], debt: input[3], net: input[2] - input[3]}, ...report.series];
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg'); svg.setAttribute('viewBox', '0 0 900 245');
  svg.setAttribute('preserveAspectRatio', 'none');
  function element(tag, attrs) {
    const e = document.createElementNS(ns, tag);
    Object.entries(attrs).forEach(([k, v]) => e.setAttribute(k, v)); svg.append(e); return e;
  }
  const values = rows.flatMap(row => [row.assets, row.debt, row.net]);
  const min = Math.min(0, ...values), max = Math.max(100, ...values);
  const y = n => 215 - (n - min) / (max - min) * 195;
  const x = i => 65 + i / input[7] * 820;
  for (let i = 0; i <= 4; i++) {
    const value = min + (max - min) * i / 4;
    element('line', {x1: 65, x2: 890, y1: y(value), y2: y(value), stroke: '#e8ece4', 'stroke-dasharray': '4 5'});
    const label = element('text', {x: 50, y: y(value) + 3, 'text-anchor': 'end', fill: '#98a18e', 'font-size': 10});
    label.textContent = compact(Math.round(value));
  }
  const area = rows.map((r, i) => `${i ? 'L' : 'M'}${x(i)},${y(r.assets)}`).join(' ');
  element('path', {d: `${area} L${x(input[7])},215 L65,215 Z`, fill: '#f0f5e9', opacity: '.7'});
  for (const [key, color] of [['assets', '#a2ba82'], ['debt', '#cba982'], ['net', '#326548']]) {
    const d = rows.map((r, i) => `${i ? 'L' : 'M'}${x(i)},${y(r[key])}`).join(' ');
    element('path', {d, fill: 'none', stroke: color, 'stroke-width': key === 'net' ? 2.8 : 1.8, 'vector-effect': 'non-scaling-stroke'});
    element('circle', {cx: x(input[7]), cy: y(rows.at(-1)[key]), r: 3.5, fill: color, stroke: '#fff', 'stroke-width': 2});
  }
  $('chart').replaceChildren(svg); $('chart-end').textContent = `${input[7]}. ay`;
}
function showReport(reports, inputs) {
  const report = reports[0], s = report.summary;
  $('net').textContent = money(s.net); $('assets').textContent = money(s.assets);
  $('remaining-debt').textContent = money(s.debt);
  const change = s.net - (inputs[2] - inputs[3]);
  $('net-change').textContent = `${change >= 0 ? '↗ +' : '↘ '}${money(change)} başlangıca göre`;
  $('period').textContent = `${inputs[7]} aylık görünüm`;
  $('debt-free').textContent = s.debtFreeMonth < 0 ? 'Dönem sonunda borç devam ediyor' : s.debtFreeMonth === 0 ? 'Başlangıçtan itibaren borçsuz' : `${s.debtFreeMonth}. ayda borçsuz`;
  $('insight').textContent = s.lowestCash < 0 ?
    `Aylık nakit akışı ${money(s.lowestCash)} seviyesine düşüyor. Birikiminizin eksiye düşme riskini aylık dökümde inceleyin.` :
    s.debtFreeMonth >= 0 ? `Bu varsayımlarla dönem içinde borçsuzsunuz. Toplam faiz maliyeti ${money(s.interest)}; ödeme sonrası en düşük aylık nakit akışı ${money(s.lowestCash)}.` :
    `En düşük aylık nakit akışınız ${money(s.lowestCash)}. Dönem sonunda ${money(s.debt)} borç kalıyor. Ödeme planınızı veya süreyi değiştirmeyi deneyin.`;
  drawChart(report, inputs);
  $('ledger').replaceChildren();
  for (const row of report.series) {
    const tr = document.createElement('tr');
    [row.month, ...['assets', 'debt', 'net', 'cash'].map(k => money(row[k]))].forEach(text => {
      const td = document.createElement('td'); td.textContent = text; tr.append(td);
    }); $('ledger').append(tr);
  }
  $('scenarios').replaceChildren();
  const titles = ['Baz senaryo', 'Gider baskısı', 'Gelir şoku'];
  const subtitles = ['Girdiğiniz varsayımlar', 'Aylık gider +%15', 'Aylık gelir −%20'];
  reports.forEach((r, i) => {
    const card = document.createElement('article'); card.className = `card scenario${i === 0 ? ' base' : ''}`;
    for (const [tag, cls, text] of [
      ['h3', '', titles[i]], ['p', 'scenario-sub', subtitles[i]],
      ['div', 'scenario-label', 'Dönem sonu net varlık'], ['strong', '', r ? money(r.summary.net) : 'Aralık dışında'],
      ['div', 'delta', r ? (i === 0 ? `${inputs[7]} aylık plan` : `${money(r.summary.net - s.net)} baz senaryoya göre`) : 'Gider üst sınırını aşıyor'],
    ]) { const e = document.createElement(tag); e.className = cls; e.textContent = text; card.append(e); }
    $('scenarios').append(card);
  });
}
async function calculate() {
  const id = ++request; controller?.abort(); controller = new AbortController();
  current = null; $('save').disabled = true; $('export').disabled = true;
  if (!$('form').reportValidity()) return;
  let inputs;
  try { inputs = parseInputs(Object.fromEntries(fields.map(key => [key, $(key).value]))); }
  catch (error) { status(error.message, true); return; }
  $('calculate').disabled = true; status('LIR, üç senaryoyu ayrı worker içinde hesaplıyor…');
  const start = performance.now();
  try {
    if (!wasm) throw new Error('Hesaplama motoru yüklenemedi. Sayfayı yenileyin.');
    const reports = await Promise.all(variants(inputs).map(async variant => {
      if (!variant) return null;
      const result = await runInWorker(wasm, {args: ['finance', ...variant.map(String)], signal: controller.signal, timeout: 10000});
      if (result.code !== 0) throw new Error(`LIR hesaplama hatası (${result.code}): ${result.output}`);
      return decodeReport(result.output, inputs[7]);
    }));
    if (id !== request) return;
    current = {inputs, reports}; showReport(reports, inputs);
    $('save').disabled = false; $('export').disabled = false;
    status(`✓ LIR/Wasm ile hesaplandı · 3 senaryo · ${Math.round(performance.now() - start)} ms · Veriler cihazınızda`);
  } catch (error) {
    if (id === request) { controller.abort(); status(error.message, true); }
  } finally { if (id === request) $('calculate').disabled = false; }
}
$('form').addEventListener('submit', event => { event.preventDefault(); void calculate(); });
// Mark old results explicitly stale; do not export them under newly edited inputs.
$('form').addEventListener('input', () => {
  request++; controller?.abort(); current = null;
  $('calculate').disabled = false; $('save').disabled = true; $('export').disabled = true;
  status('Parametreler değişti. Görünen sonuçlar önceki hesaplamaya ait; yeniden hesaplayın.');
});
$('save').onclick = () => {
  if (!current) return;
  const previous = saved;
  saved = [{date: new Date().toISOString(), inputs: [...current.inputs]}, ...saved].slice(0, 10);
  if (!persist()) saved = previous; else status('Senaryo bu tarayıcıya kaydedildi.');
  renderSaved();
};
$('clear').onclick = () => {
  if (!saved.length || !confirm('Kaydedilen tüm senaryolar silinsin mi?')) return;
  const previous = saved; saved = []; if (!persist()) saved = previous; renderSaved();
};
$('export').onclick = () => {
  if (!current) return;
  const blob = new Blob([JSON.stringify({application: 'LIR Finance', schema: 1, date: new Date().toISOString(), ...current}, null, 2)], {type: 'application/json'});
  const url = URL.createObjectURL(blob), a = document.createElement('a');
  a.href = url; a.download = 'lir-finance-report.json'; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
};
renderSaved();
try {
  const response = await fetch('./finance.wasm');
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  wasm = await response.arrayBuffer(); await calculate();
} catch (error) { status(`LIR motoru yüklenemedi: ${error.message}. Önce Wasm çıktısını derleyin.`, true); }
