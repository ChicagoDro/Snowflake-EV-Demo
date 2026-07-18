-- Deploy Cortex Agent for EV Demo conversational analytics.
-- Co-authored with CoCo

/*=============================================================================
  10_DEPLOY_CORTEX.SQL
  Deploys the Cortex Agent for natural language analytics.

  DEPLOYMENT STRATEGY:
  1. SEMANTIC VIEW — Deployed via CoCo's semantic_studio tool or Snowsight UI.
     Cannot be created with inline YAML in a SQL script. The tool reads
     semantic/ev_registrations.yaml and deploys it as EV_DEMO.MART.EV_REGISTRATIONS.
     Run this AFTER the semantic view is deployed.

  2. CORTEX AGENT — Created via SQL (CREATE AGENT ... FROM SPECIFICATION).
     This script handles agent creation, grants, and verification.

  PREREQUISITES:
  • Semantic View EV_DEMO.MART.EV_REGISTRATIONS must already be deployed
    (use CoCo: "deploy semantic view semantic/ev_registrations.yaml to EV_DEMO.MART.EV_REGISTRATIONS")
  • Gold layer tables must exist and be populated (run 06_gold_iceberg_tables.sql)
  • CDC table EV_DEMO."public"."incentive_applications" must be accessible
=============================================================================*/

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_EV_DEMO;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. VERIFY SEMANTIC VIEW EXISTS
--    The semantic view must be deployed before creating the agent.
--    Deploy it via CoCo or Snowsight UI using semantic/ev_registrations.yaml
-- ═══════════════════════════════════════════════════════════════════════════════

SHOW SEMANTIC VIEWS IN SCHEMA EV_DEMO.MART;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. CREATE CORTEX AGENT
--    Wraps the semantic view with a conversational persona.
--    Supports multi-turn, context-aware natural language queries.
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE AGENT EV_DEMO.MART.EV_DEMO_ANALYST
    COMMENT = 'EV market analyst agent for WA State registration data and incentive programs'
FROM SPECIFICATION
$$
models:
  orchestration: claude-3-5-sonnet

instructions:
  response: >
    You are an EV market analyst for Washington State. Help business users understand
    EV adoption trends, incentive program effectiveness, and progress toward the 2030
    Clean Cars goal. When answering: reference specific data, provide context for why
    numbers matter, suggest follow-up questions, and format numbers for readability.
  sample_questions:
    - question: "How are we tracking against the 2030 EV adoption goal?"
    - question: "Which counties have the most EV registrations?"
    - question: "What is the incentive approval rate by zip code?"
    - question: "How does Tesla compare to other manufacturers?"

tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: ev_registrations_analyst
      description: "Queries WA State EV registration data, geographic distribution, adoption trends, and incentive program metrics"

tool_resources:
  ev_registrations_analyst:
    semantic_view: EV_DEMO.MART.EV_REGISTRATIONS
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. GRANTS
-- ═══════════════════════════════════════════════════════════════════════════════

GRANT SELECT ON VIEW EV_DEMO.MART.EV_REGISTRATIONS TO ROLE EV_DEMO_ENGINEER;
GRANT USAGE ON AGENT EV_DEMO.MART.EV_DEMO_ANALYST TO ROLE EV_DEMO_ENGINEER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. VERIFY
--    Test the agent with a sample question.
-- ═══════════════════════════════════════════════════════════════════════════════

-- Confirm objects exist
SHOW AGENTS IN SCHEMA EV_DEMO.MART;

-- Test the agent (returns JSON response with generated SQL + results)
SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'EV_DEMO.MART.EV_DEMO_ANALYST',
    '{"messages": [{"role": "user", "content": [{"type": "text", "text": "How many total EV registrations do we have?"}]}]}'
) AS agent_response;
