const path = require('path');
const fs = require('fs');
const express = require('express');

const { SearchIndex } = require('./src/search');
const { watchAndReindex } = require('./src/search/watch');
const { overviewRouter } = require('./src/routes/overview');
const { fileRouter } = require('./src/routes/file');
const { searchRouter } = require('./src/routes/search');

function parseArgs(argv) {
  const opts = {
    root: process.env.VIEWER_ROOT || process.cwd(),
    port: Number(process.env.VIEWER_PORT) || 5173,
    host: process.env.VIEWER_HOST || '127.0.0.1',
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--root') opts.root = argv[++i];
    else if (arg === '--port') opts.port = Number(argv[++i]);
    else if (arg === '--host') opts.host = argv[++i];
  }
  return opts;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const projectRoot = path.resolve(opts.root);
  const analysisStateDir = path.join(projectRoot, '.analysis-state');

  if (!fs.existsSync(analysisStateDir)) {
    console.warn(`Warning: ${analysisStateDir} does not exist yet. The overview page will show an error until the analysis pipeline has been run at least once.`);
  }

  const searchIndex = new SearchIndex(projectRoot, analysisStateDir);
  try {
    searchIndex.build();
  } catch (err) {
    console.warn(`Warning: could not build the initial search index (${err.message}). It will be empty until "Rebuild search index" is used or the manifest becomes readable.`);
  }

  if (fs.existsSync(analysisStateDir)) {
    watchAndReindex(analysisStateDir, searchIndex, {
      onRebuild: (err) => {
        if (err) console.warn(`Search index rebuild failed: ${err.message}`);
      },
    });
  }

  const app = express();
  app.use('/public', express.static(path.join(__dirname, 'public')));
  app.use('/vendor', express.static(path.join(__dirname, 'node_modules', 'mermaid', 'dist')));

  app.use(overviewRouter(analysisStateDir));
  app.use(fileRouter(projectRoot, analysisStateDir));
  app.use(searchRouter(searchIndex));

  app.use((req, res) => {
    res.status(404).send('Not found');
  });

  app.listen(opts.port, opts.host, () => {
    console.log(`Analysis output viewer running at http://${opts.host}:${opts.port}`);
    console.log(`Serving analysis state from: ${analysisStateDir}`);
    if (opts.host === '127.0.0.1' || opts.host === 'localhost') {
      console.log('Bound to localhost only (no authentication is provided by this viewer). To expose it on your network, pass --host 0.0.0.0 explicitly and ensure that is appropriate for your environment.');
    } else {
      console.log(`Bound to ${opts.host} - reachable beyond this machine. This viewer has no authentication; only do this on a trusted network.`);
    }
  });
}

main();
