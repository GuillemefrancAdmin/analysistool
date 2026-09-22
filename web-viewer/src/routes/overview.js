const express = require('express');
const { loadManifest, statusCounts } = require('../manifest');
const { buildTree } = require('../tree');
const { sidebarHtml, statusBadge } = require('../render/tree');
const { page, escapeHtml } = require('../render/layout');

function overviewRouter(analysisStateDir) {
  const router = express.Router();

  router.get('/', (req, res, next) => {
    let manifest;
    try {
      manifest = loadManifest(analysisStateDir);
    } catch (err) {
      res.status(500).send(page({
        title: 'Overview',
        active: '/',
        body: `<p class="error">Could not read manifest.json: ${escapeHtml(err.message)}</p>
               <p>Expected it at <code>${escapeHtml(analysisStateDir)}/queue/manifest.json</code>. Has the analysis pipeline been run yet?</p>`,
      }));
      return;
    }

    const counts = statusCounts(manifest);
    const tree = buildTree(manifest);

    const summary = Object.entries(counts)
      .map(([status, count]) => `<div class="stat"><div class="stat-count">${count}</div><div class="stat-label">${statusBadge(status)}</div></div>`)
      .join('');

    const rows = manifest.files
      .slice()
      .sort((a, b) => a.path.localeCompare(b.path))
      .map((entry) => `
        <tr>
          <td><a href="/file?path=${encodeURIComponent(entry.path)}">${escapeHtml(entry.path)}</a></td>
          <td>${statusBadge(entry.status)}</td>
          <td>${escapeHtml(entry.last_completed_stage || '')}</td>
          <td>${escapeHtml(entry.last_updated || '')}</td>
        </tr>`)
      .join('');

    const body = `
      <div class="layout-with-sidebar">
        ${sidebarHtml(tree, null)}
        <div class="content">
          <h1>Overview</h1>
          <div class="stat-row">${summary}</div>
          <table class="file-table">
            <thead><tr><th>Source file</th><th>Status</th><th>Last stage</th><th>Updated</th></tr></thead>
            <tbody>${rows}</tbody>
          </table>
        </div>
      </div>`;

    res.send(page({ title: 'Overview', active: '/', body }));
  });

  return router;
}

module.exports = { overviewRouter };
