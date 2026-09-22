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
</body>
</html>`;
}

module.exports = { page, escapeHtml };
