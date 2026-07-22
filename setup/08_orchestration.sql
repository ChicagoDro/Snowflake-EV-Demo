-- Task graph orchestration: stream-triggered ingest → parse → quality check.
-- Co-authored with CoCo

/*=============================================================================
  08_ORCHESTRATION.SQL
  Event-driven pipeline orchestration using Stream + Task graph.

  ARCHITECTURE:
  ┌─────────────────────────────────────────────────────────────────────┐
  │  @EV_STAGE (new file lands)                                         │
  │       ↓                                                             │
  │  STREAM_EV_STAGE (detects new files via Directory Table Stream)     │
  │       ↓                                                             │
  │  TASK_INGEST_RAW (COPY INTO — every 6h if stream has data)         │
  │       ↓                                                             │
  │  TASK_PARSE_BRONZE (calls SP_PARSE_EV_REGISTRATIONS)               │
  │       ↓                                                             │
  │  TASK_QUALITY_CHECK (checks DMF results, logs outcome)             │
  │       ↓                                                             │
  │  [Dynamic Tables auto-refresh Silver/Gold via TARGET_LAG]          │
  └─────────────────────────────────────────────────────────────────────┘

  WHY THIS APPROACH?
  • Event-driven — no polling; warehouse sleeps when no files arrive.
  • No external orchestrator (Airflow, dbt Cloud) to deploy or maintain.
  • Circuit breaker — SUSPEND_TASK_AFTER_NUM_FAILURES = 3 on root task
    (child tasks inherit this — do NOT set it on child tasks directly).
  • Dynamic Tables handle Silver/Gold refresh — tasks only cover Bronze.

  IMPLEMENTATION NOTES:
  • COPY INTO must use a transformation subquery for multi-column targets.
  • SQLERRM does not exist in Snowflake — use static error strings instead.
=============================================================================*/

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_EV_DEMO;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. TASK RUN LOG TABLE
--    Captures every task execution outcome for observability.
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE EV_DEMO.OBS.TASK_RUN_LOG (
    TASK_NAME       VARCHAR(100),
    RUN_STATUS      VARCHAR(20),    -- SUCCESS, FAILURE
    ROW_COUNT       NUMBER,         -- rows affected (if applicable)
    ERROR_MESSAGE   VARCHAR(2000),
    RUN_TIMESTAMP   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. DIRECTORY TABLE STREAM
--    Detects new files arriving on the internal stage.
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE STREAM EV_DEMO.RAW.STREAM_EV_STAGE
    ON STAGE EV_DEMO.RAW.EV_STAGE;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. HELPER STORED PROCEDURE: LOG TASK RUN
--    Called by each task to record its outcome.
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE EV_DEMO.OBS.SP_LOG_TASK_RUN(
    P_TASK_NAME VARCHAR,
    P_STATUS VARCHAR,
    P_ROW_COUNT NUMBER,
    P_ERROR_MESSAGE VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
BEGIN
    INSERT INTO EV_DEMO.OBS.TASK_RUN_LOG (TASK_NAME, RUN_STATUS, ROW_COUNT, ERROR_MESSAGE)
    VALUES (:P_TASK_NAME, :P_STATUS, :P_ROW_COUNT, :P_ERROR_MESSAGE);
    RETURN 'Logged: ' || P_TASK_NAME || ' — ' || P_STATUS;
END;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. QUALITY CHECK STORED PROCEDURE
--    Queries latest DMF results and logs any failures.
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE EV_DEMO.OBS.SP_QUALITY_CHECK()
RETURNS VARCHAR
LANGUAGE SQL
AS
BEGIN
    LET failure_count NUMBER := 0;

    SELECT COUNT(*) INTO :failure_count
    FROM EV_DEMO.OBS.DMF_RESULTS
    WHERE MEASUREMENT_TIME > DATEADD('hour', -2, CURRENT_TIMESTAMP())
      AND (
          (METRIC_NAME = 'DMF_DUPLICATE_VIN_COUNT' AND VALUE > 0)
          OR (METRIC_NAME = 'DMF_INVALID_BUSINESS_RULES' AND VALUE > 0)
          OR (METRIC_NAME = 'DMF_ROW_COUNT_RECONCILIATION' AND VALUE != 0)
      );

    IF (failure_count > 0) THEN
        CALL EV_DEMO.OBS.SP_LOG_TASK_RUN('TASK_QUALITY_CHECK', 'FAILURE', failure_count, 'DMF threshold breached — check V_DATA_QUALITY_DASHBOARD');
        RETURN 'QUALITY CHECK FAILED: ' || failure_count || ' metric(s) breached';
    ELSE
        CALL EV_DEMO.OBS.SP_LOG_TASK_RUN('TASK_QUALITY_CHECK', 'SUCCESS', 0, NULL);
        RETURN 'QUALITY CHECK PASSED';
    END IF;
END;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. TASK GRAPH
-- ═══════════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- 5a. ROOT TASK: INGEST RAW
--     Runs COPY INTO when new files land on stage (stream has data).
--     Schedule: every 6 hours, but only executes if stream has data.
--     SUSPEND_TASK_AFTER_NUM_FAILURES = 3 (circuit breaker — root only).
--     NOTE: Must use transformation subquery for multi-column target table.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TASK EV_DEMO.RAW.TASK_INGEST_RAW
    WAREHOUSE = WH_EV_DEMO
    SCHEDULE = 'USING CRON 0 */6 * * * America/Los_Angeles'
    SUSPEND_TASK_AFTER_NUM_FAILURES = 3
    WHEN SYSTEM$STREAM_HAS_DATA('EV_DEMO.RAW.STREAM_EV_STAGE')
AS
BEGIN
    -- Transformation subquery required: JSON → 3-column table
    COPY INTO EV_DEMO.RAW.RAW_EV_REGISTRATIONS (RAW_DATA, LOADED_AT, SOURCE_FILE)
    FROM (
        SELECT $1, CURRENT_TIMESTAMP(), METADATA$FILENAME
        FROM @EV_DEMO.RAW.EV_STAGE
    )
    FILE_FORMAT = (TYPE = 'JSON' STRIP_OUTER_ARRAY = FALSE)
    ON_ERROR = 'CONTINUE';

    CALL EV_DEMO.OBS.SP_LOG_TASK_RUN('TASK_INGEST_RAW', 'SUCCESS', NULL, NULL);
EXCEPTION
    WHEN OTHER THEN
        -- SQLERRM does not exist in Snowflake; use static message
        LET err_msg VARCHAR := 'TASK_INGEST_RAW failed — check TASK_HISTORY for details';
        CALL EV_DEMO.OBS.SP_LOG_TASK_RUN('TASK_INGEST_RAW', 'FAILURE', NULL, :err_msg);
        RAISE;
END;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5b. CHILD TASK: PARSE BRONZE
--     Calls the Snowpark stored procedure to parse VARIANT → structured.
--     Runs after TASK_INGEST_RAW completes successfully.
--     NOTE: No SUSPEND_TASK_AFTER_NUM_FAILURES — inherited from root.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TASK EV_DEMO.RAW.TASK_PARSE_BRONZE
    WAREHOUSE = WH_EV_DEMO
    AFTER EV_DEMO.RAW.TASK_INGEST_RAW
AS
BEGIN
    CALL EV_DEMO.RAW.SP_PARSE_EV_REGISTRATIONS();
    CALL EV_DEMO.OBS.SP_LOG_TASK_RUN('TASK_PARSE_BRONZE', 'SUCCESS', NULL, NULL);
EXCEPTION
    WHEN OTHER THEN
        LET err_msg VARCHAR := 'TASK_PARSE_BRONZE failed — check TASK_HISTORY for details';
        CALL EV_DEMO.OBS.SP_LOG_TASK_RUN('TASK_PARSE_BRONZE', 'FAILURE', NULL, :err_msg);
        RAISE;
END;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5c. CHILD TASK: QUALITY CHECK
--     Runs after parse to verify DMF metrics are within thresholds.
--     Does NOT block pipeline — logs findings for investigation.
--     NOTE: No SUSPEND_TASK_AFTER_NUM_FAILURES — inherited from root.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TASK EV_DEMO.RAW.TASK_QUALITY_CHECK
    WAREHOUSE = WH_EV_DEMO
    AFTER EV_DEMO.RAW.TASK_PARSE_BRONZE
AS
BEGIN
    CALL EV_DEMO.OBS.SP_QUALITY_CHECK();
END;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. GRANTS
-- ═══════════════════════════════════════════════════════════════════════════════

GRANT EXECUTE TASK ON ACCOUNT TO ROLE EV_DEMO_ENGINEER;
GRANT SELECT ON TABLE EV_DEMO.OBS.TASK_RUN_LOG TO ROLE EV_DEMO_ENGINEER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. RESUME TASKS (child tasks first, then root — required order)
-- ═══════════════════════════════════════════════════════════════════════════════

ALTER TASK EV_DEMO.RAW.TASK_QUALITY_CHECK RESUME;
ALTER TASK EV_DEMO.RAW.TASK_PARSE_BRONZE RESUME;
ALTER TASK EV_DEMO.RAW.TASK_INGEST_RAW RESUME;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 8. VERIFY
-- ═══════════════════════════════════════════════════════════════════════════════

SHOW TASKS IN SCHEMA EV_DEMO.RAW;

SHOW STREAMS IN SCHEMA EV_DEMO.RAW;

SELECT * FROM EV_DEMO.OBS.TASK_RUN_LOG ORDER BY RUN_TIMESTAMP DESC LIMIT 10;
