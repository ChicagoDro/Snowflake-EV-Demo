-- Register and execute Snowpark SP to parse Bronze VARIANT into typed BRONZE_PARSED table.
-- Co-authored with CoCo

/*=============================================================================
  03_BRONZE_RAW_INGEST.SQL
  Creates the Snowpark Python stored procedure SP_PARSE_EV_REGISTRATIONS,
  then calls it to produce BRONZE_PARSED from the raw VARIANT landing table.
  
  Why a stored procedure instead of a view or dynamic table?
    - The parsing logic uses meta.view.columns for dynamic index resolution.
    - A one-time full-reload proc keeps Bronze immutable while producing a
      structured output that downstream dbt Dynamic Tables can reference.
    - Proc can be called on-demand for verification or scheduled via TASK.
=============================================================================*/

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_EV_DEMO;
USE DATABASE EV_DEMO;
USE SCHEMA RAW;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. STORED PROCEDURE
--    Snowpark Python: reads meta for column mapping, flattens data array,
--    projects typed columns, writes to BRONZE_PARSED.
--    EXECUTE AS CALLER so it inherits the caller's role/warehouse context.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE PROCEDURE SP_PARSE_EV_REGISTRATIONS()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
COMMENT = 'Parses Bronze VARIANT into typed BRONZE_PARSED. Uses meta.view.columns for runtime index mapping — no hardcoded positions.'
AS
$$
"""
SP_PARSE_EV_REGISTRATIONS
Reads the single VARIANT row in RAW_EV_REGISTRATIONS, extracts column
metadata from meta.view.columns, and dynamically maps positional indices
to named, typed columns. No business rules — structural parsing only.
"""

from snowflake.snowpark import Session
from snowflake.snowpark.functions import col, current_timestamp


def run(session: Session) -> str:
    # 1. Read meta.view.columns to build fieldName -> index mapping at runtime.
    meta_df = session.sql("""
        SELECT f.INDEX AS idx, f.VALUE:fieldName::STRING AS field_name
        FROM EV_DEMO.RAW.RAW_EV_REGISTRATIONS,
        LATERAL FLATTEN(INPUT => RAW_DATA:meta:view:columns) f
    """).collect()

    field_index = {row["FIELD_NAME"]: row["IDX"] for row in meta_df}

    # 2. Business fields: (source_field_name, target_column, cast_type)
    business_fields = [
        ("vin_1_10",             "VIN",                  "STRING"),
        ("county",               "COUNTY",               "STRING"),
        ("city",                 "CITY",                 "STRING"),
        ("state",                "STATE",                "STRING"),
        ("zip_code",             "POSTAL_CODE",          "STRING"),
        ("model_year",           "MODEL_YEAR",           "INT"),
        ("make",                 "MAKE",                 "STRING"),
        ("model",                "MODEL",                "STRING"),
        ("ev_type",              "EV_TYPE",              "STRING"),
        ("cafv_type",            "CAFV_ELIGIBILITY",     "STRING"),
        ("electric_range",       "ELECTRIC_RANGE",       "INT"),
        ("base_msrp",            "BASE_MSRP",            "INT"),
        ("legislative_district", "LEGISLATIVE_DISTRICT", "STRING"),
        ("geocoded_column",      "VEHICLE_LOCATION",     "STRING"),
        ("electric_utility",     "ELECTRIC_UTILITY",     "STRING"),
        ("_2020_census_tract",   "CENSUS_TRACT",         "STRING"),
    ]

    # 3. Build SELECT expressions using dynamic index lookup.
    select_exprs = []
    for src_field, tgt_col, cast_type in business_fields:
        idx = field_index[src_field]
        if cast_type == "INT":
            select_exprs.append(f"TRY_CAST(f.VALUE[{idx}]::STRING AS INT) AS {tgt_col}")
        else:
            select_exprs.append(f"f.VALUE[{idx}]::STRING AS {tgt_col}")

    select_exprs.append("CURRENT_TIMESTAMP() AS LOAD_TS")
    select_clause = ",\n        ".join(select_exprs)

    # 4. Flatten data array and project columns.
    parse_sql = f"""
        SELECT
        {select_clause}
        FROM EV_DEMO.RAW.RAW_EV_REGISTRATIONS,
        LATERAL FLATTEN(INPUT => RAW_DATA:data) f
    """

    parsed_df = session.sql(parse_sql)

    # 5. Write to BRONZE_PARSED (overwrite — full reload each run).
    parsed_df.write.mode("overwrite").save_as_table(
        "EV_DEMO.RAW.BRONZE_PARSED",
        table_type=""
    )

    count = session.table("EV_DEMO.RAW.BRONZE_PARSED").count()
    return f"BRONZE_PARSED loaded: {count} rows"
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. EXECUTE — verify the procedure works
-- ─────────────────────────────────────────────────────────────────────────────
CALL SP_PARSE_EV_REGISTRATIONS();

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. VERIFICATION
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) AS row_count FROM BRONZE_PARSED;
SELECT * FROM BRONZE_PARSED LIMIT 5;
