# Snowpark SP: parse Bronze VARIANT into typed BRONZE_PARSED table using runtime column mapping.
# Co-authored with CoCo

"""
SP_PARSE_EV_REGISTRATIONS
─────────────────────────
Reads the single VARIANT row in RAW_EV_REGISTRATIONS, extracts the column
metadata from meta.view.columns, and uses it to dynamically map positional
indices in the data array to named, typed columns.

Why runtime mapping instead of hardcoded indices?
  - If the upstream SODA export reorders or adds columns, this SP adapts
    automatically without code changes.
  - Makes the pipeline self-documenting: the mapping logic is visible and auditable.

No business rules applied here — structural parsing only.
"""

from snowflake.snowpark import Session
from snowflake.snowpark.functions import (
    col, lit, sql_expr, current_timestamp
)
from snowflake.snowpark.types import (
    StructType, StructField, StringType, IntegerType, TimestampType
)


def run(session: Session) -> str:
    # ─── 1. Read meta.view.columns to build fieldName -> index mapping ───
    # We query the single Bronze row's metadata to discover column positions.
    meta_df = session.sql("""
        SELECT f.INDEX AS idx, f.VALUE:fieldName::STRING AS field_name
        FROM EV_DEMO.RAW.RAW_EV_REGISTRATIONS,
        LATERAL FLATTEN(INPUT => RAW_DATA:meta:view:columns) f
    """).collect()

    # Build lookup: field_name -> positional index in data arrays
    field_index = {row["FIELD_NAME"]: row["IDX"] for row in meta_df}

    # ─── 2. Define the business fields we want and their target types ───
    # These are the fields specified by the pipeline contract.
    # Each tuple: (source_field_name_in_meta, target_column_name, cast_type)
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

    # ─── 3. Build SELECT expressions using dynamic index lookup ───
    # Each data row is a positional array; we reference elements by index.
    select_exprs = []
    for src_field, tgt_col, cast_type in business_fields:
        idx = field_index[src_field]
        if cast_type == "INT":
            select_exprs.append(f"TRY_CAST(f.VALUE[{idx}]::STRING AS INT) AS {tgt_col}")
        else:
            select_exprs.append(f"f.VALUE[{idx}]::STRING AS {tgt_col}")

    # Add load timestamp for lineage
    select_exprs.append("CURRENT_TIMESTAMP() AS LOAD_TS")

    select_clause = ",\n        ".join(select_exprs)

    # ─── 4. Flatten data array and project columns ───
    parse_sql = f"""
        SELECT
        {select_clause}
        FROM EV_DEMO.RAW.RAW_EV_REGISTRATIONS,
        LATERAL FLATTEN(INPUT => RAW_DATA:data) f
    """

    parsed_df = session.sql(parse_sql)

    # ─── 5. Write to BRONZE_PARSED (overwrite — full reload each run) ───
    parsed_df.write.mode("overwrite").save_as_table(
        "EV_DEMO.RAW.BRONZE_PARSED",
        table_type=""  # permanent table
    )

    # Return row count for verification
    count = session.table("EV_DEMO.RAW.BRONZE_PARSED").count()
    return f"BRONZE_PARSED loaded: {count} rows"
