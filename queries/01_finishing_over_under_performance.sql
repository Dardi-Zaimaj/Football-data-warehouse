-- =====================================================================
-- Q1. Who finished above / below expectation?
-- Non-penalty goals minus non-penalty xG. Positive = clinical finisher
-- (or lucky), negative = wasteful (or unlucky).
-- Skills: joining a view, filtering on aggregates, derived metrics.
-- =====================================================================
SET search_path TO dw;

SELECT
    competition_name,
    player,
    team,
    minutes,
    shots,
    np_goals,
    npxg,
    ROUND(np_goals - npxg, 2)                         AS goals_minus_xg,
    ROUND(npxg / NULLIF(shots - (goals - np_goals), 0), 3) AS npxg_per_shot
FROM v_player_season
WHERE shots >= 10
ORDER BY goals_minus_xg DESC
LIMIT 15;
