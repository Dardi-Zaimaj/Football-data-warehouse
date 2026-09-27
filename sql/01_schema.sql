-- =====================================================================
-- Football Data Warehouse — star schema
-- Source: StatsBomb open data (event + lineup data)
-- Grain notes are written above each table.
-- =====================================================================

SET client_min_messages = warning;
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;
SET search_path TO dw;

-- ---------------------------------------------------------------------
-- DIMENSIONS
-- ---------------------------------------------------------------------

-- One row per competition + season (e.g. "1. Bundesliga 2023/2024")
CREATE TABLE dim_competition_season (
    competition_season_key  SERIAL PRIMARY KEY,          -- surrogate key
    competition_id          INT          NOT NULL,
    season_id               INT          NOT NULL,
    competition_name        TEXT         NOT NULL,
    season_name             TEXT         NOT NULL,
    country_name            TEXT,
    competition_type        TEXT         NOT NULL,       -- 'Club' / 'International'
    UNIQUE (competition_id, season_id)
);

-- One row per calendar date (only dates that have matches)
CREATE TABLE dim_date (
    date_key        INT PRIMARY KEY,                     -- yyyymmdd
    full_date       DATE        NOT NULL UNIQUE,
    year            SMALLINT    NOT NULL,
    quarter         SMALLINT    NOT NULL,
    month           SMALLINT    NOT NULL,
    month_name      TEXT        NOT NULL,
    day_of_week     TEXT        NOT NULL,
    is_weekend      BOOLEAN     NOT NULL
);

-- One row per team (clubs and national teams)
CREATE TABLE dim_team (
    team_id         INT PRIMARY KEY,                     -- StatsBomb id
    team_name       TEXT        NOT NULL,
    country_name    TEXT
);

-- One row per player
CREATE TABLE dim_player (
    player_id       INT PRIMARY KEY,                     -- StatsBomb id
    player_name     TEXT        NOT NULL,
    display_name    TEXT        NOT NULL,                -- nickname if available
    country_name    TEXT
);

-- One row per StatsBomb position (e.g. "Left Centre Back")
CREATE TABLE dim_position (
    position_id     INT PRIMARY KEY,
    position_name   TEXT        NOT NULL,
    position_group  TEXT        NOT NULL                 -- GK / DEF / MID / FWD
);

-- One row per event type (Pass, Shot, Pressure, ...)
CREATE TABLE dim_event_type (
    event_type_id   INT PRIMARY KEY,
    event_type_name TEXT        NOT NULL
);

-- One row per match. Kept as a dimension because every fact links to it
-- and it carries descriptive attributes (venue, referee, stage).
CREATE TABLE dim_match (
    match_id                INT PRIMARY KEY,
    competition_season_key  INT  NOT NULL REFERENCES dim_competition_season,
    date_key                INT  NOT NULL REFERENCES dim_date,
    kick_off                TIME,
    match_week              SMALLINT,
    competition_stage       TEXT,
    home_team_id            INT  NOT NULL REFERENCES dim_team,
    away_team_id            INT  NOT NULL REFERENCES dim_team,
    home_score              SMALLINT NOT NULL,
    away_score              SMALLINT NOT NULL,
    stadium_name            TEXT,
    referee_name            TEXT,
    match_length_seconds    INT                          -- game clock at final whistle
);

-- ---------------------------------------------------------------------
-- FACTS
-- ---------------------------------------------------------------------

-- Grain: one row per on-ball / off-ball event
CREATE TABLE fact_event (
    event_id        UUID PRIMARY KEY,
    match_id        INT      NOT NULL REFERENCES dim_match,
    event_index     INT      NOT NULL,
    period          SMALLINT NOT NULL,
    minute          SMALLINT NOT NULL,
    second          SMALLINT NOT NULL,
    event_type_id   INT      NOT NULL REFERENCES dim_event_type,
    team_id         INT      NOT NULL REFERENCES dim_team,
    player_id       INT               REFERENCES dim_player,  -- NULL for team events
    position_id     INT               REFERENCES dim_position,
    possession      INT      NOT NULL,
    possession_team_id INT   NOT NULL REFERENCES dim_team,
    play_pattern    TEXT,
    x               NUMERIC(5,1),                        -- pitch is 120 x 80
    y               NUMERIC(5,1),
    duration        NUMERIC(8,3),
    under_pressure  BOOLEAN  NOT NULL DEFAULT FALSE,
    counterpress    BOOLEAN  NOT NULL DEFAULT FALSE,
    outcome         TEXT                                 -- outcome for duels, dribbles, etc.
);

-- Grain: one row per shot
CREATE TABLE fact_shot (
    event_id        UUID PRIMARY KEY REFERENCES fact_event,
    match_id        INT      NOT NULL REFERENCES dim_match,
    team_id         INT      NOT NULL REFERENCES dim_team,
    player_id       INT      NOT NULL REFERENCES dim_player,
    period          SMALLINT NOT NULL,
    minute          SMALLINT NOT NULL,
    play_pattern    TEXT,
    x               NUMERIC(5,1) NOT NULL,
    y               NUMERIC(5,1) NOT NULL,
    end_x           NUMERIC(5,1),
    end_y           NUMERIC(5,1),
    end_z           NUMERIC(5,1),
    xg              NUMERIC(6,4) NOT NULL,
    outcome         TEXT     NOT NULL,                   -- Goal, Saved, Off T, Blocked...
    is_goal         BOOLEAN  NOT NULL,
    is_penalty      BOOLEAN  NOT NULL,
    shot_type       TEXT,                                -- Open Play, Free Kick, Penalty...
    body_part       TEXT,
    technique       TEXT,
    first_time      BOOLEAN  NOT NULL DEFAULT FALSE,
    key_pass_id     UUID                                 -- the pass that assisted the shot
);

-- Grain: one row per pass
CREATE TABLE fact_pass (
    event_id        UUID PRIMARY KEY REFERENCES fact_event,
    match_id        INT      NOT NULL REFERENCES dim_match,
    team_id         INT      NOT NULL REFERENCES dim_team,
    player_id       INT      NOT NULL REFERENCES dim_player,
    recipient_id    INT               REFERENCES dim_player,
    period          SMALLINT NOT NULL,
    minute          SMALLINT NOT NULL,
    x               NUMERIC(5,1) NOT NULL,
    y               NUMERIC(5,1) NOT NULL,
    end_x           NUMERIC(5,1) NOT NULL,
    end_y           NUMERIC(5,1) NOT NULL,
    length          NUMERIC(6,2),
    height          TEXT,                                -- Ground / Low / High
    body_part       TEXT,
    pass_type       TEXT,                                -- Corner, Free Kick, Throw-in... (NULL = open play)
    outcome         TEXT,                                -- NULL = completed
    is_complete     BOOLEAN  NOT NULL,
    is_cross        BOOLEAN  NOT NULL DEFAULT FALSE,
    is_switch       BOOLEAN  NOT NULL DEFAULT FALSE,
    is_through_ball BOOLEAN  NOT NULL DEFAULT FALSE,
    is_shot_assist  BOOLEAN  NOT NULL DEFAULT FALSE,
    is_goal_assist  BOOLEAN  NOT NULL DEFAULT FALSE,
    under_pressure  BOOLEAN  NOT NULL DEFAULT FALSE
);

-- Grain: one row per carry (player running with the ball)
CREATE TABLE fact_carry (
    event_id        UUID PRIMARY KEY REFERENCES fact_event,
    match_id        INT      NOT NULL REFERENCES dim_match,
    team_id         INT      NOT NULL REFERENCES dim_team,
    player_id       INT      NOT NULL REFERENCES dim_player,
    x               NUMERIC(5,1) NOT NULL,
    y               NUMERIC(5,1) NOT NULL,
    end_x           NUMERIC(5,1) NOT NULL,
    end_y           NUMERIC(5,1) NOT NULL
);

-- Grain: one row per player per match they appeared in
CREATE TABLE fact_player_match (
    match_id            INT      NOT NULL REFERENCES dim_match,
    player_id           INT      NOT NULL REFERENCES dim_player,
    team_id             INT      NOT NULL REFERENCES dim_team,
    primary_position_id INT               REFERENCES dim_position,
    is_starter          BOOLEAN  NOT NULL,
    minutes_played      NUMERIC(5,1) NOT NULL,
    yellow_cards        SMALLINT NOT NULL DEFAULT 0,
    red_cards           SMALLINT NOT NULL DEFAULT 0,
    PRIMARY KEY (match_id, player_id)
);

-- ---------------------------------------------------------------------
-- INDEXES for the most common join / filter paths
-- ---------------------------------------------------------------------
CREATE INDEX ix_event_match      ON fact_event (match_id);
CREATE INDEX ix_event_type       ON fact_event (event_type_id);
CREATE INDEX ix_event_player     ON fact_event (player_id);
CREATE INDEX ix_shot_player      ON fact_shot  (player_id);
CREATE INDEX ix_shot_match       ON fact_shot  (match_id);
CREATE INDEX ix_pass_player      ON fact_pass  (player_id);
CREATE INDEX ix_pass_match       ON fact_pass  (match_id);
CREATE INDEX ix_carry_player     ON fact_carry (player_id);
CREATE INDEX ix_pm_player        ON fact_player_match (player_id);
CREATE INDEX ix_match_comp       ON dim_match  (competition_season_key);
