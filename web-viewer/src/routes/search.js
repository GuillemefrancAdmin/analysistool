const express = require('express');
const { page, escapeHtml } = require('../render/layout');

function facetSelect(name, label, options, selected) {
  const opts = ['<option value="">Any</option>']
    .concat(options.map((o) => `<option value="${escapeHtml(o)}"${o === selected ? ' selected' : ''}>${escapeHtml(o)}</option>`))
    .join('');
  return `<label class="facet">${escapeHtml(label)}<select name="${name}">${opts}</select></label>`;
}

function searchRouter(searchIndex) {
  const router = express.Router();

  router.get('/search', (req, res) => {
    const q = req.query.q || '';
    const severity = req.query.severity || '';
    const businessRuleType = req.query.businessRuleType || '';
    const strategy = req.query.strategy || '';
    const criticality = req.query.criticality || '';

    const results = searchIndex.query({ q, severity, businessRuleType, strategy, criticality });
    const facets = searchIndex.facetValues();

    const resultsHtml = results.length
      ? `<ul class="search-results">${results.map((r) => `
          <li>
            <a href="/file?path=${encodeURIComponent(r.path)}">${escapeHtml(r.path)}</a>
            ${r.primaryPurpose ? `<p class="muted">${escapeHtml(r.primaryPurpose)}</p>` : ''}
            <p class="facet-tags">
              ${r.severities.map((s) => `<span class="badge severity-${escapeHtml(s)}">${escapeHtml(s)}</span>`).join(' ')}
              ${r.strategy ? `<span class="badge badge-strategy">${escapeHtml(r.strategy)}</span>` : ''}
              ${r.criticality ? `<span class="badge severity-${escapeHtml(r.criticality)}">${escapeHtml(r.criticality)}</span>` : ''}
            </p>
          </li>`).join('')}</ul>`
      : `<p class="muted">No matching analyzed files.${(q || severity || businessRuleType || strategy || criticality) ? '' : ' Run the analysis pipeline, or check back once files have completed.'}</p>`;

    const body = `
      <h1>Search analysis outputs</h1>
      <form method="get" action="/search" class="search-form">
        <input type="search" name="q" value="${escapeHtml(q)}" placeholder="Search narratives, business rules, findings..." autofocus>
        <div class="facet-row">
          ${facetSelect('severity', 'Severity', facets.severities, severity)}
          ${facetSelect('businessRuleType', 'Business rule type', facets.businessRuleTypes, businessRuleType)}
          ${facetSelect('strategy', '7R strategy', facets.strategies, strategy)}
          ${facetSelect('criticality', 'Criticality', facets.criticalities, criticality)}
        </div>
        <button type="submit">Search</button>
      </form>
      <form method="post" action="/search/reindex" class="reindex-form">
        <button type="submit">Rebuild search index</button>
        ${searchIndex.lastBuiltAt ? `<span class="muted">Last built: ${escapeHtml(searchIndex.lastBuiltAt.toISOString())}</span>` : ''}
      </form>
      <p class="muted">${results.length} result${results.length === 1 ? '' : 's'}</p>
      ${resultsHtml}
    `;

    res.send(page({ title: 'Search', active: '/search', body }));
  });

  router.post('/search/reindex', (req, res) => {
    searchIndex.build();
    res.redirect('/search');
  });

  return router;
}

module.exports = { searchRouter };
