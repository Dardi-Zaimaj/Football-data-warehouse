-- =====================================================================
-- Q5. Pressing intensity at Euro 2024 — PPDA
-- PPDA = opponent passes in their own 60% of the pitch divided by our
-- defensive actions (tackles/duels, interceptions, fouls, blocks) in
-- the same area. LOWER PPDA = MORE aggressive pressing.
-- Skills: multi-CTE pipeline, joining a team to its opponent,
--         coordinate flipping (StatsBomb records every event from the
--         acting team's point of view).
-- =====================================================================
SET search_path TO dw;

WITH opp_passes AS (       -- passes the opponent made in THEIR first 60% (x <= 72)
    SELECT tm.team_id, COUNT(*) AS opp_passes
    FROM v_team_match tm
    JOIN fact_pass p ON p.match_id = tm.match_id AND p.team_id = tm.opponent_id
    WHERE p.x <= 72
      AND COALESCE(p.pass_type, 'Open Play') NOT IN ('Goal Kick', 'Kick Off', 'Corner', 'Free Kick', 'Throw-in')
    GROUP BY tm.team_id
),
def_actions AS (          -- our defensive actions in the attacking 60% (x >= 48 from our view)
    SELECT e.team_id, COUNT(*) AS def_actions
    FROM fact_event e
    JOIN dim_event_type et USING (event_type_id)
    WHERE et.event_type_name IN ('Duel', 'Interception', 'Foul Committed', 'Block')
      AND e.x >= 48
      AND e.period < 5
    GROUP BY e.team_id
),
euro_teams AS (
    SELECT DISTINCT tm.team_id, COUNT(*) OVER (PARTITION BY tm.team_id) AS matches
    FROM v_team_match tm
    JOIN dim_competition_season cs USING (competition_season_key)
    WHERE cs.competition_name = 'UEFA Euro'
)
SELECT
    t.team_name,
    et.matches,
    op.opp_passes,
    da.def_actions,
    ROUND(op.opp_passes::NUMERIC / NULLIF(da.def_actions, 0), 2) AS ppda,
    RANK() OVER (ORDER BY op.opp_passes::NUMERIC / NULLIF(da.def_actions, 0)) AS pressing_rank
FROM euro_teams et
JOIN dim_team    t  ON t.team_id  = et.team_id
JOIN opp_passes  op ON op.team_id = et.team_id
JOIN def_actions da ON da.team_id = et.team_id
ORDER BY ppda;
