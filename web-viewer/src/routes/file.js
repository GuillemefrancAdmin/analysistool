const express = require('express');
const { loadManifest, findEntry } = require('../manifest');
const { loadOutputs } = require('../outputs');
const { buildTree } = require('../tree');
const { renderTree, statusBadge } = require('../render/tree');
const { renderReport } = require('../render/report');
const { renderMarkdown } = require('../render/markdown');
const { page, escapeHtml } = require('../render/layout');

const IN_FLIGHT_STATUSES = new Set(['queued', 'in_progress']);

function withSidebar(tree, activePath, contentHtml) {
  return `
    <div class="layout-with-sidebar">
      <aside class="sidebar">
        <h3>Files</h3>
        ${renderTree(tree, activePath)}
      </aside>
      <div class="content">${contentHtml}</div>
    </div>`;
}

function fileRouter(projectRoot, analysisStateDir) {
  const router = express.Router();

  router.get('/file', (req, res) => {
    const sourcePath = req.query.path;
    if (!sourcePath) {
      res.status(400).send(page({ title: 'File', active: '/', body: '<p class="error">Missing required "path" query parameter.</p>' }));
      return;
    }

    let manifest;
    try {
      manifest = loadManifest(analysisStateDir);
    } catch (err) {
      res.status(500).send(page({ title: 'File', active: '/', body: `<p class="error">Could not read manifest.json: ${escapeHtml(err.message)}</p>` }));
      return;
    }

    const entry = findEntry(manifest, sourcePath);
    const tree = buildTree(manifest);

    if (!entry) {
      res.status(404).send(page({
        title: 'Not found',
        active: '/',
        body: withSidebar(tree, sourcePath, `<h1>File not found</h1><p>No manifest entry for <code>${escapeHtml(sourcePath)}</code>.</p>`),
      }));
      return;
    }

    // Spec: "File still queued or in progress" - don't attempt to render a
    // report for files that haven't completed analysis yet.
    if (IN_FLIGHT_STATUSES.has(entry.status)) {
      const body = `
        <h1>${escapeHtml(entry.path)}</h1>
        <p>${statusBadge(entry.status)}</p>
        <p>This file has not yet completed analysis${entry.last_completed_stage ? ` (last completed stage: <code>${escapeHtml(entry.last_completed_stage)}</code>)` : ''}. Check back once the pipeline has processed it.</p>`;
      res.send(page({ title: entry.path, active: '/', body: withSidebar(tree, sourcePath, body) }));
      return;
    }

    const outputs = loadOutputs(projectRoot, entry);

    // Spec: "Graceful handling of blocked or invalid output" - covers both
    // an explicitly blocked status and a completed entry whose JSON somehow
    // didn't parse, rather than erroring or showing a blank page.
    if (entry.status !== 'completed' || (!outputs.json && (outputs.jsonError || outputs.raw))) {
      const parts = [`<h1>${escapeHtml(entry.path)}</h1>`, `<p>${statusBadge(entry.status)}</p>`];
      if (entry.blocker_or_error) {
        parts.push(`<div class="callout callout-warn"><strong>Blocked:</strong> ${escapeHtml(entry.blocker_or_error)}</div>`);
      } else if (outputs.jsonError) {
        parts.push(`<div class="callout callout-warn"><strong>Could not parse report JSON:</strong> ${escapeHtml(outputs.jsonError)}</div>`);
      }
      if (outputs.raw) {
        parts.push(`<h2>Raw output</h2><pre class="raw-output">${escapeHtml(outputs.raw)}</pre>`);
      } else if (!entry.blocker_or_error && !outputs.jsonError) {
        parts.push('<p>No report is available for this file yet.</p>');
      }
      res.send(page({ title: entry.path, active: '/', body: withSidebar(tree, sourcePath, parts.join('\n')) }));
      return;
    }

    // Happy path: completed with a valid parsed report.
    const sections = [`<h1>${escapeHtml(entry.path)}</h1>`, `<p>${statusBadge(entry.status)}</p>`];

    if (outputs.diagram) {
      sections.push(`
        <section class="report-section">
          <h2>Diagram</h2>
          <pre class="mermaid">${escapeHtml(outputs.diagram)}</pre>
        </section>`);
    }

    if (outputs.markdown) {
      sections.push(`
        <section class="report-section">
          <h2>Narrative</h2>
          <div class="markdown-body">${renderMarkdown(outputs.markdown)}</div>
        </section>`);
    }
    // else: spec "File has no markdown narrative" - section is simply omitted.

    sections.push(renderReport(outputs.json));

    const head = outputs.diagram
      ? `<script type="module">
           import mermaid from '/vendor/mermaid.esm.min.mjs';
           mermaid.initialize({ startOnLoad: true, securityLevel: 'strict' });
         </script>`
      : '';

    res.send(page({
      title: entry.path,
      active: '/',
      head,
      body: withSidebar(tree, sourcePath, sections.join('\n')),
    }));
  });

  return router;
}

module.exports = { fileRouter };
