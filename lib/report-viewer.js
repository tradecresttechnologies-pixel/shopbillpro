/* ════════════════════════════════════════════════════════════════════
 * lib/report-viewer.js
 * Batch 020 — Reports Engine foundation (8 May 2026)
 *
 * Generic viewer for any report whose RPC returns the standard envelope:
 *   { ok, report_key, from_date, to_date, summary, rows, groups }
 *
 * Renders into a target DOM element with:
 *   - Date range picker (presets + custom)
 *   - Refresh button
 *   - CSV export button
 *   - KPI cards (from `summary`)
 *   - Optional grouped breakdown (from `groups`)
 *   - Sortable detail table (from `rows`)
 *
 * Public API:
 *   SBPReportViewer.render({
 *     mountEl:  HTMLElement,           // where to render
 *     shopId:   uuid,
 *     reportKey: 'sales_summary',
 *     config:    REPORT_CONFIGS.sales_summary,   // see below
 *     dateRange: 'last_30_days'        // optional starting range
 *   })
 *
 * Each REPORT_CONFIG describes:
 *   - title, icon, description
 *   - rpc:    Supabase RPC name
 *   - kpis:   [{key, label, format}]   - which fields to render as KPI cards
 *   - groups: {label, columns:[{key,label,format}]} - grouped table renderer
 *   - rows:   {label, columns:[{key,label,format}]} - detail table renderer
 * ════════════════════════════════════════════════════════════════════ */

(function () {
  'use strict';

  // ─── Format helpers ──────────────────────────────────────
  const fmt = {
    inr:    v => '₹' + (parseFloat(v||0)).toLocaleString('en-IN', {maximumFractionDigits:2, minimumFractionDigits:0}),
    inrL:   v => {
      const n = parseFloat(v||0);
      if (n >= 100000) return '₹' + (n/100000).toFixed(2) + 'L';
      if (n >= 1000)   return '₹' + (n/1000).toFixed(1) + 'K';
      return '₹' + n.toFixed(0);
    },
    int:    v => parseInt(v||0, 10).toLocaleString('en-IN'),
    pct:    v => (parseFloat(v||0)).toFixed(1) + '%',
    text:   v => v == null ? '—' : String(v),
    date:   v => v ? new Date(v).toLocaleDateString('en-IN', {day:'2-digit', month:'short', year:'2-digit'}) : '—',
    dateLong: v => v ? new Date(v).toLocaleDateString('en-IN', {day:'2-digit', month:'short', year:'numeric'}) : '—',
    capitalize: v => v ? String(v).charAt(0).toUpperCase() + String(v).slice(1) : '—'
  };

  function applyFmt(value, format) {
    if (typeof format === 'function') return format(value);
    return (fmt[format] || fmt.text)(value);
  }

  function escHtml(s) {
    if (s == null) return '';
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  // ─── Date range presets ──────────────────────────────────
  function dateRangeFrom(preset) {
    const today = new Date();
    const iso = d => d.toISOString().slice(0,10);
    let from, to = iso(today);
    switch (preset) {
      case 'today':       from = iso(today); break;
      case 'this_week': {
        const d = new Date(today); d.setDate(d.getDate() - d.getDay());
        from = iso(d); break;
      }
      case 'this_month': {
        const d = new Date(today.getFullYear(), today.getMonth(), 1);
        from = iso(d); break;
      }
      case 'last_7_days':  { const d = new Date(today); d.setDate(d.getDate() - 7);  from = iso(d); break; }
      case 'last_30_days': { const d = new Date(today); d.setDate(d.getDate() - 30); from = iso(d); break; }
      case 'last_90_days': { const d = new Date(today); d.setDate(d.getDate() - 90); from = iso(d); break; }
      case 'this_year': {
        const d = new Date(today.getFullYear(), 0, 1);
        from = iso(d); break;
      }
      default: { const d = new Date(today); d.setDate(d.getDate() - 30); from = iso(d); }
    }
    return { from, to };
  }

  // ─── Supabase client ─────────────────────────────────────
  function getSb() {
    if (window._sb)  return window._sb;
    if (window.sb)   return window.sb;
    if (window.supabase && window.supabase.createClient) {
      const SB_URL = 'https://jfqeirfrkjdkqqixivru.supabase.co';
      const SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpmcWVpcmZya2pka3FxaXhpdnJ1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQzNzQ4MzgsImV4cCI6MjA4OTk1MDgzOH0.akd4E0nil8ypLR4WOykkeYIL8g4uuNU6XdSVh_Y1utk';
      window._sbReportsClient = window._sbReportsClient ||
        window.supabase.createClient(SB_URL, SB_KEY);
      return window._sbReportsClient;
    }
    return null;
  }

  // ─── REPORT CONFIGS ──────────────────────────────────────
  const REPORT_CONFIGS = {

    sales_summary: {
      title: 'Sales Summary',
      icon: '📊',
      description: 'Bills, revenue, AOV, daily breakdown',
      rpc: 'sbp_report_sales_summary',
      shopTypes: ['*'],          // works for all
      kpis: [
        {key:'total_bills',     label:'Bills',      format:'int'},
        {key:'total_revenue',   label:'Revenue',    format:'inrL'},
        {key:'total_paid',      label:'Collected',  format:'inrL'},
        {key:'total_due',       label:'Outstanding',format:'inrL'},
        {key:'aov',             label:'AOV',        format:'inr'},
        {key:'unique_customers',label:'Customers',  format:'int'}
      ],
      groups: {
        label: 'By Status',
        columns: [
          {key:'status', label:'Status', format:'capitalize'},
          {key:'count',  label:'Bills',  format:'int'},
          {key:'total',  label:'Total',  format:'inr'}
        ]
      },
      rows: {
        label: 'Daily Breakdown',
        columns: [
          {key:'date',    label:'Date',    format:'dateLong'},
          {key:'bills',   label:'Bills',   format:'int'},
          {key:'revenue', label:'Revenue', format:'inr'},
          {key:'paid',    label:'Collected', format:'inr'}
        ]
      }
    },

    item_kind_breakdown: {
      title: 'Item-Kind Breakdown',
      icon: '📦',
      description: 'Revenue split by product, service, room',
      rpc: 'sbp_report_item_kind_breakdown',
      shopTypes: ['*'],
      kpis: [
        {key:'total_lines',   label:'Lines',   format:'int'},
        {key:'total_qty',     label:'Quantity', format:'int'},
        {key:'total_revenue', label:'Revenue', format:'inrL'},
        {key:'total_gst',     label:'GST',     format:'inrL'}
      ],
      groups: {
        label: 'By Kind',
        columns: [
          {key:'kind',    label:'Kind',    format:'capitalize'},
          {key:'lines',   label:'Lines',   format:'int'},
          {key:'qty_sum', label:'Qty',     format:'int'},
          {key:'revenue', label:'Revenue', format:'inr'},
          {key:'gst',     label:'GST',     format:'inr'}
        ]
      },
      rows: {
        label: 'Top 20 Items',
        columns: [
          {key:'kind',    label:'Kind',    format:'capitalize'},
          {key:'name',    label:'Item',    format:'text'},
          {key:'qty_sum', label:'Qty',     format:'int'},
          {key:'revenue', label:'Revenue', format:'inr'}
        ]
      }
    },

    top_customers: {
      title: 'Top Customers',
      icon: '🏆',
      description: 'Top spenders, frequent visitors, outstanding dues',
      rpc: 'sbp_report_top_customers',
      shopTypes: ['*'],
      kpis: [
        {key:'unique_customers',  label:'Customers',   format:'int'},
        {key:'total_revenue',     label:'Revenue',     format:'inrL'},
        {key:'total_visits',      label:'Visits',      format:'int'},
        {key:'total_outstanding', label:'Outstanding', format:'inrL'}
      ],
      rows: {
        label: 'Top 25 Customers',
        columns: [
          {key:'customer_name', label:'Customer',  format:'text'},
          {key:'customer_wa',   label:'Phone',     format:'text'},
          {key:'visits',        label:'Visits',    format:'int'},
          {key:'total_spend',   label:'Spend',     format:'inr'},
          {key:'avg_spend',     label:'AOV',       format:'inr'},
          {key:'total_due',     label:'Due',       format:'inr'},
          {key:'last_visit',    label:'Last Visit', format:'date'}
        ]
      }
    },

    payment_mode_mix: {
      title: 'Payment Mode Mix',
      icon: '💳',
      description: 'Cash / UPI / Card / Credit breakdown',
      rpc: 'sbp_report_payment_mode_mix',
      shopTypes: ['*'],
      kpis: [
        {key:'total_paid',  label:'Total Collected', format:'inrL'},
        {key:'modes_count', label:'Modes Used',      format:'int'}
      ],
      rows: {
        label: 'By Payment Mode',
        columns: [
          {key:'payment_mode', label:'Mode',  format:'text'},
          {key:'count',        label:'Bills', format:'int'},
          {key:'total',        label:'Total', format:'inr'},
          {key:'pct',          label:'Share', format:'pct'}
        ]
      }
    }
  };

  // ─── CSV export ──────────────────────────────────────────
  function rowsToCSV(rows, columns) {
    const head = columns.map(c => c.label).join(',');
    const body = rows.map(r =>
      columns.map(c => {
        const v = r[c.key];
        const s = v == null ? '' : String(v).replace(/"/g, '""');
        return /[,"\n]/.test(s) ? `"${s}"` : s;
      }).join(',')
    ).join('\n');
    return head + '\n' + body;
  }

  function downloadCSV(filename, content) {
    const blob = new Blob([content], {type: 'text/csv;charset=utf-8;'});
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement('a');
    a.href     = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  // ─── Styles (injected once) ──────────────────────────────
  const STYLE_ID = 'sbp-rpt-styles';
  function ensureStyles() {
    if (document.getElementById(STYLE_ID)) return;
    const s = document.createElement('style');
    s.id = STYLE_ID;
    s.textContent = `
      .sbp-rpt{font-family:'Outfit',sans-serif;color:var(--text,#F0EFF8)}
      .sbp-rpt-head{display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:12px;margin-bottom:18px}
      .sbp-rpt-title{font-size:22px;font-weight:800;margin:0 0 4px;background:linear-gradient(135deg,#F5A623,#FF8A00);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
      .sbp-rpt-desc{font-size:13px;color:rgba(255,255,255,.55);margin:0}
      .sbp-rpt-actions{display:flex;gap:8px;flex-wrap:wrap}
      .sbp-rpt-btn{padding:8px 14px;background:rgba(124,58,237,.12);border:1px solid rgba(124,58,237,.3);border-radius:8px;color:var(--text,#F0EFF8);font-family:inherit;font-size:13px;font-weight:600;cursor:pointer}
      .sbp-rpt-btn:hover{background:rgba(124,58,237,.22)}
      .sbp-rpt-btn.primary{background:linear-gradient(135deg,#F5A623,#FF8A00);color:#0A0E1A;border-color:transparent}
      .sbp-rpt-controls{display:flex;gap:8px;flex-wrap:wrap;align-items:center;background:rgba(20,18,32,.5);border:1px solid rgba(124,58,237,.2);border-radius:10px;padding:10px 14px;margin-bottom:18px}
      .sbp-rpt-controls label{font-size:11px;color:rgba(255,255,255,.55);margin-right:4px;font-weight:600}
      .sbp-rpt-controls select,.sbp-rpt-controls input[type=date]{padding:7px 10px;background:var(--surf2,#0e0e1a);border:1px solid rgba(124,58,237,.3);border-radius:8px;color:var(--text,#F0EFF8);font-family:inherit;font-size:13px}
      .sbp-rpt-kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-bottom:22px}
      .sbp-rpt-kpi{background:rgba(20,18,32,.6);border:1px solid rgba(124,58,237,.2);border-radius:10px;padding:14px}
      .sbp-rpt-kpi-l{font-size:11px;color:rgba(255,255,255,.55);font-weight:600;text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px}
      .sbp-rpt-kpi-v{font-size:22px;font-weight:800;line-height:1.1}
      .sbp-rpt-section{background:rgba(20,18,32,.4);border:1px solid rgba(124,58,237,.18);border-radius:12px;padding:16px;margin-bottom:18px}
      .sbp-rpt-section h3{font-size:14px;font-weight:700;margin:0 0 12px;color:var(--text,#F0EFF8)}
      .sbp-rpt-table{width:100%;border-collapse:collapse;font-size:13px}
      .sbp-rpt-table th{text-align:left;padding:10px 12px;font-size:11px;text-transform:uppercase;letter-spacing:.5px;color:rgba(255,255,255,.55);border-bottom:1px solid rgba(124,58,237,.2);font-weight:700;cursor:pointer;user-select:none}
      .sbp-rpt-table th:hover{color:#F5A623}
      .sbp-rpt-table td{padding:9px 12px;border-bottom:1px solid rgba(124,58,237,.08)}
      .sbp-rpt-table tr:last-child td{border-bottom:none}
      .sbp-rpt-table tr:hover td{background:rgba(124,58,237,.05)}
      .sbp-rpt-empty{text-align:center;padding:40px 20px;color:rgba(255,255,255,.45);font-size:13px}
      .sbp-rpt-loading{text-align:center;padding:40px;color:rgba(255,255,255,.55);font-size:13px}
      .sbp-rpt-err{background:rgba(239,68,68,.08);border:1px solid rgba(239,68,68,.3);color:#FCA5A5;padding:14px;border-radius:8px;font-size:13px;margin-bottom:14px}
      @media(max-width:640px){
        .sbp-rpt-table{font-size:12px}
        .sbp-rpt-table th,.sbp-rpt-table td{padding:7px 8px}
        .sbp-rpt-kpi-v{font-size:18px}
      }
    `;
    document.head.appendChild(s);
  }

  // ─── Main render ─────────────────────────────────────────
  async function render(opts) {
    if (!opts.mountEl)   throw new Error('mountEl required');
    if (!opts.shopId)    throw new Error('shopId required');
    if (!opts.reportKey) throw new Error('reportKey required');

    ensureStyles();
    const config = opts.config || REPORT_CONFIGS[opts.reportKey];
    if (!config) throw new Error('Unknown reportKey: ' + opts.reportKey);

    const root = opts.mountEl;
    let dateRange = opts.dateRange || 'last_30_days';
    let { from, to } = dateRangeFrom(dateRange);
    let lastData = null;

    function shell() {
      root.innerHTML = `
        <div class="sbp-rpt">
          <div class="sbp-rpt-head">
            <div>
              <h2 class="sbp-rpt-title">${escHtml(config.icon)} ${escHtml(config.title)}</h2>
              <p class="sbp-rpt-desc">${escHtml(config.description || '')}</p>
            </div>
            <div class="sbp-rpt-actions">
              <button class="sbp-rpt-btn" data-act="refresh">↻ Refresh</button>
              <button class="sbp-rpt-btn primary" data-act="csv">⬇️ CSV</button>
            </div>
          </div>

          <div class="sbp-rpt-controls">
            <label>Range:</label>
            <select data-ctl="preset">
              <option value="today">Today</option>
              <option value="this_week">This Week</option>
              <option value="this_month">This Month</option>
              <option value="last_7_days">Last 7 Days</option>
              <option value="last_30_days" selected>Last 30 Days</option>
              <option value="last_90_days">Last 90 Days</option>
              <option value="this_year">This Year</option>
              <option value="custom">Custom</option>
            </select>
            <label>From:</label>
            <input type="date" data-ctl="from" value="${from}">
            <label>To:</label>
            <input type="date" data-ctl="to" value="${to}">
          </div>

          <div class="sbp-rpt-body">
            <div class="sbp-rpt-loading">Loading…</div>
          </div>
        </div>
      `;

      const presetEl = root.querySelector('[data-ctl=preset]');
      const fromEl   = root.querySelector('[data-ctl=from]');
      const toEl     = root.querySelector('[data-ctl=to]');

      presetEl.value = dateRange;

      presetEl.addEventListener('change', () => {
        dateRange = presetEl.value;
        if (dateRange !== 'custom') {
          const r = dateRangeFrom(dateRange);
          from = r.from; to = r.to;
          fromEl.value = from; toEl.value = to;
          load();
        }
      });
      [fromEl, toEl].forEach(el =>
        el.addEventListener('change', () => {
          from = fromEl.value; to = toEl.value;
          dateRange = 'custom';
          presetEl.value = 'custom';
          load();
        })
      );

      root.querySelector('[data-act=refresh]').addEventListener('click', load);
      root.querySelector('[data-act=csv]').addEventListener('click', exportCsv);
    }

    function renderBody(data) {
      const body = root.querySelector('.sbp-rpt-body');
      let html = '';

      // KPI cards
      if (config.kpis && data.summary) {
        html += '<div class="sbp-rpt-kpis">';
        config.kpis.forEach(k => {
          const v = data.summary[k.key];
          html += `
            <div class="sbp-rpt-kpi">
              <div class="sbp-rpt-kpi-l">${escHtml(k.label)}</div>
              <div class="sbp-rpt-kpi-v">${escHtml(applyFmt(v, k.format))}</div>
            </div>
          `;
        });
        html += '</div>';
      }

      // Groups (sub-tables)
      if (config.groups && Array.isArray(data.groups) && data.groups.length) {
        html += `<div class="sbp-rpt-section"><h3>${escHtml(config.groups.label || 'Breakdown')}</h3>`;
        html += renderTable(data.groups, config.groups.columns);
        html += '</div>';
      }

      // Rows (detail table)
      if (config.rows) {
        html += `<div class="sbp-rpt-section"><h3>${escHtml(config.rows.label || 'Details')}</h3>`;
        if (Array.isArray(data.rows) && data.rows.length) {
          html += renderTable(data.rows, config.rows.columns);
        } else {
          html += '<div class="sbp-rpt-empty">No data for this period.</div>';
        }
        html += '</div>';
      }

      body.innerHTML = html || '<div class="sbp-rpt-empty">No data.</div>';
    }

    function renderTable(rows, columns) {
      let html = '<div style="overflow-x:auto"><table class="sbp-rpt-table"><thead><tr>';
      columns.forEach(c => {
        html += `<th>${escHtml(c.label)}</th>`;
      });
      html += '</tr></thead><tbody>';
      rows.forEach(r => {
        html += '<tr>';
        columns.forEach(c => {
          const v = r[c.key];
          html += `<td>${escHtml(applyFmt(v, c.format))}</td>`;
        });
        html += '</tr>';
      });
      html += '</tbody></table></div>';
      return html;
    }

    async function load() {
      const body = root.querySelector('.sbp-rpt-body');
      body.innerHTML = '<div class="sbp-rpt-loading">Loading…</div>';
      try {
        const sb = getSb();
        if (!sb) throw new Error('Supabase client not available');
        const args = { p_shop_id: opts.shopId, p_from_date: from, p_to_date: to };
        if (config.rpc === 'sbp_report_top_customers') args.p_limit = 25;
        const { data, error } = await sb.rpc(config.rpc, args);
        if (error) throw new Error(error.message);
        if (!data || !data.ok) throw new Error((data && data.error) || 'report_failed');
        lastData = data;
        renderBody(data);
      } catch (e) {
        body.innerHTML = `<div class="sbp-rpt-err">⚠ ${escHtml(e.message)}</div>`;
        console.error('[SBPReportViewer]', e);
      }
    }

    function exportCsv() {
      if (!lastData) return;
      const rows = lastData.rows || [];
      const cols = config.rows ? config.rows.columns : [];
      if (!rows.length || !cols.length) {
        alert('No data to export');
        return;
      }
      const csv = rowsToCSV(rows, cols);
      const fname = `${config.rpc}_${from}_to_${to}.csv`;
      downloadCSV(fname, csv);
    }

    shell();
    await load();
  }

  // ─── Public API ──────────────────────────────────────────
  window.SBPReportViewer = {
    render:  render,
    configs: REPORT_CONFIGS,
    fmt:     fmt
  };
})();
