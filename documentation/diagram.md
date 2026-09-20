# Legacy Source Analysis Workflow

┌──────────────────────────────────────────────────┐
│  [ Raw Legacy Source + DDL Schema ]             │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  Agent 0: File Queue Orchestrator & Resume       │
│  - rescans repo each turn                        │
│  - discovers source files                        │
│  - builds one-file-at-a-time queue               │
│  - persists base state in .analysis-state         │
│  - resumes from the last checkpoint              │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  .analysis-state/                                │
│  - queue manifest                                │
│  - per-file state files                          │
│  - checkpoints / recovery metadata               │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  Agent 1: Sanitizer & Context Ingestion Agent   │
│  - cleans legacy code                             │
│  - integrates schema context                     │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  Agent 2: Business Domain Extractor              │
│  - extracts business meaning                     │
│  - identifies workflows and relevant entities    │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  Agent 3: Source AST & Structural Mapper        │
│  - maps procedures, call paths and dependencies │
│  - extracts structure and state patterns         │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  Agent 4: Business Logic Extractor              │
│  - decodes rules, formulas and edge cases       │
│  - captures validation and exception flows       │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  Agent 5: Security & Compliance Analyst         │
│  - checks secrets, PII, auth and injection risk │
│  - evaluates compliance requirements            │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  Agent 6: Performance & Scalability Analyst     │
│  - reviews bottlenecks and resource usage       │
│  - evaluates scaling risk                       │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  Agent 7: Test & Validation Analyst             │
│  - reviews coverage and validation evidence     │
│  - flags known risks and missing proof          │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  Agent 8: Diagram Designer & Context Visualizer │
│  - renders module flow and data context         │
│  - produces Mermaid / draw.io overview          │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  Agent 9: Architecture & Spec Writer            │
│  - consolidates findings                        │
│  - produces structured JSON + markdown report    │
└──────────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────┐
│  Final Architecture Diagram                     │
│  - end-of-workflow system view                  │
│  - target-state architecture and dependencies   │
└──────────────────────────────────────────────────┘
                │
                ▼
[ Final technical specification + structured JSON report + end-of-workflow architecture diagram ]
