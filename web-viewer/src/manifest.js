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

function readStateFile(projectRoot, entry) {
  if (!entry || !entry.state_file) return null;
  try {
    return JSON.parse(fs.readFileSync(path.join(projectRoot, entry.state_file), 'utf8'));
  } catch (err) {
    return null;
  }
}

// manifest.json entries only carry output_references/blocker_or_error on
// runs made after that field was added to Update-ManifestEntry - older
// completed runs (confirmed present in this repo's own .analysis-state/)
// only have them on the per-file states/*.state.json, which
// analysis-state-persistence guarantees for every processed file. Falling
// back there keeps the viewer working across data from either pipeline
// version instead of silently rendering an empty page.
function resolveOutputReferences(projectRoot, entry) {
  if (Array.isArray(entry.output_references) && entry.output_references.length) {
    return entry.output_references;
  }
  const state = readStateFile(projectRoot, entry);
  return (state && Array.isArray(state.output_references)) ? state.output_references : [];
}

function resolveBlockerOrError(projectRoot, entry) {
  if (entry.blocker_or_error) return entry.blocker_or_error;
  const state = readStateFile(projectRoot, entry);
  return (state && state.blocker_or_error) || null;
}

module.exports = {
  manifestPath,
  loadManifest,
  findEntry,
  statusCounts,
  resolveOutputReferences,
  resolveBlockerOrError,
};
