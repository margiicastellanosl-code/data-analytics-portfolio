/*
=============================================================
  New Store Handoff Analysis
=============================================================
  Purpose : Identifies newly onboarded stores (R2S within a
            defined window) and checks whether each store
            received a successful first contact ("handoff")
            from the field team within 15 days of signing.

  Skills  : Multi-step CTEs, QUALIFY + ROW_NUMBER dedup,
            DATEDIFF filtering, conditional aggregation,
            ILIKE pattern matching
=============================================================
*/

-- Step 1: Get the most recent load date per store
WITH LOAD_DATE AS (
    SELECT
        store_id,
        brand_id,
        onboarding_start_date,
        load_date
    FROM schema.store_onboarding_inflow
    WHERE assigned_date IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY store_id
        ORDER BY COALESCE(credentials_sent_date, '1900-01-01') DESC,
                 load_date DESC
    ) = 1
),

-- Step 2: Filter stores onboarded in the target window
--         and loaded within 7 days of signing (SLA check)
NEW_STORES AS (
    SELECT
        s.country,
        s.country || s.brand_id      AS country_brand_id,
        s.store_id,
        s.channel,                        -- e.g. HUNTING, INSIDE SALES
        s.store_created_date             AS r2s_date,
        l.load_date
    FROM schema.store_signings AS s
    LEFT JOIN LOAD_DATE AS l ON l.store_id = s.store_id
    WHERE
        s.store_created_date BETWEEN '2025-11-01' AND '2026-01-31'
        AND DATEDIFF('DAY', s.store_created_date, l.load_date) <= 7
    QUALIFY
        CASE
            WHEN s.store_id IS NULL THEN 1
            ELSE ROW_NUMBER() OVER (PARTITION BY s.store_id ORDER BY s.store_created_date DESC)
        END = 1
),

-- Step 3: Find the first successful handoff contact per store
HANDOFF AS (
    SELECT
        s.country,
        s.store_id,
        s.r2s_date,
        MIN(e.contact_timestamp::DATE) AS first_handoff_date
    FROM NEW_STORES s
    JOIN schema.contact_follow_up e
        ON  e.country_brand_id  = s.country_brand_id
        AND e.contact_timestamp::DATE >= DATEADD('DAY', -15, s.r2s_date)
        AND e.sprint_name ILIKE '%Handoff%'
        AND e.contacted = 'YES'
    GROUP BY 1, 2, 3
)

-- Final: join handoff result back to the store base
SELECT
    s.*,
    h.first_handoff_date,
    CASE WHEN h.store_id IS NOT NULL THEN 'YES' ELSE 'NO' END AS handoff_completed
FROM NEW_STORES  AS s
LEFT JOIN HANDOFF AS h ON h.store_id = s.store_id
WHERE
    s.country  = 'MX'
    AND handoff_completed = 'YES'
    AND s.channel IN ('HUNTING', 'INSIDE SALES');
