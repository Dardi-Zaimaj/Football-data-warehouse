-- =====================================================================
-- Q2. Leverkusen's unbeaten 2023/24 season: rolling 5-match form
-- Rolling xG, xG against and points using window frames.
-- Skills: window functions (ROWS BETWEEN), running totals.
-- =====================================================================
SET search_path TO dw;

SELECT
    d.full_date,
    opp.team_name                                             AS opponent,
    tm.venue,
    tm.goals_for || '-' || tm.goals_against                   AS score,
    tm.result,
    ROUND(tm.xg, 2)                                           AS xg,
    ROUND(tm.xg_against, 2)                                   AS xga,
    SUM(tm.points) OVER w_season                              AS cumulative_points,
    ROUND(AVG(tm.xg)         OVER w_last5, 2)                 AS xg_last5_avg,
    ROUND(AVG(tm.xg_against) OVER w_last5, 2)                 AS xga_last5_avg,
    SUM(tm.points)           OVER w_last5                     AS points_last5
FROM v_team_match tm
JOIN dim_team t    ON t.team_id   = tm.team_id
JOIN dim_team opp  ON opp.team_id = tm.opponent_id
JOIN dim_date d    ON d.date_key  = tm.date_key
JOIN dim_competition_season cs ON cs.competition_season_key = tm.competition_season_key
WHERE t.team_name = 'Bayer Leverkusen'
  AND cs.competition_name = '1. Bundesliga'
WINDOW
    w_season AS (ORDER BY d.full_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
    w_last5  AS (ORDER BY d.full_date ROWS BETWEEN 4 PRECEDING AND CURRENT ROW)
ORDER BY d.full_date;
