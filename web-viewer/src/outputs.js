const fs = require('fs');
const path = require('path');
const { resolveOutputReferences } = require('./manifest');

// Categorizes an entry's output_references (relative paths from the project
// root, e.g. ".analysis-state/outputs/GESACAD/cobol/x.scb.json") by kind, and
// loads their content. Missing or unreadable files are simply omitted rather
// than throwing, since a blocked/in-progress file may legitimately have only
// some of these present (analysis-state-persistence: "Output artifacts kept
// self-contained per file").
function loadOutputs(projectRoot, entry) {
  const refs = entry ? resolveOutputReferences(projectRoot, entry) : [];
  const result = { json: null, jsonError: null, markdown: null, diagram: null, raw: null };

  for (const ref of refs) {
    const abs = path.join(projectRoot, ref);
    if (ref.endsWith('.json')) {
      try {
        result.json = JSON.parse(fs.readFileSync(abs, 'utf8'));
      } catch (err) {
        result.jsonError = err.message;
      }
    } else if (ref.endsWith('.md')) {
      try {
        result.markdown = fs.readFileSync(abs, 'utf8');
      } catch (err) {
        // No markdown narrative is a valid, non-error state (spec: "File has
        // no markdown narrative") - leave result.markdown as null.
      }
    } else if (ref.endsWith('.mmd')) {
      try {
        result.diagram = fs.readFileSync(abs, 'utf8');
      } catch (err) {
        // diagram optional
      }
    } else if (ref.endsWith('.raw.txt')) {
      try {
        result.raw = fs.readFileSync(abs, 'utf8');
      } catch (err) {
        // raw fallback optional
      }
    }
  }

  return result;
}

module.exports = { loadOutputs };
