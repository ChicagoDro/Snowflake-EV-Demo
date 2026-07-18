
# WA EV Registration Pipeline — Build Playbook
### How this was built: Prompts, Architecture Decisions, and Implementation Steps
> This document is the behind-the-scenes build log for the EV Demo pipeline.
> It shows the exact prompts used with Cortex Code (CoCo) to generate each component,
> the manual integration steps, and the reasoning behind every architectural choice.
> For the demo presentation script, see [`demo/presentation_script.md`](demo/presentation_script.md).

---

# CoCo Prompt 0

## Context Primer (No executed actions)
```
You are helping build a medallion data-engineering pipeline in Snowflake for Washington State

EV registration data, for a state-agency audience measuring progress toward the 2030 EV goal.

**Database** EV_DEMO, **Warehouse** WH_EV_DEMO. **Schemas**: RAW, CLEAN, MART, OBS.

**Architecture:**
1. Bronze: Raw CSV ingested via COPY INTO from Azure Blob stage → parsed into VARIANT → Snowpark stored procedure for structured parsing.
2. Dynamic operational data: PostgreSQL CDC replication via Snowflake Connector for PostgreSQL (Docker agent → EV_DEMO."public") for `incentive_applications` — a frequently-changing operational table. In production, this would use OpenFlow (not available on trial accounts).
3. Static reference data: `zip_code_demographics` and `state_ev_goals` loaded as dbt seeds into EV_DEMO.RAW (version-controlled, infrequently-changing).
4. Silver: dbt models materialized as Dynamic Tables (joins Bronze + CDC data + seed reference data, applies business rules).
5. Gold: dbt models materialized as Dynamic Iceberg Tables on external volume EV_EXT_VOL (Azure Blob Storage).
6. Semantic layer: Cortex Analyst semantic view on Gold + Cortex Agent for natural-language conversational analytics. Streamlit chat interface for business users.

**Priorities:**
 - governed, cost-efficient, trustworthy enough to brief the legislature.
 - Favor scheduled/declarative refresh over real-time for the registration feed.

**General Instructions**
 - Comment every object with why it exists.
 - For verification, call procedures directly instead of waiting for scheduled tasks.

Do not create or execute anything yet. Acknowledge this context and wait for my next instruction. I will give you the build in sequential prompts.
```
---

# External Service Setup & SF Integrations (Manual)

## A. Azure Storage (for Iceberg Gold Layer)

### Azure Portal
1. Create an **Azure Blob Storage container** for Iceberg files. Note the **Base URL** and **Tenant ID**.

### Snowflake
2. Create the **External Volume** linked to the Azure container:
```sql
CREATE OR REPLACE EXTERNAL VOLUME EV_EXT_VOL
  STORAGE_LOCATIONS = (
    (
      NAME = 'azure-ev-gold'
      STORAGE_PROVIDER = 'AZURE'
      STORAGE_BASE_URL = 'azure://tamisinsfdemo.blob.core.windows.net/iceberg/'
      AZURE_TENANT_ID = '<add Azure Tenant ID>'
    )
  );
```
3. Describe the volume to extract **AZURE_CONSENT_URL** and **AZURE_MULTI_TENANT_APP_NAME**:
```sql
DESC EXTERNAL VOLUME EV_EXT_VOL;
```

### Azure Portal
4. Open the consent URL in a browser and accept.
5. In Azure Portal → Storage Account → Access Control (IAM) → Add role assignment → **Storage Blob Data Contributor** → assign to the Snowflake app principal.

### Snowflake
6. Verify the link:
```sql
SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('EV_EXT_VOL');
```

---

## B. PostgreSQL (Dynamic Operational Data via Snowflake Connector + CDC)

> **Why CDC for `incentive_applications` only?**
> This is an operational table that changes daily as residents submit applications and the state
> approves/denies them. CDC ensures Snowflake always has the latest status without manual ETL.
> Static reference tables (`zip_code_demographics`, `state_ev_goals`) are loaded as **dbt seeds** instead —
> they change annually at most, so CDC would be overkill. Version-controlling them as CSVs in the
> dbt project makes them auditable and reproducible.

> **Note on OpenFlow vs. Legacy Connector:**
> The production-grade approach is **Snowflake OpenFlow Connector for PostgreSQL** (GA),
> which runs on Apache NiFi with better performance and BYOC/SPCS deployment options.
> However, **OpenFlow is not available on trial accounts**. This demo uses the legacy
> **Snowflake Connector for PostgreSQL** (Native App + Docker agent) instead.

### Azure Database for PostgreSQL Flexible Server (External)
7. Provision an **Azure Database for PostgreSQL Flexible Server**:
   - Azure Portal → Create a resource → "Azure Database for PostgreSQL Flexible Server"
   - **Compute tier:** Burstable B1ms (free-tier eligible for 12 months, plenty for demo data)
   - **Authentication:** PostgreSQL authentication (username + password) — **not** Entra-only, since the Snowflake connector requires password auth
   - **Networking:** Public access; add a firewall rule for the Docker agent's IP (or check "Allow access from any Azure service" if agent runs in Azure)
   - **Region:** Same region as your Snowflake account (East US 2) for lowest latency

8. After creation, configure **server parameters** (Portal → Server parameters):
   - `wal_level` = `logical` (required for CDC — triggers a server restart)
   - `max_replication_slots` ≥ `4`
   - `max_wal_senders` ≥ `4`
   - Click Save (server will restart automatically)

9. Connect to the server (via psql, Azure Cloud Shell, or pgAdmin) and run the setup script:

   **→ See [`connectors/postgres_ev_cdc_data.sql`](connectors/postgres_ev_cdc_data.sql)** — run this in your PostgreSQL instance (not Snowflake).

   This creates:
   - `ev_reference` database
   - `incentive_applications` (dynamic operational table — the CDC target)
   - Seed data (15 rows with realistic WA incentive applications)
   - A publication (`snowflake_pub`) for CDC replication
   - A dedicated replication user

10. **Networking note:** The legacy Snowflake Connector uses a Docker agent that runs in your network and connects *outbound* to both Postgres and Snowflake. So:
    - **Agent → Postgres:** Add the agent's IP (or Azure service IPs) to the Flexible Server firewall rules
    - **Agent → Snowflake:** Outbound HTTPS (443) — typically allowed by default
    - You do **not** need to allowlist Snowflake egress IPs on Postgres (the agent is the intermediary)

### Snowflake (Legacy Connector Setup)
12. Install the **Snowflake Connector for PostgreSQL** Native App from the Snowflake Marketplace (search "Snowflake Connector for PostgreSQL").
13. Configure the connector and start replication:

    **→ See [`connectors/sf_connector_replication_setup.sql`](connectors/sf_connector_replication_setup.sql)** — run this in Snowflake as ACCOUNTADMIN.

    This grants the connector access to EV_DEMO, adds the data source, selects tables for replication, and enables a 15-minute CDC schedule.

14. Deploy the **Docker-based agent** (connects to both Postgres and Snowflake):
    - Image: `snowflakedb/database-connector-agent:6.11.2`
    - Mount `snowflake.json` (from connector wizard) at `/home/agent/snowflake.json`
    - Mount `datasources.json` (JDBC URL + credentials) at `/home/agent/datasources.json`
    - Mount empty dir at `/home/agent/.ssh` (agent generates keys)
    - Run locally or on Azure Container Instance
15. Verify `incentive_applications` appears in `EV_DEMO."public"` (the connector creates it here).

> **Production upgrade path:** Replace this connector with the OpenFlow Connector for PostgreSQL.
> OpenFlow provides a visual NiFi canvas, better throughput tuning, SPCS or BYOC deployment,
> and is actively maintained (GA). The legacy connector is in Preview and frozen.

### CoCo Prompt 1 - Generate PostgreSQL CDC Data
```
Generate a PostgreSQL SQL file for an external database called ev_reference that will be replicated
into Snowflake via the Snowflake Connector for PostgreSQL (CDC).

Create this table in the public schema:

1. incentive_applications (the CDC target — simulates daily operational data)
   - application_id (SERIAL PK), submitted_date, applicant_zip, vehicle_type (BEV/PHEV),
     make, model, model_year, incentive_amount, status (PENDING/APPROVED/DENIED),
     reviewed_date, denial_reason, updated_at
   - Seed with 15 rows showing a realistic mix of statuses, popular EV makes/models,
     and denial reasons (income threshold, MSRP cap)
   - Use Washington State zip codes and recent dates (June–July 2026)

Also include:
- A CREATE PUBLICATION for this table (for CDC logical replication)
- A dedicated replication user with SELECT + REPLICATION privileges
- Comments explaining this is operational data that changes daily

This file is meant to be run in psql, not Snowflake.
Save to connectors/postgres_ev_cdc_data.sql
```
**CoCo Output:** PostgreSQL CDC data **connectors/postgres_ev_cdc_data.sql**

---

## C. GitHub (for Git Workspace / CICD)

### GitHub
18. Create a GitHub repository (or use existing: https://github.com/ChicagoDro/Snowflake-EV-Demo.git).
19. Generate a **classic Personal Access Token** with `repo` scope.

### Snowflake
20. Connect SF Workspace to the repo using the notebook:

    **→ See [`setup/git_workspace_setup.ipynb`](setup/git_workspace_setup.ipynb)** — created by CoCo Prompt 2.

---
### CoCo Prompt 2 - Git Workspace Setup (SQL + Manual Instructions)
**Turn on Plan**

```
Create a SQL script to set up a bidirectional Git workspace in Snowflake linked to this GitHub repo: https://github.com/ChicagoDro/Snowflake-EV-Demo.git

Create a new role named EV_DEMO_ENGINEER to serve as the executer and owner of the code in the repository. In the comments, specify that this is a purpose-scoped role that avoids ACCOUNTADMIN drift and lets us audit pipeline-specific access separately from platform admin activity.

Ownership model:
 - ACCOUNTADMIN creates the API integration (account-level object).
 - EV_DEMO_ENGINEER owns the secret and Git repository object.
 
Requirements:

Include an API integration (type git_https_api) and a secret for a GitHub classic PAT.

GitHub username: ChicagoDro

Store Git infrastructure objects (secret, repo) in a SEPARATE dedicated database/schema (GIT_REPOS.INTEGRATIONS), not in the pipeline's target data database.

Grant USAGE on the integration, database, and schema to EV_DEMO_ENGINEER.

After creating the Git repository object, fetch and show branches to verify connectivity.

End with instructions on creating the bidirectional workspace from the Snowsight UI.

Comment every command for clarity.

Save the code to a notebook file in setup named git_workspace_setup.ipynb
```

---
# Manual Step (Folder Structure Setup)
Create folders in new Snowflake-EV-Demo Git Workspace
 - setup (one-time DDL and deployment scripts, run in order)
 - pipeline (reusable stored procs and logic called by orchestration)
 - dbt (dbt project: seeds, models, tests)
 - streamlit (Streamlit apps)
 - semantic (Cortex Analyst semantic models)
 - connectors (connector config templates, no secrets)
 - demo (verification queries, presentation artifacts)

 Move git_workspace_setup.ipynb into Snowflake-EV-Demo/setup
 
---
# CoCo Prompt 3 - Environmental Scaffolding
**Turn on Plan**
```
1. Create warehouse: WH_EV_DEMO (XSMALL, auto-suspend 60s, auto-resume, initially suspended).
2. Create database: EV_DEMO.
3. Create schemas in EV_DEMO: RAW, CLEAN, MART, OBS
4. Create internal stage EV_DEMO.RAW.EV_STAGE with directory enabled and a JSON file format (STRIP_OUTER_ARRAY = FALSE).
5. Grant EV_DEMO_ENGINEER the permissions it needs to interact with these objects, including usage on external volume EV_EXT_VOL.

- If any of the objects already exist, drop them first
- Comment each statement with why it exists and why it's sized/scoped that way. Confirm creation.
- Save the code to a SQL file named 01_environment.sql in workspace folder Snowflake-EV-Demo/setup 
```
**CoCo Output:** Script to generate SF environment **01_environment.sql**

---

# Seed Data from local (Manual)

Upload the file **ElectricVehiclePopulationData.json** to the EV_DEMO.RAW.EV_STAGE

---

# CoCo Prompt 4 - Bronze raw ingest
**Turn on Plan**
```
1. Create table EV_DEMO.RAW.RAW_EV_REGISTRATIONS with a single VARIANT column plus load timestamp and source filename.
2. COPY INTO it from @RAW.EV_STAGE (ElectricVehiclePopulationData.json) as raw JSON — do not flatten. This is the immutable, auditable landing zone. Show row count and one sample record.

 - Comment each statement with why it exists and why it's sized/scoped that way. Confirm creation.
 - Save the code to a SQL file named 02_bronze_raw_ingest.sql in Snowflake-EV-Demo/setup 
```
---
**CoCo Output:** Script to generate SF environment **02_bronze_raw_ingest.sql**

---

# CoCo Prompt 5 - Snowpark parse
**Turn on Plan**
```
Write a Snowpark Python stored procedure **EV_DEMO.RAW.SP_PARSE_EV_REGISTRATIONS** that:

1. Reads the Bronze VARIANT record.

2. Reads meta.view.columns from the JSON to build an index -> column-name mapping AT RUNTIME

   (do not hardcode positional indices).

3. Explodes :data (array of positional arrays) and projects the business fields using that mapping.

4. Writes typed output to **EV_DEMO.RAW.BRONZE_PARSED** (VIN, county, city, state, postal_code,

   model_year INT, make, model, ev_type, cafv_eligibility, electric_range INT, base_msrp INT,

   legislative_district, vehicle_location, electric_utility, census_tract, plus load_ts).

5. Applies NO business rules — structural parsing only. Returns rows written.

Comment the code with why it exists and why it's written that way.

Confirm creation. Then call the procedure directly to verify.

Save the code to a sql file named 03_bronze_raw_ingest.sql in Snowflake-EV-Demo/setup
Save the Snowpark stored procedure source to pipeline/sp_parse_ev_registrations.py 
```
---
CoCo Output: Script to generate SF environment **03_bronze_raw_ingest.sql**

---

# CoCo Prompt 6 - Reference Data (dbt Seeds) + CDC Verification
**Turn on Plan**
```
Set up reference data as dbt seeds and verify the CDC-replicated operational table.

**Part A: dbt Seeds (static reference data)**
Create dbt seed CSV files for tables that change infrequently (annually):
  - zip_code_demographics (zip_code, population, median_income, ev_charging_stations) — 15 WA zip codes
  - state_ev_goals (state, year, target_ev_count, policy_name) — WA targets 2025-2035

Place CSVs in dbt/seeds/ and configure dbt_project.yml to load them into EV_DEMO.RAW schema.
These are version-controlled, auditable, and don't require an external system to manage.

**Part B: CDC verification**
Verify that EV_DEMO."public".INCENTIVE_APPLICATIONS exists and has data from the Snowflake
Connector for PostgreSQL (configured in Section B).

Build:
1. A SQL script that:
   - Verifies EV_DEMO."public".INCENTIVE_APPLICATIONS exists (SELECT COUNT, sample rows)
   - Checks CDC status via REPLICATION_STATE in the connector schema
   - Creates a placeholder table in EV_DEMO.RAW if CDC hasn't synced yet (for downstream dev)

2. Document in comments:
   - Why CDC for incentive_applications (operational, status changes daily)
   - Why dbt seeds for zip/goals (static, version-controlled, no external dependency)
   - Join paths: applicant_zip ↔ postal_code, make/model ↔ make/model

3. Grant SELECT on CDC table to EV_DEMO_ENGINEER if not already granted.

Comment each object. Save to setup/04_reference_tables.sql in Snowflake-EV-Demo
```
**CoCo Output:** Reference data setup **setup/04_reference_tables.sql** + **dbt/seeds/*.csv**

---

# CoCo Prompt 7 - Silver Dynamic Table (Enriched with Reference Data)
**Turn on Plan**
```
Create a Dynamic Table EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS sourced from EV_DEMO.RAW.BRONZE_PARSED with TARGET_LAG = '60 minutes' on warehouse WH_EV_DEMO.

Logic (structural + business rules + enrichment):
1. Deduplicate: one row per VIN, keep the latest by LOAD_TS.
2. Standardize: UPPER() on MAKE, MODEL, COUNTY, CITY for consistent grouping.
3. Parse VEHICLE_LOCATION (format: "POINT (lng lat)") into LONGITUDE FLOAT and LATITUDE FLOAT columns.
4. Cast POSTAL_CODE to VARCHAR(10), LEGISLATIVE_DISTRICT to VARCHAR(5).
5. Validate: filter OUT rows where ev_type NOT IN ('Battery Electric Vehicle (BEV)', 'Plug-in Hybrid Electric Vehicle (PHEV)') OR electric_range < 0 OR VIN IS NULL. Route these to a quarantine table instead.
6. LEFT JOIN to EV_DEMO.RAW.ZIP_CODE_DEMOGRAPHICS (dbt seed) on postal_code = zip_code to enrich with population, median_income, ev_charging_stations.
7. LEFT JOIN to EV_DEMO.RAW.STATE_EV_GOALS (dbt seed) on state = state AND model_year = year to enrich with target_ev_count and policy_name.
8. LEFT JOIN to EV_DEMO."public".INCENTIVE_APPLICATIONS (CDC-replicated) on UPPER(make) = make AND UPPER(model) = model AND postal_code = applicant_zip to enrich with incentive_amount, application status. Use latest application per vehicle match.

Also create a Dynamic Table EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS (same source, same lag) capturing rejected rows with a REJECTION_REASON column explaining why each row failed.

Comment each object with why it exists.
Save the code to a SQL file named 05_silver_dynamic_tables.sql in Snowflake-EV-Demo/setup
```
**CoCo Output:** Silver layer Dynamic Tables **setup/05_silver_dynamic_tables.sql**

---

# CoCo Prompt 8 - Gold Layer (Dynamic Iceberg Tables)
**Turn on Plan**
```
Create Dynamic Iceberg Tables in EV_DEMO.MART on external volume EV_EXT_VOL, sourced from EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS, with TARGET_LAG = '120 minutes'.

Build these Gold models:

1. MART.DIM_VEHICLE — distinct vehicle dimension (VIN, make, model, model_year, ev_type, electric_range, base_msrp). One row per VIN.

2. MART.DIM_GEOGRAPHY — distinct geographic dimension (county, city, state, postal_code, legislative_district, latitude, longitude, population, median_income, ev_charging_stations). Surrogate key via SHA2 hash of county+city+postal_code.

3. MART.FACT_EV_REGISTRATIONS — fact table joining to dims via VIN and geo surrogate key. Include cafv_eligibility, electric_utility, census_tract, target_ev_count, policy_name.

4. MART.AGG_REGISTRATIONS_BY_COUNTY — registrations grouped by county, ev_type, with total count, avg electric range, population, and registrations_per_capita (count / population).

5. MART.AGG_REGISTRATIONS_BY_YEAR — registrations grouped by model_year, ev_type, showing adoption trends (count, cumulative count, target_ev_count, pct_of_goal).

Each table should use CATALOG = 'SNOWFLAKE' and BASE_LOCATION pointing to a subfolder matching the table name.

Comment each object with why it exists and what insights it enables.
Save the code to a SQL file named 06_gold_iceberg_tables.sql in Snowflake-EV-Demo/setup
```
**CoCo Output:** Gold layer Iceberg Tables **setup/06_gold_iceberg_tables.sql**

---

# CoCo Prompt 9 - Demo Verification Queries
**Turn on Plan**
```
Generate a SQL file with verification queries to run live during a demo, proving data flows
end-to-end through the pipeline. Organize into clearly labeled sections:

1. BRONZE — row counts for RAW_EV_REGISTRATIONS and BRONZE_PARSED, sample rows
2. CDC — EV_DEMO."public".INCENTIVE_APPLICATIONS counts by status, connector REPLICATION_STATE
3. REFERENCE — dbt seed table counts (ZIP_CODE_DEMOGRAPHICS, STATE_EV_GOALS)
4. SILVER — row count + freshness, sample enriched rows showing joined data, quarantine breakdown,
   Dynamic Table refresh status from INFORMATION_SCHEMA.DYNAMIC_TABLES()
5. GOLD — dimension/fact counts, a quick business insight query (top makes), Iceberg table refresh status
6. PIPELINE HEALTH SUMMARY — single query comparing row counts across all layers

This is NOT automated monitoring (that's the OBS layer). This is a "show don't tell" script
for walking someone through the pipeline during a live demo or interview.

Save to demo/demo_verification_queries.sql
```
**CoCo Output:** Demo walkthrough queries **demo/demo_verification_queries.sql**

---

# CoCo Prompt 10 - Data Quality & Observability
**Turn on Plan**
```
Build data quality monitoring in EV_DEMO.OBS using Snowflake Data Metric Functions (DMFs).

1. Create custom DMFs for:
   - COMPLETENESS: % of non-null VINs in BRONZE_PARSED vs SILVER
   - UNIQUENESS: duplicate VIN count in Silver (should be 0)
   - FRESHNESS: minutes since last LOAD_TS in each layer
   - BUSINESS_RULES: count of rows where electric_range < 0 or ev_type is invalid (should be 0 in Silver, captured in Quarantine)
   - ROW_COUNT_RECONCILIATION: compare row counts across Bronze → Silver → Gold (Silver + Quarantine should equal Bronze)

2. Attach DMFs to the Silver and Gold tables using ALTER TABLE ... SET DATA_METRIC_SCHEDULE.

3. Create a view OBS.V_DATA_QUALITY_DASHBOARD that queries SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS to surface all DMF results in one place.

4. Create a notification integration and an ALERT that fires when any quality metric breaches its threshold.

Comment each object. Save to setup/07_data_quality.sql in Snowflake-EV-Demo
```
**CoCo Output:** Data quality framework **setup/07_data_quality.sql**

---

# CoCo Prompt 11 - Orchestration (Stream + Task Graph)
**Turn on Plan**
```
Build a Task graph to orchestrate the full pipeline end-to-end.

Architecture:
- Directory Table Stream on @EV_DEMO.RAW.EV_STAGE to detect new file arrivals.
- Root Task: TASK_INGEST_RAW — triggered by SYSTEM$STREAM_HAS_DATA(), runs COPY INTO for new files.
- Child Task: TASK_PARSE_BRONZE — calls SP_PARSE_EV_REGISTRATIONS() after ingest completes.
- The Dynamic Tables (Silver, Gold) refresh automatically via their TARGET_LAG — no tasks needed for those layers.
- Final Task: TASK_QUALITY_CHECK — runs after parse, executes a stored procedure that checks DMF results and raises an alert if thresholds are breached.

Requirements:
- SUSPEND_TASK_AFTER_NUM_FAILURES = 3 (circuit breaker)
- Warehouse: WH_EV_DEMO
- Schedule on root task: USING CRON '0 */6 * * *' (every 6 hours, or when stream has data — whichever comes first)
- Error handling: each task should log failures to OBS.TASK_RUN_LOG table
- Grant EXECUTE TASK to EV_DEMO_ENGINEER

Comment each object. Save to setup/08_orchestration.sql in Snowflake-EV-Demo
```
**CoCo Output:** Task-based orchestration **setup/08_orchestration.sql**

---

# CoCo Prompt 12 - Data Sharing
**Turn on Plan**
```
Demonstrate data sharing for the Gold layer.

1. Create a SECURE VIEW over MART.FACT_EV_REGISTRATIONS joined to dims (so consumers get a denormalized, governed view without direct table access).

2. Create a SHARE named EV_DEMO_GOLD_SHARE. Add the secure view and the aggregate tables to it.

3. Document (in comments) the governance model:
   - Why secure views (hides underlying SQL, prevents reverse-engineering of joins)
   - When to use Direct Share vs Listing vs Data Exchange
   - How row-access policies could restrict shared data by consumer account
   - Cross-region/cross-cloud considerations

4. Show how to add a consumer account to the share (template command with placeholder).

5. Discuss alternative: creating a Marketplace Listing (private or public) for broader distribution.

Comment each object. Save to setup/09_data_sharing.sql in Snowflake-EV-Demo
```
**CoCo Output:** Data sharing setup **setup/09_data_sharing.sql**

---

# CoCo Prompt 13 - Semantic Model & Cortex Agent
**Turn on Plan**
```
Build a semantic layer for conversational analytics on the EV Demo Gold layer.

**Part A: Semantic View**
Create a Cortex Analyst semantic view YAML covering:

Tables:
- MART.FACT_EV_REGISTRATIONS (measures: registration_count, avg_electric_range, pct_of_goal)
- MART.DIM_VEHICLE (dimensions: make, model, model_year, ev_type, electric_range, cafv_eligibility)
- MART.DIM_GEOGRAPHY (dimensions: county, city, state, postal_code, population, median_income, ev_charging_stations)
- MART.AGG_REGISTRATIONS_BY_YEAR (measures: count, cumulative_count, target_ev_count, pct_of_goal)
- MART.AGG_REGISTRATIONS_BY_COUNTY (measures: count, registrations_per_capita, avg_electric_range)
- EV_DEMO."public".INCENTIVE_APPLICATIONS (measures: approval_rate, total_incentive_amount, pending_count; dimensions: status, vehicle_type, applicant_zip)

Define:
- Time grains (model_year, submitted_date)
- Relationships/joins between tables
- Business-friendly names and descriptions for all columns
- Verified queries (5-8) covering the question categories below

Question categories the model must support:
- Executive: YoY growth, regional adoption rates, BEV vs PHEV market penetration, progress toward 2030 goal
- Sales/Marketing: Tesla vs competitors by region, CAFV eligibility %, trending models by demographic
- Operations (leveraging CDC data): incentive approval rates by zip, pending application backlog,
  denial reasons breakdown, avg days to review, which zip codes have high demand but low approval rates

Save semantic view to semantic/ev_registrations.yaml

**Part B: Cortex Agent**
Create a Cortex Agent that uses the semantic view as a tool.

- Agent name: EV_DEMO_ANALYST
- Instructions: "You are an EV market analyst for Washington State. Help business users understand
  EV adoption trends, incentive program effectiveness, and progress toward the 2030 goal."
- Tool: cortex_analyst with the semantic view

Save agent spec to semantic/ev_analyst_agent.yaml

**Part C: Agent Integration Notes (comments in the agent YAML)**
Document how this could be extended for:
- Tool-calling: adding a web search tool for real-time EV news, a Python tool for custom calculations
- External systems: CRM integration for dealer follow-up, ERP for budget tracking
- Multi-turn: maintaining conversation context for drill-down analysis
```
**CoCo Output:** Semantic view **semantic/ev_registrations.yaml** + Agent **semantic/ev_analyst_agent.yaml**

---

# CoCo Prompt 14 - Insights & Visualization (Streamlit + Chat)
**Turn on Plan**
```
Build a Streamlit app in Snowflake (Streamlit in Snowflake / SiS) with two tabs:

**Tab 1: Executive Dashboard** — 4 static insights from the Gold layer:
1. EV Adoption Trend — line chart of cumulative registrations by model_year, split by BEV vs PHEV. Shows progress toward 2030 goal with target_ev_count reference line.
2. Geographic Distribution — bar chart of top 15 counties by registration count with registrations_per_capita overlay. Highlights concentration vs. equity.
3. Make/Model Leaderboard — horizontal bar chart of top 10 makes by registration count, with avg electric range as secondary metric.
4. CAFV Eligibility Breakdown — pie/donut chart showing proportion of vehicles eligible for clean fuel incentives.
5. Incentive Program Status — summary cards showing total applications, approval rate, pending backlog, total incentive $ disbursed (from CDC data).

**Tab 2: Ask the Data (Cortex Agent Chat)** — conversational interface:
- Use the EV_DEMO_ANALYST Cortex Agent (created in Prompt 13)
- Streamlit chat UI with st.chat_message / st.chat_input
- Display agent responses including generated SQL and result tables
- Include 3-4 suggested starter questions as clickable chips
- Support multi-turn conversation (maintain message history)

Requirements:
- Query Gold Iceberg tables for Tab 1
- Use Cortex Agent API (snowflake.cortex.data_agent_run) for Tab 2
- Use st.connection("snowflake") for the session
- Include a title, brief narrative text explaining each insight for a legislative audience
- Use Altair or Plotly for charts (not matplotlib)

Save the Streamlit app to streamlit/ev_insights_app.py in Snowflake-EV-Demo
```
**CoCo Output:** Streamlit insights + chat app **streamlit/ev_insights_app.py**

---
