-- =====================================================================
-- Analytical views (the "semantic layer" that BI tools connect to)
-- =====================================================================
SET search_path TO dw;

-- ---------------------------------------------------------------------
-- Distance from a pitch location to the centre of the opponent goal.
-- StatsBomb pitch: 120 x 80, attacking left -> right, goal centre (120, 40).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dist_to_goal(x NUMERIC, y NUMERIC)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
    SELECT sqrt(power(120 - x, 2) + power(40 - y, 2));
$$;

-- ---------------------------------------------------------------------
-- Passes enriched with a "progressive" flag.
-- Definition used: a completed open-play pass that moves the ball at
-- least 25% closer to the goal centre and ends in the opponent half.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_pass AS
SELECT
    p.*,
    (   p.is_complete
    AND COALESCE(p.pass_type, 'Open Play') NOT IN ('Corner', 'Free Kick', 'Throw-in', 'Goal Kick', 'Kick Off')
    AND dist_to_goal(p.end_x, p.end_y) <= 0.75 * dist_to_goal(p.x, p.y)
    AND p.end_x >= 60
    )                                                AS is_progressive,
    (p.is_complete AND p.end_x >= 80)                AS into_final_third,
    (p.is_complete AND p.end_x >= 102
                   AND p.end_y BETWEEN 18 AND 62)    AS into_box
FROM fact_pass p;

-- Same idea for carries (minimum 5 metres to avoid tiny touches)
CREATE OR REPLACE VIEW v_carry AS
SELECT
    c.*,
    (   dist_to_goal(c.end_x, c.end_y) <= 0.75 * dist_to_goal(c.x, c.y)
    AND c.end_x >= 60
    AND sqrt(power(c.end_x - c.x, 2) + power(c.end_y - c.y, 2)) >= 5
    )                                                AS is_progressive
FROM fact_carry c;

-- ---------------------------------------------------------------------
-- Match results from each team's point of view (2 rows per match)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_team_match AS
WITH sides AS (
    SELECT match_id, competition_season_key, date_key,
           home_team_id AS team_id, away_team_id AS opponent_id,
           home_score   AS goals_for, away_score AS goals_against, 'Home' AS venue
    FROM dim_match
    UNION ALL
    SELECT match_id, competition_season_key, date_key,
           away_team_id, home_team_id, away_score, home_score, 'Away'
    FROM dim_match
),
shots AS (
    SELECT match_id, team_id,
           COUNT(*)                                     AS shots,
           SUM(xg)                                      AS xg,
           SUM(xg) FILTER (WHERE NOT is_penalty)        AS npxg
    FROM fact_shot
    GROUP BY match_id, team_id
),
passes AS (
    SELECT match_id, team_id, COUNT(*) AS passes
    FROM fact_pass
    GROUP BY match_id, team_id
)
SELECT
    s.*,
    CASE WHEN s.goals_for > s.goals_against THEN 'W'
         WHEN s.goals_for = s.goals_against THEN 'D'
         ELSE 'L' END                                              AS result,
    CASE WHEN s.goals_for > s.goals_against THEN 3
         WHEN s.goals_for = s.goals_against THEN 1
         ELSE 0 END                                                AS points,
    COALESCE(sh.shots, 0)                                          AS shots,
    COALESCE(sh.xg, 0)                                             AS xg,
    COALESCE(sh.npxg, 0)                                           AS npxg,
    COALESCE(osh.shots, 0)                                         AS shots_against,
    COALESCE(osh.xg, 0)                                            AS xg_against,
    ROUND(100.0 * pa.passes / NULLIF(pa.passes + opa.passes, 0), 1) AS pass_share_pct
FROM sides s
LEFT JOIN shots  sh  ON sh.match_id  = s.match_id AND sh.team_id  = s.team_id
LEFT JOIN shots  osh ON osh.match_id = s.match_id AND osh.team_id = s.opponent_id
LEFT JOIN passes pa  ON pa.match_id  = s.match_id AND pa.team_id  = s.team_id
LEFT JOIN passes opa ON opa.match_id = s.match_id AND opa.team_id = s.opponent_id;

-- ---------------------------------------------------------------------
-- Player season summary with per-90 metrics
-- Grain: player x team x competition season
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_player_season AS
WITH mins AS (
    SELECT pm.player_id, pm.team_id, m.competition_season_key,
           COUNT(*)                                   AS appearances,
           COUNT(*) FILTER (WHERE pm.is_starter)      AS starts,
           SUM(pm.minutes_played)                     AS minutes,
           MODE() WITHIN GROUP (ORDER BY pos.position_group) AS position_group
    FROM fact_player_match pm
    JOIN dim_match    m   ON m.match_id = pm.match_id
    LEFT JOIN dim_position pos ON pos.position_id = pm.primary_position_id
    GROUP BY pm.player_id, pm.team_id, m.competition_season_key
),
shots AS (
    SELECT s.player_id, s.team_id, m.competition_season_key,
           COUNT(*)                                        AS shots,
           COUNT(*) FILTER (WHERE s.is_goal)               AS goals,
           COUNT(*) FILTER (WHERE s.is_goal AND NOT s.is_penalty) AS np_goals,
           SUM(s.xg)                                       AS xg,
           SUM(s.xg) FILTER (WHERE NOT s.is_penalty)       AS npxg
    FROM fact_shot s JOIN dim_match m USING (match_id)
    GROUP BY 1, 2, 3
),
passes AS (
    SELECT p.player_id, p.team_id, m.competition_season_key,
           COUNT(*)                                        AS passes,
           COUNT(*) FILTER (WHERE p.is_complete)           AS passes_completed,
           COUNT(*) FILTER (WHERE p.is_progressive)        AS progressive_passes,
           COUNT(*) FILTER (WHERE p.into_box)              AS passes_into_box,
           COUNT(*) FILTER (WHERE p.is_shot_assist OR p.is_goal_assist) AS key_passes,
           COUNT(*) FILTER (WHERE p.is_goal_assist)        AS assists
    FROM v_pass p JOIN dim_match m USING (match_id)
    GROUP BY 1, 2, 3
),
xa AS (   -- expected assists: xG of the shots a player's passes created
    SELECT p.player_id, p.team_id, m.competition_season_key,
           SUM(s.xg) AS xa
    FROM fact_shot s
    JOIN fact_pass p ON p.event_id = s.key_pass_id
    JOIN dim_match m ON m.match_id = s.match_id
    GROUP BY 1, 2, 3
),
carries AS (
    SELECT c.player_id, c.team_id, m.competition_season_key,
           COUNT(*) FILTER (WHERE c.is_progressive) AS progressive_carries
    FROM v_carry c JOIN dim_match m USING (match_id)
    GROUP BY 1, 2, 3
),
defending AS (
    SELECT e.player_id, e.team_id, m.competition_season_key,
           COUNT(*) FILTER (WHERE et.event_type_name = 'Pressure')      AS pressures,
           COUNT(*) FILTER (WHERE et.event_type_name = 'Ball Recovery') AS recoveries,
           COUNT(*) FILTER (WHERE et.event_type_name = 'Interception')  AS interceptions,
           COUNT(*) FILTER (WHERE et.event_type_name = 'Duel'
                              AND e.outcome IN ('Won', 'Success In Play', 'Success Out')) AS duels_won
    FROM fact_event e
    JOIN dim_event_type et USING (event_type_id)
    JOIN dim_match m       USING (match_id)
    WHERE e.player_id IS NOT NULL
    GROUP BY 1, 2, 3
)
SELECT
    cs.competition_name, cs.season_name, mi.competition_season_key,
    pl.player_id, pl.display_name AS player, t.team_name AS team,
    mi.position_group, mi.appearances, mi.starts, mi.minutes,
    COALESCE(sh.goals, 0)  AS goals,       COALESCE(sh.np_goals, 0) AS np_goals,
    COALESCE(sh.shots, 0)  AS shots,       ROUND(COALESCE(sh.xg, 0), 2)   AS xg,
    ROUND(COALESCE(sh.npxg, 0), 2) AS npxg, ROUND(COALESCE(xa.xa, 0), 2) AS xa,
    COALESCE(pa.assists, 0) AS assists,    COALESCE(pa.key_passes, 0) AS key_passes,
    COALESCE(pa.passes, 0)  AS passes,
    ROUND(100.0 * pa.passes_completed / NULLIF(pa.passes, 0), 1) AS pass_completion_pct,
    COALESCE(pa.progressive_passes, 0)  AS progressive_passes,
    COALESCE(ca.progressive_carries, 0) AS progressive_carries,
    COALESCE(pa.passes_into_box, 0)     AS passes_into_box,
    COALESCE(d.pressures, 0) AS pressures, COALESCE(d.recoveries, 0) AS recoveries,
    COALESCE(d.interceptions, 0) AS interceptions, COALESCE(d.duels_won, 0) AS duels_won,
    -- per 90 metrics
    ROUND(90 * COALESCE(sh.np_goals, 0)          / NULLIF(mi.minutes, 0), 2) AS np_goals_p90,
    ROUND(90 * COALESCE(sh.npxg, 0)              / NULLIF(mi.minutes, 0), 2) AS npxg_p90,
    ROUND(90 * COALESCE(xa.xa, 0)                / NULLIF(mi.minutes, 0), 2) AS xa_p90,
    ROUND(90 * COALESCE(pa.progressive_passes,0) / NULLIF(mi.minutes, 0), 2) AS prog_passes_p90,
    ROUND(90 * COALESCE(ca.progressive_carries,0)/ NULLIF(mi.minutes, 0), 2) AS prog_carries_p90,
    ROUND(90 * COALESCE(d.pressures, 0)          / NULLIF(mi.minutes, 0), 2) AS pressures_p90,
    ROUND(90 * COALESCE(d.recoveries, 0)         / NULLIF(mi.minutes, 0), 2) AS recoveries_p90
FROM mins mi
JOIN dim_player pl              ON pl.player_id = mi.player_id
JOIN dim_team   t               ON t.team_id    = mi.team_id
JOIN dim_competition_season cs  ON cs.competition_season_key = mi.competition_season_key
LEFT JOIN shots     sh ON sh.player_id = mi.player_id AND sh.team_id = mi.team_id AND sh.competition_season_key = mi.competition_season_key
LEFT JOIN passes    pa ON pa.player_id = mi.player_id AND pa.team_id = mi.team_id AND pa.competition_season_key = mi.competition_season_key
LEFT JOIN xa        xa ON xa.player_id = mi.player_id AND xa.team_id = mi.team_id AND xa.competition_season_key = mi.competition_season_key
LEFT JOIN carries   ca ON ca.player_id = mi.player_id AND ca.team_id = mi.team_id AND ca.competition_season_key = mi.competition_season_key
LEFT JOIN defending d  ON d.player_id = mi.player_id AND d.team_id = mi.team_id AND d.competition_season_key = mi.competition_season_key;
