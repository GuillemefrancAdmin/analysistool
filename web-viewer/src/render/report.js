const { escapeHtml } = require('./layout');

const SEVERITY_WORDS = new Set([
  'critical', 'high', 'medium', 'low', 'informational',
]);

function humanizeKey(key) {
  return key
    .replace(/_/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

function renderScalar(value) {
  if (value === null || value === undefined || value === '') {
    return '<span class="muted">&mdash;</span>';
  }
  if (typeof value === 'boolean') {
    return `<span class="badge ${value ? 'badge-yes' : 'badge-no'}">${value ? 'Yes' : 'No'}</span>`;
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
function renderValue(value) {
  if (Array.isArray(value)) {
    if (value.length === 0) return '<span class="muted">None</span>';
    const allScalars = value.every((v) => typeof v !== 'object' || v === null);
    if (allScalars) {
      return `<ul class="value-list">${value.map((v) => `<li>${renderScalar(v)}</li>`).join('')}</ul>`;
    }
    return `<div class="card-list">${value.map((v) => `<div class="card">${renderValue(v)}</div>`).join('')}</div>`;
  }
  if (value !== null && typeof value === 'object') {
    const rows = Object.entries(value)
      .map(([k, v]) => `<dt>${escapeHtml(humanizeKey(k))}</dt><dd>${renderValue(v)}</dd>`)
      .join('');
    return `<dl class="field-list">${rows}</dl>`;
  }
  return renderScalar(value);
}

// Renders the full parsed report JSON as a sequence of titled sections, one
// per top-level schema key (module_metadata, functional_requirements,
// security_findings, modernization_recommendations, etc.), per
// output-web-viewer "File detail page renders report content".
function renderReport(report) {
  if (!report || typeof report !== 'object') return '';
  return Object.entries(report)
    .map(([key, value]) => `
      <section class="report-section">
        <h2>${escapeHtml(humanizeKey(key))}</h2>
        ${renderValue(value)}
      </section>`)
    .join('\n');
}

module.exports = { renderReport, renderValue, humanizeKey };
