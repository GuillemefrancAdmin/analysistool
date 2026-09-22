// Builds a folder-tree navigation structure mirroring the analyzed source
// layout (manifest `files[].path` segments), per the output-web-viewer spec
// requirement "Navigation mirrors the analyzed source tree". Each leaf node
// carries the manifest entry for that file.
function buildTree(manifest) {
  const root = { name: '', children: new Map(), entry: null };
  for (const entry of manifest.files) {
    const segments = entry.path.split('/').filter(Boolean);
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
