-- =====================================================================
-- Q3. Best ball progressors per position group (min. 450 minutes)
-- Progressive passes + progressive carries per 90, ranked within
-- each position group.
-- Skills: RANK() with PARTITION BY, filtering on a window result.
-- =====================================================================
SET search_path TO dw;

WITH ranked AS (
    SELECT
        position_group,
        player,
        team,
        competition_name,
        minutes,
        prog_passes_p90,
        prog_carries_p90,
        prog_passes_p90 + prog_carries_p90 AS progressions_p90,
        RANK() OVER (PARTITION BY position_group
                     ORDER BY prog_passes_p90 + prog_carries_p90 DESC) AS rank_in_position
    FROM v_player_season
    WHERE minutes >= 450
      AND position_group <> 'GK'
)
SELECT *
FROM ranked
WHERE rank_in_position <= 5
ORDER BY position_group, rank_in_position;
