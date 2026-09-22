const fs = require('fs');
const path = require('path');

function manifestPath(analysisStateDir) {
  return path.join(analysisStateDir, 'queue', 'manifest.json');
}

// Reads manifest.json fresh from disk on every call. The manifest is small
// (one entry per source file) and is the live, mutable index per
// analysis-state-persistence, so re-reading avoids ever serving stale state.
function loadManifest(analysisStateDir) {
  const file = manifestPath(analysisStateDir);
  const raw = fs.readFileSync(file, 'utf8');
  const data = JSON.parse(raw);
  data.files = Array.isArray(data.files) ? data.files : [];
  return data;
}

function findEntry(manifest, sourcePath) {
  return manifest.files.find((f) => f.path === sourcePath) || null;
}

function statusCounts(manifest) {
  const counts = { queued: 0, in_progress: 0, blocked: 0, completed: 0, failed: 0 };
  for (const f of manifest.files) {
    if (Object.prototype.hasOwnProperty.call(counts, f.status)) {
      counts[f.status] += 1;
    }
  }
  return counts;
}

module.exports = { manifestPath, loadManifest, findEntry, statusCounts };
