const { escapeHtml } = require('./layout');
const { renderMarkdown } = require('./markdown');

const SEVERITY_WORDS = new Set([
  'critical', 'high', 'medium', 'low', 'informational',
]);

// Acronyms that should stay upper-cased after humanizeKey's title-casing,
// e.g. "Pii Handling" -> "PII Handling", "Sla Or Availability" -> "SLA Or Availability".
const ACRONYMS = ['Api', 'Cli', 'Csv', 'Db', 'Eol', 'Http', 'Id', 'Io', 'Iso', 'Json', 'Pii', 'Rpc', 'Sdk', 'Sla', 'Sql', 'Url', 'Xml'];
const ACRONYM_RE = new RegExp(`\\b(${ACRONYMS.join('|')})\\b`, 'g');

// Field/key names whose numeric value is a 0-1 (or occasionally 0-100 /
// 1.0-5.0) ratio or score, worth rendering as a bar rather than a bare
// number - matched by name rather than hardcoded per-field since the report
// schema is deliberately treated as a moving target (see renderReport).
const RATIO_KEY_RE = /score|ratio|confidence|index/i;

// "REQ-001 | Retrieve user info" / "ISSUE-001 | Unclear behavior" - the
// pipeline consistently emits list items in this "ID | description" shape
// across functional_requirements, technical_debt_and_code_smells, etc.,
// even though the schema models them as objects. Detecting it generically
// means every such list benefits, without hardcoding per-section handling.
const ID_ITEM_RE = /^([A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+)\s*\|\s*(.+)$/;

function humanizeKey(key) {
  const words = key
    .replace(/_/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase());
  return words.replace(ACRONYM_RE, (m) => m.toUpperCase());
}

function renderIdItem(text) {
  const m = ID_ITEM_RE.exec(text);
  if (!m) return null;
  return `<span class="id-badge">${escapeHtml(m[1])}</span><span class="id-text">${escapeHtml(m[2])}</span>`;
}

// Renders a 0-1 fraction (falling back to a 0-5 or 0-100 scale if the value
// exceeds 1, since both appear in this schema) as a small filled bar next to
// its raw value, so scores/confidence/ratios scan faster than bare decimals.
function renderRatioBar(value) {
  const max = Math.abs(value) > 1 ? (Math.abs(value) > 5 ? 100 : 5) : 1;
  const pct = Math.max(0, Math.min(100, (value / max) * 100));
  return `<span class="ratio-bar"><span class="ratio-fill" style="width:${pct}%"></span></span><span class="ratio-label">${escapeHtml(String(value))}</span>`;
}

function renderScalar(value, key) {
  if (value === null || value === undefined || value === '') {
    return '<span class="muted">&mdash;</span>';
  }
  if (typeof value === 'boolean') {
    return `<span class="badge ${value ? 'badge-yes' : 'badge-no'}">${value ? 'Yes' : 'No'}</span>`;
  }
  if (typeof value === 'number' && key && RATIO_KEY_RE.test(key)) {
    return renderRatioBar(value);
  }
  const text = String(value);
  const lower = text.toLowerCase();
  if (SEVERITY_WORDS.has(lower)) {
    return `<span class="badge severity-${lower}">${escapeHtml(text)}</span>`;
  }
  return escapeHtml(text);
}

// Recursively renders an arbitrary JSON value (the analysis report follows
// templates/source-code-analysis-schema.json, but this stays schema-agnostic
// so it degrades gracefully if the schema evolves) into a readable HTML
// fragment: objects become definition lists, arrays of objects become card
// lists, arrays of scalars become bullet lists, and scalars render inline.
// `key` (the field name this value was found under) is passed through so
// scalars can key formatting decisions - like the ratio bar above - off it.
function renderValue(value, key) {
  if (Array.isArray(value)) {
    if (value.length === 0) return '<span class="muted">None</span>';
    const allScalars = value.every((v) => typeof v !== 'object' || v === null);
    if (allScalars) {
      return `<ul class="value-list">${value.map((v) => {
        const idItem = typeof v === 'string' ? renderIdItem(v) : null;
        return idItem ? `<li class="id-li">${idItem}</li>` : `<li>${renderScalar(v)}</li>`;
      }).join('')}</ul>`;
    }
    return `<div class="card-list">${value.map((v) => `<div class="card">${renderValue(v)}</div>`).join('')}</div>`;
  }
  if (value !== null && typeof value === 'object') {
    const keys = Object.keys(value);
    // {score, findings} - used throughout iso_25010_attributes - reads
    // better as a bar + prose line than a two-row field list.
    if (keys.length === 2 && keys.includes('score') && keys.includes('findings')) {
      return `<div class="score-card"><div class="score-bar-row">${renderValue(value.score, 'score')}</div><div class="score-findings">${renderValue(value.findings, 'findings')}</div></div>`;
    }
    const rows = Object.entries(value)
      .map(([k, v]) => `<dt>${escapeHtml(humanizeKey(k))}</dt><dd>${renderValue(v, k)}</dd>`)
      .join('');
    return `<dl class="field-list">${rows}</dl>`;
  }
  return renderScalar(value, key);
}

// Curated reading order for the report's top-level sections, grouped into
// the categories a reviewer actually thinks in. Anything the schema adds
// later that isn't listed here still renders (see "Additional Details"
// below) - this groups for readability, it doesn't gate on the schema.
const GROUPS = [
  { heading: 'Architecture & Quality', keys: ['architectural_layer', 'quality_metrics', 'iso_25010_attributes'] },
  { heading: 'Functional Requirements', keys: ['functional_requirements'] },
  { heading: 'Risks & Technical Debt', keys: ['technical_debt_and_code_smells', 'security_findings', 'business_impact'] },
  { heading: 'Data & Integrations', keys: ['dependencies_and_integrations', 'data_lineage'] },
  { heading: 'Operations', keys: ['exception_handling', 'test_status'] },
  { heading: 'Modernization Plan', keys: ['modernization_recommendations'] },
];
const GROUPED_KEYS = new Set(GROUPS.flatMap((g) => g.keys));
// module_metadata is rendered as the page's title/purpose/meta strip
// instead (see routes/file.js); markdown_report gets its own prose section.
const EXCLUDED_KEYS = new Set(['module_metadata', 'markdown_report']);

function renderSubsection(key, value) {
  return `
      <section class="report-section">
        <h3>${escapeHtml(humanizeKey(key))}</h3>
        ${renderValue(value)}
      </section>`;
}

// Renders the full parsed report JSON as titled, grouped sections, per
// output-web-viewer "File detail page renders report content".
function renderReport(report) {
  if (!report || typeof report !== 'object') return '';
  const parts = [];

  for (const group of GROUPS) {
    const present = group.keys.filter((k) => Object.prototype.hasOwnProperty.call(report, k));
    if (!present.length) continue;
    parts.push(`
      <div class="section-group">
        <h2 class="group-heading">${escapeHtml(group.heading)}</h2>
        ${present.map((k) => renderSubsection(k, report[k])).join('')}
      </div>`);
  }

  if (report.markdown_report) {
    parts.push(`
      <div class="section-group">
        <h2 class="group-heading">Narrative Report</h2>
        <div class="markdown-body">${renderMarkdown(report.markdown_report)}</div>
      </div>`);
  }

  const leftoverKeys = Object.keys(report).filter((k) => !GROUPED_KEYS.has(k) && !EXCLUDED_KEYS.has(k));
  if (leftoverKeys.length) {
    parts.push(`
      <div class="section-group">
        <h2 class="group-heading">Additional Details</h2>
        ${leftoverKeys.map((k) => renderSubsection(k, report[k])).join('')}
      </div>`);
  }

  return parts.join('\n');
}

module.exports = { renderReport, renderValue, humanizeKey };
