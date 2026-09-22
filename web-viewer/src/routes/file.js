const express = require('express');
const { loadManifest, findEntry, resolveBlockerOrError } = require('../manifest');
const { loadOutputs } = require('../outputs');
const { buildTree } = require('../tree');
const { sidebarHtml, statusBadge } = require('../render/tree');
const { renderReport } = require('../render/report');
const { renderMarkdown } = require('../render/markdown');
const { page, escapeHtml } = require('../render/layout');
const { diagramToolbarHtml, diagramViewportHtml, diagramInitScript } = require('../render/diagram');

const IN_FLIGHT_STATUSES = new Set(['queued', 'in_progress']);

function withSidebar(tree, activePath, contentHtml) {
  return `
    <div class="layout-with-sidebar">
      ${sidebarHtml(tree, activePath)}
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
    if (entry.status !== 'completed' || !outputs.json) {
      const blockerOrError = resolveBlockerOrError(projectRoot, entry);
      const parts = [`<h1>${escapeHtml(entry.path)}</h1>`, `<p>${statusBadge(entry.status)}</p>`];
      if (blockerOrError) {
        parts.push(`<div class="callout callout-warn"><strong>Blocked:</strong> ${escapeHtml(blockerOrError)}</div>`);
      } else if (outputs.jsonError) {
        parts.push(`<div class="callout callout-warn"><strong>Could not parse report JSON:</strong> ${escapeHtml(outputs.jsonError)}</div>`);
      }
      if (outputs.raw) {
        parts.push(`<h2>Raw output</h2><pre class="raw-output">${escapeHtml(outputs.raw)}</pre>`);
      } else if (!blockerOrError && !outputs.jsonError) {
        parts.push('<p>No report is available for this file yet.</p>');
      }
      res.send(page({ title: entry.path, active: '/', body: withSidebar(tree, sourcePath, parts.join('\n')) }));
      return;
    }

    // Happy path: completed with a valid parsed report.
    const sections = [`<h1>${escapeHtml(entry.path)}</h1>`, `<p>${statusBadge(entry.status)}</p>`];

    const meta = outputs.json && outputs.json.module_metadata;
    if (meta && meta.primary_purpose) {
      sections.push(`<p class="primary-purpose">${escapeHtml(meta.primary_purpose)}</p>`);
    }
    if (meta) {
      const metaItems = [];
      if (meta.programming_language) {
        const lang = meta.language_version ? `${meta.programming_language} (${meta.language_version})` : meta.programming_language;
        metaItems.push(`<span class="meta-item"><strong>Language</strong>${escapeHtml(lang)}</span>`);
      }
      if (meta.module_scope) {
        metaItems.push(`<span class="meta-item"><strong>Scope</strong>${escapeHtml(meta.module_scope)}</span>`);
      }
      if (metaItems.length) {
        sections.push(`<div class="meta-strip">${metaItems.join('')}</div>`);
      }
    }

    if (outputs.diagram) {
      const openHref = `/file/diagram?path=${encodeURIComponent(entry.path)}`;
      sections.push(`
        <div class="section-group">
          <h2 class="group-heading">Diagram</h2>
          ${diagramToolbarHtml({ openHref })}
          ${diagramViewportHtml(outputs.diagram)}
        </div>`);
    }

    if (outputs.markdown) {
      sections.push(`
        <div class="section-group">
          <h2 class="group-heading">Narrative</h2>
          <div class="markdown-body">${renderMarkdown(outputs.markdown)}</div>
        </div>`);
    }
    // else: spec "File has no markdown narrative" - section is simply omitted.

    sections.push(renderReport(outputs.json));

    const head = outputs.diagram
      ? `<script type="module">${diagramInitScript()}</script>`
      : '';

    res.send(page({
      title: entry.path,
      active: '/',
      head,
      body: withSidebar(tree, sourcePath, sections.join('\n')),
    }));
  });

  // Standalone, full-window diagram view for the "Open in new tab" link -
  // re-renders from the same mermaid source with the same controls (wheel
  // zoom, middle-button pan, fit width), rather than a static, uninteractive
  // image.
  router.get('/file/diagram', (req, res) => {
    const sourcePath = req.query.path;
    if (!sourcePath) {
      res.status(400).send('Missing required "path" query parameter.');
      return;
    }

    let manifest;
    try {
      manifest = loadManifest(analysisStateDir);
    } catch (err) {
      res.status(500).send(`Could not read manifest.json: ${escapeHtml(err.message)}`);
      return;
    }

    const entry = findEntry(manifest, sourcePath);
    if (!entry) {
      res.status(404).send(`No manifest entry for "${escapeHtml(sourcePath)}".`);
      return;
    }

    const outputs = loadOutputs(projectRoot, entry);
    if (!outputs.diagram) {
      res.status(404).send('No diagram is available for this file.');
      return;
    }

    res.send(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Diagram - ${escapeHtml(entry.path)}</title>
<link rel="stylesheet" href="/public/style.css">
<script type="module">${diagramInitScript()}</script>
</head>
<body class="diagram-standalone">
${diagramToolbarHtml({ homeHref: '/', sourceName: entry.path })}
${diagramViewportHtml(outputs.diagram)}
</body>
</html>`);
  });

  return router;
}

module.exports = { fileRouter };
