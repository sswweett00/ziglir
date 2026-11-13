export const fields = ['income', 'expense', 'savings', 'debt', 'apr', 'payment', 'growth', 'months'];
export const maxima = [100000000, 100000000, 100000000, 100000000, 3600, 100000000, 2000, 360];
export function parseInputs(values) {
  return fields.map((key, i) => {
    const raw = String(values[key] ?? '');
    if (!(i === 7 ? /^\d{1,3}$/ : /^\d{1,7}(\.\d{1,2})?$/).test(raw))
      throw new Error(`${key}: geçerli bir sayı girin (en fazla iki ondalık basamak).`);
    const [whole, fraction = ''] = raw.split('.');
    const value = i === 7 ? Number(whole) : Number(whole) * 100 + Number(fraction.padEnd(2, '0'));
    if (!Number.isSafeInteger(value) || value < (i === 7 ? 1 : 0) || value > maxima[i])
      throw new Error(`${key}: desteklenen aralığın dışında.`);
    return value;
  });
}
export function validateInputs(inputs) {
  return Array.isArray(inputs) && inputs.length === 8 && inputs.every((n, i) =>
    Number.isSafeInteger(n) && n >= (i === 7 ? 1 : 0) && n <= maxima[i]);
}
export function formatInput(n, i) { return i === 7 ? String(n) : (n / 100).toFixed(2); }
export function variants(base) {
  const expense = [...base]; expense[1] = Math.floor(base[1] * 115 / 100);
  const income = [...base]; income[0] = Math.floor(base[0] * 80 / 100);
  return [base, validateInputs(expense) ? expense : null, income];
}
// Validate the wire schema before presenting any results from the engine.
export function decodeReport(text, months) {
  const data = JSON.parse(text);
  const keys = ['assets', 'debt', 'net', 'interest', 'paid', 'debtFreeMonth', 'lowestCash'];
  if (data?.schema !== 1 || !Array.isArray(data.series) || data.series.length !== months || !data.summary ||
      !keys.every(key => Number.isSafeInteger(data.summary[key])) ||
      !data.series.every((row, i) => row.month === i + 1 &&
        ['assets', 'debt', 'net', 'cash'].every(key => Number.isSafeInteger(row[key]))))
    throw new Error('LIR rapor şeması doğrulanamadı.');
  return data;
}
