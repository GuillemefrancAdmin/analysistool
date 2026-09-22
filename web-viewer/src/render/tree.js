const { escapeHtml } = require('./layout');

const STATUS_LABELS = {
  completed: 'completed',
  blocked: 'blocked',
  in_progress: 'in progress',
  queued: 'queued',
  failed: 'failed',
};

function statusBadge(status) {
  const label = STATUS_LABELS[status] || status || 'unknown';
  return `<span class="badge status-${escapeHtml(status || 'unknown')}">${escapeHtml(label)}</span>`;
}

// Renders the nav tree built by src/tree.js as nested <ul> markup, mirroring
// the analyzed output folder layout (output-web-viewer "Navigation mirrors
// the analyzed source tree"). `activePath` highlights the currently open
// file. Folders use <details>/<summary> so they can be expanded/collapsed
// natively, no JS required; all start collapsed, regardless of activePath.
function renderTree(node, activePath) {
  const folderNames = Array.from(node.children.keys()).sort((a, b) => a.localeCompare(b));
  if (folderNames.length === 0) return '';
  const items = folderNames.map((name) => {
    const child = node.children.get(name);
    if (child.entry && child.children.size === 0) {
      const entry = child.entry;
      const cls = entry.path === activePath ? ' class="active"' : '';
      const href = `/file?path=${encodeURIComponent(entry.path)}`;
      return `<li><a href="${href}"${cls}>${escapeHtml(name)}</a> ${statusBadge(entry.status)}</li>`;
    }
    return `<li><details><summary class="folder">${escapeHtml(name)}</summary>${renderTree(child, activePath)}</details></li>`;
  });
  return `<ul class="tree">${items.join('')}</ul>`;
}

// Full sidebar markup: the filter textbox (wired up client-side by the
// script in render/layout.js's page()) plus the tree itself. Shared by
// routes/overview.js and routes/file.js so both stay in sync.
function sidebarHtml(tree, activePath) {
  return `
    <aside class="sidebar">
      <h3>Files</h3>
      <input type="search" class="tree-filter" placeholder="Filter files..." aria-label="Filter files by name">
      ${renderTree(tree, activePath)}
    </aside>`;
}

module.exports = { renderTree, sidebarHtml, statusBadge };
