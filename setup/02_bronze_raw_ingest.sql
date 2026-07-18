-- Bronze layer: ingest raw EV registration JSON as a single immutable VARIANT record.
-- Co-authored with CoCo

/*=============================================================================
  02_BRONZE_RAW_INGEST.SQL
  Loads the entire raw EV registration JSON file into ONE VARIANT row.
  No flattening, no parsing — this is the immutable, auditable landing zone.
  Downstream Snowpark SP (Prompt 5) reads meta.view.columns and explodes :data.
  Idempotent: OR REPLACE recreates the table; re-running COPY skips loaded files.
=============================================================================*/

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_EV_DEMO;
USE DATABASE EV_DEMO;
USE SCHEMA RAW;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. FILE FORMAT
--    STRIP_OUTER_ARRAY = FALSE keeps the entire JSON document as one VARIANT.
--    The file is SODA API format: {meta: {...}, data: [[...], ...]}
--    We want both meta (column definitions) and data (records) preserved intact
--    so the parsing SP can use meta to decode positional arrays at runtime.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FILE FORMAT JSON_RAW
    TYPE = 'JSON'
    STRIP_OUTER_ARRAY = FALSE
    COMMENT = 'JSON format for raw ingest — preserves entire document as single VARIANT.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RAW LANDING TABLE
--    Single VARIANT column holds the complete JSON document.
--    LOADED_AT: audit timestamp — when did this row land in Snowflake?
--    SOURCE_FILE: lineage — which staged file produced this row?
--    One row per source file. Immutable once loaded.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE RAW_EV_REGISTRATIONS (
    RAW_DATA     VARIANT        NOT NULL   COMMENT 'Complete JSON document (meta + data). Immutable source of truth.',
    LOADED_AT    TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP() COMMENT 'Wall-clock time the row was ingested into Snowflake.',
    SOURCE_FILE  VARCHAR        COMMENT 'Stage file path that produced this row (METADATA$FILENAME).'
)
COMMENT = 'Bronze landing table — one row per source file. Immutable raw JSON from WA DOL EV registration feed.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. COPY INTO
--    Loads all JSON files on stage as single VARIANT rows.
--    No hardcoded filename — picks up any file on @EV_STAGE.
--    ON_ERROR = ABORT_STATEMENT — fail loudly; partial loads are unacceptable
--    in an auditable pipeline.
--    COPY tracks loaded files so re-runs are no-ops (idempotent).
-- ─────────────────────────────────────────────────────────────────────────────
COPY INTO RAW_EV_REGISTRATIONS (RAW_DATA, LOADED_AT, SOURCE_FILE)
FROM (
    SELECT
        $1,
        CURRENT_TIMESTAMP(),
        METADATA$FILENAME
    FROM @EV_DEMO.RAW.EV_STAGE
)
FILE_FORMAT = (TYPE = 'JSON' STRIP_OUTER_ARRAY = FALSE)
ON_ERROR = ABORT_STATEMENT;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) AS row_count FROM RAW_EV_REGISTRATIONS;
SELECT
    OBJECT_KEYS(RAW_DATA) AS top_level_keys,
    ARRAY_SIZE(RAW_DATA:data) AS record_count_in_data_array,
    RAW_DATA:meta:view:name::STRING AS dataset_name,
    LOADED_AT,
    SOURCE_FILE
FROM RAW_EV_REGISTRATIONS;
