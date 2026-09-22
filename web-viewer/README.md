# Analysis Output Viewer

A local, read-only web UI for browsing and searching the analysis outputs the
pipeline writes under `.analysis-state/outputs/`.

## Requirements

- [Node.js](https://nodejs.org/) (npm included). This is the only new runtime
  dependency introduced by the viewer; the analysis pipeline itself remains
  PowerShell-only.

## Running it

From the repo root:

```powershell
.\scripts\run_output_viewer.ps1
```

This installs npm dependencies on first run, then starts the server at
`http://127.0.0.1:5173` by default. Options:

```powershell
.\scripts\run_output_viewer.ps1 -Port 8080
.\scripts\run_output_viewer.ps1 -BindHost 0.0.0.0   # opt into network exposure - see below
```

Or run it directly with Node:

```
node web-viewer/server.js --root <path-to-repo> --port 5173 --host 127.0.0.1
```

## What it shows

- **Overview** (`/`): every file tracked in `.analysis-state/queue/manifest.json`
  with its status, plus a folder tree mirroring the analyzed source layout.
- **File detail** (`/file?path=...`): the rendered `<file>.md` narrative, the
  structured `<file>.json` report, and `diagram.mmd` rendered as a diagram.
  Blocked or still-in-progress files show their status and any available raw
  output instead of erroring.
- **Search** (`/search`): full-text search across all completed files'
  narratives and report content, with filters for severity, business rule
  type, recommended 7R strategy, and criticality level. The index refreshes
  automatically as the pipeline completes new files; a "Rebuild search
  index" button is available as a manual fallback.

## Security note

The viewer has **no authentication**. It is intended for trusted internal use
only, the same trust boundary as the `.analysis-state/outputs/` folder itself
today - the analysis reports it displays include security findings,
credential/secret-usage notes, and PII-handling assessments about the
analyzed legacy systems. It binds to `127.0.0.1` (localhost) by default;
exposing it more broadly (`-BindHost 0.0.0.0` / a non-loopback `--host`) is an
explicit, unsupported-by-default choice left to the operator.

The viewer only reads `.analysis-state/`; it does not start, stop, or modify
pipeline runs.
