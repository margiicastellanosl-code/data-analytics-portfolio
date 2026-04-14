/*
=============================================================
  Store Performance: Cancel Rate & Availability Hours
=============================================================
  Purpose : For every store in the active portfolio,
            calculates:
              - Overall cancel rate + breakdown by
                cancellation category (partner, user, tech…)
              - Availability hours in the first 7 days
                after going live (W1 ramp-up proxy)

  Skills  : Multiple independent CTEs joined at the end,
            DIV0 for safe division, conditional COUNT,
            date-window filtering with DATEDIFF
=============================================================
*/

WITH ACTIVE_STORES AS (
    -- Universe: all stores currently assigned to field agents
    SELECT DISTINCT store_id
    FROM schema.agent_store_assignments
),

-- ── Orders summary ────────────────────────────────────────
ORDERS_SUMMARY AS (
    SELECT
        o.country || o.store_id                                       AS store_id,

        -- Valid orders + ops-cancelled orders = denominator
        COUNT(CASE WHEN o.counts_to_gmv = TRUE  AND o.is_cancelled = FALSE THEN o.order_key END)
      + COUNT(CASE WHEN o.is_cancelled  = TRUE  AND o.is_ops       = TRUE  THEN o.order_key END)
                                                                      AS total_orders,

        COUNT(CASE WHEN o.is_cancelled = TRUE AND o.is_ops = TRUE THEN o.order_key END)
                                                                      AS cancelled_orders,

        DIV0(
            COUNT(CASE WHEN o.is_cancelled = TRUE AND o.is_ops = TRUE THEN o.order_key END),
            COUNT(CASE WHEN o.counts_to_gmv = TRUE AND o.is_cancelled = FALSE THEN o.order_key END)
          + COUNT(CASE WHEN o.is_cancelled  = TRUE AND o.is_ops = TRUE THEN o.order_key END)
        )                                                             AS cancel_rate

    FROM schema.order_facts o
    INNER JOIN ACTIVE_STORES s ON (o.country || o.store_id) = s.store_id
    WHERE
        o.vertical  = 'RESTAURANTS'
        AND o.synthetic = 'FALSE'
        AND o.created_at >= '2025-11-01'
    GROUP BY 1
),

-- ── Cancel rate broken down by responsible party ──────────
CANCEL_RATE_BY_TYPE AS (
    SELECT
        od.country || od.store_id                                     AS store_id,
        DIV0(COUNT(DISTINCT CASE WHEN bo.category = 'Partner' THEN od.order_key END),
             COUNT(DISTINCT od.order_key))                            AS cancel_rate_partner,
        DIV0(COUNT(DISTINCT CASE WHEN bo.category = 'User'    THEN od.order_key END),
             COUNT(DISTINCT od.order_key))                            AS cancel_rate_user,
        DIV0(COUNT(DISTINCT CASE WHEN bo.category = 'RT'      THEN od.order_key END),
             COUNT(DISTINCT od.order_key))                            AS cancel_rate_logistics,
        DIV0(COUNT(DISTINCT CASE WHEN bo.category = 'Tech'    THEN od.order_key END),
             COUNT(DISTINCT od.order_key))                            AS cancel_rate_tech,
        DIV0(COUNT(DISTINCT CASE WHEN bo.category = 'Other'   THEN od.order_key END),
             COUNT(DISTINCT od.order_key))                            AS cancel_rate_other
    FROM schema.order_facts od
    LEFT JOIN schema.bad_orders bo
        ON od.country = bo.country AND od.order_id = bo.order_id
    INNER JOIN ACTIVE_STORES s ON (od.country || od.store_id) = s.store_id
    WHERE
        od.vertical  = 'RESTAURANTS'
        AND od.synthetic = 'FALSE'
        AND od.created_at >= '2025-11-01'
    GROUP BY 1
),

-- ── Availability hours in Week 1 (days 0-7 after first login) ─
AVA_HOURS AS (
    SELECT
        a.country || a.store_id                                       AS store_id,
        DIV0(
            SUM(CASE
                    WHEN DATEDIFF('DAY',
                                  COALESCE(b.first_login, b.first_order_date),
                                  a.date) BETWEEN 0 AND 7
                    THEN a.available_minutes
                    ELSE 0
                END),
            60
        )                                                             AS available_hours_w1
    FROM schema.store_availability_daily a
    INNER JOIN schema.store_ramp_dates   b ON (a.country || a.store_id) = b.store_id
    WHERE
        a.date >= '2025-11-01'
        AND DATEDIFF('DAY', COALESCE(b.first_login, b.first_order_date), a.date) BETWEEN 0 AND 7
    GROUP BY 1
)

-- ── Final join ────────────────────────────────────────────
SELECT
    s.store_id,
    COALESCE(os.total_orders,            0) AS total_orders,
    COALESCE(os.cancelled_orders,        0) AS cancelled_orders,
    COALESCE(os.cancel_rate,             0) AS cancel_rate,
    COALESCE(cr.cancel_rate_partner,     0) AS cancel_rate_partner,
    COALESCE(cr.cancel_rate_user,        0) AS cancel_rate_user,
    COALESCE(cr.cancel_rate_logistics,   0) AS cancel_rate_logistics,
    COALESCE(cr.cancel_rate_tech,        0) AS cancel_rate_tech,
    COALESCE(cr.cancel_rate_other,       0) AS cancel_rate_other,
    COALESCE(ah.available_hours_w1,      0) AS available_hours_w1
FROM ACTIVE_STORES    s
LEFT JOIN ORDERS_SUMMARY     os ON os.store_id = s.store_id
LEFT JOIN CANCEL_RATE_BY_TYPE cr ON cr.store_id = s.store_id
LEFT JOIN AVA_HOURS           ah ON ah.store_id = s.store_id;
