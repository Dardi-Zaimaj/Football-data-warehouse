-- =====================================================================
-- Q9. Euro 2024: actual results vs. expected goals
-- Which teams over- or under-performed their chance creation?
-- Skills: aggregation of a team-match view, ranking two ways and
--         comparing ranks.
-- =====================================================================
SET search_path TO dw;

WITH team_totals AS (
    SELECT
        t.team_name,
        COUNT(*)                            AS played,
        SUM(tm.points)                      AS points,   -- 3 per win; knockout draws decided on penalties count as draws
        SUM(tm.goals_for)                   AS gf,
        SUM(tm.goals_against)               AS ga,
        ROUND(SUM(tm.npxg), 1)              AS npxg,
        ROUND(SUM(tm.xg_against), 1)        AS xga,
        ROUND(SUM(tm.npxg - tm.xg_against) / COUNT(*), 2) AS xgd_per_match,
        ROUND(AVG(tm.pass_share_pct), 1)    AS avg_pass_share
    FROM v_team_match tm
    JOIN dim_team t USING (team_id)
    JOIN dim_competition_season cs USING (competition_season_key)
    WHERE cs.competition_name = 'UEFA Euro'
    GROUP BY t.team_name
)
SELECT
    *,
    RANK() OVER (ORDER BY xgd_per_match DESC)  AS xgd_rank,
    ROUND((gf - ga)::NUMERIC / played, 2)      AS gd_per_match
FROM team_totals
ORDER BY xgd_per_match DESC;
