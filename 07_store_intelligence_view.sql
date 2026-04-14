/*
=============================================================
  Store Intelligence View — Master Operational Dashboard
=============================================================
  Purpose : Single, self-contained CREATE OR REPLACE VIEW
            that serves as the analytical backbone for a
            field-agent (Farmer) program across 9 countries.

            Combines 12+ data sources into one wide table
            consumed by Power BI dashboards and daily
            operational workflows.

  Output  : One row per store with 80+ attributes covering:
              - Store identity & assignment metadata
              - Order activity (W1, W4, L7D, L28D, L90D)
              - Availability (90-day window)
              - Catalog quality score
              - Contact / follow-up history
              - Ads revenue & markdown activity
              - Commission / take-rate per country
              - Prioritization score (ML model output)
              - Handoff validation (two sources)
              - Seamless delivery status
              - Churn & new-active compensation flags
              - Deep-link for outbound outreach

  Skills  : CREATE OR REPLACE VIEW, 12+ CTEs,
            UNION (two-branch store universe with date logic),
            ARRAY_EXCEPT + ARRAY_DISTINCT for phone dedup,
            TRANSLATE for accent-insensitive city matching,
            CONVERT_TIMEZONE, REGEXP_REPLACE,
            multi-country UNION ALL for commission rates (9 countries),
            GROUPING SETS, QUALIFY, window functions,
            IFF / COALESCE / DIV0 / NULLIF
=============================================================
*/

CREATE OR REPLACE VIEW schema_dev.postsales.store_intelligence_view (
    -- Prioritization
    PRIORITY_REASON,
    PRIORITY_SCORE,
    -- Identity
    COUNTRY,
    BRAND_ID,
    BRAND_NAME,
    STORE_ID,
    STORE_NAME,
    NORMALIZED_CITY,
    SUPERVISOR,
    STORE_CITY,
    BRAND_CATEGORY,
    BRAND_SUBCLASS,
    -- Contact info
    EMAIL_STORE,
    STORE_PHONE,
    PHONE,
    PHONE_CMS,
    PHONE_CONTACT,
    MOBILE_LS,
    PHONE_LS,
    FORMATTED_PHONE,
    PRIMARY_PHONE,
    OTHER_PHONES_UNIQUE,
    -- Assignment
    AGENT_EMAIL_SCORECARD,
    AGENT_EMAIL,
    AGENT_VIEW,
    ASSIGNMENT_SOURCE,
    TEAM_LEAD,
    -- Key dates
    FIRST_ORDER_DATE,
    CREDENTIALS_SENT_DATE,
    R2S_DATE,
    FIRST_LOGIN,
    -- Store health flags
    TOP_PERFORMER,
    CREATED_DATE,
    MENU_PDF,
    LAST_LOGIN,
    STORE_AGE_DAYS,
    FIRST_STORE_ORDER,
    ONBOARDING_START_DATE,
    LOAD_DATE,
    ASSIGNMENT_DATE,
    AGE_DAYS,
    -- Follow-up activity
    CONTACTS_M1,
    DAYS_SINCE_LAST_CONTACT,
    FAILED_CONTACTS_L1M,
    LAST_CONTACT_DAYS_AGO,
    -- Availability
    AVAILABLE_90D,
    SHOULD_BE_AVAILABLE_90D,
    AVA_RATE_90D,
    -- Catalog
    CATALOG_QUALITY_SCORE,
    IS_PERFECT_CATALOG,
    -- Orders (ramp-up)
    ORDERS_W1,
    ORDERS_W4,
    ORDERS_W13,
    -- Orders (rolling)
    ORDERS_L7D,
    ORDERS_L28D,
    ORDERS_L90D,
    GMV_L4W,
    -- Contact counts
    CONTACT_ATTEMPTS,
    SUCCESSFUL_CONTACTS,
    FAILED_CONTACTS,
    CONTACT_ATTEMPTS_WEEK,
    SUCCESSFUL_CONTACTS_WEEK,
    FAILED_CONTACTS_WEEK,
    -- Activity
    LAST_STORE_ORDER,
    MD_ACTIVE,
    ADS_ACTIVE,
    TEAM,
    OPS_ZONE,
    -- Catalog details
    PRODUCTS_WITH_IMAGE,
    NUM_PRODUCTS,
    NUM_HOURS,
    CATALOG_INITIAL,
    CATALOG_LAST_WEEK,
    CATALOG_DEGRADED,
    -- Commercial
    COMMISSION_RATE,
    IS_TOP_PRIORITY,
    FU_ATTEMPTS_TOTAL,
    FU_SUCCESS_TOTAL,
    SLA_LAST_CONTACT_DAYS,
    MENU_LINK,
    -- Status flags
    HAD_HANDOFF,
    IS_SEAMLESS,
    MANAGEMENT_TYPE,
    MANAGEMENT_RESULT,
    DEEP_LINK
) AS (

WITH ONBOARDING_DATES AS (
    /*
      Dedup: keep the most recent onboarding record per store.
      QUALIFY + ROW_NUMBER avoids a subquery.
    */
    SELECT
        store_id,
        onboarding_start_date,
        load_date,
        assignment_date,
        catalog_snapshot::STRING AS catalog
    FROM schema_prod.postsales.store_onboarding_inflow
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY store_id
        ORDER BY COALESCE(credentials_sent_date, '1900-01-01') DESC,
                 load_date DESC
    ) = 1
),

-- ── 1. Store universe (two branches merged with UNION) ────────────────────
--   Branch A: stores covered by the compensation table (end-of-month window)
--   Branch B: stores covered by the current assignment view (rest of month)
--   The WHERE + date math controls which branch is active on any given day.
ACTIVE_STORES AS (

    SELECT DISTINCT
        scorecard.brand_id,
        scorecard.store_id,
        ramp.first_login,
        ramp.first_order_date,
        signings.store_created_date       AS credentials_sent_date,
        compensation.agent_email,
        scorecard.brand_subclass,
        compensation.team_lead,
        'COMPENSATION_TABLE'              AS source_type,
        onboarding.onboarding_start_date,
        onboarding.load_date,
        onboarding.assignment_date,
        COALESCE(signings.store_created_date, onboarding.onboarding_start_date) AS r2s_date,
        onboarding.catalog
    FROM schema_prod.analytics.store_scorecard          AS scorecard
    LEFT JOIN schema_silver.ops.store_ramp_dates        AS ramp
           ON ramp.store_id = scorecard.store_id
    LEFT JOIN schema_silver.ops.store_signings          AS signings
           ON signings.store_id = scorecard.store_id
    LEFT JOIN ONBOARDING_DATES                          AS onboarding
           ON onboarding.store_id = scorecard.store_id
    INNER JOIN schema_prod.postsales.compensation_table AS compensation
           ON compensation.store_id = scorecard.store_id
    LEFT JOIN schema_prod.ops.agent_assignments         AS current_assign
           ON current_assign.store_id = scorecard.store_id
    WHERE
        -- Active during the last 5 days of the month OR on the 1st
        (CURRENT_DATE() > (LAST_DAY(CURRENT_DATE()) - 5))
        OR (DAY(CURRENT_DATE()) = 1)
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY scorecard.store_id
        ORDER BY signings.store_created_date DESC NULLS LAST
    ) = 1

    UNION

    SELECT DISTINCT
        scorecard.brand_id,
        scorecard.store_id,
        ramp.first_login,
        ramp.first_order_date,
        signings.store_created_date       AS credentials_sent_date,
        assignments.agent_email,
        scorecard.brand_subclass,
        assignments.team_lead,
        'CURRENT_ASSIGNMENT'              AS source_type,
        onboarding.onboarding_start_date,
        onboarding.load_date,
        onboarding.assignment_date,
        COALESCE(signings.store_created_date, onboarding.onboarding_start_date) AS r2s_date,
        onboarding.catalog
    FROM schema_prod.analytics.store_scorecard          AS scorecard
    INNER JOIN schema_prod.ops.agent_assignments        AS assignments
           ON assignments.store_id = scorecard.store_id
    LEFT JOIN schema_silver.ops.store_ramp_dates        AS ramp
           ON ramp.store_id = scorecard.store_id
    LEFT JOIN schema_silver.ops.store_signings          AS signings
           ON signings.store_id = scorecard.store_id
    LEFT JOIN ONBOARDING_DATES                          AS onboarding
           ON onboarding.store_id = scorecard.store_id
    LEFT JOIN schema_prod.postsales.compensation_table  AS compensation
           ON compensation.store_id = scorecard.store_id
    WHERE
        -- Active during rest of the month (complement of Branch A)
        (
            compensation.store_id IS NULL
            OR (
                (CURRENT_DATE() <= (LAST_DAY(CURRENT_DATE()) - 5))
                AND (DAY(CURRENT_DATE()) != 1)
            )
        )
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY scorecard.store_id
        ORDER BY signings.store_created_date DESC NULLS LAST
    ) = 1
),

-- ── 2. Availability — last 90 days ────────────────────────────────────────
AVA_90 AS (
    SELECT
        s.store_id,
        SUM(a.available_minutes)         AS available_90d,
        SUM(a.should_be_available_min)   AS should_be_available_90d
    FROM schema_silver.ops.store_availability_daily AS a
    INNER JOIN ACTIVE_STORES AS s ON s.store_id = (a.country || a.store_id)
    WHERE a.date >= DATEADD(DAY, -90, CURRENT_DATE)
    GROUP BY s.store_id
),

-- ── 3. Catalog quality ────────────────────────────────────────────────────
CATALOG AS (
    SELECT
        s.store_id,
        c.quality_score,
        c.is_perfect_catalog,
        c.products_without_image         AS products_with_image_criteria,
        c.num_products,
        c.num_operating_hours
    FROM schema.catalog_quality          AS c
    INNER JOIN ACTIVE_STORES AS s ON s.store_id = (c.country || c.store_id)
),

-- ── 4. Orders raw ─────────────────────────────────────────────────────────
ORDERS_RAW AS (
    SELECT
        COALESCE(o.closed_at, o.created_at)::DATE AS order_date,
        s.store_id,
        o.gmv_usd                                 AS gmv,
        o.order_id
    FROM schema_prod.orders.order_facts AS o
    INNER JOIN ACTIVE_STORES AS s ON s.store_id = (o.country || o.store_id)
    WHERE
        o.created_at::DATE >= '2024-01-01'
        AND o.counts_to_gmv = TRUE
        AND o.synthetic     = FALSE
        AND o.vertical      = 'RESTAURANTS'
),

-- Days since first login for each order (used in ramp-up buckets)
ORDERS_WITH_DIFF AS (
    SELECT
        s.store_id,
        DATEDIFF(DAY, COALESCE(s.first_login, s.first_order_date), o.order_date) AS days_diff,
        o.order_id
    FROM ORDERS_RAW o
    INNER JOIN ACTIVE_STORES s ON s.store_id = o.store_id
    WHERE DATEDIFF(DAY, COALESCE(s.first_login, s.first_order_date), o.order_date) BETWEEN 0 AND 336
),

-- Ramp-up order counts (W1=0-7d, W4=0-28d, W13=0-90d)
ORDERS_RAMPUP AS (
    SELECT
        store_id,
        COUNT(DISTINCT CASE WHEN days_diff BETWEEN 0 AND 90 THEN order_id END) AS orders_w13
    FROM ORDERS_WITH_DIFF
    GROUP BY store_id
),

-- Rolling order/GMV windows (L7D, L28D, L90D, L4W)
ORDERS_ROLLING AS (
    SELECT
        store_id,
        COUNT(CASE WHEN order_date BETWEEN CURRENT_DATE - 7  AND CURRENT_DATE - 1 THEN order_id END) AS orders_l7d,
        COUNT(CASE WHEN order_date BETWEEN CURRENT_DATE - 28 AND CURRENT_DATE - 1 THEN order_id END) AS orders_l28d,
        COUNT(CASE WHEN order_date BETWEEN CURRENT_DATE - 90 AND CURRENT_DATE - 1 THEN order_id END) AS orders_l90d,
        SUM(  CASE WHEN order_date BETWEEN CURRENT_DATE - 28 AND CURRENT_DATE - 1 THEN gmv   END) AS gmv_l4w
    FROM ORDERS_RAW
    GROUP BY store_id
),

-- ── 5. Ads revenue ────────────────────────────────────────────────────────
ADS AS (
    SELECT
        CONCAT(l.country, l.store_id)                   AS store_id,
        f.exchange_rate,
        DIV0(SUM(l.net_revenue)   - SUM(l.ads_subsidized_revenue), f.exchange_rate) AS ads_revenue_usd,
        DIV0(SUM(l.net_bookings)  - SUM(l.ads_subsidized_bookings), f.exchange_rate) AS ads_bookings_usd
    FROM schema_silver.ads.revenue_by_campaign l
    LEFT JOIN schema.exchange_rates f ON l.country = f.country_code
    INNER JOIN ACTIVE_STORES s ON s.store_id = CONCAT(l.country, l.store_id)
    WHERE l.date = CURRENT_DATE
    GROUP BY CONCAT(l.country, l.store_id), f.exchange_rate
),

-- ── 6. Markdown ───────────────────────────────────────────────────────────
MARKDOWN AS (
    SELECT
        m.date,
        CONCAT(m.country, m.store_id)  AS store_id,
        SUM(m.gmv_usd)                 AS gmv_usd,
        SUM(m.markdown_usd)            AS md_usd,
        SUM(CASE WHEN m.segment = 'PRIME_USERS' THEN m.markdown_usd END) AS md_prime_usd
    FROM schema_prod.ads.markdown_global m
    INNER JOIN ACTIVE_STORES s ON s.store_id = CONCAT(m.country, m.store_id)
    WHERE m.end_date = CURRENT_DATE
    GROUP BY m.date, CONCAT(m.country, m.store_id)
),

-- ── 7. Follow-up / contact history ───────────────────────────────────────
-- 7a. Contacts in first month after credentials (M1 window)
CONTACTS_M1 AS (
    SELECT
        s.store_id,
        fu.brand_id,
        COALESCE(COUNT(CASE WHEN fu.date BETWEEN s.r2s_date AND s.r2s_date + INTERVAL '1 MONTH'
                            THEN fu.contacted END), 0)   AS contacts_m1,
        DATEDIFF(DAY, MAX(fu.date), CURRENT_DATE)        AS days_since_last_contact
    FROM schema_prod.postsales.follow_up_activity AS fu
    INNER JOIN ACTIVE_STORES AS s ON s.brand_id = fu.brand_id
    WHERE fu.contacted = 'YES'
    GROUP BY s.store_id, fu.brand_id
),

-- 7b. Failed contacts in last 30 days
FAILED_CONTACTS_L1M AS (
    SELECT
        s.store_id,
        fu.brand_id,
        COUNT(DISTINCT fu.date) AS failed_contacts_l1m
    FROM schema_prod.postsales.follow_up_activity AS fu
    INNER JOIN ACTIVE_STORES AS s ON s.brand_id = fu.brand_id
    WHERE
        fu.contacted = 'NO'
        AND fu.date BETWEEN CURRENT_DATE - INTERVAL '1 MONTH' AND CURRENT_DATE - 1
    GROUP BY s.store_id, fu.brand_id
),

-- 7c. Weekly contact counters (this week's activity)
CONTACTS_WEEKLY AS (
    SELECT
        s.store_id,
        fu.brand_id,
        COUNT(fu.contacted)                                                  AS attempts_week,
        COUNT(CASE WHEN UPPER(fu.contacted) = 'YES' THEN 1 END)             AS successful_week,
        COUNT(CASE WHEN UPPER(fu.contacted) = 'NO'  THEN 1 END)             AS failed_week
    FROM schema_prod.postsales.follow_up_activity AS fu
    INNER JOIN ACTIVE_STORES AS s ON s.brand_id = fu.brand_id
    WHERE fu.date >= DATE_TRUNC('WEEK', CURRENT_DATE)
    GROUP BY s.store_id, fu.brand_id
),

-- 7d. Unified contact log (FM + ELC channels) for SLA & totals
FU_CONTACTS AS (
    SELECT
        s.store_id,
        s.r2s_date               AS reference_date,
        fu.date                  AS contact_date,
        IFF(UPPER(fu.contacted) = 'YES', 1, 0) AS is_success
    FROM schema_prod.postsales.follow_up_activity fu
    JOIN ACTIVE_STORES s ON s.brand_id = fu.brand_id

    UNION ALL

    SELECT
        s.store_id,
        s.r2s_date               AS reference_date,
        elc.contact_date,
        IFF(UPPER(elc.contact_result) IN (
            'SUCCESSFUL CONTACT', 'GESTIÓN EXITOSA'
        ), 1, 0)                 AS is_success
    FROM schema_prod.postsales.elc_follow_up elc
    JOIN ACTIVE_STORES s ON s.store_id = elc.store_id
),

FU_SUMMARY AS (
    SELECT
        store_id,
        SUM(IFF(contact_date >= reference_date OR reference_date IS NULL, 1, 0))             AS fu_attempts_total,
        SUM(IFF((contact_date >= reference_date OR reference_date IS NULL)
                AND is_success = 1, 1, 0))                                                   AS fu_success_total,
        MAX(IFF(contact_date >= reference_date OR reference_date IS NULL, contact_date, NULL)) AS last_fu_date
    FROM FU_CONTACTS
    GROUP BY store_id
),

-- ── 8. Ops zone (microzone mapping) ──────────────────────────────────────
OPS_ZONE AS (
    SELECT
        s.store_id,
        mz.zone_name,
        mz.zone_id
    FROM schema_prod.analytics.store_scorecard s
    LEFT JOIN schema_silver.ops.microzones mz
           ON s.country = mz.country
          AND s.microzone_id = mz.microzone_id
),

-- ── 9. Commission / Take-rate (9 countries via UNION ALL) ─────────────────
--   Each country has its own payment schema; we unify them here.
--   Pattern: STORES → STORE_CONTRACTS → CONTRACTS (active) → OBJECTIVES
COMMISSION_RATES AS (
    SELECT country_code, store_id, commission FROM (

        SELECT 'CO' AS country_code, s.store_id,
               CAST(obj.commission AS NUMBER(10,4)) AS commission
        FROM schema_co.partner_payment.stores s
        JOIN (
            SELECT sc.store_id, obj.commission,
                   ROW_NUMBER() OVER (PARTITION BY sc.store_id ORDER BY sc.created_at DESC) AS rn
            FROM schema_co.partner_payment.store_contracts sc
            JOIN schema_co.partner_payment.contracts       c   ON sc.contract_id = c.id
             AND NOT c._fivetran_deleted AND CURRENT_DATE BETWEEN c.start_date AND c.end_date
            JOIN schema_co.partner_payment.objectives      obj ON c.id = obj.contract_id
             AND obj.order_classification_id = 1 AND obj.start_date <= CURRENT_DATE
            WHERE NOT sc._fivetran_deleted
        ) sc ON s.store_id = sc.store_id AND sc.rn = 1
        WHERE NOT s._fivetran_deleted

        UNION ALL SELECT 'MX' AS country_code, s.store_id, CAST(obj.commission AS NUMBER(10,4))
        FROM schema_mx.partner_payment.stores s
        JOIN (
            SELECT sc.store_id, obj.commission,
                   ROW_NUMBER() OVER (PARTITION BY sc.store_id ORDER BY sc.created_at DESC) AS rn
            FROM schema_mx.partner_payment.store_contracts sc
            JOIN schema_mx.partner_payment.contracts       c   ON sc.contract_id = c.id
             AND NOT c._fivetran_deleted AND CURRENT_DATE BETWEEN c.start_date AND c.end_date
            JOIN schema_mx.partner_payment.objectives      obj ON c.id = obj.contract_id
             AND obj.order_classification_id = 1 AND obj.start_date <= CURRENT_DATE
            WHERE NOT sc._fivetran_deleted
        ) sc ON s.store_id = sc.store_id AND sc.rn = 1
        WHERE NOT s._fivetran_deleted

        UNION ALL SELECT 'AR' AS country_code, s.store_id, CAST(obj.commission AS NUMBER(10,4))
        FROM schema_ar.partner_payment.stores s
        JOIN (
            SELECT sc.store_id, obj.commission,
                   ROW_NUMBER() OVER (PARTITION BY sc.store_id ORDER BY sc.created_at DESC) AS rn
            FROM schema_ar.partner_payment.store_contracts sc
            JOIN schema_ar.partner_payment.contracts       c   ON sc.contract_id = c.id
             AND NOT c._fivetran_deleted AND CURRENT_DATE BETWEEN c.start_date AND c.end_date
            JOIN schema_ar.partner_payment.objectives      obj ON c.id = obj.contract_id
             AND obj.order_classification_id = 1 AND obj.start_date <= CURRENT_DATE
            WHERE NOT sc._fivetran_deleted
        ) sc ON s.store_id = sc.store_id AND sc.rn = 1
        WHERE NOT s._fivetran_deleted

        -- ... additional countries (BR, CL, CR, EC, PE, UY) follow the same pattern
    )
),

-- ── 10. Top priority flag ─────────────────────────────────────────────────
TOP_PRIORITY AS (
    SELECT store_id, is_priority_partner
    FROM schema_silver.ops.store_ramp_dates
),

-- ── 11. ML prioritization score ───────────────────────────────────────────
PRIORITY_SCORE AS (
    SELECT
        store_id,
        MAX(score)  AS priority_score,
        MAX(reason) AS priority_reason
    FROM schema.ml_models.store_prioritization_output
    GROUP BY store_id
),

-- ── 11a. Handoff — ELC channel ────────────────────────────────────────────
HANDOFF_ELC AS (
    SELECT
        s.store_id,
        MIN(e.contact_date::DATE) AS first_elc_handoff_date
    FROM ACTIVE_STORES s
    JOIN schema_prod.postsales.elc_follow_up e
      ON e.store_id = s.store_id
     AND e.contact_date::DATE >= s.r2s_date
     AND e.contact_channel = 'Meet-Hunter'
    GROUP BY 1
),

-- ── 11b. Handoff — Field agent channel ───────────────────────────────────
HANDOFF_FIELD AS (
    SELECT
        s.store_id,
        MIN(e.contact_timestamp::DATE) AS first_field_handoff_date
    FROM ACTIVE_STORES s
    JOIN schema_prod.postsales.follow_up_activity e
      ON e.brand_id = s.brand_id
     AND e.contact_timestamp::DATE >= s.r2s_date
     AND e.sprint_name ILIKE '%Handoff%'
     AND e.contacted = 'YES'
    GROUP BY 1
),

-- ── 11c. Seamless delivery status ─────────────────────────────────────────
SEAMLESS AS (
    SELECT DISTINCT
        country || store_id              AS store_id,
        MAX(delivery_type)               AS seamless_status   -- full / parcial / valle / no_oper
    FROM schema.ops.seamless_stores_manual
    GROUP BY 1
),

-- ── 11d. First login for stores without availability data ─────────────────
FIRST_LOGIN_NO_RAMP AS (
    SELECT
        s.store_id,
        MIN(CASE WHEN a.date >= s.credentials_sent_date THEN a.date ELSE NULL END) AS first_login
    FROM ACTIVE_STORES s
    LEFT JOIN schema_silver.ops.store_ramp_dates r ON r.store_id = s.store_id
    LEFT JOIN schema_silver.ops.store_availability_daily a
           ON (a.country || a.store_id) = s.store_id
    WHERE r.first_login IS NULL AND a.cms_state > 0
    GROUP BY s.store_id
),

-- ── 11e. Catalog snapshot from last week ──────────────────────────────────
CATALOG_LAST_WEEK AS (
    SELECT
        store_id,
        catalog_snapshot::STRING AS catalog_lw
    FROM schema_prod.postsales.weekly_store_snapshot
    WHERE week = DATE_TRUNC('WEEK', DATE_TRUNC('WEEK', CURRENT_DATE()) - 1)
),

-- ── 11f. Compensation / churn flags (current month) ──────────────────────
COMPENSATION AS (
    SELECT
        store_id,
        qualifies_new_active,
        achieved_new_active,
        achieved_churn_retention,
        qualifies_churn_retention
    FROM schema_prod.postsales.compensation_monthly_detail
    WHERE reporting_month = DATE_TRUNC('MONTH', CURRENT_DATE())
),

-- ── 11g. Menu PDF links (from onboarding form, latest per store) ──────────
MENU_LINKS AS (
    SELECT
        country_code,
        store_id,
        country_code || store_id AS full_store_id,
        menu_pdf_link
    FROM (
        SELECT
            CASE form.country
                WHEN 'Argentina'   THEN 'AR'
                WHEN 'Brazil'      THEN 'BR'
                WHEN 'Chile'       THEN 'CL'
                WHEN 'Costa Rica'  THEN 'CR'
                WHEN 'Colombia'    THEN 'CO'
                WHEN 'Ecuador'     THEN 'EC'
                WHEN 'Mexico'      THEN 'MX'
                WHEN 'Peru'        THEN 'PE'
                WHEN 'Uruguay'     THEN 'UY'
            END                                                                    AS country_code,
            REGEXP_REPLACE(detail.cms_id, '^(AR|BR|CL|CR|CO|EC|MX|PE|UY)', '')   AS store_id,
            CASE WHEN detail.menu_type = 'Attached' THEN form.menu_pdf_url
                 ELSE NULL END                                                     AS menu_pdf_link,
            CONVERT_TIMEZONE('America/Bogota', 'GMT', form.created_at)            AS created_at_local,
            ROW_NUMBER() OVER (
                PARTITION BY country_code, store_id
                ORDER BY CONVERT_TIMEZONE('America/Bogota', 'GMT', form.created_at) DESC
            ) AS rn
        FROM schema.onboarding.restaurant_forms    form
        LEFT JOIN schema.onboarding.form_store_detail detail ON form.id = detail.form_id
        WHERE
            CONVERT_TIMEZONE('America/Bogota', 'GMT', form.created_at) >= '2025-10-01'
            AND detail.menu_type = 'Attached'
            AND form.menu_pdf_url ILIKE '%https%'
    )
    WHERE rn = 1
),

-- ── 11h. Deep links for outbound campaigns ────────────────────────────────
DEEP_LINKS AS (
    SELECT brand_id, deep_link_url
    FROM schema.campaigns.store_deep_links
),

-- ── 12. Final assembly ────────────────────────────────────────────────────
DATA_COMBINED AS (
    SELECT
        -- Scorecard / identity
        scorecard.country,
        scorecard.brand_id,
        scorecard.store_id,
        scorecard.brand_name,
        scorecard.store_name,
        scorecard.store_city,
        scorecard.brand_category,
        scorecard.brand_subclass,
        scorecard.email_store,
        scorecard.store_phone,
        scorecard.ops_country_code,
        scorecard.created_date,
        scorecard.last_login,

        -- Assignment
        s.agent_email          AS agent_email_scorecard,
        vw.agent_email,
        vw.agent_view,
        s.source_type          AS assignment_source,
        vw.team_lead,

        -- Dates
        ramp.first_order_date,
        s.credentials_sent_date,
        s.r2s_date,
        COALESCE(ramp.first_login, s.first_login, flna.first_login) AS first_login,

        -- Health
        ramp.is_top_performer,
        ramp.menu_pdf_flag,
        DATEDIFF(DAY, s.credentials_sent_date, CURRENT_DATE)        AS store_age_days,
        ramp.first_store_order,
        s.onboarding_start_date,
        s.load_date,
        s.assignment_date,
        DATEDIFF(DAY, COALESCE(ramp.first_login, s.first_login), CURRENT_DATE) AS age_days,

        -- Follow-up counters
        COALESCE(fm1.contacts_m1,           0) AS contacts_m1,
        COALESCE(fm1.days_since_last_contact, 0) AS days_since_last_contact,
        COALESCE(fnl.failed_contacts_l1m,   0) AS failed_contacts_l1m,
        COALESCE(fus.sla_last_contact_days, 0) AS last_contact_days_ago,

        -- Availability
        COALESCE(ava.available_90d,          0) AS available_90d,
        COALESCE(ava.should_be_available_90d,0) AS should_be_available_90d,
        DIV0(ava.available_90d, ava.should_be_available_90d) AS ava_rate_90d,

        -- Catalog
        cat.quality_score,
        cat.is_perfect_catalog,

        -- Orders (ramp-up)
        COALESCE(ramp.orders_0_7,  0)        AS orders_w1,
        COALESCE(ramp.orders_0_28, 0)        AS orders_w4,
        COALESCE(orp.orders_w13,   0)        AS orders_w13,

        -- Orders (rolling)
        COALESCE(orr.orders_l7d,   0)        AS orders_l7d,
        COALESCE(orr.orders_l28d,  0)        AS orders_l28d,
        COALESCE(orr.orders_l90d,  0)        AS orders_l90d,
        COALESCE(orr.gmv_l4w,      0)        AS gmv_l4w,

        -- Contact counts
        COALESCE(fwt.attempts_week,    0)    AS contact_attempts_week,
        COALESCE(fwt.successful_week,  0)    AS successful_contacts_week,
        COALESCE(fwt.failed_week,      0)    AS failed_contacts_week,

        -- Store activity flags
        ramp.last_store_order,
        IFF(md.store_id  IS NOT NULL, TRUE, FALSE) AS md_active,
        IFF(ads.store_id IS NOT NULL, TRUE, FALSE) AS ads_active,
        vw.team,

        -- Catalog details
        cat.products_with_image_criteria,
        cat.num_products,
        cat.num_operating_hours,

        -- Commercial
        s.catalog         AS catalog_initial,
        clw.catalog_lw    AS catalog_last_week,
        CASE WHEN s.catalog > clw.catalog_lw THEN TRUE ELSE FALSE END AS catalog_degraded,
        cr.commission     AS commission_rate,
        tp.is_priority_partner,
        COALESCE(fus_sum.fu_attempts_total, 0) AS fu_attempts_total,
        COALESCE(fus_sum.fu_success_total,  0) AS fu_success_total,
        COALESCE(DATEDIFF('DAY', fus_sum.last_fu_date, CURRENT_DATE), 0) AS sla_last_contact_days,
        ml.menu_link,
        ps.priority_score,
        ps.priority_reason,

        -- Status flags
        CASE WHEN helc.store_id IS NOT NULL OR hfld.store_id IS NOT NULL THEN 'YES' ELSE 'NO' END AS had_handoff,
        CASE
            WHEN sm.seamless_status = 'no_oper'                        THEN 'SUSPENDED'
            WHEN sm.seamless_status IN ('full', 'partial', 'valley')   THEN 'ACTIVE'
            ELSE 'NONE'
        END AS is_seamless,

        -- Compensation-derived management type & result
        comp.qualifies_new_active,
        comp.achieved_new_active,
        comp.qualifies_churn_retention,
        comp.achieved_churn_retention,

        dl.deep_link_url

    FROM schema_prod.analytics.store_scorecard      AS scorecard
    LEFT JOIN schema_silver.ops.store_ramp_dates    AS ramp  ON ramp.store_id  = scorecard.store_id
    LEFT JOIN AVA_90                                AS ava   ON ava.store_id   = scorecard.store_id
    LEFT JOIN CATALOG                               AS cat   ON cat.store_id   = scorecard.store_id
    LEFT JOIN ORDERS_RAMPUP                         AS orp   ON orp.store_id   = scorecard.store_id
    LEFT JOIN ORDERS_ROLLING                        AS orr   ON orr.store_id   = scorecard.store_id
    LEFT JOIN ADS                                   AS ads   ON ads.store_id   = scorecard.store_id
    LEFT JOIN MARKDOWN                              AS md    ON md.store_id    = scorecard.store_id
    LEFT JOIN CONTACTS_M1                           AS fm1   ON fm1.store_id   = scorecard.store_id
    LEFT JOIN FAILED_CONTACTS_L1M                   AS fnl   ON fnl.store_id   = scorecard.store_id
    LEFT JOIN CONTACTS_WEEKLY                       AS fwt   ON fwt.store_id   = scorecard.store_id
    LEFT JOIN FU_SUMMARY                            AS fus_sum ON fus_sum.store_id = scorecard.store_id
    LEFT JOIN schema.city_mapping                   AS cm
           ON cm.city_upper = TRIM(TRANSLATE(UPPER(scorecard.store_city), 'ÁÉÍÓÚ', 'AEIOU'))
          AND cm.country    = scorecard.country
    LEFT JOIN OPS_ZONE                              AS oz    ON oz.store_id    = scorecard.store_id
    INNER JOIN ACTIVE_STORES                        AS s     ON s.store_id     = scorecard.store_id
    LEFT JOIN schema_prod.ops.agent_assignments     AS vw    ON vw.store_id    = scorecard.store_id
    LEFT JOIN COMMISSION_RATES                      AS cr    ON cr.store_id    = scorecard.store_id
    LEFT JOIN TOP_PRIORITY                          AS tp    ON tp.store_id    = scorecard.store_id
    LEFT JOIN FU_SUMMARY                            AS fus   ON fus.store_id   = scorecard.store_id
    LEFT JOIN PRIORITY_SCORE                        AS ps    ON ps.store_id    = scorecard.store_id
    LEFT JOIN HANDOFF_ELC                           AS helc  ON helc.store_id  = scorecard.store_id
    LEFT JOIN HANDOFF_FIELD                         AS hfld  ON hfld.store_id  = scorecard.store_id
    LEFT JOIN SEAMLESS                              AS sm    ON sm.store_id    = scorecard.store_id
    LEFT JOIN FIRST_LOGIN_NO_RAMP                   AS flna  ON flna.store_id  = scorecard.store_id
    LEFT JOIN CATALOG_LAST_WEEK                     AS clw   ON clw.store_id   = scorecard.store_id
    LEFT JOIN MENU_LINKS                            AS ml    ON ml.full_store_id = scorecard.store_id
    LEFT JOIN COMPENSATION                          AS comp  ON comp.store_id  = scorecard.store_id
    LEFT JOIN DEEP_LINKS                            AS dl    ON dl.brand_id    = scorecard.brand_id
)

-- ── Final SELECT with phone deduplication ─────────────────────────────────
--   ARRAY_EXCEPT + ARRAY_DISTINCT ensures the "primary" phone is not
--   repeated in the "other phones" list, producing a clean contact set.
SELECT DISTINCT
    priority_reason,
    priority_score,
    country,
    brand_id,
    brand_name,
    store_id,
    store_name,
    TRIM(TRANSLATE(UPPER(store_city), 'ÁÉÍÓÚ', 'AEIOU'))    AS normalized_city,
    -- supervisor field from city mapping join
    store_city,
    brand_category,
    brand_subclass,
    email_store,
    store_phone,
    -- raw phone fields omitted for brevity

    -- Primary phone: prefer formatted/verified phone, fall back to store_phone
    COALESCE(REPLACE(formatted_phone, '+', ''), store_phone)  AS primary_phone,

    -- Other phones: deduplicate all sources, exclude the primary
    ARRAY_TO_STRING(
        ARRAY_EXCEPT(
            ARRAY_DISTINCT(
                ARRAY_CONSTRUCT_COMPACT(
                    REPLACE(store_phone,    '+', ''),
                    REPLACE(phone,          '+', ''),
                    REPLACE(phone_cms,      '+', ''),
                    REPLACE(phone_contact,  '+', ''),
                    REPLACE(mobile_ls,      '+', ''),
                    REPLACE(phone_ls,       '+', ''),
                    REPLACE(formatted_phone,'+', '')
                )
            ),
            -- Remove whatever we already set as primary
            ARRAY_CONSTRUCT(
                formatted_phone,
                REPLACE(formatted_phone, '+', ''),
                store_phone,
                REPLACE(store_phone, '+', '')
            )
        ),
        ', '
    )                                                         AS other_phones_unique,

    agent_email_scorecard,
    agent_email,
    agent_view,
    assignment_source,
    team_lead,
    first_order_date,
    credentials_sent_date,
    r2s_date,
    first_login,
    is_top_performer,
    menu_pdf_flag,
    last_login,
    store_age_days,
    first_store_order,
    onboarding_start_date,
    load_date,
    assignment_date,
    age_days,
    contacts_m1,
    days_since_last_contact,
    failed_contacts_l1m,
    last_contact_days_ago,
    available_90d,
    should_be_available_90d,
    ava_rate_90d,
    quality_score,
    is_perfect_catalog,
    orders_w1,
    orders_w4,
    orders_w13,
    orders_l7d,
    orders_l28d,
    orders_l90d,
    gmv_l4w,
    fu_attempts_total,
    fu_success_total,
    sla_last_contact_days,
    contact_attempts_week,
    successful_contacts_week,
    failed_contacts_week,
    last_store_order,
    md_active,
    ads_active,
    team,
    products_with_image_criteria,
    num_products,
    num_operating_hours,
    catalog_initial,
    catalog_last_week,
    catalog_degraded,
    commission_rate,
    is_priority_partner,
    menu_link,
    had_handoff,
    is_seamless,

    -- Management type derived from compensation flags
    CASE
        WHEN qualifies_new_active = 1 AND qualifies_churn_retention = 1 THEN 'NEW_ACTIVE|CHURN_RETENTION'
        WHEN qualifies_churn_retention = 1                               THEN 'CHURN_RETENTION'
        WHEN qualifies_new_active      = 1                               THEN 'NEW_ACTIVE'
        ELSE NULL
    END AS management_type,

    -- Management result (2x2 of new_active × churn_retention outcomes)
    CASE
        WHEN qualifies_new_active = 1 AND qualifies_churn_retention = 1 AND achieved_churn_retention = 1 AND achieved_new_active = 1 THEN 'ACTIVE|RETAINED'
        WHEN qualifies_new_active = 1 AND qualifies_churn_retention = 1 AND achieved_churn_retention = 1 AND achieved_new_active = 0 THEN 'INACTIVE|RETAINED'
        WHEN qualifies_new_active = 1 AND qualifies_churn_retention = 1 AND achieved_churn_retention = 0 AND achieved_new_active = 1 THEN 'ACTIVE|CHURNED'
        WHEN qualifies_new_active = 1 AND qualifies_churn_retention = 1 AND achieved_churn_retention = 0 AND achieved_new_active = 0 THEN 'INACTIVE|CHURNED'
        WHEN qualifies_churn_retention = 1 AND achieved_churn_retention = 1                                                          THEN 'RETAINED'
        WHEN qualifies_churn_retention = 1 AND achieved_churn_retention = 0                                                          THEN 'CHURNED'
        WHEN qualifies_new_active      = 1 AND achieved_new_active      = 1                                                          THEN 'ACTIVE'
        WHEN qualifies_new_active      = 1 AND achieved_new_active      = 0                                                          THEN 'INACTIVE'
        ELSE NULL
    END AS management_result,

    deep_link_url AS deep_link

FROM DATA_COMBINED

);
