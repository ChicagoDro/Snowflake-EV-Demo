-- Environment setup for EV_DEMO medallion pipeline (warehouse, database, schemas, stage, role, grants).
-- Co-authored with CoCo

/*=============================================================================
  01_ENVIRONMENT.SQL
  Idempotent environment bootstrap for Washington State EV Registration pipeline.
  Safe to re-run: uses IF NOT EXISTS / OR REPLACE where dropping would be destructive.
  NOTE: Database is NOT dropped — CDC replication schema ("public") must be preserved.
=============================================================================*/

USE ROLE ACCOUNTADMIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. WAREHOUSE
--    XSMALL keeps cost minimal for scheduled batch loads.
--    60s auto-suspend balances cost vs. cold-start latency.
--    Initially suspended so creation doesn't consume credits.
-- ─────────────────────────────────────────────────────────────────────────────
DROP WAREHOUSE IF EXISTS WH_EV_DEMO;

CREATE WAREHOUSE WH_EV_DEMO
    WAREHOUSE_SIZE   = 'XSMALL'
    AUTO_SUSPEND     = 60
    AUTO_RESUME      = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Compute for EV demo pipeline. XSMALL + 60s suspend balances cost vs. cold-start latency for scheduled batch loads.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. DATABASE
--    CREATE IF NOT EXISTS preserves the CDC "public" schema created by the
--    Snowflake Connector for PostgreSQL. Dropping would break replication.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE DATABASE IF NOT EXISTS EV_DEMO
    COMMENT = 'Washington State EV registration pipeline — medallion architecture (Bronze/Silver/Gold).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. SCHEMAS
--    OR REPLACE is safe here — these are pipeline-managed schemas.
--    The CDC schema EV_DEMO."public" is untouched.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE SCHEMA EV_DEMO.RAW
    COMMENT = 'Bronze layer — raw JSON ingestion. Immutable, auditable landing zone.';

CREATE OR REPLACE SCHEMA EV_DEMO.CLEAN
    COMMENT = 'Silver layer — validated, deduplicated, typed records. Business rules enforced here.';

CREATE OR REPLACE SCHEMA EV_DEMO.MART
    COMMENT = 'Gold layer — consumption-ready models, Iceberg tables on external volume.';

CREATE OR REPLACE SCHEMA EV_DEMO.OBS
    COMMENT = 'Observability — data quality DMFs, monitoring alerts, pipeline health metrics.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. INTERNAL STAGE
--    Landing zone for raw CSV/JSON files uploaded from Azure Blob or local.
--    Directory enabled for Snowsight browsing; JSON file format for COPY INTO.
--    STRIP_OUTER_ARRAY = FALSE keeps each file as a single VARIANT row
--    so downstream parsing controls record-level splitting.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE STAGE EV_DEMO.RAW.EV_STAGE
    DIRECTORY = (ENABLE = TRUE)
    FILE_FORMAT = (
        TYPE = 'JSON'
        STRIP_OUTER_ARRAY = FALSE
    )
    COMMENT = 'Landing stage for raw EV registration JSON files. Directory enabled for Snowsight browsing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. ROLE
--    Purpose-scoped role for pipeline engineers. Avoids ACCOUNTADMIN drift
--    and enables isolated audit of pipeline activity.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE ROLE IF NOT EXISTS EV_DEMO_ENGINEER
    COMMENT = 'Purpose-scoped role for EV demo pipeline. Owns and executes pipeline code. Avoids ACCOUNTADMIN drift; enables isolated audit of pipeline activity.';

-- Grant role to SYSADMIN hierarchy so it inherits standard admin oversight.
GRANT ROLE EV_DEMO_ENGINEER TO ROLE SYSADMIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. GRANTS
--    Principle of least privilege: EV_DEMO_ENGINEER gets exactly what it needs
--    to build and run the pipeline — nothing more.
-- ─────────────────────────────────────────────────────────────────────────────

-- Warehouse: run queries
GRANT USAGE ON WAREHOUSE WH_EV_DEMO TO ROLE EV_DEMO_ENGINEER;

-- Database: access all schemas
GRANT USAGE ON DATABASE EV_DEMO TO ROLE EV_DEMO_ENGINEER;

-- Schemas: full DDL/DML within each pipeline schema
GRANT ALL PRIVILEGES ON SCHEMA EV_DEMO.RAW   TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON SCHEMA EV_DEMO.CLEAN TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON SCHEMA EV_DEMO.MART  TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON SCHEMA EV_DEMO.OBS   TO ROLE EV_DEMO_ENGINEER;

-- Future tables/views in each schema so new objects are auto-accessible
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA EV_DEMO.RAW   TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA EV_DEMO.CLEAN TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA EV_DEMO.MART  TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA EV_DEMO.OBS   TO ROLE EV_DEMO_ENGINEER;

GRANT ALL PRIVILEGES ON FUTURE TABLES IN SCHEMA EV_DEMO.RAW   TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON FUTURE TABLES IN SCHEMA EV_DEMO.CLEAN TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON FUTURE TABLES IN SCHEMA EV_DEMO.MART  TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON FUTURE TABLES IN SCHEMA EV_DEMO.OBS   TO ROLE EV_DEMO_ENGINEER;

GRANT ALL PRIVILEGES ON FUTURE VIEWS IN SCHEMA EV_DEMO.RAW   TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON FUTURE VIEWS IN SCHEMA EV_DEMO.CLEAN TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON FUTURE VIEWS IN SCHEMA EV_DEMO.MART  TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON FUTURE VIEWS IN SCHEMA EV_DEMO.OBS   TO ROLE EV_DEMO_ENGINEER;

GRANT ALL PRIVILEGES ON FUTURE DYNAMIC TABLES IN SCHEMA EV_DEMO.CLEAN TO ROLE EV_DEMO_ENGINEER;
GRANT ALL PRIVILEGES ON FUTURE DYNAMIC TABLES IN SCHEMA EV_DEMO.MART  TO ROLE EV_DEMO_ENGINEER;

-- Stage: read/write raw files
GRANT ALL PRIVILEGES ON STAGE EV_DEMO.RAW.EV_STAGE TO ROLE EV_DEMO_ENGINEER;

-- External volume: required for Iceberg tables in MART schema
GRANT USAGE ON EXTERNAL VOLUME EV_EXT_VOL TO ROLE EV_DEMO_ENGINEER;

-- CDC schema: read access to replicated tables (owned by connector application)
GRANT USAGE ON SCHEMA EV_DEMO."public" TO ROLE EV_DEMO_ENGINEER;
GRANT SELECT ON ALL TABLES IN SCHEMA EV_DEMO."public" TO ROLE EV_DEMO_ENGINEER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA EV_DEMO."public" TO ROLE EV_DEMO_ENGINEER;
