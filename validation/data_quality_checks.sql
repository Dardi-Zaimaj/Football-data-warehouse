-- =====================================================================
-- Data quality checks
-- Every check returns one row: check name, number of failing rows, status.
-- A healthy load returns PASS for every check.
-- =====================================================================
SET search_path TO dw;

WITH checks AS (

    -- 1. Goals recorded as shots (+ own goals) must equal the official score
    SELECT 'Goals in fact_shot + own goals = official score' AS check_name,
           COUNT(*) AS failing_rows
    FROM (
        SELECT tm.match_id, tm.team_id, tm.goals_for,
               COALESCE(g.shot_goals, 0) + COALESCE(og.own_goals, 0) AS derived_goals
        FROM v_team_match tm
        LEFT JOIN (SELECT match_id, team_id, COUNT(*) AS shot_goals
                   FROM fact_shot WHERE is_goal GROUP BY 1, 2) g
               ON g.match_id = tm.match_id AND g.team_id = tm.team_id
        LEFT JOIN (SELECT e.match_id, e.team_id, COUNT(*) AS own_goals
                   FROM fact_event e JOIN dim_event_type t USING (event_type_id)
                   WHERE t.event_type_name = 'Own Goal For' AND e.period < 5
                   GROUP BY 1, 2) og
               ON og.match_id = tm.match_id AND og.team_id = tm.team_id
    ) x
    WHERE goals_for <> derived_goals

    UNION ALL
    -- 2. Every match has exactly 11 starters per team
    SELECT 'Exactly 11 starters per team per match', COUNT(*)
    FROM (SELECT match_id, team_id FROM fact_player_match
          GROUP BY 1, 2 HAVING COUNT(*) FILTER (WHERE is_starter) <> 11) x

    UNION ALL
    -- 3. Coordinates stay inside the 120 x 80 pitch
    --    (0.5 unit tolerance: the source occasionally records e.g. x = 120.1
    --     for a ball exactly on the line)
    SELECT 'Event coordinates inside the pitch', COUNT(*)
    FROM fact_event
    WHERE x NOT BETWEEN -0.5 AND 120.5 OR y NOT BETWEEN -0.5 AND 80.5

    UNION ALL
    -- 4. xG must be a probability
    SELECT 'xG between 0 and 1', COUNT(*)
    FROM fact_shot WHERE xg NOT BETWEEN 0 AND 1

    UNION ALL
    -- 5. No player can play more than the length of the match
    SELECT 'Minutes played <= match length', COUNT(*)
    FROM fact_player_match pm JOIN dim_match m USING (match_id)
    WHERE pm.minutes_played > m.match_length_seconds / 60.0 + 0.1

    UNION ALL
    -- 6. Team total minutes should be ~11 x match length (red cards reduce it)
    SELECT 'Team minutes within 10-11 players x match length', COUNT(*)
    FROM (SELECT pm.match_id, pm.team_id,
                 SUM(pm.minutes_played) / (MAX(m.match_length_seconds) / 60.0) AS players_on_pitch
          FROM fact_player_match pm JOIN dim_match m USING (match_id)
          GROUP BY 1, 2) x
    WHERE players_on_pitch NOT BETWEEN 9.5 AND 11.05

    UNION ALL
    -- 7. Duplicate events (same match, same index)
    SELECT 'No duplicate event index within a match', COUNT(*)
    FROM (SELECT match_id, event_index FROM fact_event
          GROUP BY 1, 2 HAVING COUNT(*) > 1) x

    UNION ALL
    -- 8. Shots / passes by players who are not in that match's lineup
    SELECT 'Every shooter/passer appears in the match lineup', COUNT(*)
    FROM (SELECT match_id, player_id FROM fact_shot
          UNION SELECT match_id, player_id FROM fact_pass) a
    WHERE NOT EXISTS (SELECT 1 FROM fact_player_match pm
                      WHERE pm.match_id = a.match_id AND pm.player_id = a.player_id)

    UNION ALL
    -- 9. Every key pass referenced by a shot exists
    SELECT 'Every shot key_pass_id exists in fact_pass', COUNT(*)
    FROM fact_shot s
    WHERE s.key_pass_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM fact_pass p WHERE p.event_id = s.key_pass_id)

    UNION ALL
    -- 10. Home and away team are different
    SELECT 'Home team differs from away team', COUNT(*)
    FROM dim_match WHERE home_team_id = away_team_id
)
SELECT check_name,
       failing_rows,
       CASE WHEN failing_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM checks;
