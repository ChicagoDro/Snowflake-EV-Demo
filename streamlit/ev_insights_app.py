# EV Insights Dashboard with Executive Analytics and Cortex Agent Chat
# Co-authored with CoCo
import streamlit as st
import altair as alt
import pandas as pd
import json
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="WA EV Insights", layout="wide")
st.title("Washington State EV Insights Dashboard")

session = get_active_session()

tab1, tab2 = st.tabs(["Executive Dashboard", "Ask the Data"])

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
        st.info("No incentive application data available yet. CDC pipeline may not have captured application events.")

# =============================================================================
# TAB 2: Ask the Data (Cortex Agent Chat)
# =============================================================================
with tab2:
    st.subheader("Ask the Data")
    st.markdown(
        "Chat with the **EV Demo Analyst** agent to explore EV registration data, "
        "trends, and incentive programs using natural language."
    )

    AGENT_FQN = "EV_DEMO.MART.EV_DEMO_ANALYST"

    # Starter questions
    starter_questions = [
        "What are the top 5 counties by EV registrations?",
        "How has BEV adoption grown year over year?",
        "Which EV makes have the longest electric range?",
        "What percentage of EVs are eligible for clean fuel incentives?",
    ]

    st.markdown("**Suggested questions:**")
    cols = st.columns(len(starter_questions))
    for i, q in enumerate(starter_questions):
        if cols[i].button(q, key=f"starter_{i}"):
            st.session_state["pending_question"] = q

    # Message history
    if "messages" not in st.session_state:
        st.session_state["messages"] = []

    # Display chat history
    for msg in st.session_state["messages"]:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])

    # Determine input
    user_input = st.chat_input("Ask a question about EV data...")
    if "pending_question" in st.session_state:
        user_input = st.session_state.pop("pending_question")

    if user_input:
        st.session_state["messages"].append({"role": "user", "content": user_input})
        with st.chat_message("user"):
            st.markdown(user_input)

        with st.chat_message("assistant"):
            with st.spinner("Thinking..."):
                try:
                    # Build messages payload for multi-turn
                    api_messages = []
                    for msg in st.session_state["messages"]:
                        api_messages.append({
                            "role": msg["role"],
                            "content": [{"type": "text", "text": msg["content"]}]
                        })

                    request_body = json.dumps({"messages": api_messages})

                    result = session.sql(f"""
                        SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
                            '{AGENT_FQN}',
                            PARSE_JSON('{request_body.replace("'", "''")}')
                        ) AS RESPONSE
                    """).collect()

                    response_json = json.loads(result[0]["RESPONSE"])

                    # Extract text response
                    assistant_text = ""
                    sql_text = None

                    if "choices" in response_json:
                        for choice in response_json["choices"]:
                            messages = choice.get("messages", [])
                            for m in messages:
                                if m.get("role") == "assistant":
                                    for content_block in m.get("content", []):
                                        if content_block.get("type") == "text":
                                            assistant_text += content_block.get("text", "")
                                        elif content_block.get("type") == "tool_results":
                                            for tr in content_block.get("tool_results", []):
                                                if tr.get("type") == "sql":
                                                    sql_text = tr.get("statement", "")
                    elif "message" in response_json:
                        msg_content = response_json["message"].get("content", [])
                        for block in msg_content:
                            if block.get("type") == "text":
                                assistant_text += block.get("text", "")

                    if not assistant_text:
                        assistant_text = "I received a response but couldn't extract text. Raw response available in logs."

                    st.markdown(assistant_text)

                    if sql_text:
                        with st.expander("Generated SQL"):
                            st.code(sql_text, language="sql")
                        try:
                            df_result = session.sql(sql_text).to_pandas()
                            st.dataframe(df_result, use_container_width=True)
                        except Exception:
                            pass

                    st.session_state["messages"].append({"role": "assistant", "content": assistant_text})

                except Exception as e:
                    error_msg = f"Error communicating with agent: {str(e)}"
                    st.error(error_msg)
                    st.session_state["messages"].append({"role": "assistant", "content": error_msg})
