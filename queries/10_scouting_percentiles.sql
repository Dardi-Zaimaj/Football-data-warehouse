-- =====================================================================
-- Q10. Scouting: percentile profile of Euro 2024 midfielders
-- (min. 270 minutes). Each metric is converted to a 0-100 percentile
-- within the pool — the data behind a scouting radar chart.
-- Skills: PERCENT_RANK(), comparing players inside a peer group.
-- =====================================================================
SET search_path TO dw;

WITH pool AS (
    SELECT *
    FROM v_player_season
    WHERE position_group = 'MID'
      AND competition_name = 'UEFA Euro'
      AND minutes >= 270
),
percentiles AS (
    SELECT
        player,
        team,
        minutes,
        ROUND(100 * PERCENT_RANK() OVER (ORDER BY npxg_p90))            AS npxg_pctl,
        ROUND(100 * PERCENT_RANK() OVER (ORDER BY xa_p90))              AS xa_pctl,
        ROUND(100 * PERCENT_RANK() OVER (ORDER BY prog_passes_p90))     AS prog_pass_pctl,
        ROUND(100 * PERCENT_RANK() OVER (ORDER BY prog_carries_p90))    AS prog_carry_pctl,
        ROUND(100 * PERCENT_RANK() OVER (ORDER BY pressures_p90))       AS pressure_pctl,
        ROUND(100 * PERCENT_RANK() OVER (ORDER BY recoveries_p90))      AS recovery_pctl,
        ROUND(100 * PERCENT_RANK() OVER (ORDER BY pass_completion_pct)) AS pass_pct_pctl
    FROM pool
)
SELECT *,
       ROUND((npxg_pctl + xa_pctl + prog_pass_pctl + prog_carry_pctl
              + pressure_pctl + recovery_pctl + pass_pct_pctl) / 7.0) AS overall_score
FROM percentiles
ORDER BY overall_score DESC
LIMIT 15;
