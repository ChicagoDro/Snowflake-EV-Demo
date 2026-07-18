# EV Demo — Presentation Script
## Partner Solutions Architect Interview Demo (60 Minutes)

---

## Format (60 Minutes)
| Time | Section | Focus |
|------|---------|-------|
| 10 min | Overview Slides | Use case, architecture, trade-offs, business value vs. Spark/Lakehouse |
| 20 min | Demo Part 1 | Data engineering pipeline — transformations, orchestration, open table formats, data sharing |
| 15 min | Demo Part 2 | Semantic model and conversational analytics with Streamlit |
| 15 min | Q&A | Panel questions |

---

## Deliverables Checklist (confirm all are covered)
- [x] End-to-end Snowflake data engineering pipeline (Bronze/Silver/Gold)
- [x] Transformation implementation with justification
- [x] Open table format (Iceberg) for interoperability
- [x] Data sharing configuration
- [x] Orchestration implementation
- [x] Data quality checks
- [x] Semantic model with Streamlit chat interface
- [x] Architecture documentation (data flow, tech choices, orchestration, CI/CD)
- [x] GitHub repository with all source code

---

## Slides to Prepare (10 min section)

### Slide 1: Title
- **WA State EV Registration Pipeline**
- Subtitle: "A Medallion Architecture for Measuring Progress Toward the 2030 Goal"
- Your name, Partner SA candidate

### Slide 2: The Problem & Business Value
- Washington State targets 1M EVs by 2030
- Legislature needs governed, trustworthy data to measure progress
- Data arrives from multiple systems at different cadences
- **Business value:** Replace manual quarterly reports with real-time, self-service analytics
- **Why Snowflake over Spark/Lakehouse:** Managed platform = lower ops burden for a state agency; Iceberg gives them the open format escape hatch without the infrastructure tax

### Slide 3: Architecture Diagram (KEY SLIDE)
- Visual showing the full flow:
  ```
  [Azure Blob CSV] → Stage → COPY INTO → Bronze (VARIANT)
                                              ↓ Snowpark Parse
  [PostgreSQL CDC] → Connector Agent → EV_DEMO."public" (CDC)
                                              ↓
  [SQL Seeds] ────────────────────→ EV_DEMO.RAW (Reference)
                                              ↓
                              Silver (Dynamic Tables) ← joins all sources
                                              ↓
                              Gold (Dynamic Iceberg Tables on Azure Blob)
                                              ↓
                    ┌─────────────────────────────────────────────┐
                    │  Semantic View → Cortex Agent → Streamlit   │
                    │  Secure Views → SHARE → Cross-account       │
                    │  Iceberg → Spark/Trino (external compute)   │
                    └─────────────────────────────────────────────┘
  ```
- Label each component with the Snowflake feature

### Slide 4: Tool Selection & Alternatives Considered
| Need | Tool Choice | Alternative Considered | Why This Choice |
|------|-------------|----------------------|-----------------|
| Raw landing | VARIANT + COPY INTO | Snowpipe | Batch is sufficient for this cadence; Snowpipe adds cost for low-volume |
| Parsing | Snowpark Python SP | SQL FLATTEN | JSON has dynamic column metadata; Snowpark adapts at runtime |
| CDC ingestion | SF Connector for PostgreSQL | Custom Snowpipe + Kafka | Managed = zero custom code; OpenFlow in production |
| Static reference | SQL CREATE + INSERT | dbt seeds / COPY INTO | Small static data (26 rows total); no external tooling dependency; version-controlled in git |
| Silver | Dynamic Tables | dbt incremental + Tasks | Declarative refresh, no scheduling code, Snowflake-managed |
| Gold | Dynamic Iceberg Tables | Regular tables | Open format for external compute; cost separation |
| Orchestration | Stream + Task graph | Airflow / dbt Cloud | Native, no external tool; event-driven not time-based |
| Quality | DMFs | Great Expectations / dbt tests | Native scheduling, integrated with Snowflake monitoring UI |
| Sharing | Secure Views + Shares | ETL to consumer's account | Zero-copy, real-time, governed |
| Analytics | Cortex Analyst + Agent | Tableau / Power BI | No BI tool dependency; NL interface for non-technical users |
| Dev workflow | Cortex Code (CoCo) | Manual SQL authoring | Iterative, context-aware, accelerates development 3-5x |

### Slide 5: Orchestration Approach
- **Event-driven:** Directory Table Stream detects new files on stage
- **Task graph:** TASK_INGEST_RAW → TASK_PARSE_BRONZE → (Dynamic Tables auto-refresh)
- **Error handling:** Task logs failures to OBS.TASK_RUN_LOG; DMFs fire alerts on quality breach
- **Comparison to Airflow:** No external scheduler to maintain; native Snowflake retry/dependency handling
- **Dynamic Tables vs. Tasks for Silver/Gold:** "I let Snowflake decide when to refresh based on data staleness, not a cron"

### Slide 6: Cost Optimization
- XSMALL warehouse, 60s auto-suspend (right-sized; no idle burn)
- Dynamic Tables = compute only when upstream changes (not on schedule)
- Iceberg = storage-compute separation (Azure Blob pricing vs. Snowflake managed storage)
- CDC at 15-min intervals (not continuous streaming — right-sized for the data cadence)
- Static reference data loaded once via SQL (zero ongoing compute cost; source CSVs in Git for auditability)
- Stream + Task = event-driven (no polling; warehouse sleeps when no files arrive)
- Role separation (EV_DEMO_ENGINEER) prevents accidental ACCOUNTADMIN compute usage

### Slide 7: CI/CD & Governance
- Git-connected Snowflake Workspace (bidirectional sync)
- Purpose-scoped role (EV_DEMO_ENGINEER) avoids ACCOUNTADMIN drift
- SQL-based reference data with CSVs in Git for auditability
- Secure views + SHARE object for governed cross-account access
- DMFs as automated quality attestation (auditors can see SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS)

---

## Demo Part 1: Data Engineering Pipeline (20 min)

### 1a. Bronze Layer — Ingestion & Parsing (5 min)
- Open `demo/demo_verification_queries.sql` in Snowsight
- Run BRONZE section: show raw VARIANT record, then parsed table

**Say:** "Bronze is our immutable, auditable landing zone. Raw JSON with load timestamp and source filename — we never transform in place. The Snowpark procedure reads column metadata from the JSON itself and maps dynamically. If the state adds a field to their export, the procedure adapts without code changes."

**Say:** "I chose Snowpark Python over SQL FLATTEN because the source uses positional arrays with a column-name mapping in metadata. SQL would require hardcoded indices. The Snowpark proc builds the mapping at runtime."

### 1b. CDC Replication (3 min)
- Run CDC section: incentive_applications counts by status, REPLICATION_STATE

**Say:** "This is a real Azure Database for PostgreSQL Flexible Server, replicating via the Snowflake Connector for PostgreSQL. The agent runs as a Docker container, reading WAL logs and pushing changes every 15 minutes."

**Say:** "I chose CDC here because incentive applications change daily — statuses flip from PENDING to APPROVED or DENIED. For static reference data like zip demographics, I use direct SQL loads from version-controlled CSVs. Right tool for the right data cadence."

**Say:** "In production, this would be OpenFlow — the GA successor with NiFi-based visual flow design and SPCS deployment. Trial accounts don't have access, but the pattern is identical."

### 1c. Silver — Dynamic Tables & Transformations (4 min)
- Run SILVER section: enriched rows, quarantine breakdown, Dynamic Table refresh status

**Say:** "Silver joins three sources: batch registrations from Bronze, CDC incentive data, and static reference tables (demographics and state goals). It deduplicates by VIN, standardizes text, parses geospatial data, and validates business rules."

**Say:** "You'll notice Bronze has 22,000 rows but Silver has about 5,000. That's deduplication at work — the state's export contains multiple snapshots of the same vehicle over time. Silver keeps one row per VIN, the latest record. This is intentional, not data loss."

**Say:** "Invalid rows don't disappear — they route to a quarantine table with a REJECTION_REASON column. The reconciliation is: distinct VINs in Bronze = Silver + Quarantine. Every vehicle is accounted for."

**Say:** "Dynamic Tables handle refresh automatically. TARGET_LAG of 60 minutes means Snowflake decides when to recompute based on upstream changes. I don't manage cron schedules or incremental logic — it's declarative."

### 1d. Gold — Iceberg Tables & Open Format (4 min)
- Run GOLD section: dim/fact counts, business insight query

**Say:** "Gold is a star schema on Dynamic Iceberg Tables. External volume on Azure Blob means this data is stored in open Parquet/Iceberg format. The legislature's data science team can query it from Spark, Trino, or Databricks without going through Snowflake."

**Say:** "This is the interoperability story: Snowflake manages the lifecycle and freshness, but the data isn't locked in. If the agency ever decides to bring their own compute, the data is portable."

**Say:** "Cost angle: Iceberg on external volume means storage is at Azure Blob pricing, not Snowflake managed storage rates. For a multi-terabyte Gold layer, that's significant savings."

### 1e. Orchestration (2 min)
- Show Task graph structure (or run INFORMATION_SCHEMA query for tasks)

> **DEMOER PREP:** Before this section, upload a new JSON file (different filename) to
> `@EV_DEMO.RAW.EV_STAGE`, then run `demo/force_pipeline_run.sql` to push data through
> all layers immediately. Dynamic Tables have TARGET_LAG of 60-120 minutes — the force
> script bypasses the wait so you can show fresh data in real-time during the demo.

**Say:** "The pipeline is event-driven: a Directory Table Stream watches the stage for new files. When a file lands, TASK_INGEST_RAW fires, then TASK_PARSE_BRONZE runs after it completes. Dynamic Tables handle Silver and Gold refresh on their own."

**Say:** "Compared to Airflow: no external scheduler to deploy, no DAG code to maintain, no separate monitoring. Everything is native, observable in Snowsight, and costs nothing when idle."

### 1f. Data Sharing & Quality (2 min)
- Mention the SHARE configuration and DMFs

**Say:** "Gold is exposed via a Secure View in a SHARE object — zero-copy, real-time, governed. A partner agency can access it without data movement or ETL. In production, I'd publish this as a Marketplace listing."

**Say:** "Quality is automated: DMFs check completeness, uniqueness, freshness, and row-count reconciliation on a schedule. If Silver + Quarantine doesn't equal Bronze, an alert fires. This gives the legislature confidence the numbers are trustworthy."

---

## Demo Part 2: Semantic Model & Conversational Analytics (15 min)

### 2a. Semantic View Design (3 min)
- Show `semantic/ev_registrations.yaml` (or describe the structure)

**Say:** "The semantic view sits on top of Gold and the CDC table. It defines business-friendly names, metrics, time grains, and relationships. This is what enables natural language queries without the user knowing SQL or table structures."

**Say:** "I designed it to cover three personas: executives asking about goal progress, marketing asking about market share, and operations asking about incentive program effectiveness."

### 2b. Cortex Agent Demo (7 min)
- Open Streamlit app → Tab 2 (Chat)
- Ask these questions in sequence:

1. **"How are we tracking against the 2030 goal?"**
   - Shows progress metric, references AGG_REGISTRATIONS_BY_YEAR
   - **Say:** "Executive question — the agent pulls from the Gold aggregate and compares to the target."

2. **"What is the incentive approval rate by zip code?"**
   - Shows CDC data in action
   - **Say:** "This hits the CDC-replicated table directly. As applications get approved in Postgres, the numbers here update within 15 minutes."

3. **"Which zip codes have high demand but low approval rates?"**
   - Cross-source join (registrations + incentives + demographics)
   - **Say:** "This is the powerful one — it joins registrations from batch, incentive data from CDC, and demographics from reference tables. Three ingestion patterns, one natural language question."

4. **Follow-up: "Break that down by BEV vs PHEV"**
   - Multi-turn drill-down
   - **Say:** "Multi-turn context. The agent remembers what 'that' refers to and drills deeper."

### 2c. Streamlit Dashboard Tab (3 min)
- Switch to Tab 1 (Executive Dashboard)
- Walk through the 5 visualizations briefly

**Say:** "Tab 1 is the static dashboard for executives who want at-a-glance metrics. Tab 2 is the conversational interface for ad-hoc exploration. Same data, two consumption patterns — one for boards, one for analysts."

### 2d. Extension & Agent Architecture (2 min)
**Say:** "This agent has one tool today: the semantic view. I'd extend it with:"
- "A web search tool for real-time EV policy news"
- "A Python tool for statistical forecasting (will we hit the 2030 goal at current growth?)"
- "CRM integration so dealers can see which zip codes are underserved"
- "Multi-agent: one agent for EV data, one for budget/cost, orchestrated by a coordinator"

---

## Q&A Preparation (15 min)

### Likely Questions & Answers

**"Why Dynamic Tables instead of dbt models with Tasks?"**
→ "For Silver/Gold, the refresh logic is pure SQL joins and aggregations — no testing framework needed at that layer. Dynamic Tables eliminate scheduling code entirely. I'd use dbt if I had a large analytics engineering team managing hundreds of models, needed dbt's built-in testing framework (unique, not_null, accepted_values), required Jinja templating for complex conditional logic, or needed cross-warehouse portability (BigQuery, Redshift). For this pipeline — small team, Snowflake-native, declarative refresh — Dynamic Tables are simpler and require no external tooling."

**"Why not Snowpipe instead of COPY INTO + Tasks?"**
→ "The data arrives in daily/weekly batches, not a continuous stream. Snowpipe adds always-on cost for a low-frequency feed. Stream + Task is event-driven and costs nothing when no files arrive."

**"How would you handle schema evolution?"**
→ "The Snowpark parse procedure adapts automatically — it reads column metadata from the JSON, so new columns flow through without code changes. For Dynamic Tables, I'd ALTER to add new columns. For Iceberg, schema evolution is native."

**"What about data masking for cross-agency sharing?"**
→ "I'd add row-access policies on the Secure View so each agency only sees their legislative district. Column-level masking policies on sensitive fields like applicant_zip for agencies that shouldn't see individual-level data."

**"How does this compare to a Databricks/Spark Lakehouse?"**
→ "Similar outcome, different operational model. With Snowflake: no cluster management, no Spark tuning, no Delta maintenance. The trade-off is Snowflake's pricing model vs. bring-your-own-compute economics. For a state agency without a platform team, managed wins. The Iceberg Gold layer gives them an exit path if they ever want external compute."

**"What would you change in production?"**
→ "OpenFlow instead of legacy connector. Snowpipe Streaming if data cadence increases. Resource monitors with budgets. Network policies. MFA enforcement. Marketplace listing instead of direct SHARE. A Cortex Agent with guardrails and audit logging."

**"How did you use Cortex Code?"**
→ "Every component was generated iteratively. The README is the build log — each prompt specifies intent, CoCo generates implementation, I review and refine. The CDC connector debugging is a great example: CoCo helped diagnose Spring Boot errors from container logs and iterated through config issues until the agent connected."

---

## Grading Criteria Checklist

| Skill Area | Where You Demonstrate It | Time in Demo |
|-----------|--------------------------|-------------|
| **Architecture Design** | Slide 3, Section 1a-1d talking points | 10 min slides + throughout Part 1 |
| **Tool Selection** | Slide 4 (matrix with alternatives), every "why" talking point | 10 min slides |
| **Transformation Approach** | Section 1a (Snowpark), 1c (Silver joins + quarantine) | Part 1: 9 min |
| **Orchestration Knowledge** | Slide 5, Section 1e (Stream → Task → DT cascade) | Part 1: 2 min |
| **Open Table Formats** | Section 1d (Iceberg, external volume, multi-engine) | Part 1: 4 min |
| **Data Sharing** | Section 1f (Secure Views, SHARE, Marketplace mention) | Part 1: 2 min |
| **Cost Optimization** | Slide 6 + woven throughout (auto-suspend, event-driven, Iceberg) | Throughout |
| **Semantic Modeling** | Section 2a-2d (semantic view design, agent demo, extension) | Part 2: 15 min |
| **Cortex Code Adoption** | Q&A answer + README as artifact | Q&A: as asked |
