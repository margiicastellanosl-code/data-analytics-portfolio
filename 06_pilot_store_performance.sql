/*
=============================================================
  Store Pilot Performance — Full Onboarding Analysis
=============================================================
  Purpose : End-to-end view of a store cohort from sign-up
            through the first 14 days of operation.
            Combines availability, orders, catalog quality,
            contact history, and suspension data into one
            analytical base table for pilot evaluation.

  Skills  : 10+ CTEs, multi-source LEFT JOINs, window
            functions with QUALIFY, date arithmetic,
            LATERAL JOIN pattern, IFF / COALESCE,
            DIV0 for safe ratios
=============================================================
*/

-- ── Dedup helpers ─────────────────────────────────────────

WITH ONBOARDING_DEDUP AS (
    SELECT
        store_id,
        credentials_sent_date,
        first_login,
        assigned_date
    FROM schema.store_onboarding_inflow
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY store_id
        ORDER BY credentials_sent_date DESC NULLS LAST
    ) = 1
),

SIGNINGS_DEDUP AS (
    SELECT
        country || store_id::STRING AS store_id,
        store_created_date
    FROM schema.store_signings
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY country, store_id
        ORDER BY store_created_date DESC NULLS LAST
    ) = 1
),

-- ── Core store universe for this pilot ───────────────────
PILOT_STORES AS (
    SELECT
        a.store_id,
        a.brand_id,
        a.brand_name,
        a.store_name,
        a.city,
        a.category,
        a.country,
        a.team_lead,
        a.assignment_type,
        a.assigned_date,
        a.agent_email,
        a.team,
        CASE WHEN ob.assigned_date IS NOT NULL THEN 'MASS_ASSIGNED'
             ELSE 'NOT_ASSIGNED'
        END                                                  AS assignment_status,
        COALESCE(r30.credentials_sent_date,
                 ob.credentials_sent_date,
                 sig.store_created_date)                     AS credentials_sent_date,
        DATE_TRUNC('MONTH', COALESCE(
                 r30.credentials_sent_date,
                 ob.credentials_sent_date,
                 sig.store_created_date))                    AS cohort_month,
        COALESCE(r30.first_login, ob.first_login)            AS first_login
    FROM schema.agent_store_assignments AS a
    INNER JOIN ONBOARDING_DEDUP AS ob ON ob.store_id = a.store_id
    LEFT JOIN  schema.store_ramp_dates  AS r30 ON r30.store_id = a.store_id
    LEFT JOIN  SIGNINGS_DEDUP           AS sig ON sig.store_id = a.store_id
    -- Pilot scope: two specific team leads
    WHERE a.team_lead IN ('lead_a@company.com', 'lead_b@company.com')
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY a.store_id
        ORDER BY COALESCE(r30.credentials_sent_date,
                          ob.credentials_sent_date,
                          sig.store_created_date) DESC NULLS LAST
    ) = 1
),

-- ── Availability in W1 and W2 ─────────────────────────────
AVA_RAW AS (
    SELECT
        s.store_id,
        a.date                  AS ava_date,
        a.available_minutes,
        a.should_be_available_minutes,
        s.credentials_sent_date,
        s.first_login
    FROM schema.store_availability_daily AS a
    INNER JOIN PILOT_STORES AS s ON s.store_id = (a.country || a.store_id)
    WHERE a.date >= '2025-07-01'
),

AVA_CALC AS (
    SELECT
        store_id,
        SUM(IFF(ava_date BETWEEN first_login AND DATEADD('DAY',  6, first_login), available_minutes,           0)) AS avail_w1,
        SUM(IFF(ava_date BETWEEN first_login AND DATEADD('DAY', 13, first_login), available_minutes,           0)) AS avail_w2,
        SUM(IFF(ava_date BETWEEN first_login AND DATEADD('DAY',  6, first_login), should_be_available_minutes, 0)) AS should_avail_w1,
        SUM(IFF(ava_date BETWEEN first_login AND DATEADD('DAY', 13, first_login), should_be_available_minutes, 0)) AS should_avail_w2
    FROM AVA_RAW
    GROUP BY 1
),

-- ── Orders W1 and W2 ──────────────────────────────────────
ORDERS_RAW AS (
    SELECT
        s.store_id,
        COALESCE(o.closed_at, o.created_at)::DATE AS order_date,
        o.gmv_usd,
        o.order_id,
        s.credentials_sent_date
    FROM schema.order_facts AS o
    INNER JOIN PILOT_STORES AS s ON s.store_id = (o.country || o.store_id)
    WHERE
        o.created_at::DATE >= '2025-07-01'
        AND o.counts_to_gmv = TRUE
        AND o.synthetic     = FALSE
        AND o.vertical      = 'RESTAURANTS'
),

FIRST_LAST_ORDER AS (
    SELECT
        store_id,
        MIN(IFF(order_date >= credentials_sent_date, order_date, NULL)) AS first_order_date,
        MAX(IFF(order_date >= credentials_sent_date, order_date, NULL)) AS last_order_date
    FROM ORDERS_RAW
    GROUP BY 1
),

ORDERS_CALC AS (
    SELECT
        o.store_id,
        fl.first_order_date,
        fl.last_order_date,
        SUM(IFF(o.order_date BETWEEN fl.first_order_date AND DATEADD('DAY', 6,  fl.first_order_date), 1, 0)) AS orders_w1,
        SUM(IFF(o.order_date BETWEEN fl.first_order_date AND DATEADD('DAY', 13, fl.first_order_date), 1, 0)) AS orders_w2
    FROM ORDERS_RAW o
    LEFT JOIN FIRST_LAST_ORDER fl ON fl.store_id = o.store_id
    GROUP BY 1, 2, 3
),

-- ── Catalog quality ───────────────────────────────────────
CATALOG AS (
    SELECT
        s.store_id,
        c.quality_score,
        c.is_perfect_catalog
    FROM schema.catalog_quality AS c
    INNER JOIN PILOT_STORES AS s ON s.store_id = (c.country || c.store_id)
),

-- ── Contact history ───────────────────────────────────────
CONTACTS AS (
    SELECT
        a.brand_id,
        COUNT(CASE WHEN UPPER(a.contacted) = 'YES' THEN 1 END) AS successful_contacts,
        COUNT(a.contacted)                                       AS total_attempts
    FROM schema.contact_follow_up AS a
    INNER JOIN PILOT_STORES AS s ON s.brand_id = a.brand_id
    GROUP BY 1
),

-- ── Current suspension status ─────────────────────────────
SUSPENSION_STATUS AS (
    SELECT
        UPPER(a.country) || a.store_id                          AS store_id,
        a.date::DATE                                            AS suspension_checked_at,
        a.is_suspended,
        a.suspension_reason
    FROM schema.store_availability_snapshot a
    INNER JOIN PILOT_STORES AS s
        ON s.store_id = (UPPER(a.country) || a.store_id)
    WHERE a.date > CURRENT_DATE()
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY a.country, a.store_id
        ORDER BY a.date DESC NULLS FIRST
    ) = 1
),

-- ── Suspension minutes in first 28 days ──────────────────
SUSPENSION_MINUTES AS (
    SELECT
        'MX' || s.store_id                                      AS store_id,
        SUM(CASE WHEN s.suspension_type = 'TIMED' THEN s.minutes ELSE 0 END) AS total_suspended_minutes
    FROM schema.store_suspension_history s
    INNER JOIN PILOT_STORES AS p ON ('MX' || s.store_id) = p.store_id
    WHERE
        s.is_suspended = TRUE
        AND p.first_login IS NOT NULL
        AND s.created_at::DATE BETWEEN p.first_login AND DATEADD('DAY', 28, p.first_login)
    GROUP BY 1
)

-- ── Final assembly ────────────────────────────────────────
SELECT
    -- Store identifiers
    s.store_id,
    s.brand_id,
    s.brand_name,
    s.store_name,
    s.city,
    s.category,
    s.country,
    s.team_lead,
    s.assignment_type,
    s.assigned_date,
    s.agent_email,
    s.team,
    s.assignment_status,
    s.cohort_month,
    s.credentials_sent_date,
    s.first_login,

    -- Availability ratios
    ac.avail_w1,
    ac.avail_w2,
    ac.should_avail_w1,
    ac.should_avail_w2,
    DIV0(ac.avail_w1, ac.should_avail_w1) AS availability_rate_w1,
    DIV0(ac.avail_w2, ac.should_avail_w2) AS availability_rate_w2,

    -- Order activity
    oc.first_order_date,
    oc.last_order_date,
    oc.orders_w1,
    oc.orders_w2,

    -- Catalog
    c.quality_score,
    c.is_perfect_catalog,

    -- Contact
    ct.successful_contacts,
    ct.total_attempts,

    -- Suspension
    IFF(su.is_suspended = TRUE, 'YES', 'NO')                    AS is_currently_suspended,
    su.suspension_reason,
    IFF(su.is_suspended = TRUE, sm.total_suspended_minutes, NULL) AS suspended_minutes_first_28d

FROM PILOT_STORES           AS s
LEFT JOIN AVA_CALC          AS ac ON ac.store_id  = s.store_id
LEFT JOIN ORDERS_CALC       AS oc ON oc.store_id  = s.store_id
LEFT JOIN CATALOG           AS c  ON c.store_id   = s.store_id
LEFT JOIN CONTACTS          AS ct ON ct.brand_id  = s.brand_id
LEFT JOIN SUSPENSION_STATUS AS su ON su.store_id  = s.store_id
LEFT JOIN SUSPENSION_MINUTES AS sm ON sm.store_id = s.store_id;
