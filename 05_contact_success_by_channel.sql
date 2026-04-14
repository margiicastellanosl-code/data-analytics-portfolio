/*
=============================================================
  Contact Success Rate by Channel & Country
=============================================================
  Purpose : Measures agent effectiveness by contact channel
            (call, WhatsApp, email, etc.) using GROUPING SETS
            to produce both a country-level detail and a
            cross-country summary (*) in a single query pass.

  Skills  : GROUPING SETS, conditional COUNT, INNER JOIN
            deduplication pattern, ORDER BY with CASE for
            controlled row ordering
=============================================================
*/

WITH AGENT_ROSTER AS (
    -- Deduplicate agent table: one row per agent with latest attributes
    SELECT
        MAX(country)    AS country,
        MAX(team_lead)  AS team_lead,
        agent_email,
        MAX(region)     AS supervisor,
        MAX(status)     AS agent_status
    FROM schema.field_agent_roster
    GROUP BY agent_email
)

SELECT
    activity.week,

    -- COALESCE turns the NULL produced by GROUPING SETS into '*' (all-countries total)
    COALESCE(agents.country, '*')           AS country,
    activity.contact_channel                AS channel,

    -- Effective contacts: only rows where the store actually picked up / responded
    COUNT(CASE WHEN UPPER(activity.contacted) = 'YES' THEN 1 END)
                                            AS successful_contacts,

    -- Total attempts: every logged contact attempt (YES + NO)
    COUNT(activity.contacted)               AS total_attempts,

    -- Derived rate (can also be computed in BI layer)
    DIV0(
        COUNT(CASE WHEN UPPER(activity.contacted) = 'YES' THEN 1 END),
        COUNT(activity.contacted)
    )                                       AS contact_success_rate

FROM schema.contact_follow_up AS activity

INNER JOIN AGENT_ROSTER AS agents
    ON UPPER(TRIM(agents.agent_email)) = UPPER(TRIM(activity.agent_email))
   AND activity.week >= '2026-01-01'

GROUP BY GROUPING SETS (
    -- Row 1: weekly total across all countries (country = NULL → '*')
    (activity.week, activity.contact_channel),

    -- Row 2: weekly detail per country
    (activity.week, agents.country, activity.contact_channel)
)

ORDER BY
    activity.week                                              ASC,
    CASE WHEN agents.country IS NULL THEN 0 ELSE 1 END        ASC,  -- totals first
    channel                                                    ASC,
    country                                                    ASC;
