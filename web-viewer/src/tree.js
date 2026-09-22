// Mirrors scripts/run_analysis_pipeline.ps1's Get-SanitizedRelativeDir,
// which derives each file's actual folder under .analysis-state/outputs/
// from its manifest path - kept in sync by hand since the pipeline (Windows
// PowerShell) and this viewer (Node) don't share code. The sidebar tree is
// built from this same transform so it matches the real output layout on
// disk, rather than the raw, noisier source manifest path (which has an
// inconsistently-cased/named container per system and a redundant nested
// folder that repeats the container's own name).
const SYSTEM_NAME_MAP = {
  'gesacad cobol': 'GESACAD',
  'sigare 4gl': 'SIGARE',
  'sigare web': 'SIGARE-WEB',
};
const REDUNDANT_CONTAINER_SUBFOLDER = {
  'gesacad cobol': 'gesacad',
};

function getOutputSegments(relativePath) {
  let segments = relativePath.split('/').filter(Boolean).map((s) => s.replace(/[:*?"<>|]/g, ''));
  if (segments.length >= 2 && segments[0].toLowerCase() === 'source code') {
    const systemKey = segments[1].toLowerCase();
    const systemName = SYSTEM_NAME_MAP[systemKey] || segments[1];
    let rest = segments.slice(2);
    if (rest.length >= 2 && REDUNDANT_CONTAINER_SUBFOLDER[systemKey] && rest[0].toLowerCase() === REDUNDANT_CONTAINER_SUBFOLDER[systemKey]) {
      rest = rest.slice(1);
    }
    segments = [systemName, ...rest];
  }
  return segments;
}

// Builds a folder-tree navigation structure mirroring the actual
// .analysis-state/outputs/ layout, per the output-web-viewer spec
// requirement "Navigation mirrors the analyzed source tree". Each leaf node
// carries the manifest entry for that file.
function buildTree(manifest) {
  const root = { name: '', children: new Map(), entry: null };
  for (const entry of manifest.files) {
    const segments = getOutputSegments(entry.path);
    let node = root;
    segments.forEach((segment, i) => {
      const isLeaf = i === segments.length - 1;
      if (!node.children.has(segment)) {
        node.children.set(segment, { name: segment, children: new Map(), entry: null });
      }
      node = node.children.get(segment);
      if (isLeaf) node.entry = entry;
    });
  }
  return root;
}

module.exports = { buildTree };
