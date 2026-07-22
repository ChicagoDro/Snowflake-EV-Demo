# EV Insights Dashboard with Executive Analytics and Data Quality Monitoring
# Co-authored with CoCo
import streamlit as st
import altair as alt
import pandas as pd
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="WA EV Insights", layout="wide")
st.title("Washington State EV Insights Dashboard")

session = get_active_session()

tab1, tab2 = st.tabs(["Executive Dashboard", "Data Quality & Pipeline Health"])

# =============================================================================
# TAB 1: Executive Dashboard
# =============================================================================
with tab1:
    st.markdown(
        """This dashboard provides Washington State legislators with a data-driven
        overview of electric vehicle adoption, geographic equity, market composition,
        and incentive program performance."""
    )

    # --- 1. EV Adoption Trend ---
    st.subheader("1. EV Adoption Trend")
    st.caption(
        "Cumulative BEV and PHEV registrations by model year, benchmarked against the 2030 target."
    )

    df_trend = session.sql("""
        SELECT MODEL_YEAR, EV_TYPE, CUMULATIVE_COUNT, TARGET_EV_COUNT
        FROM EV_DEMO.MART.AGG_REGISTRATIONS_BY_YEAR
        ORDER BY MODEL_YEAR
    """).to_pandas()

    if not df_trend.empty:
        base = alt.Chart(df_trend).encode(
            x=alt.X("MODEL_YEAR:O", title="Model Year")
        )
        lines = base.mark_line(point=True).encode(
            y=alt.Y("CUMULATIVE_COUNT:Q", title="Cumulative Registrations"),
            color=alt.Color("EV_TYPE:N", title="EV Type"),
            tooltip=["MODEL_YEAR", "EV_TYPE", "CUMULATIVE_COUNT"]
        )
        target_df = df_trend[df_trend["TARGET_EV_COUNT"].notna()].drop_duplicates("MODEL_YEAR")
        if not target_df.empty:
            target_line = alt.Chart(target_df).mark_line(
                strokeDash=[5, 5], color="red"
            ).encode(
                x="MODEL_YEAR:O",
                y=alt.Y("TARGET_EV_COUNT:Q"),
                tooltip=["MODEL_YEAR", "TARGET_EV_COUNT"]
            )
            chart = (lines + target_line).properties(height=350)
        else:
            chart = lines.properties(height=350)
        st.altair_chart(chart, use_container_width=True)

    # --- 2. Geographic Distribution ---
    st.subheader("2. Geographic Distribution")
    st.caption(
        "Top 15 counties by total registrations with per-capita overlay — highlights concentration vs. equity gaps."
    )

    df_geo = session.sql("""
        SELECT COUNTY,
               SUM(REGISTRATION_COUNT) AS REGISTRATION_COUNT,
               MAX(REGISTRATIONS_PER_CAPITA) AS REGISTRATIONS_PER_CAPITA
        FROM EV_DEMO.MART.AGG_REGISTRATIONS_BY_COUNTY
        GROUP BY COUNTY
        ORDER BY REGISTRATION_COUNT DESC
        LIMIT 15
    """).to_pandas()

    if not df_geo.empty:
        bar = alt.Chart(df_geo).mark_bar(color="#4C78A8").encode(
            x=alt.X("REGISTRATION_COUNT:Q", title="Registrations"),
            y=alt.Y("COUNTY:N", sort="-x", title="County"),
            tooltip=["COUNTY", "REGISTRATION_COUNT"]
        )
        points = alt.Chart(df_geo).mark_circle(color="orange", size=80).encode(
            x=alt.X("REGISTRATIONS_PER_CAPITA:Q", title="Registrations per Capita"),
            y=alt.Y("COUNTY:N", sort=alt.EncodingSortField(field="REGISTRATION_COUNT", order="descending")),
            tooltip=["COUNTY", "REGISTRATIONS_PER_CAPITA"]
        )
        geo_chart = alt.layer(bar, points).resolve_scale(x="independent").properties(height=400)
        st.altair_chart(geo_chart, use_container_width=True)

    # --- 3. Make/Model Leaderboard ---
    st.subheader("3. Make/Model Leaderboard")
    st.caption(
        "Top 10 manufacturers by registration count with average electric range as a quality signal."
    )

    df_make = session.sql("""
        SELECT v.MAKE,
               COUNT(*) AS REGISTRATION_COUNT,
               AVG(v.ELECTRIC_RANGE) AS AVG_ELECTRIC_RANGE
        FROM EV_DEMO.MART.DIM_VEHICLE v
        GROUP BY v.MAKE
        ORDER BY REGISTRATION_COUNT DESC
        LIMIT 10
    """).to_pandas()

    if not df_make.empty:
        make_bar = alt.Chart(df_make).mark_bar(color="#59A14F").encode(
            x=alt.X("REGISTRATION_COUNT:Q", title="Registrations"),
            y=alt.Y("MAKE:N", sort="-x", title="Make"),
            tooltip=["MAKE", "REGISTRATION_COUNT", "AVG_ELECTRIC_RANGE"]
        )
        range_points = alt.Chart(df_make).mark_circle(color="#E45756", size=100).encode(
            x=alt.X("AVG_ELECTRIC_RANGE:Q", title="Avg Electric Range (mi)"),
            y=alt.Y("MAKE:N", sort=alt.EncodingSortField(field="REGISTRATION_COUNT", order="descending")),
            tooltip=["MAKE", "AVG_ELECTRIC_RANGE"]
        )
        make_chart = alt.layer(make_bar, range_points).resolve_scale(x="independent").properties(height=350)
        st.altair_chart(make_chart, use_container_width=True)

    # --- 4. CAFV Eligibility Breakdown ---
    st.subheader("4. CAFV Eligibility Breakdown")
    st.caption(
        "Proportion of registered EVs eligible for Clean Alternative Fuel Vehicle incentives."
    )

    df_cafv = session.sql("""
        SELECT CAFV_ELIGIBILITY, COUNT(*) AS CNT
        FROM EV_DEMO.MART.FACT_EV_REGISTRATIONS
        GROUP BY CAFV_ELIGIBILITY
    """).to_pandas()

    if not df_cafv.empty:
        cafv_chart = alt.Chart(df_cafv).mark_arc(innerRadius=50).encode(
            theta=alt.Theta("CNT:Q"),
            color=alt.Color("CAFV_ELIGIBILITY:N", title="Eligibility Status"),
            tooltip=["CAFV_ELIGIBILITY", "CNT"]
        ).properties(height=350)
        st.altair_chart(cafv_chart, use_container_width=True)

    # --- 5. Incentive Program Status ---
    st.subheader("5. Incentive Program Status")
    st.caption(
        "Summary of incentive applications captured via CDC from registration data."
    )

    df_incentive = session.sql("""
        SELECT
            COUNT(*) AS TOTAL_APPLICATIONS,
            SUM(CASE WHEN APPLICATION_STATUS = 'Approved' THEN 1 ELSE 0 END) AS APPROVED,
            SUM(CASE WHEN APPLICATION_STATUS = 'Pending' THEN 1 ELSE 0 END) AS PENDING,
            SUM(CASE WHEN APPLICATION_STATUS = 'Denied' THEN 1 ELSE 0 END) AS DENIED,
            COALESCE(SUM(INCENTIVE_AMOUNT), 0) AS TOTAL_DISBURSED
        FROM EV_DEMO.MART.FACT_EV_REGISTRATIONS
        WHERE APPLICATION_STATUS IS NOT NULL AND APPLICATION_STATUS != 'None'
    """).to_pandas()

    if not df_incentive.empty and df_incentive["TOTAL_APPLICATIONS"].iloc[0] > 0:
        c1, c2, c3, c4 = st.columns(4)
        total = int(df_incentive["TOTAL_APPLICATIONS"].iloc[0])
        approved = int(df_incentive["APPROVED"].iloc[0])
        pending = int(df_incentive["PENDING"].iloc[0])
        disbursed = float(df_incentive["TOTAL_DISBURSED"].iloc[0])
        c1.metric("Total Applications", f"{total:,}")
        c2.metric("Approval Rate", f"{approved/total*100:.1f}%" if total > 0 else "N/A")
        c3.metric("Pending Backlog", f"{pending:,}")
        c4.metric("Total $ Disbursed", f"${disbursed:,.0f}")
    else:
        st.info("No incentive application data available yet.")

# =============================================================================
# TAB 2: Data Quality & Pipeline Health
# =============================================================================
with tab2:
    st.subheader("Data Quality & Pipeline Health")
    st.caption("Operational monitoring: DMF metrics, pipeline flow, replication status, and Dynamic Table health.")

    if st.button("Refresh", key="refresh_dq"):
        st.rerun()

    # --- DMF Metrics Panel ---
    st.markdown("### DMF Metrics")
    try:
        df_dmf = session.sql("""
            SELECT SCHEDULED_TIME, MEASUREMENT_TIME, TABLE_SCHEMA, TABLE_NAME,
                   METRIC_NAME, VALUE
            FROM EV_DEMO.OBS.DMF_RESULTS
            ORDER BY MEASUREMENT_TIME DESC
        """).to_pandas()

        if not df_dmf.empty:
            # Drop rows with NULL values (e.g., Quarantine with no data)
            df_dmf = df_dmf.dropna(subset=["VALUE"])

            # Current status for each metric (latest measurement)
            latest = df_dmf.drop_duplicates(subset=["TABLE_NAME", "METRIC_NAME"], keep="first").copy()
            latest["STATUS"] = latest.apply(lambda r: (
                "FAIL" if (
                    (r["METRIC_NAME"] == "DMF_DUPLICATE_VIN_COUNT" and r["VALUE"] > 0) or
                    (r["METRIC_NAME"] == "DMF_INVALID_BUSINESS_RULES" and r["VALUE"] > 0) or
                    (r["METRIC_NAME"] == "DMF_ROW_COUNT_RECONCILIATION" and r["VALUE"] != 0)
                ) else "WARN" if (
                    (r["METRIC_NAME"] == "DMF_VIN_COMPLETENESS" and r["VALUE"] < 100) or
                    (r["METRIC_NAME"] == "FRESHNESS" and r["VALUE"] > 10800)
                ) else "PASS"
            ), axis=1)

            # Color-coded status display
            status_colors = {"PASS": "🟢", "WARN": "🟡", "FAIL": "🔴"}
            latest["INDICATOR"] = latest["STATUS"].map(status_colors)

            display_cols = ["INDICATOR", "TABLE_NAME", "METRIC_NAME", "VALUE", "STATUS", "MEASUREMENT_TIME"]
            st.dataframe(latest[display_cols], use_container_width=True)

            # Trend chart
            if len(df_dmf) > 1:
                st.markdown("**Metric Values Over Time**")
                trend_chart = alt.Chart(df_dmf).mark_line(point=True).encode(
                    x=alt.X("MEASUREMENT_TIME:T", title="Time"),
                    y=alt.Y("VALUE:Q", title="Value"),
                    color=alt.Color("METRIC_NAME:N", title="Metric"),
                    tooltip=["METRIC_NAME", "VALUE", "MEASUREMENT_TIME"]
                ).properties(height=250)
                st.altair_chart(trend_chart, use_container_width=True)
        else:
            st.info("DMF results exist but are empty for EV_DEMO.")
    except Exception as e:
        st.error(f"DMF query error: {str(e)}")

    st.divider()

    # --- Pipeline Data Flow Panel ---
    st.markdown("### Pipeline Data Flow")
    try:
        df_flow = session.sql("""
            SELECT
                (SELECT COUNT(*) FROM EV_DEMO.RAW.RAW_EV_REGISTRATIONS) AS RAW_VARIANT,
                (SELECT COUNT(*) FROM EV_DEMO.RAW.BRONZE_PARSED) AS BRONZE_PARSED,
                (SELECT COUNT(DISTINCT VIN) FROM EV_DEMO.RAW.BRONZE_PARSED) AS BRONZE_DISTINCT_VINS,
                (SELECT COUNT(*) FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS) AS SILVER,
                (SELECT COUNT(*) FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS) AS QUARANTINE,
                (SELECT COUNT(*) FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS)
                    + (SELECT COUNT(*) FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS) AS SILVER_PLUS_QUARANTINE,
                (SELECT COUNT(*) FROM EV_DEMO.MART.FACT_EV_REGISTRATIONS) AS GOLD_FACT,
                CASE
                    WHEN (SELECT COUNT(DISTINCT VIN) FROM EV_DEMO.RAW.BRONZE_PARSED)
                        = (SELECT COUNT(*) FROM EV_DEMO.CLEAN.SILVER_EV_REGISTRATIONS)
                        + (SELECT COUNT(*) FROM EV_DEMO.CLEAN.QUARANTINE_EV_REGISTRATIONS)
                    THEN 'PASS'
                    ELSE 'INVESTIGATE'
                END AS RECONCILIATION_STATUS
        """).to_pandas()

        if not df_flow.empty:
            row = df_flow.iloc[0]
            c1, c2, c3, c4 = st.columns(4)
            c1.metric("Raw Files", f"{int(row['RAW_VARIANT']):,}")
            c2.metric("Bronze Parsed", f"{int(row['BRONZE_PARSED']):,}")
            c3.metric("Silver", f"{int(row['SILVER']):,}")
            c4.metric("Gold Fact", f"{int(row['GOLD_FACT']):,}")

            c5, c6, c7 = st.columns(3)
            c5.metric("Distinct VINs (Bronze)", f"{int(row['BRONZE_DISTINCT_VINS']):,}")
            c6.metric("Silver + Quarantine", f"{int(row['SILVER_PLUS_QUARANTINE']):,}")
            c7.metric("Quarantine", f"{int(row['QUARANTINE']):,}")

            if row["RECONCILIATION_STATUS"] == "PASS":
                st.success("PASS — all vehicles accounted for (dedup reduces raw rows to distinct VINs)")
            else:
                st.warning("INVESTIGATE — row count mismatch between Bronze distinct VINs and Silver + Quarantine")
    except Exception as e:
        st.error(f"Error querying pipeline flow: {str(e)}")

    st.divider()

    # --- Ingested Files Panel ---
    st.markdown("### Ingested Files")
    try:
        df_files = session.sql("""
            SELECT SOURCE_FILE, LOADED_AT
            FROM EV_DEMO.RAW.RAW_EV_REGISTRATIONS
            ORDER BY LOADED_AT DESC
        """).to_pandas()

        if not df_files.empty:
            st.dataframe(df_files, use_container_width=True)
        else:
            st.info("No files ingested yet.")
    except Exception as e:
        st.error(f"Error querying ingested files: {str(e)}")
