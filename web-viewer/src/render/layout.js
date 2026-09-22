// Filters the sidebar file tree (render/tree.js's sidebarHtml) as you type:
// hides non-matching files, hides folders with no matching descendant, and
// opens the <details> ancestors of whatever still matches. A no-op on pages
// with no .tree-filter (e.g. /search), so this is safe to include always.
const TREE_FILTER_JS = `
document.querySelectorAll('.tree-filter').forEach(function (input) {
  var sidebar = input.closest('.sidebar');
  if (!sidebar) return;
  input.addEventListener('input', function () {
    var query = input.value.trim().toLowerCase();
    sidebar.querySelectorAll('ul.tree li').forEach(function (li) {
      var link = li.querySelector(':scope > a');
      if (link) {
        li.hidden = query !== '' && link.textContent.toLowerCase().indexOf(query) === -1;
        return;
      }
      var details = li.querySelector(':scope > details');
      if (!details) return;
      if (query === '') {
        li.hidden = false;
        details.open = false;
        return;
      }
      var hasMatch = Array.prototype.some.call(details.querySelectorAll('a'), function (a) {
        return a.textContent.toLowerCase().indexOf(query) !== -1;
      });
      li.hidden = !hasMatch;
      if (hasMatch) details.open = true;
    });
  });
});
`;

function escapeHtml(value) {
  return String(value == null ? '' : value).replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  }[ch]));
}

function page({ title, active, body, head = '' }) {
  const nav = [
    ['/', 'Overview'],
    ['/search', 'Search'],
  ]
    .map(([href, label]) => {
      const cls = active === href ? ' class="active"' : '';
      return `<a href="${href}"${cls}>${escapeHtml(label)}</a>`;
    })
    .join('');

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)} - Analysis Output Viewer</title>
<link rel="stylesheet" href="/public/style.css">
${head}
</head>
<body>
<header class="topbar">
  <div class="brand">Analysis Output Viewer</div>
  <nav>${nav}</nav>
</header>
<main>
${body}
</main>
<script>${TREE_FILTER_JS}</script>
</body>
</html>`;
}

module.exports = { page, escapeHtml };
