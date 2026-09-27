-- =====================================================================
-- Q6. When are goals scored? Goals and xG in 15-minute intervals
-- Skills: bucketing with integer division, generate_series to
--         include empty buckets, LEFT JOIN on a derived table.
-- =====================================================================
SET search_path TO dw;

WITH buckets AS (
    SELECT b AS bucket,
           CASE WHEN b < 6 THEN (b * 15) || '-' || (b * 15 + 15)
                WHEN b = 6 THEN '90+ (stoppage)'
                ELSE 'Extra time' END AS interval_label
    FROM generate_series(0, 7) AS b
),
shots AS (
    SELECT s.*,
           CASE WHEN s.period >= 3 THEN 7
                WHEN s.period = 1 AND s.minute >= 45 THEN 2   -- 1st-half stoppage counts as 30-45
                WHEN s.minute >= 90 THEN 6
                ELSE s.minute / 15 END AS bucket
    FROM fact_shot s
)
SELECT
    b.interval_label,
    COUNT(s.event_id)                              AS shots,
    COUNT(s.event_id) FILTER (WHERE s.is_goal)     AS goals,
    ROUND(COALESCE(SUM(s.xg), 0), 1)               AS xg,
    ROUND(100.0 * COUNT(s.event_id) FILTER (WHERE s.is_goal)
          / SUM(COUNT(s.event_id) FILTER (WHERE s.is_goal)) OVER (), 1) AS pct_of_all_goals
FROM buckets b
LEFT JOIN shots s ON s.bucket = b.bucket
GROUP BY b.bucket, b.interval_label
ORDER BY b.bucket;
