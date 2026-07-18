-- Demo verification queries: end-to-end pipeline walkthrough for live presentations.
-- Co-authored with CoCo

/*=============================================================================
  DEMO_VERIFICATION_QUERIES.SQL
  Run these queries live during a demo to prove data flows end-to-end.
  Each section shows a different layer of the medallion architecture.

  This is NOT automated monitoring — it's a "show don't tell" script for
  walking someone through the pipeline during a live demo or interview.

  Prerequisite: Run all setup scripts (01-06) before using this file.
=============================================================================*/

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_EV_DEMO;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. BRONZE — Raw Ingestion Layer
--    "This is our immutable landing zone. Raw JSON, untransformed."
-- ═══════════════════════════════════════════════════════════════════════════════

-- Row counts: how much raw data do we have?
SELECT 'RAW_EV_REGISTRATIONS (VARIANT)' AS layer, COUNT(*) AS row_count
FROM EV_DEMO.RAW.RAW_EV_REGISTRATIONS
UNION ALL
SELECT 'BRONZE_PARSED (structured)', COUNT(*)
FROM EV_DEMO.RAW.BRONZE_PARSED;

-- Sample raw VARIANT record (show the audience what raw JSON looks like)
-- NOTE: columns are RAW_DATA, LOADED_AT, SOURCE_FILE (not LOAD_TS)
SELECT RAW_DATA, LOADED_AT, SOURCE_FILE
FROM EV_DEMO.RAW.RAW_EV_REGISTRATIONS
LIMIT 1;

-- Sample parsed record (show the Snowpark procedure's output)
SELECT VIN, MAKE, MODEL, MODEL_YEAR, EV_TYPE, COUNTY, POSTAL_CODE, ELECTRIC_RANGE
FROM EV_DEMO.RAW.BRONZE_PARSED
LIMIT 5;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. CDC — Real-time Operational Data (PostgreSQL Connector)
--    "This table changes daily as the state processes incentive applications."
-- ═══════════════════════════════════════════════════════════════════════════════

-- Application counts by status (shows the operational mix)
-- NOTE: table/schema names lowercase-quoted, column names UPPERCASE unquoted
SELECT STATUS, COUNT(*) AS application_count
FROM EV_DEMO."public"."incentive_applications"
GROUP BY STATUS
ORDER BY application_count DESC;

-- Sample applications (show the audience what CDC data looks like)
SELECT APPLICATION_ID, SUBMITTED_DATE, MAKE, MODEL, APPLICANT_ZIP,
       INCENTIVE_AMOUNT, STATUS, REVIEWED_DATE
FROM EV_DEMO."public"."incentive_applications"
ORDER BY SUBMITTED_DATE DESC
LIMIT 5;

-- Connector status (confirms CDC is active)
CALL SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL.PUBLIC.GET_CONNECTOR_STATUS();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. REFERENCE — Static Lookup Tables (SQL Seeds)
--    "Small, version-controlled datasets that change annually at most."
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT 'ZIP_CODE_DEMOGRAPHICS' AS table_name, COUNT(*) AS row_count
FROM EV_DEMO.RAW.ZIP_CODE_DEMOGRAPHICS
UNION ALL
SELECT 'STATE_EV_GOALS', COUNT(*)
FROM EV_DEMO.RAW.STATE_EV_GOALS;

-- Show the WA state EV targets (context for the Gold layer metrics)
SELECT * FROM EV_DEMO.RAW.STATE_EV_GOALS ORDER BY YEAR;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. SILVER — Enriched & Validated (Dynamic Tables)
--    "Three sources joined, deduplicated, standardized, validated."
-- ═══════════════════════════════════════════════════════════════════════════════

-- Row count and freshness (query LOAD_TS from Silver, not Gold — Silver supports TIMESTAMP_LTZ)
SELECT
    COUNT(*) AS row_count,
    MAX(LOAD_TS) AS most_recent_record,
    DATEDIFF('minute', MAX(LOAD_TS), CURRENT_TIMESTAMP()) AS minutes_since_latest
FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS;

-- Sample enriched row (show joins working: demographics + goals + incentives)
SELECT VIN, MAKE, MODEL, COUNTY, POSTAL_CODE,
       POPULATION, MEDIAN_INCOME, EV_CHARGING_STATIONS,
       TARGET_EV_COUNT, POLICY_NAME,
       INCENTIVE_AMOUNT, APPLICATION_STATUS
FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
WHERE POPULATION IS NOT NULL
LIMIT 5;

-- Quarantine breakdown (show validation rules catching bad data)
SELECT REJECTION_REASON, COUNT(*) AS rejected_count
FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS
GROUP BY REJECTION_REASON
ORDER BY rejected_count DESC;

-- Dynamic Table refresh status (must qualify with database name)
SELECT NAME, SCHEDULING_STATE
FROM TABLE(EV_DEMO.INFORMATION_SCHEMA.DYNAMIC_TABLES())
WHERE SCHEMA_NAME = 'CLEAN'
ORDER BY NAME;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. GOLD — Star Schema on Iceberg (Dynamic Iceberg Tables)
--    "Open format, readable by Spark/Trino, auto-refreshing."
-- ═══════════════════════════════════════════════════════════════════════════════

-- Dimension/fact row counts
SELECT 'DIM_VEHICLE' AS table_name, COUNT(*) AS row_count FROM EV_DEMO.MART.DIM_VEHICLE
UNION ALL
SELECT 'DIM_GEOGRAPHY', COUNT(*) FROM EV_DEMO.MART.DIM_GEOGRAPHY
UNION ALL
SELECT 'FACT_EV_REGISTRATIONS', COUNT(*) FROM EV_DEMO.MART.FACT_EV_REGISTRATIONS
UNION ALL
SELECT 'AGG_REGISTRATIONS_BY_COUNTY', COUNT(*) FROM EV_DEMO.MART.AGG_REGISTRATIONS_BY_COUNTY
UNION ALL
SELECT 'AGG_REGISTRATIONS_BY_YEAR', COUNT(*) FROM EV_DEMO.MART.AGG_REGISTRATIONS_BY_YEAR;

-- Business insight: top 10 makes by registration count
SELECT MAKE, COUNT(*) AS registrations, AVG(ELECTRIC_RANGE) AS avg_range
FROM EV_DEMO.MART.DIM_VEHICLE
GROUP BY MAKE
ORDER BY registrations DESC
LIMIT 10;

-- Adoption trend: progress toward the 2030 goal
SELECT MODEL_YEAR, EV_TYPE, REGISTRATION_COUNT, CUMULATIVE_COUNT,
       TARGET_EV_COUNT, ROUND(PCT_OF_GOAL * 100, 2) AS pct_of_goal
FROM EV_DEMO.MART.AGG_REGISTRATIONS_BY_YEAR
WHERE MODEL_YEAR >= 2020
ORDER BY MODEL_YEAR, EV_TYPE;

-- Iceberg table status (confirm is_iceberg column = true)
SHOW DYNAMIC TABLES LIKE '%' IN SCHEMA EV_DEMO.MART;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. PIPELINE HEALTH SUMMARY
--    "Every vehicle is accounted for. Silver + Quarantine = Distinct VINs in Bronze."
--    NOTE: Bronze has ~22k raw rows but only ~5k distinct VINs (multiple snapshots
--    per vehicle). Deduplication is intentional — Silver keeps one row per VIN.
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    (SELECT COUNT(*) FROM EV_DEMO.RAW.RAW_EV_REGISTRATIONS) AS raw_variant,
    (SELECT COUNT(*) FROM EV_DEMO.RAW.BRONZE_PARSED) AS bronze_parsed,
    (SELECT COUNT(DISTINCT VIN) FROM EV_DEMO.RAW.BRONZE_PARSED) AS bronze_distinct_vins,
    (SELECT COUNT(*) FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS) AS silver,
    (SELECT COUNT(*) FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS) AS quarantine,
    (SELECT COUNT(*) FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS)
      + (SELECT COUNT(*) FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS) AS silver_plus_quarantine,
    (SELECT COUNT(*) FROM EV_DEMO.MART.FACT_EV_REGISTRATIONS) AS gold_fact,
    CASE
        WHEN (SELECT COUNT(DISTINCT VIN) FROM EV_DEMO.RAW.BRONZE_PARSED)
           = (SELECT COUNT(*) FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS)
           + (SELECT COUNT(*) FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS)
        THEN 'PASS — all vehicles accounted for (dedup reduces raw rows to distinct VINs)'
        ELSE 'INVESTIGATE — row count mismatch'
    END AS reconciliation_status;
