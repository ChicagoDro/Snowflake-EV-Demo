-- Demo verification queries: run live to prove data flows through each pipeline layer
-- Co-authored with CoCo

-- ============================================================
-- BRONZE LAYER — Raw ingestion from Azure Blob stage
-- ============================================================

-- Raw VARIANT records (immutable landing zone)
SELECT COUNT(*) AS raw_record_count FROM EV_DEMO.RAW.RAW_EV_REGISTRATIONS;

-- Parsed Bronze table (Snowpark procedure output)
SELECT COUNT(*) AS parsed_row_count FROM EV_DEMO.RAW.BRONZE_PARSED;
SELECT * FROM EV_DEMO.RAW.BRONZE_PARSED LIMIT 5;

-- ============================================================
-- CDC LAYER — PostgreSQL connector (incentive_applications)
-- ============================================================

-- Verify CDC-replicated table has data
SELECT COUNT(*) AS incentive_app_count FROM EV_DEMO."public".INCENTIVE_APPLICATIONS;
SELECT status, COUNT(*) AS cnt
FROM EV_DEMO."public".INCENTIVE_APPLICATIONS
GROUP BY status
ORDER BY cnt DESC;

-- Show sample rows with mix of statuses
SELECT application_id, submitted_date, applicant_zip, make, model, status, reviewed_date
FROM EV_DEMO."public".INCENTIVE_APPLICATIONS
ORDER BY submitted_date DESC
LIMIT 10;

-- Connector replication status (proves CDC is running)
SELECT * FROM SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL.PUBLIC.REPLICATION_STATE;

-- Connector health check
SELECT * FROM SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL.PUBLIC.DATA_SOURCE_REPLICATION_STATE;

-- ============================================================
-- REFERENCE DATA — dbt seeds (static, version-controlled)
-- ============================================================

-- Zip code demographics (loaded via dbt seed)
SELECT COUNT(*) AS zip_count FROM EV_DEMO.RAW.ZIP_CODE_DEMOGRAPHICS;
SELECT * FROM EV_DEMO.RAW.ZIP_CODE_DEMOGRAPHICS LIMIT 5;

-- State EV goals (loaded via dbt seed)
SELECT COUNT(*) AS goals_count FROM EV_DEMO.RAW.STATE_EV_GOALS;
SELECT * FROM EV_DEMO.RAW.STATE_EV_GOALS ORDER BY year;

-- ============================================================
-- SILVER LAYER — Dynamic Table (enriched, deduplicated, validated)
-- ============================================================

-- Row count and freshness
SELECT
    COUNT(*) AS silver_row_count,
    MAX(LOAD_TS) AS most_recent_load,
    DATEDIFF('minute', MAX(LOAD_TS), CURRENT_TIMESTAMP()) AS minutes_since_last_load
FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS;

-- Sample enriched rows (should have zip demographics + incentive data joined)
SELECT VIN, MAKE, MODEL, COUNTY, POSTAL_CODE, EV_TYPE,
       POPULATION, MEDIAN_INCOME, INCENTIVE_AMOUNT, STATUS AS INCENTIVE_STATUS
FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS
LIMIT 10;

-- Quarantine table (rejected rows with reasons)
SELECT COUNT(*) AS quarantined_rows FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS;
SELECT REJECTION_REASON, COUNT(*) AS cnt
FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS
GROUP BY REJECTION_REASON;

-- Dynamic Table refresh status
SELECT NAME, TARGET_LAG, REFRESH_MODE, SCHEDULING_STATE, LAST_COMPLETED_REFRESH_END
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES())
WHERE SCHEMA_NAME = 'CLEAN';

-- ============================================================
-- GOLD LAYER — Dynamic Iceberg Tables (star schema on external volume)
-- ============================================================

-- Dimension tables
SELECT COUNT(*) AS vehicle_dim_count FROM EV_DEMO.MART.DIM_VEHICLE;
SELECT COUNT(*) AS geography_dim_count FROM EV_DEMO.MART.DIM_GEOGRAPHY;

-- Fact table
SELECT COUNT(*) AS fact_row_count FROM EV_DEMO.MART.FACT_EV_REGISTRATIONS;

-- Quick business insight: top 5 makes by registration count
SELECT MAKE, COUNT(*) AS registrations
FROM EV_DEMO.MART.FACT_EV_REGISTRATIONS f
JOIN EV_DEMO.MART.DIM_VEHICLE v ON f.VIN = v.VIN
GROUP BY MAKE
ORDER BY registrations DESC
LIMIT 5;

-- Dynamic Iceberg Table refresh status
SELECT NAME, TARGET_LAG, REFRESH_MODE, SCHEDULING_STATE, LAST_COMPLETED_REFRESH_END
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES())
WHERE SCHEMA_NAME = 'MART';

-- ============================================================
-- PIPELINE HEALTH SUMMARY
-- ============================================================

-- One-glance row count comparison across all layers
SELECT
    (SELECT COUNT(*) FROM EV_DEMO.RAW.RAW_EV_REGISTRATIONS) AS bronze_raw,
    (SELECT COUNT(*) FROM EV_DEMO.RAW.BRONZE_PARSED) AS bronze_parsed,
    (SELECT COUNT(*) FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS) AS silver,
    (SELECT COUNT(*) FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS) AS quarantine,
    (SELECT COUNT(*) FROM EV_DEMO.MART.FACT_EV_REGISTRATIONS) AS gold_fact,
    (SELECT COUNT(*) FROM EV_DEMO."public".INCENTIVE_APPLICATIONS) AS cdc_incentives;
