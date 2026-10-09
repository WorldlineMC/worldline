"""Check emitted evidence, not live acceptance or simulation-wide authority."""
import math
from pathlib import Path
import re
import sys

UUID = r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fields(line):
    return dict(re.findall(r"\b([a-z_]+)=([^\s]+)", line))


def coordinates(event):
    point = tuple(float(event[axis]) for axis in ("x", "y", "z"))
    require(all(math.isfinite(value) for value in point), "non-finite movement coordinate")
    return point


def validate(log_dir):
    logs = {name: (Path(log_dir) / f"{name}.log").read_text().splitlines()
            for name in ("proxy", "server-a", "server-b")}
    proxy = logs["proxy"]
    require(not any(re.search(r"client_transition_packets=[1-9]|attempted unexpected client transition packet", line)
                    for line in proxy), "client-visible transition output was observed")
    completed = [(i, line, re.search(rf"Worldline M5 completed transfer ({UUID})(?=\s|$)", line))
                 for i, line in enumerate(proxy)]
    completed = [(i, line, match[1]) for i, line, match in completed if match]
    require(completed, "no completed M5 transfer found")
    ids = [transfer for _, _, transfer in completed]
    require(len(ids) == len(set(ids)), "transfer did not complete exactly once")

    for complete_index, complete_line, transfer in completed:
        def events(name, marker, key="transfer"):
            return [(i, fields(line)) for i, line in enumerate(logs[name])
                    if marker in line and fields(line).get(key) == transfer]

        def one(name, marker, key="transfer"):
            found = events(name, marker, key)
            require(len(found) == 1, f"{transfer}: expected exactly one {marker} in {name}")
            return found[0]

        require(fields(complete_line).get("client_transition_packets") == "0",
                f"{transfer}: missing zero client-transition count")
        phases = events("proxy", "Worldline handoff ", "transfer_id")
        selected = {}
        for phase in ("COMMITTED", "ACTIVE_DESTINATION", "SOURCE_CLEANED"):
            matches = [(i, event) for i, event in phases if event.get("next_phase") == phase]
            require(len(matches) == 1, f"{transfer}: missing or duplicate phase {phase}")
            selected[phase] = matches[0]
        committed, envelope = selected["COMMITTED"]
        source, destination, player = (envelope[key] for key in ("source", "destination", "player_uuid"))
        require({source, destination} == {"server-a", "server-b"}, f"{transfer}: invalid route")
        for _, event in phases:
            require(all(event.get(key) == envelope[key] for key in ("source", "destination", "player_uuid")),
                    f"{transfer}: inconsistent proxy transfer envelope")

        replay = events("proxy", "Worldline replay ")
        require(replay, f"{transfer}: no replay evidence")
        sequences = [int(event["sequence"]) for _, event in replay]
        require(sequences == list(range(len(replay))), f"{transfer}: replay sequence is not contiguous from zero")
        active = selected["ACTIVE_DESTINATION"][0]
        cleaned = selected["SOURCE_CLEANED"][0]
        require(committed < active < replay[0][0] <= replay[-1][0] < cleaned < complete_index,
                f"{transfer}: proxy phase/replay ordering is invalid")
        crossing = replay[0][1]
        require(crossing.get("has_position") == "true", f"{transfer}: first replay is not positioned")
        crossing_position = coordinates(crossing)

        freeze_i, freeze = one(source, "Worldline froze source player=")
        commit_i, commit = one(source, "Worldline committed away source player=")
        clean_i, clean = one(source, "Worldline cleaned source player=")
        attach_i, attach = one(destination, "Worldline attached inert destination player=")
        activate_i, activate = one(destination, "Worldline activated destination player=")
        applied_i, applied = one(destination, "Worldline applied first replay movement player=")
        require(freeze_i < commit_i < clean_i, f"{transfer}: source lifecycle ordering is invalid")
        require(attach_i < activate_i < applied_i, f"{transfer}: destination lifecycle ordering is invalid")
        for event in (freeze, commit, clean, attach, activate, applied):
            require(event.get("player") == player, f"{transfer}: server player does not match proxy envelope")
        require(not events(source, "Worldline applied first replay movement player="),
                f"{transfer}: source applied destination replay")
        snapshot_hash = freeze.get("snapshot_hash", "")
        require(re.fullmatch(r"[0-9a-f]{64}", snapshot_hash) and snapshot_hash == activate.get("snapshot_hash"),
                f"{transfer}: canonical snapshot hashes differ or are missing")
        source_position = coordinates(freeze)
        destination_position = coordinates(applied)
        require(applied.get("has_position") == "true", f"{transfer}: applied replay is not positioned")
        eastbound = source == "server-a"
        require((source_position[0] < 0 <= crossing_position[0]) if eastbound
                else (crossing_position[0] < 0 <= source_position[0]),
                f"{transfer}: crossing does not match route direction")
        require(all(abs(a - b) < 0.000001 for a, b in zip(crossing_position, destination_position)),
                f"{transfer}: actual applied position differs from crossing replay")
        require(int(commit["authority_millis"]) <= int(activate["authority_millis"]),
                f"{transfer}: authority timestamps overlap")
    return len(completed)


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 2, "usage: assert-m5-trace.sh LOG_DIR | --self-test")
        count = validate(sys.argv[1])
        print(f"M5 trace assertions passed for {count} transfer(s). Live client acceptance remains separate.")
    except (ValueError, KeyError, OSError) as error:
        print(f"M5 trace assertion failed: {error}", file=sys.stderr)
        sys.exit(1)
