-- Silver layer Dynamic Tables: deduplicate, standardize, validate, enrich, and quarantine.
-- Co-authored with CoCo

/*=============================================================================
  05_SILVER_DYNAMIC_TABLES.SQL
  Creates the Silver layer as Dynamic Tables that auto-refresh when upstream
  data changes (TARGET_LAG = 60 minutes).

  TWO TABLES:
  1. SILVER_EV_REGISTRATIONS — clean, enriched, validated records ready for Gold
  2. QUARANTINE_EV_REGISTRATIONS — rejected rows with explanation (nothing is lost)

  WHY DYNAMIC TABLES?
  • Declarative — Snowflake decides when to refresh based on upstream changes
  • No scheduling code, no incremental logic, no orchestrator dependency
  • Automatic dependency tracking across the DAG (Bronze → Silver → Gold)

  TRANSFORMATION LOGIC:
  • Deduplicate by VIN (keep latest LOAD_TS)
  • Standardize text (UPPER) for consistent grouping/joins
  • Parse geospatial POINT string into lat/lng floats
  • Validate business rules (ev_type, electric_range, VIN not null)
  • Enrich via LEFT JOINs to reference tables and CDC data

  CDC TABLE NOTE:
  EV_DEMO."public"."incentive_applications" — table/schema names are lowercase-quoted
  (PostgreSQL convention), but COLUMN names are standard UPPERCASE unquoted identifiers
  in Snowflake: MAKE, MODEL, APPLICANT_ZIP, INCENTIVE_AMOUNT, STATUS, UPDATED_AT.
=============================================================================*/

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_EV_DEMO;

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. PREREQUISITE: Enable change tracking on BRONZE_PARSED
--    Dynamic Tables require change tracking on source tables to detect updates.
--    Without this, REFRESH and auto-refresh will fail with:
--    "Change tracking is not enabled or has been missing for the time range requested"
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE EV_DEMO.RAW.BRONZE_PARSED SET CHANGE_TRACKING = TRUE;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. SILVER_EV_REGISTRATIONS
--    The core analytical table: one clean, enriched row per vehicle.
--    Feeds all Gold layer aggregations and the semantic model.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DYNAMIC TABLE EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
    TARGET_LAG = '60 minutes'
    WAREHOUSE = WH_EV_DEMO
AS
WITH deduplicated AS (
    -- Keep only the latest record per VIN (handles re-ingestion / corrections)
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY VIN ORDER BY LOAD_TS DESC) AS rn
        FROM EV_DEMO.RAW.BRONZE_PARSED
    )
    WHERE rn = 1
),
validated AS (
    -- Filter to valid records only (quarantine handles the rejects)
    SELECT *
    FROM deduplicated
    WHERE VIN IS NOT NULL
      AND EV_TYPE IN ('Battery Electric Vehicle (BEV)', 'Plug-in Hybrid Electric Vehicle (PHEV)')
      AND (ELECTRIC_RANGE >= 0 OR ELECTRIC_RANGE IS NULL)
),
latest_incentive AS (
    -- Get the most recent incentive application per make/model/zip combination.
    -- Column names are UPPERCASE unquoted (Snowflake connector convention).
    SELECT
        UPPER(MAKE) AS INC_MAKE,
        UPPER(MODEL) AS INC_MODEL,
        APPLICANT_ZIP AS INC_ZIP,
        INCENTIVE_AMOUNT,
        STATUS AS APPLICATION_STATUS,
        ROW_NUMBER() OVER (
            PARTITION BY UPPER(MAKE), UPPER(MODEL), APPLICANT_ZIP
            ORDER BY UPDATED_AT DESC
        ) AS rn
    FROM EV_DEMO."public"."incentive_applications"
)
SELECT
    -- Core vehicle fields
    v.VIN,
    UPPER(v.COUNTY) AS COUNTY,
    UPPER(v.CITY) AS CITY,
    v.STATE,
    CAST(v.POSTAL_CODE AS VARCHAR(10)) AS POSTAL_CODE,
    v.MODEL_YEAR,
    UPPER(v.MAKE) AS MAKE,
    UPPER(v.MODEL) AS MODEL,
    v.EV_TYPE,
    v.CAFV_ELIGIBILITY,
    v.ELECTRIC_RANGE,
    v.BASE_MSRP,
    CAST(v.LEGISLATIVE_DISTRICT AS VARCHAR(5)) AS LEGISLATIVE_DISTRICT,
    v.ELECTRIC_UTILITY,
    v.CENSUS_TRACT,

    -- Parsed geospatial (VEHICLE_LOCATION format: "POINT (lng lat)")
    TRY_CAST(SPLIT_PART(REPLACE(REPLACE(v.VEHICLE_LOCATION, 'POINT (', ''), ')', ''), ' ', 1) AS FLOAT) AS LONGITUDE,
    TRY_CAST(SPLIT_PART(REPLACE(REPLACE(v.VEHICLE_LOCATION, 'POINT (', ''), ')', ''), ' ', 2) AS FLOAT) AS LATITUDE,

    -- Enrichment: demographics (from reference table)
    z.POPULATION,
    z.MEDIAN_INCOME,
    z.EV_CHARGING_STATIONS,

    -- Enrichment: state policy targets (from reference table)
    g.TARGET_EV_COUNT,
    g.POLICY_NAME,

    -- Enrichment: incentive program (from CDC)
    i.INCENTIVE_AMOUNT,
    i.APPLICATION_STATUS,

    -- Audit
    v.LOAD_TS

FROM validated v

-- Join to zip demographics on postal_code
LEFT JOIN EV_DEMO.RAW.ZIP_CODE_DEMOGRAPHICS z
    ON CAST(v.POSTAL_CODE AS VARCHAR(10)) = z.ZIP_CODE

-- Join to state EV goals on state + model_year
LEFT JOIN EV_DEMO.RAW.STATE_EV_GOALS g
    ON v.STATE = g.STATE
    AND v.MODEL_YEAR = g.YEAR

-- Join to latest incentive application per vehicle match
LEFT JOIN latest_incentive i
    ON UPPER(v.MAKE) = i.INC_MAKE
    AND UPPER(v.MODEL) = i.INC_MODEL
    AND CAST(v.POSTAL_CODE AS VARCHAR(10)) = i.INC_ZIP
    AND i.rn = 1;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. QUARANTINE_EV_REGISTRATIONS
--    Captures rows that fail validation with a human-readable reason.
--    Ensures every Bronze record is accounted for (Silver + Quarantine = Bronze).
--    Critical for government audiences: no data silently disappears.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DYNAMIC TABLE EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS
    TARGET_LAG = '60 minutes'
    WAREHOUSE = WH_EV_DEMO
AS
WITH deduplicated AS (
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY VIN ORDER BY LOAD_TS DESC) AS rn
        FROM EV_DEMO.RAW.BRONZE_PARSED
    )
    WHERE rn = 1
)
SELECT
    VIN,
    COUNTY,
    CITY,
    STATE,
    POSTAL_CODE,
    MODEL_YEAR,
    MAKE,
    MODEL,
    EV_TYPE,
    ELECTRIC_RANGE,
    LOAD_TS,

    -- Explain why this row was rejected
    CASE
        WHEN VIN IS NULL THEN 'VIN is NULL'
        WHEN EV_TYPE NOT IN ('Battery Electric Vehicle (BEV)', 'Plug-in Hybrid Electric Vehicle (PHEV)')
            THEN 'Invalid ev_type: ' || COALESCE(EV_TYPE, 'NULL')
        WHEN ELECTRIC_RANGE < 0
            THEN 'Negative electric_range: ' || ELECTRIC_RANGE::VARCHAR
        ELSE 'Unknown rejection reason'
    END AS REJECTION_REASON

FROM deduplicated
WHERE VIN IS NULL
   OR EV_TYPE NOT IN ('Battery Electric Vehicle (BEV)', 'Plug-in Hybrid Electric Vehicle (PHEV)')
   OR ELECTRIC_RANGE < 0;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. GRANTS
--    EV_DEMO_ENGINEER needs access to Silver tables for downstream operations.
-- ─────────────────────────────────────────────────────────────────────────────
GRANT SELECT ON DYNAMIC TABLE EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS TO ROLE EV_DEMO_ENGINEER;
GRANT SELECT ON DYNAMIC TABLE EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS TO ROLE EV_DEMO_ENGINEER;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. VERIFY
--    Check row counts and confirm the Dynamic Tables are initializing.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 'SILVER_EV_REGISTRATIONS' AS table_name, COUNT(*) AS row_count
FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
UNION ALL
SELECT 'QUARANTINE_EV_REGISTRATIONS', COUNT(*)
FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS;

-- Check Dynamic Table refresh status
SELECT name, scheduling_state
FROM TABLE(EV_DEMO.INFORMATION_SCHEMA.DYNAMIC_TABLES())
WHERE SCHEMA_NAME = 'CLEAN'
ORDER BY name;
