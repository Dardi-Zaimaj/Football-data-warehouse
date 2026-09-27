-- =====================================================================
-- Q4. Where do goals come from? Shot quality by pitch zone
-- Skills: CASE-based bucketing, conditional aggregation, ratios.
-- =====================================================================
SET search_path TO dw;

WITH zoned AS (
    SELECT
        s.*,
        CASE
            WHEN s.is_penalty                                    THEN '0. Penalty'
            WHEN s.x >= 114 AND s.y BETWEEN 30 AND 50            THEN '1. Six-yard box'
            WHEN s.x >= 102 AND s.y BETWEEN 30 AND 50            THEN '2. Central penalty area'
            WHEN s.x >= 102 AND s.y BETWEEN 18 AND 62            THEN '3. Wide penalty area'
            WHEN s.x >= 90                                       THEN '4. Edge of the box (18-30m)'
            ELSE                                                      '5. Long range (30m+)'
        END AS zone
    FROM fact_shot s
)
SELECT
    zone,
    COUNT(*)                                                     AS shots,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)           AS pct_of_shots,
    COUNT(*) FILTER (WHERE is_goal)                              AS goals,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_goal) / COUNT(*), 1) AS conversion_pct,
    ROUND(AVG(xg), 3)                                            AS avg_xg,
    ROUND(COUNT(*) FILTER (WHERE is_goal) - SUM(xg), 1)          AS goals_minus_xg
FROM zoned
GROUP BY zone
ORDER BY zone;
