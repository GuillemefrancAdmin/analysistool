const MiniSearch = require('minisearch').default || require('minisearch');
const { loadManifest } = require('../manifest');
const { loadOutputs } = require('../outputs');

const SCHEMA_FIELDS = ['id', 'path', 'text', 'primaryPurpose'];

function buildDocument(projectRoot, entry) {
  if (!entry || entry.status !== 'completed') return null;
  const outputs = loadOutputs(projectRoot, entry);
  // Excludes files without a valid parsed JSON report AND no markdown
  // narrative from the searchable index, per output-search "Search excludes
  // incomplete or invalid reports from indexed content" - a completed status
  // with no readable content isn't useful to index.
  if (!outputs.json && !outputs.markdown) return null;

  const report = outputs.json || {};
  const meta = report.module_metadata || {};
  const textParts = [];
  const severities = new Set();
  const businessRuleTypes = new Set();
  let strategy = null;
  let criticality = null;

  if (meta.primary_purpose) textParts.push(meta.primary_purpose);
  if (meta.file_path) textParts.push(meta.file_path);

  for (const req of report.functional_requirements || []) {
    if (req.title) textParts.push(req.title);
    if (req.description) textParts.push(req.description);
    if (req.business_rule_type) businessRuleTypes.add(req.business_rule_type);
  }

  for (const debt of report.technical_debt_and_code_smells || []) {
    if (debt.description) textParts.push(debt.description);
    if (debt.remediation_strategy) textParts.push(debt.remediation_strategy);
    if (debt.severity) severities.add(debt.severity);
  }

  const security = report.security_findings || {};
  for (const key of Object.keys(security)) {
    if (typeof security[key] === 'string') textParts.push(security[key]);
  }

  const modernization = report.modernization_recommendations || {};
  if (Array.isArray(modernization.step_by_step_migration_plan)) {
    textParts.push(...modernization.step_by_step_migration_plan);
  }
  if (modernization.recommended_7r_strategy) strategy = modernization.recommended_7r_strategy;

  const businessImpact = report.business_impact || {};
  if (businessImpact.operational_risk) textParts.push(businessImpact.operational_risk);
  if (businessImpact.criticality_level) criticality = businessImpact.criticality_level;

  if (outputs.markdown) textParts.push(outputs.markdown);

  return {
    id: entry.path,
    path: entry.path,
    primaryPurpose: meta.primary_purpose || '',
    text: textParts.join('\n'),
    severities: Array.from(severities),
    businessRuleTypes: Array.from(businessRuleTypes),
    strategy,
    criticality,
  };
}

class SearchIndex {
  constructor(projectRoot, analysisStateDir) {
    this.projectRoot = projectRoot;
    this.analysisStateDir = analysisStateDir;
    this.mini = null;
    this.docs = new Map(); // id -> document, used for facet-only browsing and empty queries
    this.lastBuiltAt = null;
  }

  _newMini() {
    return new MiniSearch({
      fields: ['text', 'primaryPurpose', 'path'],
      storeFields: SCHEMA_FIELDS.concat(['severities', 'businessRuleTypes', 'strategy', 'criticality']),
      searchOptions: { prefix: true, fuzzy: 0.2, boost: { primaryPurpose: 2, path: 1.5 } },
    });
  }

  // Full rebuild from current manifest + on-disk outputs. Cheap enough at
  // single-codebase scale (design.md Decision 4) to run entirely on demand.
  build() {
    const manifest = loadManifest(this.analysisStateDir);
    const mini = this._newMini();
    const docs = new Map();
    for (const entry of manifest.files) {
      const doc = buildDocument(this.projectRoot, entry);
      if (doc) {
        docs.set(doc.id, doc);
        mini.add(doc);
      }
    }
    this.mini = mini;
    this.docs = docs;
    this.lastBuiltAt = new Date();
    return this;
  }

  // Incrementally refresh a single file's entry in the index, used by the
  // filesystem watcher (output-search "Search index stays current with
  // pipeline output").
  refreshFile(sourcePath) {
    if (!this.mini) return this.build();
    let manifest;
    try {
      manifest = loadManifest(this.analysisStateDir);
    } catch (err) {
      return; // manifest mid-write; next watcher event will retry
    }
    const entry = manifest.files.find((f) => f.path === sourcePath);
    const existing = this.docs.get(sourcePath);
    if (existing) {
      this.mini.discard(sourcePath);
      this.docs.delete(sourcePath);
    }
    const doc = entry ? buildDocument(this.projectRoot, entry) : null;
    if (doc) {
      this.mini.add(doc);
      this.docs.set(doc.id, doc);
    }
  }

  query({ q = '', severity = '', businessRuleType = '', strategy = '', criticality = '' } = {}) {
    if (!this.mini) this.build();
    let results;
    if (q && q.trim()) {
      results = this.mini.search(q.trim()).map((r) => ({ ...this.docs.get(r.id), score: r.score }));
    } else {
      results = Array.from(this.docs.values())
        .sort((a, b) => a.path.localeCompare(b.path))
        .map((d) => ({ ...d, score: 0 }));
    }
    return results.filter((d) => {
      if (severity && !d.severities.includes(severity)) return false;
      if (businessRuleType && !d.businessRuleTypes.includes(businessRuleType)) return false;
      if (strategy && d.strategy !== strategy) return false;
      if (criticality && d.criticality !== criticality) return false;
      return true;
    });
  }

  facetValues() {
    const severities = new Set();
    const businessRuleTypes = new Set();
    const strategies = new Set();
    const criticalities = new Set();
    for (const doc of this.docs.values()) {
      doc.severities.forEach((s) => severities.add(s));
      doc.businessRuleTypes.forEach((t) => businessRuleTypes.add(t));
      if (doc.strategy) strategies.add(doc.strategy);
      if (doc.criticality) criticalities.add(doc.criticality);
    }
    return {
      severities: Array.from(severities).sort(),
      businessRuleTypes: Array.from(businessRuleTypes).sort(),
      strategies: Array.from(strategies).sort(),
      criticalities: Array.from(criticalities).sort(),
    };
  }
}

module.exports = { SearchIndex, buildDocument };
