
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
3. Static reference data: `zip_code_demographics` and `state_ev_goals` loaded via direct SQL into EV_DEMO.RAW (small, static datasets — 26 rows total; source CSVs version-controlled in Git for auditability).
4. Silver: Dynamic Tables (joins Bronze + CDC data + reference data, applies business rules). Declarative refresh via TARGET_LAG — no external scheduler needed.
5. Gold: Dynamic Iceberg Tables on external volume EV_EXT_VOL (Azure Blob Storage). Open format for external compute portability.
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
> Static reference tables (`zip_code_demographics`, `state_ev_goals`) are loaded via **direct SQL** instead —
> they're small (26 rows total) and change annually at most, so CDC would be overkill. The source CSVs
> remain version-controlled in `dbt/seeds/` for Git auditability.

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
 - dbt (dbt seed CSVs retained for Git auditability; seeds loaded via SQL instead)
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
2. COPY INTO it from @RAW.EV_STAGE (all files on stage, not a specific filename) as raw JSON — do not flatten. This is the immutable, auditable landing zone. Show row count and one sample record.

NOTE: Use a transformation subquery to map into the 3-column table:
  COPY INTO RAW_EV_REGISTRATIONS (RAW_DATA, LOADED_AT, SOURCE_FILE)
  FROM (SELECT $1, CURRENT_TIMESTAMP(), METADATA$FILENAME FROM @EV_DEMO.RAW.EV_STAGE)
  FILE_FORMAT = (TYPE = 'JSON' STRIP_OUTER_ARRAY = FALSE) ON_ERROR = ABORT_STATEMENT;
Do NOT hardcode a specific filename — the stage may contain any number of JSON files.

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

After BRONZE_PARSED is created, enable change tracking on it:
  ALTER TABLE EV_DEMO.RAW.BRONZE_PARSED SET CHANGE_TRACKING = TRUE;
This is REQUIRED for downstream Dynamic Tables (Silver) to detect changes.
Without it, manual REFRESH and auto-refresh will fail with "Change tracking is not enabled".

Save the code to a sql file named 03_bronze_raw_ingest.sql in Snowflake-EV-Demo/setup
Save the Snowpark stored procedure source to pipeline/sp_parse_ev_registrations.py 
```
---
CoCo Output: Script to generate SF environment **03_bronze_raw_ingest.sql**

---

# CoCo Prompt 6 - Reference Data (SQL) + CDC Verification
**Turn on Plan**
```
Set up static reference data and verify the CDC-replicated operational table.

**Part A: Reference Tables (static data via SQL)**
Create SQL CREATE TABLE + INSERT statements for tables that change infrequently (annually):
  - zip_code_demographics (zip_code, population, median_income, ev_charging_stations) — 15 WA zip codes
  - state_ev_goals (state, year, target_ev_count, policy_name) — WA targets 2025-2035

Load into EV_DEMO.RAW schema. These are small, static datasets (26 rows total). Direct SQL
is the right choice here — no external tooling dependency, and it keeps the pipeline 100%
Snowflake-native. Document in comments when dbt seeds would be the better choice instead
(large seed files, teams already using dbt for transformation, need for built-in schema tests,
or cross-warehouse portability).

**Part B: CDC verification**
Verify that EV_DEMO."public".INCENTIVE_APPLICATIONS exists and has data from the Snowflake
Connector for PostgreSQL (configured in Section B).

Build a single SQL script that:
1. Creates and populates the two reference tables (Part A)
2. Verifies EV_DEMO."public".INCENTIVE_APPLICATIONS exists (SELECT COUNT, sample rows)
3. Checks CDC status via the connector status procedure
4. Documents in comments:
   - Why CDC for incentive_applications (operational, status changes daily)
   - Why direct SQL for zip/goals (small, static, no external dependency)
   - Join paths: applicant_zip ↔ postal_code, make/model ↔ make/model
5. Grants SELECT on CDC table and reference tables to EV_DEMO_ENGINEER

Comment each object. Save code to setup/04_static_reference_tables.sql in Snowflake-EV-Demo
```
**CoCo Output:** Reference data + CDC verification **setup/04_static_reference_tables.sql**

---

# CoCo Prompt 7 - Silver Dynamic Table (Enriched with Reference Data)
**Turn on Plan**
```
PREREQUISITE: EV_DEMO.RAW.BRONZE_PARSED must have CHANGE_TRACKING = TRUE before creating
Dynamic Tables that source from it. If not already set, include this at the top of the script:
  ALTER TABLE EV_DEMO.RAW.BRONZE_PARSED SET CHANGE_TRACKING = TRUE;

Create a Dynamic Table EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS sourced from EV_DEMO.RAW.BRONZE_PARSED with TARGET_LAG = '60 minutes' on warehouse WH_EV_DEMO.

Logic (structural + business rules + enrichment):
1. Deduplicate: one row per VIN, keep the latest by LOAD_TS.
2. Standardize: UPPER() on MAKE, MODEL, COUNTY, CITY for consistent grouping.
3. Parse VEHICLE_LOCATION (format: "POINT (lng lat)") into LONGITUDE FLOAT and LATITUDE FLOAT columns.
4. Cast POSTAL_CODE to VARCHAR(10), LEGISLATIVE_DISTRICT to VARCHAR(5).
5. Validate: filter OUT rows where ev_type NOT IN ('Battery Electric Vehicle (BEV)', 'Plug-in Hybrid Electric Vehicle (PHEV)') OR electric_range < 0 OR VIN IS NULL. Route these to a quarantine table instead.
6. LEFT JOIN to EV_DEMO.RAW.ZIP_CODE_DEMOGRAPHICS (reference table) on POSTAL_CODE = ZIP_CODE to enrich with POPULATION, MEDIAN_INCOME, EV_CHARGING_STATIONS.
7. LEFT JOIN to EV_DEMO.RAW.STATE_EV_GOALS (reference table) on STATE = STATE AND MODEL_YEAR = YEAR to enrich with TARGET_EV_COUNT and POLICY_NAME.
8. LEFT JOIN to EV_DEMO."public"."incentive_applications" (CDC-replicated) to enrich with INCENTIVE_AMOUNT and STATUS. Use latest application per vehicle match (ROW_NUMBER partitioned by MAKE, MODEL, APPLICANT_ZIP ordered by UPDATED_AT DESC, keep rn=1). Join condition: UPPER(bronze.MAKE) = UPPER(cdc.MAKE) AND UPPER(bronze.MODEL) = UPPER(cdc.MODEL) AND bronze.POSTAL_CODE = cdc.APPLICANT_ZIP.

IMPORTANT — CDC table column naming:
The Snowflake Connector for PostgreSQL replicates columns as UPPERCASE unquoted identifiers.
The TABLE and SCHEMA names remain lowercase-quoted: EV_DEMO."public"."incentive_applications"
But COLUMN names are standard uppercase: MAKE, MODEL, APPLICANT_ZIP, INCENTIVE_AMOUNT, STATUS, UPDATED_AT.
Do NOT quote column names in lowercase — that will cause "invalid identifier" errors.

Also create a Dynamic Table EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS (same source, same lag) capturing rejected rows with a REJECTION_REASON column explaining why each row failed.

For verification, use:
  SELECT name, scheduling_state FROM TABLE(EV_DEMO.INFORMATION_SCHEMA.DYNAMIC_TABLES()) WHERE SCHEMA_NAME = 'CLEAN';
(Must qualify with database name. Do NOT use SNOWFLAKE.INFORMATION_SCHEMA.DYNAMIC_TABLES — that is not a valid view.)

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

3. MART.FACT_EV_REGISTRATIONS — fact table joining to dims via VIN and geo surrogate key. Include cafv_eligibility, electric_utility, census_tract, target_ev_count, policy_name, and load_ts.

4. MART.AGG_REGISTRATIONS_BY_COUNTY — registrations grouped by county, ev_type, with total count, avg electric range, population, and registrations_per_capita (count / population).

5. MART.AGG_REGISTRATIONS_BY_YEAR — registrations grouped by model_year, ev_type, showing adoption trends (count, cumulative count, target_ev_count, pct_of_goal).

Each table should use CATALOG = 'SNOWFLAKE' and BASE_LOCATION pointing to a subfolder matching the table name.

IMPORTANT — Iceberg data type limitations:
Iceberg tables only support TIMESTAMP_NTZ at microsecond precision (scale 6).
They do NOT support TIMESTAMP_LTZ or TIMESTAMP_TZ, and do NOT support nanosecond scale (9).
If any source column is TIMESTAMP_LTZ(9) (e.g., LOAD_TS from Silver), you MUST cast it:
  CAST(LOAD_TS AS TIMESTAMP_NTZ(6)) AS LOAD_TS
Failure to cast will produce: "Invalid time type scale specified for column..."

For grants, use GRANT SELECT ON ICEBERG TABLE (not ON DYNAMIC TABLE).
For verification, use SHOW DYNAMIC TABLES LIKE '%' IN SCHEMA EV_DEMO.MART to confirm is_iceberg = true.

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
2. CDC — EV_DEMO."public"."incentive_applications" counts by status, connector status check
3. REFERENCE — reference table counts (ZIP_CODE_DEMOGRAPHICS, STATE_EV_GOALS)
4. SILVER — row count, sample enriched rows showing joined data, quarantine breakdown,
   Dynamic Table refresh status
5. GOLD — dimension/fact counts, a quick business insight query (top makes), Iceberg table status
6. PIPELINE HEALTH SUMMARY — single query comparing row counts across all layers

IMPORTANT technical notes for this file:
- For Dynamic Table status, use: SELECT NAME, SCHEDULING_STATE FROM TABLE(EV_DEMO.INFORMATION_SCHEMA.DYNAMIC_TABLES()) WHERE SCHEMA_NAME = 'CLEAN';
- For Gold Iceberg table status, use: SHOW DYNAMIC TABLES LIKE '%' IN SCHEMA EV_DEMO.MART;
- Do NOT query LOAD_TS from Gold/Iceberg tables for freshness — it was cast to TIMESTAMP_NTZ(6).
  For freshness checks, query LOAD_TS from Silver (Dynamic Table) instead — Silver supports TIMESTAMP_LTZ(9).
- CDC table: schema/table names are lowercase-quoted, column names are UPPERCASE unquoted.
- RAW_EV_REGISTRATIONS columns are: RAW_DATA (VARIANT), LOADED_AT (TIMESTAMP_NTZ), SOURCE_FILE (VARCHAR).
  The timestamp column is LOADED_AT, NOT LOAD_TS.

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
   - BUSINESS_RULES: count of rows where electric_range < 0 or ev_type is invalid (should be 0 in Silver, captured in Quarantine)
   - ROW_COUNT_RECONCILIATION: compare distinct VIN count in Bronze vs Silver + Quarantine (difference should be 0)

2. For FRESHNESS, use the built-in system DMF SNOWFLAKE.CORE.FRESHNESS (do NOT create a custom DMF for this — custom DMFs cannot use non-deterministic functions like CURRENT_TIMESTAMP).

3. Attach DMFs to the Silver and Quarantine tables using ALTER TABLE ... SET DATA_METRIC_SCHEDULE.
   NOTE: Dynamic Tables and Dynamic Iceberg Tables support DMFs. Attach to Silver (CLEAN schema).

4. Create a view OBS.V_DATA_QUALITY_DASHBOARD that queries SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS to surface all DMF results in one place.

5. Create a notification integration and an ALERT that fires when any quality metric breaches its threshold.

IMPORTANT — DMF limitations:
- DMF expressions MUST be deterministic. Do NOT use CURRENT_TIMESTAMP(), CURRENT_DATE(), or any non-deterministic function inside a DMF body. This will cause: "Data metric function body cannot refer to the non-deterministic function..."
- For freshness/staleness checks, use the built-in SNOWFLAKE.CORE.FRESHNESS system DMF instead.
- DMFs require Enterprise Edition and the EXECUTE DATA METRIC FUNCTION account privilege.
- DATA_METRIC_SCHEDULE valid intervals are ONLY: 5, 15, 30, 60, 720, 1440 MINUTES (plural), 'TRIGGER_ON_CHANGES', or 'USING CRON ...'. Other values like 120 or 360 MINUTES are INVALID.
- INFORMATION_SCHEMA table functions must be qualified with the database name: TABLE(EV_DEMO.INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(...)), not TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(...)).
- ALLOWED_RECIPIENTS in notification integrations must use validated emails belonging to users in the account. Use: norm@tamisin.com
- For alert SCHEDULE, use CRON syntax: 'USING CRON 0 */2 * * * America/Los_Angeles' (not '120 MINUTES').

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
- SUSPEND_TASK_AFTER_NUM_FAILURES = 3 on ROOT TASK ONLY (child tasks inherit this from the root — setting it on a child task causes an error: "Cannot set parameter SUSPEND_TASK_AFTER_NUM_FAILURES on non-root task")
- Warehouse: WH_EV_DEMO
- Schedule on root task: 'USING CRON 0 */6 * * * America/Los_Angeles' (every 6 hours, or when stream has data — whichever comes first)
- Error handling: each task should log failures to OBS.TASK_RUN_LOG table via a helper stored procedure
- Grant EXECUTE TASK to EV_DEMO_ENGINEER
- Resume tasks in correct order: child tasks first, root task last

IMPORTANT — Task implementation notes:
- COPY INTO with JSON file format into a multi-column table (RAW_DATA, LOADED_AT, SOURCE_FILE) MUST use a transformation subquery:
    COPY INTO EV_DEMO.RAW.RAW_EV_REGISTRATIONS (RAW_DATA, LOADED_AT, SOURCE_FILE)
    FROM (SELECT $1, CURRENT_TIMESTAMP(), METADATA$FILENAME FROM @EV_DEMO.RAW.EV_STAGE)
    FILE_FORMAT = (TYPE = 'JSON' STRIP_OUTER_ARRAY = FALSE) ON_ERROR = 'CONTINUE';
  A bare "COPY INTO table FROM @stage" will fail with: "JSON file format can produce one and only one column of type variant"
- SQLERRM does NOT exist in Snowflake SQL scripting (it's Oracle/PL-SQL). In EXCEPTION WHEN OTHER handlers, use a static error message string instead:
    LET err_msg VARCHAR := 'Task failed — check TASK_HISTORY for details';
  Do NOT reference SQLERRM or SQLCODE — they will cause "invalid identifier" errors.

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
Build the semantic layer artifacts for conversational analytics on the EV Demo Gold layer.

**Part A: Verified Queries CSV (for Semantic View wizard)**
Generate a CSV file at semantic/verified_queries.csv for upload to the Cortex Analyst Semantic View wizard.
Format: two columns (question, sql) with a header row. Enclose SQL in double quotes (standard CSV escaping).

Tables available in the semantic view (MART schema only):
- MART.FACT_EV_REGISTRATIONS (VIN, GEO_KEY, MODEL_YEAR, CAFV_ELIGIBILITY, ELECTRIC_UTILITY, CENSUS_TRACT, TARGET_EV_COUNT, POLICY_NAME, INCENTIVE_AMOUNT, APPLICATION_STATUS, LOAD_TS)
- MART.DIM_VEHICLE (VIN, MAKE, MODEL, MODEL_YEAR, EV_TYPE, ELECTRIC_RANGE, BASE_MSRP)
- MART.DIM_GEOGRAPHY (GEO_KEY, COUNTY, CITY, STATE, POSTAL_CODE, LEGISLATIVE_DISTRICT, LATITUDE, LONGITUDE, POPULATION, MEDIAN_INCOME, EV_CHARGING_STATIONS)
- MART.AGG_REGISTRATIONS_BY_YEAR (MODEL_YEAR, EV_TYPE, REGISTRATION_COUNT, CUMULATIVE_COUNT, TARGET_EV_COUNT, PCT_OF_GOAL)
- MART.AGG_REGISTRATIONS_BY_COUNTY (COUNTY, EV_TYPE, REGISTRATION_COUNT, AVG_ELECTRIC_RANGE, POPULATION, REGISTRATIONS_PER_CAPITA)

Include 5-8 queries covering these question categories:
- Executive: YoY growth, regional adoption rates, BEV vs PHEV market penetration, progress toward 2030 goal
- Sales/Marketing: Tesla vs competitors by region, CAFV eligibility %, trending models by demographic
- Operations: incentive approval rates (via APPLICATION_STATUS in FACT), which counties have high demand but low per-capita adoption

**Part B: Cortex Agent Deployment Script**
Create a SQL deployment script (setup/10_deploy_cortex.sql) that:
1. Creates the Cortex Agent: CREATE OR REPLACE AGENT EV_DEMO.MART.EV_DEMO_ANALYST FROM SPECIFICATION $$...$$
   - Agent name: EV_DEMO_ANALYST
   - Instructions: "You are an EV market analyst for Washington State. Help business users understand EV adoption trends, incentive program effectiveness, and progress toward the 2030 goal."
   - Tool: cortex_analyst_text_to_sql pointing to EV_DEMO.MART.EV_REGISTRATIONS
2. Grants USAGE on the semantic view and agent to EV_DEMO_ENGINEER.
3. Verifies with SHOW AGENTS and a test query using SNOWFLAKE.CORTEX.DATA_AGENT_RUN.

The script should start with SHOW SEMANTIC VIEWS to verify the semantic view exists (it's deployed via UI, not SQL).

**Part C: Agent Integration Notes (comments in the agent spec)**
Document how this could be extended for:
- Tool-calling: adding a web search tool for real-time EV news, a Python tool for custom calculations
- External systems: CRM integration for dealer follow-up, ERP for budget tracking
- Multi-turn: maintaining conversation context for drill-down analysis

Save verified queries to semantic/verified_queries.csv
Save deployment script to setup/10_deploy_cortex.sql
```
**CoCo Output:** Verified queries **semantic/verified_queries.csv** + Deployment **setup/10_deploy_cortex.sql**

---

# Deploy Semantic View (Manual via Snowsight UI)

The semantic view YAML cannot be deployed via raw SQL or reliably via the CoCo semantic_studio tool in all account types. Deploy it manually through the Snowsight UI:

1. Go to **AI & ML → Cortex Analyst → Semantic Views**
2. Click **Create Semantic View**
3. Set name: `EV_REGISTRATIONS`, database: `EV_DEMO`, schema: `MART`
4. Add these tables:
   - `EV_DEMO.MART.FACT_EV_REGISTRATIONS`
   - `EV_DEMO.MART.DIM_VEHICLE`
   - `EV_DEMO.MART.DIM_GEOGRAPHY`
   - `EV_DEMO.MART.AGG_REGISTRATIONS_BY_YEAR`
   - `EV_DEMO.MART.AGG_REGISTRATIONS_BY_COUNTY`
   - `EV_DEMO."public"."incentive_applications"` (CDC table)
5. The wizard auto-detects columns — mark dimensions, metrics, and relationships:
   - **Relationships:** FACT.VIN → DIM_VEHICLE.VIN, FACT.GEO_KEY → DIM_GEOGRAPHY.GEO_KEY
   - **Key metrics:** COUNT(VIN) as registration_count, AVG(ELECTRIC_RANGE), approval_rate, etc.
   - Use `semantic/ev_registrations.yaml` as a reference for column descriptions and verified queries
6. Save and verify: `SHOW SEMANTIC VIEWS IN SCHEMA EV_DEMO.MART;`

Then run **setup/10_deploy_cortex.sql** to create the agent and grants.

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

#### Manual Step: Deploy Streamlit App

After CoCo generates the app file, deploy it as a Streamlit in Snowflake (SiS) object.
Run these statements in order (the workspace `snow://` URI requires copying to a named stage first):

```sql
-- Create a named stage for the Streamlit source files
CREATE STAGE IF NOT EXISTS EV_DEMO.MART.STREAMLIT_STAGE
  DIRECTORY = (ENABLE = TRUE);

-- Copy app file from workspace to the named stage
COPY FILES
  INTO @EV_DEMO.MART.STREAMLIT_STAGE
  FROM 'snow://workspace/USER$.PUBLIC."Snowflake-EV-Demo"/versions/live/streamlit/';

-- Create the Streamlit app using the FROM syntax
CREATE OR REPLACE STREAMLIT EV_DEMO.MART.EV_INSIGHTS_APP
  FROM '@EV_DEMO.MART.STREAMLIT_STAGE'
  MAIN_FILE = 'ev_insights_app.py'
  QUERY_WAREHOUSE = 'WH_EV_DEMO';

-- Initialize the live version
ALTER STREAMLIT EV_DEMO.MART.EV_INSIGHTS_APP ADD LIVE VERSION FROM LAST;

-- Grant access
GRANT USAGE ON STREAMLIT EV_DEMO.MART.EV_INSIGHTS_APP TO ROLE PUBLIC;
```

#### Accessing the Streamlit App

Once deployed, open the app in Snowsight:

1. Navigate to **Projects → Streamlit** in the left sidebar.
2. Select **EV_INSIGHTS_APP** under `EV_DEMO.MART`.
3. The app opens in-browser — no additional infrastructure required.

Direct URL format:
```
https://<your-account>.snowflakecomputing.com/#/streamlit-apps/EV_DEMO.MART.EV_INSIGHTS_APP
```

Any role granted `USAGE` on the Streamlit object (e.g., `PUBLIC`) can access the app.

---
