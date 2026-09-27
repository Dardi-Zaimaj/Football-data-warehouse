"""
Football Data Warehouse — ETL pipeline
======================================

Extract  : download StatsBomb open data (matches, events, lineups) as JSON
Transform: flatten nested JSON into tidy tables that match the star schema
Load     : create the schema in PostgreSQL and bulk-load with \\copy

Usage
-----
    python etl/pipeline.py                 # run all steps
    python etl/pipeline.py extract
    python etl/pipeline.py transform
    python etl/pipeline.py load

Connection settings come from the standard PostgreSQL environment variables
(PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE). See .env.example.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw"          # downloaded JSON (git-ignored)
STAGING_DIR = ROOT / "data" / "staging"  # transformed CSVs (git-ignored)
SQL_DIR = ROOT / "sql"

BASE_URL = os.environ.get(
    "STATSBOMB_BASE_URL",
    "https://raw.githubusercontent.com/statsbomb/open-data/master/data",
)

# (competition_id, season_id) pairs to load. Add more here to grow the warehouse.
COMPETITIONS = [
    (9, 281),   # 1. Bundesliga 2023/2024 (all Bayer Leverkusen matches)
    (55, 282),  # UEFA Euro 2024 (all 51 matches)
]

POSITION_GROUPS = {
    **{i: "GK" for i in [1]},
    **{i: "DEF" for i in range(2, 9)},
    **{i: "MID" for i in [9, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20]},
    **{i: "FWD" for i in [17, 21, 22, 23, 24, 25]},
}


# ---------------------------------------------------------------------------
# EXTRACT
# ---------------------------------------------------------------------------
def _fetch(rel_path: str) -> Path:
    """Download one file from StatsBomb open data unless it is cached."""
    target = RAW_DIR / rel_path
    if target.exists():
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    url = f"{BASE_URL}/{rel_path}"
    with urllib.request.urlopen(url, timeout=60) as resp:
        target.write_bytes(resp.read())
    return target


def extract() -> None:
    _fetch("competitions.json")
    for comp_id, season_id in COMPETITIONS:
        matches = json.loads(_fetch(f"matches/{comp_id}/{season_id}.json").read_text())
        print(f"  competition {comp_id}/{season_id}: {len(matches)} matches")
        for i, m in enumerate(matches, 1):
            _fetch(f"events/{m['match_id']}.json")
            _fetch(f"lineups/{m['match_id']}.json")
            if i % 10 == 0:
                print(f"    downloaded {i}/{len(matches)}")


# ---------------------------------------------------------------------------
# TRANSFORM helpers
# ---------------------------------------------------------------------------
def _load_json(rel_path: str):
    return json.loads((RAW_DIR / rel_path).read_text(encoding="utf-8"))


def _xy(loc, idx):
    return loc[idx] if loc and len(loc) > idx else None


def _name(obj):
    return obj["name"] if isinstance(obj, dict) else None

# StatsBomb's clock restarts at a fixed value each period (2nd half at 45:00,
# extra time at 90:00 / 105:00) no matter how much stoppage time was played,
# so real elapsed time has to be rebuilt period by period.
PERIOD_START_CLOCK = {1: 0, 2: 45 * 60, 3: 90 * 60, 4: 105 * 60}
RED_CARDS = {"Red Card", "Second Yellow"}


def _playing_time(events):
    """Return (match_length_seconds, {player_id: (on_sec, off_sec, is_starter)}).

    Built from the event stream (Starting XI, Substitution, red cards) rather
    than the lineup 'positions' spells, which can overlap in extra-time games.
    Period 5 (penalty shootout) is not playing time and is ignored.
    """
    clock = lambda e: e["minute"] * 60 + e["second"]
    period_len = {}
    for e in events:
        if e["period"] < 5:
            p = e["period"]
            period_len[p] = max(period_len.get(p, 0), clock(e) - PERIOD_START_CLOCK[p])
    offset, running = {}, 0
    for p in sorted(period_len):
        offset[p] = running
        running += period_len[p]
    match_length = running

    def elapsed(e):
        return offset[e["period"]] + clock(e) - PERIOD_START_CLOCK[e["period"]]

    on, off, starters = {}, {}, set()
    for e in events:
        name = e["type"]["name"]
        if name == "Starting XI":
            for pl in e["tactics"]["lineup"]:
                starters.add(pl["player"]["id"])
                on[pl["player"]["id"]] = 0
        elif e["period"] >= 5:
            continue
        elif name == "Substitution":
            off[e["player"]["id"]] = elapsed(e)
            on[e["substitution"]["replacement"]["id"]] = elapsed(e)
        elif e.get("player"):
            card = (e.get("foul_committed", {}).get("card")
                    or e.get("bad_behaviour", {}).get("card"))
            if card and card["name"] in RED_CARDS:
                off[e["player"]["id"]] = elapsed(e)
    return match_length, {pid: (t, off.get(pid, match_length), pid in starters)
                          for pid, t in on.items()}


def _primary_position(events, lineup_player):
    """Position a player was in for most of their events (fallback: lineup)."""
    counts = {}
    for e in events:
        if e.get("player", {}).get("id") == lineup_player["player_id"] and e.get("position"):
            counts[e["position"]["id"]] = counts.get(e["position"]["id"], 0) + 1
    if counts:
        return max(counts, key=counts.get)
    return lineup_player["positions"][0]["position_id"] if lineup_player["positions"] else None


def transform() -> None:
    STAGING_DIR.mkdir(parents=True, exist_ok=True)
    comps_raw = _load_json("competitions.json")

    comp_rows, match_rows, team_rows, player_rows = [], [], {}, {}
    position_rows, event_type_rows = {}, {}
    event_rows, shot_rows, pass_rows, carry_rows, pm_rows = [], [], [], [], []

    for comp_key, (comp_id, season_id) in enumerate(COMPETITIONS, start=1):
        meta = next(c for c in comps_raw
                    if c["competition_id"] == comp_id and c["season_id"] == season_id)
        comp_rows.append({
            "competition_season_key": comp_key,
            "competition_id": comp_id,
            "season_id": season_id,
            "competition_name": meta["competition_name"],
            "season_name": meta["season_name"],
            "country_name": meta["country_name"],
            "competition_type": "International" if meta["competition_international"] else "Club",
        })

        for m in _load_json(f"matches/{comp_id}/{season_id}.json"):
            mid = m["match_id"]
            events = _load_json(f"events/{mid}.json")
            lineups = _load_json(f"lineups/{mid}.json")

            match_end, time_on_pitch = _playing_time(events)

            for side in ("home", "away"):
                t = m[f"{side}_team"]
                team_rows[t[f"{side}_team_id"]] = {
                    "team_id": t[f"{side}_team_id"],
                    "team_name": t[f"{side}_team_name"],
                    "country_name": _name(t.get("country")),
                }

            match_rows.append({
                "match_id": mid,
                "competition_season_key": comp_key,
                "match_date": m["match_date"],
                "kick_off": (m.get("kick_off") or "")[:8] or None,
                "match_week": m.get("match_week"),
                "competition_stage": _name(m.get("competition_stage")),
                "home_team_id": m["home_team"]["home_team_id"],
                "away_team_id": m["away_team"]["away_team_id"],
                "home_score": m["home_score"],
                "away_score": m["away_score"],
                "stadium_name": _name(m.get("stadium")),
                "referee_name": _name(m.get("referee")),
                "match_length_seconds": match_end,
            })

            # ---- lineups -> dim_player, dim_position, fact_player_match
            for team in lineups:
                for p in team["lineup"]:
                    player_rows[p["player_id"]] = {
                        "player_id": p["player_id"],
                        "player_name": p["player_name"],
                        "display_name": p.get("player_nickname") or p["player_name"],
                        "country_name": _name(p.get("country")),
                    }
                    for pos in p["positions"]:
                        position_rows[pos["position_id"]] = {
                            "position_id": pos["position_id"],
                            "position_name": pos["position"],
                            "position_group": POSITION_GROUPS.get(pos["position_id"], "MID"),
                        }
                    if p["player_id"] not in time_on_pitch:
                        continue  # unused substitute
                    on, off, starter = time_on_pitch[p["player_id"]]
                    cards = [c["card_type"] for c in p.get("cards", [])]
                    pm_rows.append({
                        "match_id": mid,
                        "player_id": p["player_id"],
                        "team_id": team["team_id"],
                        "primary_position_id": _primary_position(events, p),
                        "is_starter": starter,
                        "minutes_played": round((off - on) / 60, 1),
                        "yellow_cards": sum(c in ("Yellow Card", "Second Yellow") for c in cards),
                        "red_cards": sum(c in ("Red Card", "Second Yellow") for c in cards),
                    })

            # ---- events -> fact_event and the specialised fact tables
            for e in events:
                etype = e["type"]
                event_type_rows[etype["id"]] = {"event_type_id": etype["id"],
                                                "event_type_name": etype["name"]}
                team_rows.setdefault(e["team"]["id"], {"team_id": e["team"]["id"],
                                                       "team_name": e["team"]["name"],
                                                       "country_name": None})
                player = e.get("player")
                if player:
                    player_rows.setdefault(player["id"], {"player_id": player["id"],
                                                          "player_name": player["name"],
                                                          "display_name": player["name"],
                                                          "country_name": None})
                if e.get("position"):
                    position_rows.setdefault(e["position"]["id"], {
                        "position_id": e["position"]["id"],
                        "position_name": e["position"]["name"],
                        "position_group": POSITION_GROUPS.get(e["position"]["id"], "MID"),
                    })

                loc = e.get("location")
                # generic outcome for types that carry one (duel, dribble, interception...)
                outcome = None
                for key in ("duel", "dribble", "interception", "50_50", "goalkeeper"):
                    if key in e and "outcome" in e[key]:
                        outcome = e[key]["outcome"]["name"]
                        break

                base = {
                    "event_id": e["id"],
                    "match_id": mid,
                    "team_id": e["team"]["id"],
                    "player_id": player["id"] if player else None,
                }
                event_rows.append({
                    **base,
                    "event_index": e["index"],
                    "period": e["period"],
                    "minute": e["minute"],
                    "second": e["second"],
                    "event_type_id": etype["id"],
                    "position_id": e["position"]["id"] if e.get("position") else None,
                    "possession": e["possession"],
                    "possession_team_id": e["possession_team"]["id"],
                    "play_pattern": _name(e.get("play_pattern")),
                    "x": _xy(loc, 0),
                    "y": _xy(loc, 1),
                    "duration": e.get("duration"),
                    "under_pressure": bool(e.get("under_pressure", False)),
                    "counterpress": bool(e.get("counterpress", False)),
                    "outcome": outcome,
                })

                if e["period"] == 5:
                    continue  # shootout kicks stay in fact_event only

                if etype["name"] == "Shot":
                    s = e["shot"]
                    end = s.get("end_location")
                    shot_rows.append({
                        **base,
                        "period": e["period"],
                        "minute": e["minute"],
                        "play_pattern": _name(e.get("play_pattern")),
                        "x": _xy(loc, 0), "y": _xy(loc, 1),
                        "end_x": _xy(end, 0), "end_y": _xy(end, 1), "end_z": _xy(end, 2),
                        "xg": s["statsbomb_xg"],
                        "outcome": s["outcome"]["name"],
                        "is_goal": s["outcome"]["name"] == "Goal",
                        "is_penalty": _name(s.get("type")) == "Penalty",
                        "shot_type": _name(s.get("type")),
                        "body_part": _name(s.get("body_part")),
                        "technique": _name(s.get("technique")),
                        "first_time": bool(s.get("first_time", False)),
                        "key_pass_id": s.get("key_pass_id"),
                    })

                elif etype["name"] == "Pass":
                    p = e["pass"]
                    end = p["end_location"]
                    outcome_name = _name(p.get("outcome"))
                    pass_rows.append({
                        **base,
                        "recipient_id": p["recipient"]["id"] if p.get("recipient") else None,
                        "period": e["period"],
                        "minute": e["minute"],
                        "x": _xy(loc, 0), "y": _xy(loc, 1),
                        "end_x": end[0], "end_y": end[1],
                        "length": p.get("length"),
                        "height": _name(p.get("height")),
                        "body_part": _name(p.get("body_part")),
                        "pass_type": _name(p.get("type")),
                        "outcome": outcome_name,
                        "is_complete": outcome_name is None,
                        "is_cross": bool(p.get("cross", False)),
                        "is_switch": bool(p.get("switch", False)),
                        "is_through_ball": bool(p.get("through_ball", False)),
                        "is_shot_assist": bool(p.get("shot_assist", False)),
                        "is_goal_assist": bool(p.get("goal_assist", False)),
                        "under_pressure": bool(e.get("under_pressure", False)),
                    })
                    if p.get("recipient"):
                        r = p["recipient"]
                        player_rows.setdefault(r["id"], {"player_id": r["id"],
                                                         "player_name": r["name"],
                                                         "display_name": r["name"],
                                                         "country_name": None})

                elif etype["name"] == "Carry":
                    end = e["carry"]["end_location"]
                    carry_rows.append({
                        **base,
                        "x": _xy(loc, 0), "y": _xy(loc, 1),
                        "end_x": end[0], "end_y": end[1],
                    })

    # ---- dim_date built from the match dates
    dates = pd.to_datetime(pd.Series(sorted({r["match_date"] for r in match_rows})))
    dim_date = pd.DataFrame({
        "date_key": dates.dt.strftime("%Y%m%d").astype(int),
        "full_date": dates.dt.date,
        "year": dates.dt.year,
        "quarter": dates.dt.quarter,
        "month": dates.dt.month,
        "month_name": dates.dt.month_name(),
        "day_of_week": dates.dt.day_name(),
        "is_weekend": dates.dt.dayofweek >= 5,
    })
    matches = pd.DataFrame(match_rows)
    matches.insert(2, "date_key", pd.to_datetime(matches.pop("match_date")).dt.strftime("%Y%m%d").astype(int))

    tables = {
        "dim_competition_season": pd.DataFrame(comp_rows),
        "dim_date": dim_date,
        "dim_team": pd.DataFrame(team_rows.values()),
        "dim_player": pd.DataFrame(player_rows.values()),
        "dim_position": pd.DataFrame(position_rows.values()),
        "dim_event_type": pd.DataFrame(event_type_rows.values()),
        "dim_match": matches,
        "fact_event": pd.DataFrame(event_rows),
        "fact_shot": pd.DataFrame(shot_rows),
        "fact_pass": pd.DataFrame(pass_rows),
        "fact_carry": pd.DataFrame(carry_rows),
        "fact_player_match": pd.DataFrame(pm_rows),
    }
    int_cols = {"player_id", "recipient_id", "position_id", "primary_position_id", "match_week"}
    for name, df in tables.items():
        for col in int_cols & set(df.columns):
            df[col] = df[col].astype("Int64")  # keep NULLs without turning ids into floats
        df.to_csv(STAGING_DIR / f"{name}.csv", index=False)
        print(f"  {name:<24} {len(df):>9,} rows")


# ---------------------------------------------------------------------------
# LOAD
# ---------------------------------------------------------------------------
LOAD_ORDER = [
    "dim_competition_season", "dim_date", "dim_team", "dim_player", "dim_position",
    "dim_event_type", "dim_match", "fact_event", "fact_shot", "fact_pass",
    "fact_carry", "fact_player_match",
]


def _psql(*args: str) -> None:
    subprocess.run(["psql", "-v", "ON_ERROR_STOP=1", "-q", *args], check=True)


def load() -> None:
    _psql("-f", str(SQL_DIR / "01_schema.sql"))
    for table in LOAD_ORDER:
        csv_path = STAGING_DIR / f"{table}.csv"
        header = pd.read_csv(csv_path, nrows=0).columns
        cols = ", ".join(f'"{c}"' for c in header)
        _psql("-c", f"\\copy dw.{table} ({cols}) FROM '{csv_path}' WITH (FORMAT csv, HEADER true)")
        print(f"  loaded {table}")
    # keep the surrogate-key sequence in sync after loading explicit keys
    _psql("-c", "SELECT setval('dw.dim_competition_season_competition_season_key_seq', "
                "(SELECT MAX(competition_season_key) FROM dw.dim_competition_season));", "-o", os.devnull)
    _psql("-f", str(SQL_DIR / "02_views.sql"))
    _psql("-c", "ANALYZE;")
    print("  views created")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("step", nargs="?", default="all",
                        choices=["all", "extract", "transform", "load"])
    step = parser.parse_args().step
    if step in ("all", "extract"):
        print("EXTRACT");   extract()
    if step in ("all", "transform"):
        print("TRANSFORM"); transform()
    if step in ("all", "load"):
        print("LOAD");      load()


if __name__ == "__main__":
    sys.exit(main())
