/*
=============================================================
  Churn Prevention — Contact Phone List
=============================================================
  Purpose : Builds a deduplicated contact list for stores
            at risk of churn (M1 / M3 age cohorts).
            Each store can have a primary phone + multiple
            secondary phones stored as a comma-separated
            string; LATERAL FLATTEN unpacks them into
            individual rows for outbound dialing.

  Skills  : LATERAL FLATTEN, SPLIT, TRIM/NULLIF cleaning,
            UNION ALL to combine phone sources,
            conditional labeling for prevention urgency
=============================================================
*/

WITH BASE_DATA AS (
    SELECT
        churn.age_cohort,                       -- e.g. M1, M3
        churn.store_id,

        -- Prevention urgency based on weeks ahead
        CASE
            WHEN churn.age_cohort = 'M1'
             AND churn.week = DATE_TRUNC('week', CURRENT_DATE) + INTERVAL '1 week'  THEN 'Prevent_1W'
            WHEN churn.age_cohort = 'M1'
             AND churn.week = DATE_TRUNC('week', CURRENT_DATE) + INTERVAL '2 weeks' THEN 'Prevent_2W'
            WHEN churn.age_cohort = 'M1'
             AND churn.week = DATE_TRUNC('week', CURRENT_DATE) + INTERVAL '3 weeks' THEN 'Prevent_3W'
            ELSE 'Other'
        END AS prevention_bucket,

        -- Clean phone fields (nullify empty strings)
        NULLIF(TRIM(info.primary_phone),    '') AS primary_phone,
        NULLIF(TRIM(info.additional_phones),'') AS additional_phones   -- comma-separated list
    FROM schema.churn_age_cohorts AS churn
    LEFT JOIN schema.store_contact_info AS info
        ON churn.store_id = info.store_id
),

PHONES_UNPACKED AS (

    -- Source 1: primary phone (single value)
    SELECT
        age_cohort,
        store_id,
        prevention_bucket,
        TRIM(primary_phone) AS phone_number
    FROM BASE_DATA
    WHERE primary_phone IS NOT NULL

    UNION ALL

    -- Source 2: additional phones (split comma-separated string into rows)
    SELECT
        age_cohort,
        store_id,
        prevention_bucket,
        TRIM(f.value::STRING) AS phone_number
    FROM BASE_DATA,
        LATERAL FLATTEN(input => SPLIT(additional_phones, ',')) f
    WHERE additional_phones IS NOT NULL
      AND TRIM(f.value::STRING) <> ''
)

SELECT DISTINCT
    age_cohort,
    store_id,
    prevention_bucket,
    phone_number
FROM PHONES_UNPACKED
WHERE age_cohort IN ('M1', 'M3')
ORDER BY prevention_bucket, store_id;
