"""Synthetic trace regression fixtures; no Minecraft process or network required."""
from pathlib import Path
import tempfile
import unittest

from assert_m5_trace import validate

TRANSFER = "00000000-0000-0000-0000-000000000099"
PLAYER = "00000000-0000-0000-0000-000000000001"
HASH = "a" * 64


def fixture(transfer=TRANSFER, reverse=False):
    source, destination = ("server-b", "server-a") if reverse else ("server-a", "server-b")
    before, after = (0.25, -0.25) if reverse else (-0.25, 0.25)
    envelope = f"transfer_id={transfer} player_uuid={PLAYER} source={source} destination={destination}"
    return {
        "proxy": [
            f"Worldline handoff {envelope} next_phase=COMMITTED",
            f"Worldline handoff {envelope} next_phase=ACTIVE_DESTINATION",
            f"Worldline replay transfer={transfer} sequence=0 has_position=true x={after} y=64.0 z=0.0",
            f"Worldline replay transfer={transfer} sequence=1 has_position=false",
            f"Worldline handoff {envelope} next_phase=SOURCE_CLEANED",
            f"Worldline M5 completed transfer {transfer} for Test epoch=1 route_generation=1 client_transition_packets=0",
        ],
        source: [
            f"Worldline froze source player={PLAYER} transfer={transfer} snapshot_hash={HASH} x={before} y=64.0 z=0.0",
            f"Worldline committed away source player={PLAYER} transfer={transfer} authority_millis=1000",
            f"Worldline cleaned source player={PLAYER} transfer={transfer}",
        ],
        destination: [
            f"Worldline attached inert destination player={PLAYER} transfer={transfer}",
            f"Worldline activated destination player={PLAYER} transfer={transfer} snapshot_hash={HASH} authority_millis=1001",
            f"Worldline applied first replay movement player={PLAYER} transfer={transfer} has_position=true x={after} y=64.0 z=0.0",
        ],
    }


class TraceTests(unittest.TestCase):
    def check(self, logs, valid=True, count=1):
        with tempfile.TemporaryDirectory() as directory:
            for name, lines in logs.items():
                (Path(directory) / f"{name}.log").write_text("\n".join(lines) + "\n")
            if valid:
                self.assertEqual(count, validate(directory))
            else:
                with self.assertRaises((ValueError, KeyError)):
                    validate(directory)

    def test_eastbound(self):
        self.check(fixture())

    def test_westbound(self):
        self.check(fixture(reverse=True))

    def test_round_trip(self):
        first = fixture()
        second = fixture(transfer=TRANSFER[:-1] + "8", reverse=True)
        self.check({name: first[name] + second[name] for name in first}, count=2)

    def test_out_of_order_sequence(self):
        logs = fixture()
        logs["proxy"][2:4] = reversed(logs["proxy"][2:4])
        self.check(logs, False)

    def test_duplicate_or_gap_sequence(self):
        for sequence in (0, 2, -1):
            with self.subTest(sequence=sequence):
                logs = fixture()
                logs["proxy"][3] = logs["proxy"][3].replace("sequence=1", f"sequence={sequence}")
                self.check(logs, False)

    def test_replay_after_cleanup(self):
        logs = fixture()
        logs["proxy"][3], logs["proxy"][4] = logs["proxy"][4], logs["proxy"][3]
        self.check(logs, False)

    def test_received_marker_is_not_applied_evidence(self):
        logs = fixture()
        logs["server-b"][2] = logs["server-b"][2].replace("applied first", "processed first")
        self.check(logs, False)

    def test_wrong_actual_position(self):
        for axis, value in (("x", "-0.25"), ("y", "65.0"), ("z", "1.0"), ("x", "nan")):
            with self.subTest(axis=axis, value=value):
                logs = fixture()
                old = {"x": "0.25", "y": "64.0", "z": "0.0"}[axis]
                logs["server-b"][2] = logs["server-b"][2].replace(f"{axis}={old}", f"{axis}={value}")
                self.check(logs, False)

    def test_mismatched_player(self):
        logs = fixture()
        logs["server-b"][2] = logs["server-b"][2].replace(PLAYER, TRANSFER)
        self.check(logs, False)

    def test_mismatched_transfer(self):
        logs = fixture()
        logs["server-b"][2] = logs["server-b"][2].replace(TRANSFER, PLAYER)
        self.check(logs, False)

    def test_inconsistent_route(self):
        logs = fixture()
        logs["proxy"][1] = logs["proxy"][1].replace("source=server-a", "source=server-b")
        self.check(logs, False)

    def test_wrong_direction(self):
        logs = fixture()
        logs["server-a"][0] = logs["server-a"][0].replace("x=-0.25", "x=0.25")
        self.check(logs, False)

    def test_missing_duplicate_lifecycle_or_applied(self):
        for name, index in (("server-a", 0), ("server-b", 2), ("proxy", 1), ("proxy", 5)):
            for duplicate in (False, True):
                with self.subTest(name=name, index=index, duplicate=duplicate):
                    logs = fixture()
                    if duplicate:
                        logs[name].insert(index, logs[name][index])
                    else:
                        del logs[name][index]
                    self.check(logs, False)

    def test_snapshot_mismatch(self):
        logs = fixture()
        logs["server-b"][1] = logs["server-b"][1].replace(HASH, "b" * 64)
        self.check(logs, False)

    def test_authority_overlap(self):
        logs = fixture()
        logs["server-b"][1] = logs["server-b"][1].replace("1001", "999")
        self.check(logs, False)

    def test_transition_packet(self):
        logs = fixture()
        logs["proxy"][-1] = logs["proxy"][-1].replace("packets=0", "packets=1")
        self.check(logs, False)

    def test_source_applies_destination_replay(self):
        logs = fixture()
        logs["server-a"].append(logs["server-b"][2])
        self.check(logs, False)

    def test_applied_before_activation(self):
        logs = fixture()
        logs["server-b"][1:3] = reversed(logs["server-b"][1:3])
        self.check(logs, False)

    def test_unrelated_transfers_cannot_supply_evidence(self):
        logs = fixture()
        logs["proxy"][2] = logs["proxy"][2].replace(TRANSFER, PLAYER)
        self.check(logs, False)


if __name__ == "__main__":
    unittest.main()
