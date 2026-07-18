-- Data sharing: secure view over Gold layer + SHARE object for cross-account access.
-- Co-authored with CoCo

/*=============================================================================
  09_DATA_SHARING.SQL
  Demonstrates governed data sharing for the Gold layer.

  GOVERNANCE MODEL:
  ┌─────────────────────────────────────────────────────────────────────┐
  │ WHY SECURE VIEWS?                                                   │
  │ • Hides underlying SQL — consumers can't see join logic or sources  │
  │ • Prevents reverse-engineering of table structures via EXPLAIN       │
  │ • Allows row-level filtering via row-access policies per consumer   │
  │ • Single governed interface — change the view, all consumers update │
  └─────────────────────────────────────────────────────────────────────┘

  SHARING OPTIONS COMPARISON:
  ┌──────────────────┬────────────────────────────────────────────────────┐
  │ Method           │ When to Use                                        │
  ├──────────────────┼────────────────────────────────────────────────────┤
  │ Direct Share     │ Known consumer accounts, tight control, no cost    │
  │                  │ to consumer (free data access). Best for internal  │
  │                  │ gov agencies or trusted partners.                  │
  ├──────────────────┼────────────────────────────────────────────────────┤
  │ Marketplace      │ Broader distribution (public or private listing).  │
  │ Listing          │ Discoverability, usage analytics, monetization.    │
  │                  │ Best for public data or commercial data products.  │
  ├──────────────────┼────────────────────────────────────────────────────┤
  │ Data Exchange    │ Curated group of accounts (e.g., state agencies).  │
  │ (deprecated →    │ Being replaced by Private Listings. Use Private    │
  │  Private Listing)│ Listings for new implementations.                  │
  └──────────────────┴────────────────────────────────────────────────────┘

  CROSS-REGION / CROSS-CLOUD:
  • Direct Shares work within the same region only.
  • For cross-region/cross-cloud: use Auto-Fulfillment (replicates data
    to consumer's region automatically) or Listings with replication enabled.
  • Cost consideration: replication = storage + transfer charges.

  ROW-ACCESS POLICY EXAMPLE (not implemented here, documented for reference):
    CREATE ROW ACCESS POLICY rap_by_consumer AS (county VARCHAR)
    RETURNS BOOLEAN ->
      CASE
        WHEN CURRENT_ACCOUNT() = 'AGENCY_KING_COUNTY' THEN county = 'KING'
        WHEN CURRENT_ACCOUNT() = 'AGENCY_PIERCE' THEN county = 'PIERCE'
        ELSE TRUE  -- provider sees all
      END;
    ALTER VIEW ... ADD ROW ACCESS POLICY rap_by_consumer ON (county);
=============================================================================*/

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WH_EV_DEMO;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. SECURE VIEW: Denormalized Gold for consumers
--    Joins fact to both dims so consumers get a flat, governed table.
--    They never need to know about the star schema or join paths.
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE SECURE VIEW EV_DEMO.MART.V_SHARED_EV_REGISTRATIONS AS
SELECT
    f.VIN,
    f.MODEL_YEAR,
    f.CAFV_ELIGIBILITY,
    f.ELECTRIC_UTILITY,
    f.CENSUS_TRACT,
    f.TARGET_EV_COUNT,
    f.POLICY_NAME,
    f.INCENTIVE_AMOUNT,
    f.APPLICATION_STATUS,
    f.LOAD_TS,
    -- Vehicle attributes
    v.MAKE,
    v.MODEL,
    v.EV_TYPE,
    v.ELECTRIC_RANGE,
    v.BASE_MSRP,
    -- Geography
    g.COUNTY,
    g.CITY,
    g.STATE,
    g.POSTAL_CODE,
    g.LEGISLATIVE_DISTRICT,
    g.LATITUDE,
    g.LONGITUDE,
    g.POPULATION,
    g.MEDIAN_INCOME,
    g.EV_CHARGING_STATIONS
FROM EV_DEMO.MART.FACT_EV_REGISTRATIONS f
LEFT JOIN EV_DEMO.MART.DIM_VEHICLE v ON f.VIN = v.VIN
LEFT JOIN EV_DEMO.MART.DIM_GEOGRAPHY g ON f.GEO_KEY = g.GEO_KEY;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. CREATE SHARE
--    Zero-copy, real-time, governed access for consumer accounts.
--    Consumers query the data without ETL, storage, or egress costs.
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE SHARE EV_DEMO_GOLD_SHARE
    COMMENT = 'WA State EV Registration Gold layer — denormalized view + aggregates for partner agencies';

-- Grant usage on the database and schema to the share
GRANT USAGE ON DATABASE EV_DEMO TO SHARE EV_DEMO_GOLD_SHARE;
GRANT USAGE ON SCHEMA EV_DEMO.MART TO SHARE EV_DEMO_GOLD_SHARE;

-- Add the secure view (primary governed interface)
GRANT SELECT ON VIEW EV_DEMO.MART.V_SHARED_EV_REGISTRATIONS TO SHARE EV_DEMO_GOLD_SHARE;

-- Add aggregate tables (pre-computed insights for lightweight queries)
GRANT SELECT ON TABLE EV_DEMO.MART.AGG_REGISTRATIONS_BY_COUNTY TO SHARE EV_DEMO_GOLD_SHARE;
GRANT SELECT ON TABLE EV_DEMO.MART.AGG_REGISTRATIONS_BY_YEAR TO SHARE EV_DEMO_GOLD_SHARE;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. ADD CONSUMER ACCOUNTS (template — replace with actual account locators)
--    In production, you'd add each partner agency's Snowflake account.
-- ═══════════════════════════════════════════════════════════════════════════════

-- ALTER SHARE EV_DEMO_GOLD_SHARE ADD ACCOUNTS = '<consumer_account_locator>';
-- Example: ALTER SHARE EV_DEMO_GOLD_SHARE ADD ACCOUNTS = 'xy12345.us-east-2.azure';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. MARKETPLACE LISTING ALTERNATIVE (documentation only)
--    For broader distribution, create a Private or Public Listing instead:
--
--    Advantages over Direct Share:
--    • Discoverability — consumers find it via Marketplace search
--    • Usage analytics — see who queries what, how often
--    • Auto-Fulfillment — cross-region replication handled automatically
--    • Terms & conditions — attach data usage agreements
--    • Monetization — charge per-query or subscription (public listings)
--
--    To create a listing:
--    1. Go to Snowsight → Data → Provider Studio → + Listing
--    2. Select the SHARE object (EV_DEMO_GOLD_SHARE)
--    3. Choose Private (targeted accounts) or Public (marketplace-wide)
--    4. Add description, sample queries, usage examples
--    5. Publish
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. VERIFY
-- ═══════════════════════════════════════════════════════════════════════════════

-- Confirm share exists and objects are attached
SHOW SHARES LIKE 'EV_DEMO_GOLD_SHARE';

DESCRIBE SHARE EV_DEMO_GOLD_SHARE;

-- Test the secure view returns data
SELECT COUNT(*) AS shared_view_rows FROM EV_DEMO.MART.V_SHARED_EV_REGISTRATIONS;
