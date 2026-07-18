-- Snowflake Connector for PostgreSQL setup: grants, data source, table replication, and monitoring
-- Co-authored with CoCo
USE ROLE ACCOUNTADMIN;
GRANT USAGE ON DATABASE EV_DEMO TO APPLICATION SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL;
GRANT CREATE SCHEMA ON DATABASE EV_DEMO TO APPLICATION SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL;
GRANT USAGE ON WAREHOUSE WH_EV_DEMO TO APPLICATION SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL;

-----------------------------------
-- Init session
-----------------------------------

ALTER SESSION SET AUTOCOMMIT = TRUE;
USE SCHEMA "SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL".PUBLIC;

-----------------------------------
-- Configuring replication
-----------------------------------

-- Adding a data source for replication
-- Add the data source
CALL ADD_DATA_SOURCE('POSTGRESQL', 'EV_DEMO');

-- Add source tables for replication (incentive_applications is the CDC target)
CALL ADD_TABLES('POSTGRESQL', 'public', ['incentive_applications']);

-- Enable scheduled replication (15 min minimum)
CALL ENABLE_SCHEDULED_REPLICATION('POSTGRESQL', '15 MINUTES');


-----------------------------------
-- Monitoring
-----------------------------------

-- Viewing general information about the connector
SELECT * FROM CONNECTOR_CONFIGURATION;

-- Viewing data sources
SELECT * FROM DATA_SOURCES;

-- Viewing the replication state of data sources
SELECT * FROM DATA_SOURCE_REPLICATION_STATE;

-- Viewing the replication state of source tables
SELECT * FROM REPLICATION_STATE;

-- Viewing connector metrics
SELECT * FROM CONNECTOR_STATS;
SELECT * FROM AGGREGATED_CONNECTOR_STATS;

-- Viewing a history of state changes for all enabled source tables
SELECT * FROM EXPERIMENTAL_TABLE_REPLICATION_HISTORY;

-- Viewing a history of state changes for all configured data sources
SELECT * FROM EXPERIMENTAL_DATA_SOURCE_REPLICATION_HISTORY;

-- Viewing a history of all events that occurred in the connector
SELECT * FROM EXPERIMENTAL_EVENTS_HISTORY;

-- Viewing the connector audit log view
SELECT * FROM AUDIT_LOG;

-- Viewing the agent audit log view
SELECT * FROM AGENT_AUDIT_LOG;

-- Viewing the connector logs
SELECT * FROM snowflake.telemetry.events
   WHERE RECORD_TYPE = 'LOG'
   AND RESOURCE_ATTRIBUTES:"snow.database.name" = 'SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL';

-- Viewing errors and warnings in the connector logs
SELECT * FROM snowflake.telemetry.events
   WHERE RECORD_TYPE = 'LOG'
   AND RESOURCE_ATTRIBUTES:"snow.database.name" = 'SNOWFLAKE_CONNECTOR_FOR_POSTGRESQL'
   AND RECORD:"severity_text" IN ('ERROR', 'WARN');

-- Viewing the agent logs
SELECT * FROM AGENT_LOGS;

-- Viewing errors and warnings in the agent logs
SELECT * FROM AGENT_LOGS 
   WHERE LEVEL IN ('ERROR', 'WARN');
