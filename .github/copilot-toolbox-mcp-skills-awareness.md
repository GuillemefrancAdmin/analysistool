# GitHub Copilot Toolbox — MCP & Skills awareness

_Generated: 2026-09-20T15:34:35.248Z_

## How to use this report

- **Saved copy:** This file is **`.github/copilot-toolbox-mcp-skills-awareness.md`** — refreshed whenever the toolbox runs an MCP & Skills scan (including on workspace open when auto-scan is enabled). It is meant for **Copilot workspace context** together with `.github/copilot-instructions.md` (which gets a shorter replaceable summary when auto-merge is on).
- **MCP:** Lists **configured** servers from `mcp.json`. **Live tool use** still requires **Copilot Chat → Agent** with those servers **trusted/started** in the MCP tools UI.
- **Skills:** **On-disk** folders with `SKILL.md`. Copilot does not auto-load them; attach `SKILL.md` or paths in chat when useful.
- **Task routing:** When the user’s request matches a server’s purpose (e.g. Confluence → Confluence/Atlassian MCP), prefer that **server id** from the tables below.

---

## MCP — workspace

Workspace `mcp.json` _(folder: analysistool)_

- **f:\analysistool\.vscode\mcp.json** — _File missing_

_No active workspace servers in mcp.json._

## MCP — user profile

- **C:\Users\francois\AppData\Roaming\Code\User\mcp.json** — _File exists — servers defined_

| Server id | Kind | Detail |
|-----------|------|--------|
| MCP_DOCKER | stdio | docker mcp gateway run --profile uqacdevmcptool |

## Skills (local `SKILL.md` folders)

### Project-scoped

- **openspec-apply-change** — `f:\analysistool\.github\skills\openspec-apply-change`
  - Implement tasks from an OpenSpec change. Use when the user wants to start implementing, continue implementation, or work through tasks.

- **openspec-archive-change** — `f:\analysistool\.github\skills\openspec-archive-change`
  - Archive a completed change in the experimental workflow. Use when the user wants to finalize and archive a change after implementation is complete.

- **openspec-explore** — `f:\analysistool\.github\skills\openspec-explore`
  - Enter explore mode - a thinking partner for exploring ideas, investigating problems, and clarifying requirements. Use when the user wants to think through something before or during a change.

- **openspec-propose** — `f:\analysistool\.github\skills\openspec-propose`
  - Propose a new change with all artifacts generated in one step. Use when the user wants to quickly describe what they want to build and get a complete proposal with design, specs, and tasks ready for implementation.

- **openspec-apply-change** — `f:\analysistool\.claude\skills\openspec-apply-change`
  - Implement tasks from an OpenSpec change. Use when the user wants to start implementing, continue implementation, or work through tasks.

- **openspec-archive-change** — `f:\analysistool\.claude\skills\openspec-archive-change`
  - Archive a completed change in the experimental workflow. Use when the user wants to finalize and archive a change after implementation is complete.

- **openspec-explore** — `f:\analysistool\.claude\skills\openspec-explore`
  - Enter explore mode - a thinking partner for exploring ideas, investigating problems, and clarifying requirements. Use when the user wants to think through something before or during a change.

- **openspec-propose** — `f:\analysistool\.claude\skills\openspec-propose`
  - Propose a new change with all artifacts generated in one step. Use when the user wants to quickly describe what they want to build and get a complete proposal with design, specs, and tasks ready for implementation.

### User-scoped

- **icm-architect** — `C:\Users\francois\.claude\skills\icm-architect`
  - Design any process, idea, problem, or body of knowledge into an ICM (Interpretable Context Methodology) workspace — folder structure as agent architecture — or restructure an existing folder, repo, or vault into one. Use

---

## Suggested next steps

- **MCP:** Command Palette → `MCP: List Servers` (or this extension’s hub **MCP** tab) → start/trust servers in **Copilot Chat → Agent → tools**.
- **Edit config:** `MCP: Open Workspace Folder MCP Configuration` / `MCP: Open User Configuration`.
- **Refresh this report:** run **Intelligence — scan MCP & Skills awareness** again after changing `mcp.json` or adding skills.

_Report from GitHub Copilot Toolbox extension._
