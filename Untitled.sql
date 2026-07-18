USE SCHEMA "SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL".PUBLIC;

-- Remove static tables from replication
CALL REMOVE_TABLE('POSTGRESQL', 'public', 'zip_code_demographics');
CALL REMOVE_TABLE('POSTGRESQL', 'public', 'state_ev_goals');

-- Verify only incentive_applications remains
SELECT * FROM REPLICATION_STATE;

-- In Snowflake
DROP TABLE IF EXISTS EV_DEMO."public".ZIP_CODE_DEMOGRAPHICS;
DROP TABLE IF EXISTS EV_DEMO."public".STATE_EV_GOALS;