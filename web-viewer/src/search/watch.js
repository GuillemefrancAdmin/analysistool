const path = require('path');
const chokidar = require('chokidar');

// Watches the outputs tree and manifest for changes and debounces a full
// index rebuild, per output-search "Search index stays current with
// pipeline output". A full rebuild (not per-file correlation) is used
// because a raw fs event only gives an output *file* path, not the source
// path the index is keyed by, and design.md notes a full rebuild is cheap
// enough at single-codebase scale to run on demand.
function watchAndReindex(analysisStateDir, searchIndex, { debounceMs = 500, onRebuild } = {}) {
  const outputsDir = path.join(analysisStateDir, 'outputs');
  const manifestFile = path.join(analysisStateDir, 'queue', 'manifest.json');

  let timer = null;
  const scheduleRebuild = () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      try {
        searchIndex.build();
        if (onRebuild) onRebuild(null);
      } catch (err) {
        if (onRebuild) onRebuild(err);
      }
    }, debounceMs);
  };

  const watcher = chokidar.watch([outputsDir, manifestFile], {
    ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 50 },
  });

  watcher.on('add', scheduleRebuild);
  watcher.on('change', scheduleRebuild);
  watcher.on('unlink', scheduleRebuild);
  watcher.on('error', (err) => {
    if (onRebuild) onRebuild(err);
  });

  return watcher;
}

module.exports = { watchAndReindex };
