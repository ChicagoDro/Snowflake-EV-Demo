-- Data quality monitoring with Snowflake Data Metric Functions (DMFs) on Silver/Quarantine.
-- Co-authored with CoCo

/*=============================================================================
  07_DATA_QUALITY.SQL
  Automated data quality monitoring using Snowflake's native DMF framework.

  WHY DMFs?
  • Native to Snowflake — no external tools (Great Expectations, dbt tests)
  • Serverless compute — runs on schedule without a warehouse
  • Results stored in EV_DEMO.OBS.DMF_RESULTS (DIY approach — works on all editions)
  • Enterprise Edition users can also access SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
  • Integrated with Snowflake alerting for threshold breaches

  DMF STRATEGY:
  • COMPLETENESS — are critical fields populated? (custom DMF)
  • UNIQUENESS — is our dedup logic working? (custom DMF)
  • FRESHNESS — is data flowing? (built-in SNOWFLAKE.CORE.FRESHNESS)
  • BUSINESS_RULES — are validation rules holding? (custom DMF)
  • ROW_COUNT_RECONCILIATION — does Silver + Quarantine = distinct Bronze VINs? (custom DMF)

  IMPORTANT — DMF LIMITATIONS:
  • DMF expressions MUST be deterministic — no CURRENT_TIMESTAMP(), CURRENT_DATE(), RANDOM().
  • For freshness, use built-in SNOWFLAKE.CORE.FRESHNESS instead of a custom DMF.
  • DATA_METRIC_SCHEDULE valid formats: 'TRIGGER_ON_CHANGES', 'N MINUTES' (plural), 'USING CRON ...'.
  • DMFs require Enterprise Edition and EXECUTE DATA METRIC FUNCTION privilege.
=============================================================================*/

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_EV_DEMO;

-- Grant DMF execution privilege
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE ACCOUNTADMIN;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. CUSTOM DATA METRIC FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- 1a. COMPLETENESS: % of non-null VINs
--     Returns the percentage of rows where VIN is NOT NULL.
--     Expected: 100% in Silver (nulls route to Quarantine).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DATA METRIC FUNCTION EV_DEMO.OBS.DMF_VIN_COMPLETENESS(
    arg_t TABLE(arg_c1 VARCHAR)
)
RETURNS NUMBER
AS
$$
    SELECT ROUND(COUNT_IF(arg_c1 IS NOT NULL) * 100.0 / NULLIF(COUNT(*), 0), 2)
    FROM arg_t
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1b. UNIQUENESS: count of duplicate VINs
--     Returns the number of VINs that appear more than once.
--     Expected: 0 in Silver (dedup keeps one row per VIN).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DATA METRIC FUNCTION EV_DEMO.OBS.DMF_DUPLICATE_VIN_COUNT(
    arg_t TABLE(arg_c1 VARCHAR)
)
RETURNS NUMBER
AS
$$
    SELECT COUNT(*) FROM (
        SELECT arg_c1 FROM arg_t GROUP BY arg_c1 HAVING COUNT(*) > 1
    )
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1c. BUSINESS_RULES: count of rows violating EV type or range rules
--     Returns rows where ev_type is invalid OR electric_range < 0.
--     Expected: 0 in Silver (violators route to Quarantine).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DATA METRIC FUNCTION EV_DEMO.OBS.DMF_INVALID_BUSINESS_RULES(
    arg_t TABLE(arg_c1 VARCHAR, arg_c2 NUMBER)
)
RETURNS NUMBER
AS
$$
    SELECT COUNT_IF(
        arg_c1 NOT IN ('Battery Electric Vehicle (BEV)', 'Plug-in Hybrid Electric Vehicle (PHEV)')
        OR arg_c2 < 0
    )
    FROM arg_t
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1d. ROW_COUNT_RECONCILIATION: distinct Bronze VINs minus (Silver + Quarantine)
--     Returns the difference. Expected: 0 (all vehicles accounted for).
--     NOTE: References multiple tables — uses the arg_t input as trigger only.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE DATA METRIC FUNCTION EV_DEMO.OBS.DMF_ROW_COUNT_RECONCILIATION(
    arg_t TABLE(arg_c1 VARCHAR)
)
RETURNS NUMBER
AS
$$
    SELECT
        (SELECT COUNT(DISTINCT VIN) FROM EV_DEMO.RAW.BRONZE_PARSED)
        - (SELECT COUNT(*) FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS)
        - (SELECT COUNT(*) FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS)
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. SET SCHEDULES ON TARGET TABLES
--    Valid intervals: 5, 15, 30, 60, 720, 1440 MINUTES, TRIGGER_ON_CHANGES, or CRON.
--    120 MINUTES is NOT valid — use 60 MINUTES or a CRON expression instead.
-- ═══════════════════════════════════════════════════════════════════════════════

-- 60 MINUTES on Silver (aligned with Dynamic Table TARGET_LAG)
ALTER TABLE EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
    SET DATA_METRIC_SCHEDULE = '60 MINUTES';

-- 720 MINUTES on Quarantine (less frequent — quarantine is a low-activity table)
ALTER TABLE EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS
    SET DATA_METRIC_SCHEDULE = '720 MINUTES';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. ATTACH DMFs TO TABLES
-- ═══════════════════════════════════════════════════════════════════════════════

-- Custom DMFs on Silver
ALTER TABLE EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
    ADD DATA METRIC FUNCTION EV_DEMO.OBS.DMF_VIN_COMPLETENESS ON (VIN);

ALTER TABLE EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
    ADD DATA METRIC FUNCTION EV_DEMO.OBS.DMF_DUPLICATE_VIN_COUNT ON (VIN);

ALTER TABLE EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
    ADD DATA METRIC FUNCTION EV_DEMO.OBS.DMF_INVALID_BUSINESS_RULES ON (EV_TYPE, ELECTRIC_RANGE);

ALTER TABLE EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
    ADD DATA METRIC FUNCTION EV_DEMO.OBS.DMF_ROW_COUNT_RECONCILIATION ON (VIN);

-- Built-in FRESHNESS on Silver (handles non-determinism internally)
ALTER TABLE EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.FRESHNESS ON (LOAD_TS);

-- Completeness check on Quarantine
ALTER TABLE EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS
    ADD DATA METRIC FUNCTION EV_DEMO.OBS.DMF_VIN_COMPLETENESS ON (VIN);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. DIY DMF RESULTS TABLE + EVALUATION PROCEDURE
--    SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS requires Enterprise Edition.
--    This DIY approach stores DMF results in a custom table and evaluates them
--    via a stored procedure on a scheduled task — works on all editions.
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS EV_DEMO.OBS.DMF_RESULTS (
    SCHEDULED_TIME TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    MEASUREMENT_TIME TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    TABLE_DATABASE VARCHAR DEFAULT 'EV_DEMO',
    TABLE_SCHEMA VARCHAR,
    TABLE_NAME VARCHAR,
    METRIC_NAME VARCHAR,
    VALUE NUMBER(38, 2)
);

CREATE OR REPLACE PROCEDURE EV_DEMO.OBS.SP_EVALUATE_DMFS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
COMMENT = 'Evaluates all DMFs manually and inserts results into OBS.DMF_RESULTS. DIY replacement for Enterprise-only SNOWFLAKE.LOCAL.'
AS
BEGIN
    -- DMF_VIN_COMPLETENESS on Silver
    INSERT INTO EV_DEMO.OBS.DMF_RESULTS (TABLE_SCHEMA, TABLE_NAME, METRIC_NAME, VALUE)
    SELECT 'CLEAN', 'SILVER_EV_REGISTRATIONS', 'DMF_VIN_COMPLETENESS',
           EV_DEMO.OBS.DMF_VIN_COMPLETENESS(SELECT VIN FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS);

    -- DMF_DUPLICATE_VIN_COUNT on Silver
    INSERT INTO EV_DEMO.OBS.DMF_RESULTS (TABLE_SCHEMA, TABLE_NAME, METRIC_NAME, VALUE)
    SELECT 'CLEAN', 'SILVER_EV_REGISTRATIONS', 'DMF_DUPLICATE_VIN_COUNT',
           EV_DEMO.OBS.DMF_DUPLICATE_VIN_COUNT(SELECT VIN FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS);

    -- DMF_INVALID_BUSINESS_RULES on Silver
    INSERT INTO EV_DEMO.OBS.DMF_RESULTS (TABLE_SCHEMA, TABLE_NAME, METRIC_NAME, VALUE)
    SELECT 'CLEAN', 'SILVER_EV_REGISTRATIONS', 'DMF_INVALID_BUSINESS_RULES',
           EV_DEMO.OBS.DMF_INVALID_BUSINESS_RULES(SELECT EV_TYPE, ELECTRIC_RANGE FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS);

    -- DMF_ROW_COUNT_RECONCILIATION on Silver
    INSERT INTO EV_DEMO.OBS.DMF_RESULTS (TABLE_SCHEMA, TABLE_NAME, METRIC_NAME, VALUE)
    SELECT 'CLEAN', 'SILVER_EV_REGISTRATIONS', 'DMF_ROW_COUNT_RECONCILIATION',
           EV_DEMO.OBS.DMF_ROW_COUNT_RECONCILIATION(SELECT VIN FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS);

    -- FRESHNESS on Silver
    INSERT INTO EV_DEMO.OBS.DMF_RESULTS (TABLE_SCHEMA, TABLE_NAME, METRIC_NAME, VALUE)
    SELECT 'CLEAN', 'SILVER_EV_REGISTRATIONS', 'FRESHNESS',
           SNOWFLAKE.CORE.FRESHNESS(SELECT LOAD_TS FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS);

    -- DMF_VIN_COMPLETENESS on Quarantine
    INSERT INTO EV_DEMO.OBS.DMF_RESULTS (TABLE_SCHEMA, TABLE_NAME, METRIC_NAME, VALUE)
    SELECT 'CLEAN', 'QUARANTINE_EV_REGISTRATIONS', 'DMF_VIN_COMPLETENESS',
           EV_DEMO.OBS.DMF_VIN_COMPLETENESS(SELECT VIN FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS);

    RETURN 'DMF evaluation complete — ' || CURRENT_TIMESTAMP()::VARCHAR;
END;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. SCHEDULED TASK + DASHBOARD VIEW
--    Task runs hourly to populate DMF_RESULTS. View adds PASS/WARN/FAIL logic.
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TASK EV_DEMO.OBS.TASK_EVALUATE_DMFS
    WAREHOUSE = WH_EV_DEMO
    SCHEDULE = 'USING CRON 0 * * * * America/Los_Angeles'
    COMMENT = 'Evaluates all DMFs hourly and stores results in OBS.DMF_RESULTS'
AS
    CALL EV_DEMO.OBS.SP_EVALUATE_DMFS();

ALTER TASK EV_DEMO.OBS.TASK_EVALUATE_DMFS RESUME;

CREATE OR REPLACE VIEW EV_DEMO.OBS.V_DATA_QUALITY_DASHBOARD AS
SELECT
    SCHEDULED_TIME,
    MEASUREMENT_TIME,
    TABLE_SCHEMA,
    TABLE_NAME,
    METRIC_NAME,
    VALUE,
    CASE
        WHEN METRIC_NAME = 'DMF_VIN_COMPLETENESS' AND VALUE < 100 THEN 'WARN — incomplete VINs'
        WHEN METRIC_NAME = 'DMF_DUPLICATE_VIN_COUNT' AND VALUE > 0 THEN 'FAIL — duplicate VINs detected'
        WHEN METRIC_NAME = 'FRESHNESS' AND VALUE > 10800 THEN 'WARN — data stale (>3 hours)'
        WHEN METRIC_NAME = 'DMF_INVALID_BUSINESS_RULES' AND VALUE > 0 THEN 'FAIL — invalid rows in Silver'
        WHEN METRIC_NAME = 'DMF_ROW_COUNT_RECONCILIATION' AND VALUE != 0 THEN 'FAIL — row count mismatch'
        ELSE 'PASS'
    END AS QUALITY_STATUS
FROM EV_DEMO.OBS.DMF_RESULTS
ORDER BY MEASUREMENT_TIME DESC;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. ALERTING
--    Fire an alert when any quality metric breaches its threshold.
-- ═══════════════════════════════════════════════════════════════════════════════

-- Notification integration (email-based)
-- NOTE: ALLOWED_RECIPIENTS must contain validated emails belonging to users in this account.
CREATE OR REPLACE NOTIFICATION INTEGRATION EV_DEMO_DQ_ALERTS
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('norm@tamisin.com');

-- Alert: fires when any DMF indicates a failure (checks last 2 hours of results)
CREATE OR REPLACE ALERT EV_DEMO.OBS.ALERT_DATA_QUALITY_BREACH
    WAREHOUSE = WH_EV_DEMO
    SCHEDULE = 'USING CRON 0 */2 * * * America/Los_Angeles'
    IF (EXISTS (
        SELECT 1
        FROM EV_DEMO.OBS.DMF_RESULTS
        WHERE MEASUREMENT_TIME > SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME()
          AND (
              (METRIC_NAME = 'DMF_DUPLICATE_VIN_COUNT' AND VALUE > 0)
              OR (METRIC_NAME = 'DMF_INVALID_BUSINESS_RULES' AND VALUE > 0)
              OR (METRIC_NAME = 'DMF_ROW_COUNT_RECONCILIATION' AND VALUE != 0)
              OR (METRIC_NAME = 'FRESHNESS' AND VALUE > 21600)
          )
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'EV_DEMO_DQ_ALERTS',
            'norm@tamisin.com',
            'EV Demo: Data Quality Alert',
            'One or more data quality metrics have breached their threshold. Check EV_DEMO.OBS.V_DATA_QUALITY_DASHBOARD for details.'
        );

-- Resume the alert (alerts are created in suspended state)
ALTER ALERT EV_DEMO.OBS.ALERT_DATA_QUALITY_BREACH RESUME;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. RUN + VERIFY
--    Execute immediately and confirm results.
-- ═══════════════════════════════════════════════════════════════════════════════

-- Run DMF evaluation now (don't wait for the hourly task)
CALL EV_DEMO.OBS.SP_EVALUATE_DMFS();

-- Show all DMF associations on Silver
SELECT *
FROM TABLE(EV_DEMO.INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
    REF_ENTITY_NAME => 'EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS',
    REF_ENTITY_DOMAIN => 'TABLE'
));

-- Check the dashboard (populated immediately via SP_EVALUATE_DMFS)
SELECT * FROM EV_DEMO.OBS.V_DATA_QUALITY_DASHBOARD LIMIT 20;
