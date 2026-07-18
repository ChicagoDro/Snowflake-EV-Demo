-- Create static reference tables via SQL and verify CDC replication for the Silver layer.
-- Co-authored with CoCo

/*=============================================================================
  04_STATIC_REFERENCE_TABLES.SQL
  Sets up reference/operational data sources for the Silver layer.

  DATA SOURCE STRATEGY:
  ┌─────────────────────────────────┬────────────────────────────────────────┐
  │ Source                          │ Why this approach?                     │
  ├─────────────────────────────────┼────────────────────────────────────────┤
  │ incentive_applications (CDC)    │ Operational — status changes daily as  │
  │ EV_DEMO."public"                │ residents apply and state approves.    │
  │                                 │ CDC keeps Snowflake current without    │
  │                                 │ manual ETL. Lives in connector-managed │
  │                                 │ schema; Silver references directly.    │
  ├─────────────────────────────────┼────────────────────────────────────────┤
  │ zip_code_demographics (SQL)     │ Static — population/income data        │
  │ EV_DEMO.RAW                     │ changes annually at most. 15 rows.     │
  │                                 │ Direct SQL keeps pipeline 100%         │
  │                                 │ Snowflake-native with no external      │
  │                                 │ tooling dependency.                    │
  ├─────────────────────────────────┼────────────────────────────────────────┤
  │ state_ev_goals (SQL)            │ Static — legislative targets set by    │
  │ EV_DEMO.RAW                     │ policy. 11 rows. Updated annually at   │
  │                                 │ most. Same rationale as above.         │
  └─────────────────────────────────┴────────────────────────────────────────┘

  WHEN WOULD dbt SEEDS BE THE BETTER CHOICE?
  • Large seed files (hundreds+ rows) that benefit from dbt's chunked loading
  • Teams already using dbt for transformation — seeds keep everything in one DAG
  • Need for dbt's built-in schema tests (unique, not_null, accepted_values)
  • Cross-warehouse portability required (Snowflake, BigQuery, Redshift)
  • Complex dependency management where seed freshness feeds downstream models

  JOIN PATHS (used in Silver layer):
  • BRONZE_PARSED.POSTAL_CODE ↔ zip_code_demographics.zip_code
  • BRONZE_PARSED.STATE + MODEL_YEAR ↔ state_ev_goals.state + year
  • BRONZE_PARSED.MAKE + MODEL + POSTAL_CODE ↔ incentive_applications.make + model + applicant_zip
=============================================================================*/

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_EV_DEMO;

-- ─────────────────────────────────────────────────────────────────────────────
-- PART A: REFERENCE TABLES (static data via SQL)
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. ZIP_CODE_DEMOGRAPHICS
--    Static population/income/charging-station data for 15 key WA zip codes.
--    Refreshed annually from census data. Joined to Silver on postal_code.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE EV_DEMO.RAW.ZIP_CODE_DEMOGRAPHICS (
    zip_code              VARCHAR(10),
    population            INTEGER,
    median_income         INTEGER,
    ev_charging_stations  INTEGER
);

INSERT INTO EV_DEMO.RAW.ZIP_CODE_DEMOGRAPHICS (zip_code, population, median_income, ev_charging_stations)
VALUES
    ('98101', 35000, 95000, 42),
    ('98103', 45000, 88000, 38),
    ('98105', 28000, 92000, 25),
    ('98115', 40000, 85000, 31),
    ('98122', 32000, 78000, 28),
    ('98004', 38000, 145000, 55),
    ('98005', 33000, 120000, 48),
    ('98052', 62000, 135000, 62),
    ('98033', 48000, 125000, 44),
    ('98109', 25000, 98000, 35),
    ('98271', 22000, 72000, 12),
    ('98501', 42000, 68000, 18),
    ('98225', 55000, 62000, 15),
    ('98902', 35000, 58000, 8),
    ('99201', 48000, 52000, 22);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. STATE_EV_GOALS
--    Washington State legislative EV adoption targets (Clean Cars 2030).
--    Joined to Silver on state + model_year to show progress vs. policy.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE EV_DEMO.RAW.STATE_EV_GOALS (
    state             VARCHAR(2),
    year              INTEGER,
    target_ev_count   INTEGER,
    policy_name       VARCHAR(100)
);

INSERT INTO EV_DEMO.RAW.STATE_EV_GOALS (state, year, target_ev_count, policy_name)
VALUES
    ('WA', 2025, 500000, 'Clean Cars 2030'),
    ('WA', 2026, 600000, 'Clean Cars 2030'),
    ('WA', 2027, 720000, 'Clean Cars 2030'),
    ('WA', 2028, 860000, 'Clean Cars 2030'),
    ('WA', 2029, 1020000, 'Clean Cars 2030'),
    ('WA', 2030, 1200000, 'Clean Cars 2030'),
    ('WA', 2031, 1350000, 'Clean Cars 2030 Extension'),
    ('WA', 2032, 1500000, 'Clean Cars 2030 Extension'),
    ('WA', 2033, 1650000, 'Clean Cars 2030 Extension'),
    ('WA', 2034, 1800000, 'Clean Cars 2030 Extension'),
    ('WA', 2035, 2000000, 'Clean Cars 2030 Extension');

-- ─────────────────────────────────────────────────────────────────────────────
-- PART B: CDC VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. GRANT CONNECTOR APPLICATION ROLE
--    The CDC tables are owned by the SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL app.
--    DATA_READER app role provides SELECT access to replicated tables.
--    Without this grant, even ACCOUNTADMIN cannot query the CDC schema.
-- ─────────────────────────────────────────────────────────────────────────────
GRANT APPLICATION ROLE SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL.DATA_READER
    TO ROLE ACCOUNTADMIN;

GRANT APPLICATION ROLE SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL.DATA_READER
    TO ROLE EV_DEMO_ENGINEER;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. VERIFY CDC TABLE: incentive_applications
--    Confirms replication is active and data has synced from PostgreSQL.
--    NOTE: Table uses lowercase identifiers (PostgreSQL convention) — must quote.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 'incentive_applications row count' AS check_name,
       COUNT(*)::VARCHAR AS result
FROM EV_DEMO."public"."incentive_applications";

SELECT * FROM EV_DEMO."public"."incentive_applications" LIMIT 5;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. CHECK CONNECTOR STATUS
--    GET_CONNECTOR_STATUS confirms the connector is active (status = STARTED).
--    If status is not STARTED, CDC may have stalled — check agent Docker logs.
-- ─────────────────────────────────────────────────────────────────────────────
CALL SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL.PUBLIC.GET_CONNECTOR_STATUS();

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. GRANTS
--    EV_DEMO_ENGINEER needs SELECT on reference tables and CDC tables for
--    Silver layer joins. FUTURE TABLES grant ensures new replicated tables
--    are auto-accessible.
-- ─────────────────────────────────────────────────────────────────────────────
GRANT SELECT ON TABLE EV_DEMO.RAW.ZIP_CODE_DEMOGRAPHICS TO ROLE EV_DEMO_ENGINEER;
GRANT SELECT ON TABLE EV_DEMO.RAW.STATE_EV_GOALS TO ROLE EV_DEMO_ENGINEER;

GRANT USAGE ON SCHEMA EV_DEMO."public" TO ROLE EV_DEMO_ENGINEER;
GRANT SELECT ON ALL TABLES IN SCHEMA EV_DEMO."public" TO ROLE EV_DEMO_ENGINEER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA EV_DEMO."public" TO ROLE EV_DEMO_ENGINEER;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. FINAL VERIFICATION
--    Confirm all three data sources are populated and accessible.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 'zip_code_demographics' AS source, COUNT(*) AS row_count FROM EV_DEMO.RAW.ZIP_CODE_DEMOGRAPHICS
UNION ALL
SELECT 'state_ev_goals', COUNT(*) FROM EV_DEMO.RAW.STATE_EV_GOALS
UNION ALL
SELECT 'incentive_applications (CDC)', COUNT(*) FROM EV_DEMO."public"."incentive_applications";
