-- =====================================================================
-- Q8. Game state: how do teams play when winning, drawing or losing?
-- Rebuilds the live score before every shot from the goal sequence,
-- then splits xG by game state.
-- Skills: UNION of goals from shots and own goals, running totals with
--         window functions, LATERAL join to look up "score at time t".
-- =====================================================================
SET search_path TO dw;

WITH goals AS (            -- every goal with the team it counts for
    SELECT s.match_id, s.team_id AS scoring_team, s.period, s.minute, e.event_index
    FROM fact_shot s JOIN fact_event e USING (event_id)
    WHERE s.is_goal
    UNION ALL
    SELECT e.match_id, e.team_id, e.period, e.minute, e.event_index
    FROM fact_event e JOIN dim_event_type et USING (event_type_id)
    WHERE et.event_type_name = 'Own Goal For' AND e.period < 5
),
shot_state AS (
    SELECT
        s.event_id, s.match_id, s.team_id, s.xg, s.is_goal,
        -- goals for / against scored BEFORE this shot
        COALESCE(sc.goals_for, 0)     AS goals_for_before,
        COALESCE(sc.goals_against, 0) AS goals_against_before
    FROM fact_shot s
    JOIN fact_event e USING (event_id)
    LEFT JOIN LATERAL (
        SELECT COUNT(*) FILTER (WHERE g.scoring_team =  s.team_id) AS goals_for,
               COUNT(*) FILTER (WHERE g.scoring_team <> s.team_id) AS goals_against
        FROM goals g
        WHERE g.match_id = s.match_id
          AND g.event_index < e.event_index
    ) sc ON TRUE
)
SELECT
    CASE WHEN goals_for_before >  goals_against_before THEN 'Winning'
         WHEN goals_for_before =  goals_against_before THEN 'Drawing'
         ELSE 'Losing' END                                 AS game_state,
    COUNT(*)                                               AS shots,
    ROUND(SUM(xg), 1)                                      AS total_xg,
    ROUND(AVG(xg), 3)                                      AS xg_per_shot,
    COUNT(*) FILTER (WHERE is_goal)                        AS goals,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_goal) / COUNT(*), 1) AS conversion_pct
FROM shot_state
GROUP BY 1
ORDER BY xg_per_shot DESC;
