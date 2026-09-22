# GitHub Copilot instructions








<!-- github-copilot-toolbox:mcp-skills-awareness-begin -->

### MCP & Skills awareness (GitHub Copilot Toolbox)

_Last synced: 2026-09-21T23:12:39.997Z._

- **Full report:** `.github/copilot-toolbox-mcp-skills-awareness.md` in this workspace (auto-overwritten on each scan). Use it as ground truth for configured servers and skill folders.
- **MCP:** For **live tools**, use **Copilot Chat → Agent** and **trust/start** the right servers in the MCP UI.
- **When the user’s task matches a server** (e.g. “open this Confluence page” and a **Confluence** / **Atlassian** MCP is listed), **prefer that server id** and plan on Agent + MCP for actions—not only file search.
- **Skills:** Folders below contain `SKILL.md`; attach or cite paths in chat when relevant.

#### Workspace MCP

- `f:\analysistool\.vscode\mcp.json` _(workspace: analysistool)_ — _file missing_

_No active workspace servers in mcp.json._

#### User MCP

- `C:\Users\francois\AppData\Roaming\Code\User\mcp.json` — _servers defined_

| Server id | Kind | Detail |
|-----------|------|--------|
| MCP_DOCKER | stdio | docker mcp gateway run --profile uqacdevmcptool |

#### Project skills

- **openspec-apply-change** — `f:\analysistool\.github\skills\openspec-apply-change` — Implement tasks from an OpenSpec change. Use when the user wants to start implementing, continue implementation, or work through tasks.

- **openspec-archive-change** — `f:\analysistool\.github\skills\openspec-archive-change` — Archive a completed change in the experimental workflow. Use when the user wants to finalize and archive a change after implementation is complete.

- **openspec-explore** — `f:\analysistool\.github\skills\openspec-explore` — Enter explore mode - a thinking partner for exploring ideas, investigating problems, and clarifying requirements. Use when the user wants to think through something before or during a change.

- **openspec-propose** — `f:\analysistool\.github\skills\openspec-propose` — Propose a new change with all artifacts generated in one step. Use when the user wants to quickly describe what they want to build and get a complete proposal with design, specs, and tasks ready for implementation.

- **openspec-apply-change** — `f:\analysistool\.claude\skills\openspec-apply-change` — Implement tasks from an OpenSpec change. Use when the user wants to start implementing, continue implementation, or work through tasks.

- **openspec-archive-change** — `f:\analysistool\.claude\skills\openspec-archive-change` — Archive a completed change in the experimental workflow. Use when the user wants to finalize and archive a change after implementation is complete.

- **openspec-explore** — `f:\analysistool\.claude\skills\openspec-explore` — Enter explore mode - a thinking partner for exploring ideas, investigating problems, and clarifying requirements. Use when the user wants to think through something before or during a change.

- **openspec-propose** — `f:\analysistool\.claude\skills\openspec-propose` — Propose a new change with all artifacts generated in one step. Use when the user wants to quickly describe what they want to build and get a complete proposal with design, specs, and tasks ready for implementation.

#### User skills

- **icm-architect** — `C:\Users\francois\.claude\skills\icm-architect` — Design any process, idea, problem, or body of knowledge into an ICM (Interpretable Context Methodology) workspace — folder structure as agent architecture — or restructure an existing folder, repo, or vault into one. Use

<!-- github-copilot-toolbox:mcp-skills-awareness-end -->
