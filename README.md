# 📊 Data Analytics Portfolio

> SQL & Business Intelligence work focused on operations analytics, store performance, and field team productivity in the food-tech / delivery industry.

---

## 🛠 Tech Stack

| Tool | Usage |
|------|-------|
| **SQL (Snowflake)** | Data extraction, transformation, and metric calculation |
| **Power BI** | Operational dashboards and executive reporting |
| **Google Sheets** | Lightweight data inputs and team roster management |
| **Python** *(in progress)* | Automation and data pipelines |

---

## 📁 Repository Structure

```
📁 sql/
├── 01_holiday_tracker.sql              # Working-day normalisation across 8 countries
├── 02_store_handoff_analysis.sql       # New store onboarding & first-contact SLA
├── 03_cancel_rate_and_availability.sql # Store health: cancellations + availability hours
├── 04_churn_prevention_phones.sql      # At-risk store contact list (LATERAL FLATTEN)
├── 05_contact_success_by_channel.sql   # Agent effectiveness by contact channel
└── 06_pilot_store_performance.sql      # Full onboarding analysis for a store pilot
```

---

## 🔍 Project Highlights

### 1. Holiday-Aware Productivity Tracker
Enriches weekly agent activity data with public holidays across 8 LATAM countries, so that KPIs like contacts-per-day are normalised by actual working days — not calendar days.

**Key techniques:** `DATEADD`, `DAYOFWEEKISO`, `GROUP BY` aggregation, multi-country date logic.

---

### 2. Store Handoff Analysis
Identifies newly onboarded stores and validates whether the field team completed a successful first contact within the SLA window (15 days from signing).

**Key techniques:** Multi-step CTEs, `QUALIFY` + `ROW_NUMBER()` deduplication, `ILIKE` pattern matching, conditional `CASE` flags.

---

### 3. Cancel Rate & Availability Hours
Calculates overall and category-level cancellation rates (partner, user, tech, logistics) alongside availability hours in the first 7 days for every store in the portfolio.

**Key techniques:** `DIV0` for zero-safe division, conditional `COUNT`, multiple independent CTEs joined at the end, date-window filtering.

---

### 4. Churn Prevention Phone List
Builds a clean, deduplicated contact list for stores at risk of churning, unpacking comma-separated phone fields into individual dialing rows.

**Key techniques:** `LATERAL FLATTEN`, `SPLIT`, `NULLIF`/`TRIM` for data cleaning, `UNION ALL` to combine phone sources.

---

### 5. Contact Success Rate by Channel
Measures how effective each contact channel is (call, WhatsApp, email) using `GROUPING SETS` to produce both country-level detail and a cross-country summary in a single query.

**Key techniques:** `GROUPING SETS`, `COALESCE` for null-to-label conversion, ordered output with `CASE` in `ORDER BY`.

---

### 6. Pilot Store Performance — Full Onboarding Analysis
End-to-end analytical base table for a store pilot: availability rates, order ramp-up, catalog quality, contact history, and suspension data — all combined from 10+ sources.

**Key techniques:** 10+ CTEs, multi-source `LEFT JOIN`, `IFF`/`COALESCE`, `DIV0` ratios, `QUALIFY` window deduplication.

---

## 💡 SQL Patterns Demonstrated

- ✅ Common Table Expressions (CTEs) — simple to deeply nested
- ✅ Window functions: `ROW_NUMBER`, `QUALIFY`, `PARTITION BY`
- ✅ `GROUPING SETS` for multi-level aggregation
- ✅ `LATERAL FLATTEN` for semi-structured / array data
- ✅ Safe division with `DIV0`
- ✅ Date arithmetic: `DATEDIFF`, `DATEADD`, `DATE_TRUNC`
- ✅ Deduplication patterns with `QUALIFY`
- ✅ Multi-source JOIN strategies

---

## 📌 Notes

All queries in this repository have been **anonymised**: internal table names and schema references have been replaced with generic equivalents (`schema.table_name`). The business logic, structure, and SQL patterns are fully preserved.

---

## 📬 Contact

Feel free to reach out if you have questions about any of the queries or the analytical approach behind them.
