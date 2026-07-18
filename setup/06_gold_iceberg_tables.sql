-- Gold layer Dynamic Iceberg Tables: star schema for analytics on external volume.
-- Co-authored with CoCo

/*=============================================================================
  06_GOLD_ICEBERG_TABLES.SQL
  Creates the Gold layer as Dynamic Iceberg Tables on external storage.

  WHY DYNAMIC ICEBERG TABLES?
  • Open format (Parquet/Iceberg) — external engines (Spark, Trino, Databricks)
    can read the data directly without going through Snowflake.
  • Storage-compute separation — data lives at Azure Blob pricing, not Snowflake
    managed storage rates. Significant savings at scale.
  • Declarative refresh (TARGET_LAG = 120 minutes) — Snowflake manages lifecycle.
  • Portability — if the agency ever brings their own compute, data is portable.

  STAR SCHEMA DESIGN:
  • DIM_VEHICLE — one row per VIN (vehicle attributes)
  • DIM_GEOGRAPHY — one row per location (surrogate key via SHA2)
  • FACT_EV_REGISTRATIONS — registration events keyed to dims
  • AGG_REGISTRATIONS_BY_COUNTY — pre-aggregated for geographic analysis
  • AGG_REGISTRATIONS_BY_YEAR — pre-aggregated for trend/goal tracking

  ICEBERG DATA TYPE NOTE:
  Iceberg only supports TIMESTAMP_NTZ at microsecond precision (scale 6).
  TIMESTAMP_LTZ and TIMESTAMP_TZ are NOT supported. Nanosecond scale (9) is
  NOT supported. All timestamp columns must be cast:
    CAST(col AS TIMESTAMP_NTZ(6))
=============================================================================*/

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_EV_DEMO;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. DIM_VEHICLE
--    Distinct vehicle dimension. One row per VIN.
--    Enables slicing by make, model, ev_type, range, price segment.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DYNAMIC ICEBERG TABLE EV_DEMO.MART.DIM_VEHICLE
    TARGET_LAG = '120 minutes'
    WAREHOUSE = WH_EV_DEMO
    EXTERNAL_VOLUME = 'EV_EXT_VOL'
    CATALOG = 'SNOWFLAKE'
    BASE_LOCATION = 'dim_vehicle'
AS
SELECT DISTINCT
    VIN,
    MAKE,
    MODEL,
    MODEL_YEAR,
    EV_TYPE,
    ELECTRIC_RANGE,
    BASE_MSRP
FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. DIM_GEOGRAPHY
--    Distinct geographic dimension. Surrogate key via SHA2 hash.
--    Enables spatial analysis, equity assessments, infrastructure planning.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DYNAMIC ICEBERG TABLE EV_DEMO.MART.DIM_GEOGRAPHY
    TARGET_LAG = '120 minutes'
    WAREHOUSE = WH_EV_DEMO
    EXTERNAL_VOLUME = 'EV_EXT_VOL'
    CATALOG = 'SNOWFLAKE'
    BASE_LOCATION = 'dim_geography'
AS
SELECT DISTINCT
    SHA2(COALESCE(COUNTY, '') || '|' || COALESCE(CITY, '') || '|' || COALESCE(POSTAL_CODE, ''), 256) AS GEO_KEY,
    COUNTY,
    CITY,
    STATE,
    POSTAL_CODE,
    LEGISLATIVE_DISTRICT,
    LATITUDE,
    LONGITUDE,
    POPULATION,
    MEDIAN_INCOME,
    EV_CHARGING_STATIONS
FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. FACT_EV_REGISTRATIONS
--    Fact table joining to dimensions via VIN and geo surrogate key.
--    Each row is a vehicle registration event with contextual attributes.
--    NOTE: LOAD_TS cast from TIMESTAMP_LTZ(9) to TIMESTAMP_NTZ(6) for Iceberg.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DYNAMIC ICEBERG TABLE EV_DEMO.MART.FACT_EV_REGISTRATIONS
    TARGET_LAG = '120 minutes'
    WAREHOUSE = WH_EV_DEMO
    EXTERNAL_VOLUME = 'EV_EXT_VOL'
    CATALOG = 'SNOWFLAKE'
    BASE_LOCATION = 'fact_ev_registrations'
AS
SELECT
    VIN,
    SHA2(COALESCE(COUNTY, '') || '|' || COALESCE(CITY, '') || '|' || COALESCE(POSTAL_CODE, ''), 256) AS GEO_KEY,
    MODEL_YEAR,
    CAFV_ELIGIBILITY,
    ELECTRIC_UTILITY,
    CENSUS_TRACT,
    TARGET_EV_COUNT,
    POLICY_NAME,
    INCENTIVE_AMOUNT,
    APPLICATION_STATUS,
    CAST(LOAD_TS AS TIMESTAMP_NTZ(6)) AS LOAD_TS
FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. AGG_REGISTRATIONS_BY_COUNTY
--    Pre-aggregated for geographic distribution analysis.
--    Enables: top counties, registrations per capita, equity assessments.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DYNAMIC ICEBERG TABLE EV_DEMO.MART.AGG_REGISTRATIONS_BY_COUNTY
    TARGET_LAG = '120 minutes'
    WAREHOUSE = WH_EV_DEMO
    EXTERNAL_VOLUME = 'EV_EXT_VOL'
    CATALOG = 'SNOWFLAKE'
    BASE_LOCATION = 'agg_registrations_by_county'
AS
SELECT
    COUNTY,
    EV_TYPE,
    COUNT(*) AS REGISTRATION_COUNT,
    AVG(ELECTRIC_RANGE) AS AVG_ELECTRIC_RANGE,
    MAX(POPULATION) AS POPULATION,
    CASE
        WHEN MAX(POPULATION) > 0 THEN COUNT(*) / MAX(POPULATION)::FLOAT
        ELSE NULL
    END AS REGISTRATIONS_PER_CAPITA
FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
GROUP BY COUNTY, EV_TYPE;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. AGG_REGISTRATIONS_BY_YEAR
--    Pre-aggregated for adoption trend analysis.
--    Enables: YoY growth, progress toward 2030 goal, BEV vs PHEV split.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DYNAMIC ICEBERG TABLE EV_DEMO.MART.AGG_REGISTRATIONS_BY_YEAR
    TARGET_LAG = '120 minutes'
    WAREHOUSE = WH_EV_DEMO
    EXTERNAL_VOLUME = 'EV_EXT_VOL'
    CATALOG = 'SNOWFLAKE'
    BASE_LOCATION = 'agg_registrations_by_year'
AS
SELECT
    MODEL_YEAR,
    EV_TYPE,
    COUNT(*) AS REGISTRATION_COUNT,
    SUM(COUNT(*)) OVER (PARTITION BY EV_TYPE ORDER BY MODEL_YEAR) AS CUMULATIVE_COUNT,
    MAX(TARGET_EV_COUNT) AS TARGET_EV_COUNT,
    CASE
        WHEN MAX(TARGET_EV_COUNT) > 0
        THEN SUM(COUNT(*)) OVER (PARTITION BY EV_TYPE ORDER BY MODEL_YEAR) / MAX(TARGET_EV_COUNT)::FLOAT
        ELSE NULL
    END AS PCT_OF_GOAL
FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
GROUP BY MODEL_YEAR, EV_TYPE;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. GRANTS
--    EV_DEMO_ENGINEER needs access to Gold tables for semantic model and sharing.
--    Dynamic Iceberg Tables require GRANT SELECT ON ICEBERG TABLE syntax.
-- ─────────────────────────────────────────────────────────────────────────────
GRANT SELECT ON ICEBERG TABLE EV_DEMO.MART.DIM_VEHICLE TO ROLE EV_DEMO_ENGINEER;
GRANT SELECT ON ICEBERG TABLE EV_DEMO.MART.DIM_GEOGRAPHY TO ROLE EV_DEMO_ENGINEER;
GRANT SELECT ON ICEBERG TABLE EV_DEMO.MART.FACT_EV_REGISTRATIONS TO ROLE EV_DEMO_ENGINEER;
GRANT SELECT ON ICEBERG TABLE EV_DEMO.MART.AGG_REGISTRATIONS_BY_COUNTY TO ROLE EV_DEMO_ENGINEER;
GRANT SELECT ON ICEBERG TABLE EV_DEMO.MART.AGG_REGISTRATIONS_BY_YEAR TO ROLE EV_DEMO_ENGINEER;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. VERIFY
--    Confirm Gold tables are initializing and check row counts.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 'DIM_VEHICLE' AS table_name, COUNT(*) AS row_count FROM EV_DEMO.MART.DIM_VEHICLE
UNION ALL
SELECT 'DIM_GEOGRAPHY', COUNT(*) FROM EV_DEMO.MART.DIM_GEOGRAPHY
UNION ALL
SELECT 'FACT_EV_REGISTRATIONS', COUNT(*) FROM EV_DEMO.MART.FACT_EV_REGISTRATIONS
UNION ALL
SELECT 'AGG_REGISTRATIONS_BY_COUNTY', COUNT(*) FROM EV_DEMO.MART.AGG_REGISTRATIONS_BY_COUNTY
UNION ALL
SELECT 'AGG_REGISTRATIONS_BY_YEAR', COUNT(*) FROM EV_DEMO.MART.AGG_REGISTRATIONS_BY_YEAR;

-- Confirm these are Iceberg-backed Dynamic Tables
SHOW DYNAMIC TABLES LIKE '%' IN SCHEMA EV_DEMO.MART;
