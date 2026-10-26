/* =====================================================================
   Lector de resumenes de tarjeta (Santander Visa / American Express).
   Sin dependencias: recibe las FILAS de texto de un PDF y devuelve los datos.
   Si el banco cambia el formato, falla con avisos (no inventa datos).
   ===================================================================== */
(function (root) {
  const num = (s) => Number(String(s).replace(/\./g, '').replace(',', '.'));
  const iso = (d) => `20${d.slice(6, 8)}-${d.slice(3, 5)}-${d.slice(0, 2)}`;
  const AMT = '[\\d.]+,\\d\\d';
  const RE_MOV = new RegExp(`^(?:(\\d\\d/\\d\\d/\\d\\d)\\s+)?(.+?)\\s+(?:(\\d{1,2}) de (\\d{1,2})\\s+)?(\\d{6})\\s+(-?)(U\\$S|\\$)\\s*(${AMT})$`);
  const RE_TAX = new RegExp(`^(?:(\\d\\d/\\d\\d/\\d\\d)\\s+)?(.+?)\\s+(-?)\\$\\s*(${AMT})$`);
  const RE_TAXNAME = /iibb|iva|rg\s?\d|percep|impuesto|sellos|ganancias/i;
  const RE_NOTTAX = /inter[eé]s|financ|punit|comisi|seguro/i;

  // Agrupa los textos de una pagina (con posicion) en filas, de arriba hacia abajo.
  function clusterRows(items) {
    const its = items.filter((i) => i.s && i.s.trim()).sort((a, b) => b.y - a.y || a.x - b.x);
    const rows = []; let cur = null;
    its.forEach((i) => {
      if (!cur || Math.abs(cur.y - i.y) > 3) { cur = { y: i.y, items: [] }; rows.push(cur); }
      cur.items.push(i);
    });
    return rows.map((r) => r.items.sort((a, b) => a.x - b.x).map((i) => i.s).join(' ').replace(/\s+/g, ' ').trim());
  }

  function parseStatementRows(rows) {
    const out = {
      brand: null, last4: null, closed_on: null, due_on: null,
      total_ars: null, total_usd: 0, min_ars: null,
      subtotal_ars: null, subtotal_usd: null, consumos_ars: 0, consumos_usd: 0,
      cuotas: [], taxes_ars: 0, rg5617_ars: 0, tax_lines: [], other_lines: [], warnings: []
    };
    let section = ''; let lastDate = null; let expectTotals = false; let finalTotal = null; let seenDates = false;
    rows.forEach((t) => {
      let m;
      if (!out.brand && (m = t.match(/^Resumen\s+(Visa|American Express)/i))) out.brand = /visa/i.test(m[1]) ? 'Visa' : 'Amex';
      if (!out.last4 && (m = t.match(/terminada en (\d{4})/i))) out.last4 = m[1];
      if (!seenDates && (m = t.match(/^(\d\d\/\d\d\/\d\d) (\d\d\/\d\d\/\d\d) (\d\d\/\d\d\/\d\d) (\d\d\/\d\d\/\d\d) (\d\d\/\d\d\/\d\d) (\d\d\/\d\d\/\d\d)$/))) {
        out.closed_on = iso(m[3]); out.due_on = iso(m[4]); seenDates = true; return;
      }
      if (/^En pesos En dólares Mínimo a pagar$/.test(t)) { expectTotals = true; return; }
      if (expectTotals) {
        expectTotals = false;
        if ((m = t.match(new RegExp(`^\\$\\s*(${AMT})\\s+U\\$S\\s*(${AMT})\\s+\\$\\s*(${AMT})$`)))) {
          out.total_ars = num(m[1]); out.total_usd = num(m[2]); out.min_ars = num(m[3]); return;
        }
      }
      if (/^Pago anterior y devoluciones/.test(t)) { section = 'prev'; return; }
      if (/^Fecha Descripci[oó]n Cuota Comprobante/.test(t)) { section = 'mov'; return; }
      if (/^Impuestos, intereses y percepciones/.test(t)) { section = 'tax'; return; }
      if ((m = t.match(new RegExp(`^Subtotal de .*?\\$\\s*(${AMT})\\s+U\\$S\\s*(${AMT})$`)))) {
        out.subtotal_ars = (out.subtotal_ars || 0) + num(m[1]); out.subtotal_usd = (out.subtotal_usd || 0) + num(m[2]); section = 'after'; return;
      }
      if ((m = t.match(new RegExp(`^Total a pagar\\s+\\$\\s*(${AMT})\\s+U\\$S\\s*(${AMT})$`)))) { finalTotal = num(m[1]); section = 'end'; return; }

      if (section === 'mov') {
        if ((m = t.match(RE_MOV))) {
          const date = m[1] ? iso(m[1]) : lastDate; if (m[1]) lastDate = date;
          const sign = m[6] ? -1 : 1; const amount = sign * num(m[8]); const cur = m[7] === '$' ? 'ARS' : 'USD';
          if (cur === 'ARS') out.consumos_ars += amount; else out.consumos_usd += amount;
          if (m[3] && m[4]) {
            if (cur !== 'ARS') out.warnings.push(`La cuota «${m[2]}» está en dólares: por ahora no se carga como plan.`);
            else out.cuotas.push({ description: m[2].trim(), from_no: +m[3], installments: +m[4], amount, date });
          }
        } else if (new RegExp(`${AMT}$`).test(t) && !/^(Copia fiel|Total|Mínimo)/.test(t)) {
          out.warnings.push(`No pude leer esta línea de compras: «${t}»`);
        }
      } else if (section === 'tax') {
        if ((m = t.match(RE_TAX))) {
          const amount = (m[3] ? -1 : 1) * num(m[4]); const name = m[2].trim();
          if (RE_TAXNAME.test(name) && !RE_NOTTAX.test(name)) { out.tax_lines.push({ name, amount }); if (amount > 0) out.taxes_ars += amount; if (/rg\s?5617/i.test(name)) out.rg5617_ars += amount; }
          else out.other_lines.push({ name, amount });
        } else if (new RegExp(`${AMT}$`).test(t) && !/^(Copia fiel|Total|Mínimo)/.test(t)) {
          out.warnings.push(`No pude leer esta línea de impuestos: «${t}»`);
        }
      }
    });
    const r2 = (n) => Math.round(n * 100) / 100;
    out.consumos_ars = r2(out.consumos_ars); out.consumos_usd = r2(out.consumos_usd); out.taxes_ars = r2(out.taxes_ars); out.rg5617_ars = r2(out.rg5617_ars);
    if (!out.brand) out.warnings.push('No reconocí el emisor del resumen (se esperaba Santander Visa o American Express).');
    if (!out.due_on || !out.closed_on) out.warnings.push('No encontré las fechas de cierre y vencimiento.');
    if (out.total_ars == null) out.warnings.push('No encontré el total a pagar.');
    if (out.total_ars != null && finalTotal != null && Math.abs(out.total_ars - finalTotal) > 0.01) out.warnings.push('El total de la primera página no coincide con el del final.');
    if (out.subtotal_ars == null) out.warnings.push('No encontré el subtotal de compras para verificar la lectura.');
    else {
      if (Math.abs(out.consumos_ars - out.subtotal_ars) > 0.01) out.warnings.push(`Las compras en pesos que leí (${out.consumos_ars}) no suman el subtotal del resumen (${out.subtotal_ars}).`);
      if (Math.abs(out.consumos_usd - out.subtotal_usd) > 0.01) out.warnings.push(`Las compras en dólares que leí (${out.consumos_usd}) no suman el subtotal del resumen (${out.subtotal_usd}).`);
    }
    out.ok = out.warnings.length === 0;
    return out;
  }
  root.StatementParser = { parseStatementRows, clusterRows };
  if (typeof module !== 'undefined') module.exports = root.StatementParser;
})(typeof window !== 'undefined' ? window : globalThis);
