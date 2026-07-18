# Sample Chatbot Questions for EV Demo
# Use these to demonstrate the Cortex Agent during a live demo or interview.
# Co-authored with CoCo

## Executive Dashboard Queries
- "What is the YoY growth trend in EV registrations?"
- "Which regions have the highest EV adoption rates?"
- "What is our market penetration by vehicle type — BEV vs PHEV?"
- "How close are we to the 2030 goal of 1 million EVs?"
- "Which year showed the biggest jump in registrations?"
- "What percentage of the 2026 target have we achieved so far?"

## Sales & Marketing Queries
- "Compare Tesla vs other manufacturers in market share by region"
- "What percentage of EVs are eligible for CAFV incentives?"
- "Which vehicle models are trending in high-income zip codes?"
- "What's the average electric range by manufacturer?"
- "Which makes are most popular in rural vs urban areas?"
- "Show me the top 5 models registered in King County this year"

## Operations Queries (leveraging CDC incentive data)
- "What is the incentive approval rate by zip code?"
- "How many applications are currently pending?"
- "What are the top denial reasons for incentive applications?"
- "What's the average number of days from submission to review?"
- "Which zip codes have high registration demand but low incentive approval rates?"
- "How much total incentive money has been disbursed?"
- "Show me denied applications where the reason was MSRP exceeds cap"
- "Are there zip codes with many pending applications and no charging stations?"

## Cross-Source Analytical Queries (combines registration + CDC + reference data)
- "In zip codes with median income above $100K, what's the BEV vs PHEV split and approval rate?"
- "Which counties have the most registrations per charging station?"
- "Compare incentive approval rates in urban Seattle zips vs rural WA"
- "For approved incentive applications, what are the most common makes and models?"
- "Which legislative districts are furthest behind the state EV goal?"
- "Show me the relationship between population density and EV registrations per capita"

## Multi-Turn Drill-Down Examples
- Start: "What's the overall incentive approval rate?"
  - Follow-up: "Break that down by vehicle type"
  - Follow-up: "Now show me just the denied ones and why"
- Start: "Which county has the most EV registrations?"
  - Follow-up: "What's the make/model distribution there?"
  - Follow-up: "How does that compare to the state average?"
- Start: "How are we tracking against the 2030 goal?"
  - Follow-up: "At the current growth rate, will we make it?"
  - Follow-up: "Which regions are contributing most to growth?"
