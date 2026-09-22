const { marked } = require('marked');

marked.setOptions({ gfm: true, breaks: false });

function renderMarkdown(text) {
  if (!text) return '';
  return marked.parse(text);
}

module.exports = { renderMarkdown };
