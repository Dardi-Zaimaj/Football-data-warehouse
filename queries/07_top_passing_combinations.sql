-- =====================================================================
-- Q7. Most frequent passing combinations (passer -> receiver)
-- The SQL behind a pass network.
-- Skills: joining the same dimension twice (role-playing dimension).
-- =====================================================================
SET search_path TO dw;

SELECT
    t.team_name,
    passer.display_name                                         AS passer,
    receiver.display_name                                       AS receiver,
    COUNT(*)                                                    AS completed_passes,
    COUNT(*) FILTER (WHERE vp.is_progressive)                   AS progressive,
    ROUND(AVG(vp.end_x - vp.x), 1)                              AS avg_forward_distance
FROM v_pass vp
JOIN dim_team   t        ON t.team_id          = vp.team_id
JOIN dim_player passer   ON passer.player_id   = vp.player_id
JOIN dim_player receiver ON receiver.player_id = vp.recipient_id
WHERE vp.is_complete
GROUP BY t.team_name, passer.display_name, receiver.display_name
ORDER BY completed_passes DESC
LIMIT 15;
