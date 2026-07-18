-- Force a full pipeline run for demo purposes (bypass TARGET_LAG wait times).
-- Co-authored with CoCo

/*=============================================================================
  FORCE_PIPELINE_RUN.SQL
  Manually triggers the full pipeline after uploading a new file to the stage.

  WHY IS THIS NEEDED?
  In production, the pipeline is fully automated:
  • Tasks fire every 6 hours (or when stream detects new files)
  • Silver Dynamic Table refreshes within 60 minutes of upstream change
  • Gold Dynamic Iceberg Tables refresh within 120 minutes of Silver change

  For a LIVE DEMO, you don't want to wait up to 3 hours for end-to-end propagation.
  This script forces immediate execution of each layer in sequence.

  USAGE:
  1. Upload a new JSON file to @EV_DEMO.RAW.EV_STAGE (different filename from existing)
  2. Run this script top-to-bottom
  3. Verify with demo/demo_verification_queries.sql
=============================================================================*/

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_EV_DEMO;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 1: INGEST + PARSE (Bronze layer)
--    In production, the Task graph handles this automatically.
--    For demo, we run the COPY INTO and parse procedure directly.
--
--    NOTE: COPY INTO skips files it has already loaded (64-day metadata cache).
--    Only genuinely NEW files (uploaded since last COPY) will be ingested.
--    If you need to re-load a file, use FORCE = TRUE on specific files.
-- ─────────────────────────────────────────────────────────────────────────────

-- Ingest any new files from stage
COPY INTO EV_DEMO.RAW.RAW_EV_REGISTRATIONS (RAW_DATA, LOADED_AT, SOURCE_FILE)
FROM (SELECT $1, CURRENT_TIMESTAMP(), METADATA$FILENAME FROM @EV_DEMO.RAW.EV_STAGE)
FILE_FORMAT = (TYPE = 'JSON' STRIP_OUTER_ARRAY = FALSE)
ON_ERROR = 'CONTINUE';

-- Parse all raw data into structured BRONZE_PARSED
CALL EV_DEMO.RAW.SP_PARSE_EV_REGISTRATIONS();

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 2: REFRESH SILVER (Dynamic Tables)
--    TARGET_LAG = 60 minutes in production. Force immediate refresh for demo.
--
--    HOW THIS WORKS:
--    1. Ensure change tracking is enabled on BRONZE_PARSED (required for DTs)
--    2. Suspend the Dynamic Tables (stops scheduling)
--    3. Resume them (triggers a FULL re-initialization from scratch)
--    4. The RESUME itself performs the refresh — no manual REFRESH needed.
--
--    WHY SUSPEND/RESUME instead of REFRESH?
--    If change tracking was enabled AFTER the Dynamic Table was created, a manual
--    REFRESH fails because the DT's internal baseline predates the tracking start.
--    Suspend/resume resets the baseline entirely.
-- ─────────────────────────────────────────────────────────────────────────────

-- Ensure change tracking is on (idempotent)
ALTER TABLE EV_DEMO.RAW.BRONZE_PARSED SET CHANGE_TRACKING = TRUE;

-- Suspend/resume to force full re-initialization (includes refresh)
ALTER DYNAMIC TABLE EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS SUSPEND;
ALTER DYNAMIC TABLE EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS RESUME;
ALTER DYNAMIC TABLE EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS SUSPEND;
ALTER DYNAMIC TABLE EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS RESUME;

-- Verify Silver refreshed (check row count — should reflect new data)
SELECT 'SILVER' AS layer, COUNT(*) AS row_count FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
UNION ALL
SELECT 'QUARANTINE', COUNT(*) FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 3: REFRESH GOLD (Dynamic Iceberg Tables)
--    TARGET_LAG = 120 minutes in production. Force immediate refresh for demo.
--    Must run AFTER Silver refresh completes (Gold sources from Silver).
-- ─────────────────────────────────────────────────────────────────────────────
ALTER DYNAMIC TABLE EV_DEMO.MART.DIM_VEHICLE REFRESH;
ALTER DYNAMIC TABLE EV_DEMO.MART.DIM_GEOGRAPHY REFRESH;
ALTER DYNAMIC TABLE EV_DEMO.MART.FACT_EV_REGISTRATIONS REFRESH;
ALTER DYNAMIC TABLE EV_DEMO.MART.AGG_REGISTRATIONS_BY_COUNTY REFRESH;
ALTER DYNAMIC TABLE EV_DEMO.MART.AGG_REGISTRATIONS_BY_YEAR REFRESH;

-- ─────────────────────────────────────────────────────────────────────────────
-- STEP 4: VERIFY ROW COUNTS (confirm data flowed end-to-end)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 'BRONZE_PARSED' AS layer, COUNT(*) AS row_count FROM EV_DEMO.RAW.BRONZE_PARSED
UNION ALL
SELECT 'SILVER', COUNT(*) FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
UNION ALL
SELECT 'QUARANTINE', COUNT(*) FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS
UNION ALL
SELECT 'GOLD_FACT', COUNT(*) FROM EV_DEMO.MART.FACT_EV_REGISTRATIONS;
