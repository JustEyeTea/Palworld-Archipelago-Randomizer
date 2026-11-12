"""Checks locations of a slot by name, as a text-only client (for testing: e.g. ChecksFinder tiles holding the Palworld
player's bundles, to fill the mod's mailbox).
    <AP venv python> tools/send_checks.py <ws://host:port> <slot name> <password> "Tile 6" "Tile 14" ...
With no location names it lists the slot's unchecked locations instead.
The server ignores checks from TextOnly clients, so checks are sent from a second connection as the slot's own game,
and the script waits for the server to confirm them.
Tests: none; it is itself a test tool, run by hand against a room.
"""
import asyncio
import json
import pathlib
import sys
import uuid

import websockets

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from apworld_loader import minimum_ap_version  # noqa: E402  (beside this file)

CONFIRM_WAIT = 10                     # seconds to wait for each packet while the server confirms the checks


def client_version():
    """The Archipelago version the client says it is, as a Connect packet writes it: the APWorld's minimum."""
    major, minor, build = (int(part) for part in minimum_ap_version().split("."))
    return {"major": major, "minor": minor, "build": build, "class": "Version"}


async def connect(ws, slot, password, game, tags):
    """Connects to the room as a slot ("" for game: a text-only client); returns the Connected packet."""
    json.loads(await ws.recv())                                        # RoomInfo
    await ws.send(json.dumps([{
        "cmd": "Connect", "game": game, "name": slot, "password": password, "uuid": str(uuid.uuid4()),
        "version": client_version(), "items_handling": 0,
        "tags": tags, "slot_data": False}]))
    while True:
        for packet in json.loads(await ws.recv()):
            if packet["cmd"] == "ConnectionRefused":
                sys.exit(f"refused: {packet.get('errors')}")
            if packet["cmd"] == "Connected":
                return packet


async def read_location_ids(ws, game):
    """The game's location name -> id, from the server's data package."""
    await ws.send(json.dumps([{"cmd": "GetDataPackage", "games": [game]}]))
    while True:
        for packet in json.loads(await ws.recv()):
            if packet["cmd"] == "DataPackage":
                return packet["data"]["games"][game]["location_name_to_id"]


def list_unchecked(slot, game, missing, names_by_id):
    """Prints the slot's unchecked locations, shortest names first."""
    print(f"{slot} ({game}) unchecked: " + ", ".join(sorted((names_by_id.get(i, str(i)) for i in missing),
                                                             key=lambda n: (len(n), n))))


async def send_and_confirm(server, slot, password, game, send):
    """Checks the locations as the slot's own game (the server ignores checks from TextOnly clients) and waits for the
    server to confirm each one."""
    async with websockets.connect(server, max_size=None) as ws:
        await connect(ws, slot, password, game, [])
        await ws.send(json.dumps([{"cmd": "LocationChecks", "locations": send}]))
        done = set()
        try:
            while not set(send) <= done:
                done |= confirmed(json.loads(await asyncio.wait_for(ws.recv(), CONFIRM_WAIT)))
        except asyncio.TimeoutError:
            sys.exit(f"no confirmation from the server; confirmed {len(done & set(send))} of {len(send)}")


def confirmed(packets):
    """The locations a batch of packets confirms as checked; a rejection stops the script."""
    done = set()
    for packet in packets:
        if packet["cmd"] == "InvalidPacket":
            sys.exit(f"the server rejected the checks: {packet.get('text')}")
        if packet["cmd"] == "RoomUpdate":
            done |= set(packet.get("checked_locations", []))
    return done


async def main(server, slot, password, names):
    async with websockets.connect(server, max_size=None) as ws:
        connected = await connect(ws, slot, password, "", ["TextOnly"])
        game = connected["slot_info"][str(connected["slot"])]["game"]
        ids = await read_location_ids(ws, game)
    names_by_id = {v: k for k, v in ids.items()}
    missing = set(connected["missing_locations"])
    if not names:
        list_unchecked(slot, game, missing, names_by_id)
        return
    unknown = [n for n in names if n not in ids]
    if unknown:
        sys.exit(f"no such location in {game}: {', '.join(unknown)}")
    send = [ids[n] for n in names if ids[n] in missing]
    if send:
        await send_and_confirm(server, slot, password, game, send)
    print(f"checked {len(send)} location(s) as {slot}: " + ", ".join(names_by_id[i] for i in send)
          + (f" ({len(names) - len(send)} already checked)" if len(send) < len(names) else ""))


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]))
