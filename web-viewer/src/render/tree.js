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
// the analyzed source folder layout (output-web-viewer "Navigation mirrors
// the analyzed source tree"). `activePath` highlights the currently open file.
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
    return `<li><span class="folder">${escapeHtml(name)}</span>${renderTree(child, activePath)}</li>`;
  });
  return `<ul class="tree">${items.join('')}</ul>`;
}

module.exports = { renderTree, statusBadge };
