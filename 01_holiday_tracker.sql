/*
=============================================================
  Holiday Tracker by Country & Week
=============================================================
  Purpose : Enriches a follow-up activity table with the
            number of public holidays in each ISO week,
            so that productivity metrics (contacts, visits)
            can be normalised by actual working days.

  Skills  : CTEs, DATEADD/DATEDIFF, DAYOFWEEKISO,
            LEFT JOIN aggregation, multi-country logic
=============================================================
*/

WITH API_HOLIDAYS AS (

    -- Hard-coded holiday calendar for 8 LATAM countries (2026)
    -- In production this could be replaced by an API or a lookup table
    SELECT COLUMN1::DATE AS DT FROM VALUES

        -- COLOMBIA
        ('2026-01-01'),('2026-01-12'),('2026-03-23'),('2026-04-02'),('2026-04-03'),
        ('2026-05-01'),('2026-05-18'),('2026-06-08'),('2026-06-15'),('2026-06-29'),
        ('2026-07-20'),('2026-08-07'),('2026-08-17'),('2026-10-12'),('2026-11-02'),
        ('2026-11-16'),('2026-12-08'),('2026-12-25'),

        -- ARGENTINA
        ('2026-01-01'),('2026-02-16'),('2026-02-17'),('2026-03-24'),
        ('2026-04-02'),('2026-04-03'),('2026-05-01'),('2026-05-25'),
        ('2026-06-15'),('2026-06-20'),('2026-07-09'),('2026-08-17'),
        ('2026-10-12'),('2026-11-23'),('2026-12-08'),('2026-12-25'),

        -- MÉXICO
        ('2026-01-01'),('2026-02-02'),('2026-03-16'),('2026-04-02'),
        ('2026-04-03'),('2026-05-01'),('2026-09-16'),
        ('2026-11-16'),('2026-12-25')

        -- ... (remaining countries omitted for brevity)
),

-- Aggregate holidays to ISO week level
HOLIDAYS_BY_WEEK AS (
    SELECT
        DATEADD(DAY, -(DAYOFWEEKISO(DT) - 1), DT) AS WEEK_START,
        COUNT(DISTINCT DT)                          AS HOLIDAY_COUNT
    FROM API_HOLIDAYS
    GROUP BY 1
)

-- Final output: one row per agent-week, with working-day context
SELECT DISTINCT

    activity.*,
    agent_status.status          AS agent_status,

    -- Holiday enrichment
    COALESCE(h.HOLIDAY_COUNT, 0) AS holidays_in_week,
    (5.5 - COALESCE(h.HOLIDAY_COUNT, 0)) AS working_days_in_week

FROM schema.follow_up_activity        AS activity

INNER JOIN schema.agent_assignments   AS assignments
    ON activity.agent_email = assignments.agent_email

LEFT JOIN schema.agent_roster         AS agent_status
    ON activity.agent_name = agent_status.agent_name

LEFT JOIN HOLIDAYS_BY_WEEK h
    ON DATEADD(DAY, -(DAYOFWEEKISO(activity.week) - 1), activity.week) = h.WEEK_START

WHERE activity.week >= '2026-01-01';
