const { escapeHtml } = require('./layout');

// Shared browser-side controller for the mermaid diagram viewport: wheel-to-
// zoom (anchored under the cursor), middle-mouse-button pan, and the zoom/
// fit toolbar buttons. Written once here and reused verbatim by both the
// file detail page's inline diagram and the standalone /file/diagram tab
// (see routes/file.js), so "open in new tab" gets the same controls instead
// of a static, uninteractive image.
const SETUP_DIAGRAM_CONTROLS_JS = `
function setupDiagramControls(root) {
  var viewport = root.querySelector('.diagram-viewport');
  var svg = viewport && viewport.querySelector('svg');
  if (!viewport || !svg) return;

  svg.style.transformOrigin = '0 0';

  // Each node's box label already says what that step does (e.g. "Call
  // timestamp.sh script"); the diagram source's note_* entries - stripped
  // from the visible graph in prepareDiagram() below and passed through as
  // this data-notes map, keyed by the label they followed - add the why
  // (e.g. "Security implications unclear"). Combine both into one tooltip.
  var notesByLabel = {};
  try {
    notesByLabel = JSON.parse(viewport.getAttribute('data-notes') || '{}');
  } catch (e) {
    notesByLabel = {};
  }
  svg.querySelectorAll('.node').forEach(function (node) {
    if (node.querySelector('title')) return;
    var label = (node.textContent || '').replace(/\\s+/g, ' ').trim();
    if (!label) return;
    var note = notesByLabel[label];
    var text = note ? label + ' \\u2014 ' + note : label;
    var title = document.createElementNS('http://www.w3.org/2000/svg', 'title');
    title.textContent = text;
    node.insertBefore(title, node.firstChild);
  });

  // Default view relies on the stylesheet's max-width/max-height: 100% on
  // this svg to contain it within the viewport on both axes (the same
  // technique responsive images use). Zoom just layers a transform on top
  // of that; "fit width" overrides the height cap so the diagram can grow
  // taller than the box.
  var scale = 1;
  function applyZoom() {
    svg.style.transform = scale === 1 ? '' : 'scale(' + scale + ')';
  }
  function fitToWidth() {
    scale = 1;
    svg.style.transform = '';
    svg.style.maxHeight = 'none';
    svg.style.width = '100%';
    svg.style.height = 'auto';
  }

  root.querySelectorAll('[data-diagram-action]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var action = btn.getAttribute('data-diagram-action');
      if (action === 'zoom-in') {
        scale = Math.min(6, scale * 1.25);
        applyZoom();
      } else if (action === 'zoom-out') {
        scale = Math.max(0.2, scale / 1.25);
        applyZoom();
      } else if (action === 'fit') {
        fitToWidth();
      }
    });
  });

  // Scroll wheel zooms (anchored under the cursor, like a map) instead of
  // scrolling the page; preventDefault needs a non-passive listener since
  // it overrides native scroll here.
  viewport.addEventListener('wheel', function (e) {
    e.preventDefault();
    var rect = viewport.getBoundingClientRect();
    var offsetX = e.clientX - rect.left + viewport.scrollLeft;
    var offsetY = e.clientY - rect.top + viewport.scrollTop;
    var prevScale = scale;
    scale = Math.max(0.2, Math.min(6, scale * (e.deltaY < 0 ? 1.1 : 1 / 1.1)));
    applyZoom();
    var ratio = scale / prevScale;
    viewport.scrollLeft = offsetX * ratio - (e.clientX - rect.left);
    viewport.scrollTop = offsetY * ratio - (e.clientY - rect.top);
  }, { passive: false });

  // Middle mouse button drag pans the viewport.
  var pan = null;
  viewport.addEventListener('mousedown', function (e) {
    if (e.button !== 1) return;
    e.preventDefault();
    pan = { x: e.clientX, y: e.clientY, left: viewport.scrollLeft, top: viewport.scrollTop };
    viewport.style.cursor = 'grabbing';
  });
  window.addEventListener('mousemove', function (e) {
    if (!pan) return;
    viewport.scrollLeft = pan.left - (e.clientX - pan.x);
    viewport.scrollTop = pan.top - (e.clientY - pan.y);
  });
  window.addEventListener('mouseup', function (e) {
    if (e.button !== 1 || !pan) return;
    pan = null;
    viewport.style.cursor = '';
  });
  // Middle-click often fires a paste (Linux/X11) or opens a link in a new
  // tab (auxclick) after the drag; suppress both here.
  viewport.addEventListener('auxclick', function (e) {
    if (e.button === 1) e.preventDefault();
  });
}
`;

// The diagram generator emits each real node's rationale as a separate
// note_<slug>["note '...'"] node declared right after it, with no edge
// connecting them - meant as an annotation, but mermaid still renders it as
// its own floating box, cluttering the graph. This walks the raw source in
// declaration order, pairs each note with the label of the node declared
// immediately before it, and returns that pairing plus the source with the
// standalone note-node lines removed (their text becomes a tooltip instead
// - see the data-notes wiring in diagramViewportHtml/setupDiagramControls).
function prepareDiagram(source) {
  const notesByLabel = {};
  const nodeDefRe = /([A-Za-z_]\w*)\s*\[(?:"([^"]*)"|'([^']*)')\]/g;
  let lastLabel = null;
  let match = nodeDefRe.exec(source);
  while (match) {
    const id = match[1];
    const label = match[2] !== undefined ? match[2] : match[3];
    if (id.startsWith('note_')) {
      const noteMatch = /^note\s*'(.*)'$/i.exec(label);
      const noteText = (noteMatch ? noteMatch[1] : label).trim();
      const existing = notesByLabel[lastLabel];
      if (lastLabel && noteText && (!existing || !existing.includes(noteText))) {
        notesByLabel[lastLabel] = existing ? `${existing}; ${noteText}` : noteText;
      }
    } else {
      lastLabel = label;
    }
    match = nodeDefRe.exec(source);
  }

  const cleanedSource = source
    .split('\n')
    .filter((line) => !/^\s*[A-Za-z_]\w*\["note '.*'"\]\s*$/i.test(line))
    .join('\n');

  return { cleanedSource, notesByLabel };
}

// `openHref`, when given, adds an "Open in new tab" link (used on the file
// detail page). `homeHref`/`sourceName`, when given, add a Home link and the
// source file's path (used on the standalone /file/diagram tab, which - as
// its own browser tab - otherwise has no indication of which file it's for
// or way back to the app; the inline diagram on the file detail page needs
// neither, since the page title already covers both).
function diagramToolbarHtml({ openHref, homeHref, sourceName } = {}) {
  const homeBtn = homeHref
    ? `<a class="diagram-btn" href="${homeHref}" title="Back to Overview">&#8962; Home</a>`
    : '';
  const sourceLabel = sourceName
    ? `<span class="diagram-source-name" title="${escapeHtml(sourceName)}">${escapeHtml(sourceName)}</span>`
    : '';
  const openBtn = openHref
    ? `<a class="diagram-btn" href="${openHref}" target="_blank" rel="noopener" title="Open diagram in a new tab">Open in new tab &#8599;</a>`
    : '';
  return `
      <div class="diagram-toolbar">
        ${homeBtn}
        ${sourceLabel}
        <button type="button" class="diagram-btn" data-diagram-action="zoom-out" title="Zoom out">&minus;</button>
        <button type="button" class="diagram-btn" data-diagram-action="zoom-in" title="Zoom in">+</button>
        <button type="button" class="diagram-btn" data-diagram-action="fit" title="Resize to fit page width">Fit width</button>
        ${openBtn}
      </div>`;
}

function diagramViewportHtml(diagramSource) {
  const { cleanedSource, notesByLabel } = prepareDiagram(diagramSource);
  return `
      <div class="diagram-viewport" data-notes="${escapeHtml(JSON.stringify(notesByLabel))}">
        <pre class="mermaid">${escapeHtml(cleanedSource)}</pre>
      </div>`;
}

// Module script content (without the surrounding <script> tag) that
// initializes mermaid and wires up setupDiagramControls once rendering
// finishes. Shared between the file detail page's head script and the
// standalone diagram tab's page.
function diagramInitScript() {
  return `
      import mermaid from '/vendor/mermaid.esm.min.mjs';
      // Some generated diagrams enumerate thousands of raw source
      // statements as edges (observed up to ~3400 in this codebase);
      // mermaid's default cap is 500 and silently refuses to render
      // above it, so this must stay generous.
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', maxEdges: 20000 });

      ${SETUP_DIAGRAM_CONTROLS_JS}

      // startOnLoad is off so mermaid.run()'s promise tells us when the SVG
      // actually lands in the DOM, before wiring up controls that need to
      // read/transform it.
      mermaid.run({ querySelector: '.diagram-viewport .mermaid' }).then(() => {
        setupDiagramControls(document);
      });
    `;
}

module.exports = { diagramToolbarHtml, diagramViewportHtml, diagramInitScript };
