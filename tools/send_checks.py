"""Checks locations of a slot by name, as a text-only client (for testing: e.g. ChecksFinder tiles holding the Palworld
player's bundles, to fill the mod's mailbox).
    <AP venv python> tools/send_checks.py <ws://host:port> <slot name> <password> "Tile 6" "Tile 14" ...
With no location names it lists the slot's unchecked locations instead.
The server ignores checks from TextOnly clients, so checks are sent from a second connection as the slot's own game,
and the script waits for the server to confirm them.
"""
import asyncio
import json
import sys
import uuid

import websockets


async def connect(ws, slot, password, game, tags):
    json.loads(await ws.recv())                                        # RoomInfo
    await ws.send(json.dumps([{
        "cmd": "Connect", "game": game, "name": slot, "password": password, "uuid": str(uuid.uuid4()),
        "version": {"major": 0, "minor": 6, "build": 8, "class": "Version"}, "items_handling": 0,
        "tags": tags, "slot_data": False}]))
    while True:
        for packet in json.loads(await ws.recv()):
            if packet["cmd"] == "ConnectionRefused":
                sys.exit(f"refused: {packet.get('errors')}")
            if packet["cmd"] == "Connected":
                return packet


async def main(server, slot, password, names):
    async with websockets.connect(server, max_size=None) as ws:
        connected = await connect(ws, slot, password, "", ["TextOnly"])
        game = connected["slot_info"][str(connected["slot"])]["game"]
        await ws.send(json.dumps([{"cmd": "GetDataPackage", "games": [game]}]))
        ids = None
        while ids is None:
            for packet in json.loads(await ws.recv()):
                if packet["cmd"] == "DataPackage":
                    ids = packet["data"]["games"][game]["location_name_to_id"]
        names_by_id = {v: k for k, v in ids.items()}
        missing = set(connected["missing_locations"])
        if not names:
            print(f"{slot} ({game}) unchecked: " + ", ".join(sorted((names_by_id.get(i, str(i)) for i in missing),
                                                                     key=lambda n: (len(n), n))))
            return
        unknown = [n for n in names if n not in ids]
        if unknown:
            sys.exit(f"no such location in {game}: {', '.join(unknown)}")
        send = [ids[n] for n in names if ids[n] in missing]
    if send:
        async with websockets.connect(server, max_size=None) as ws:
            await connect(ws, slot, password, game, [])
            await ws.send(json.dumps([{"cmd": "LocationChecks", "locations": send}]))
            done = set()
            try:
                while not set(send) <= done:
                    for packet in json.loads(await asyncio.wait_for(ws.recv(), 10)):
                        if packet["cmd"] == "InvalidPacket":
                            sys.exit(f"the server rejected the checks: {packet.get('text')}")
                        if packet["cmd"] == "RoomUpdate":
                            done |= set(packet.get("checked_locations", []))
            except asyncio.TimeoutError:
                sys.exit(f"no confirmation from the server; confirmed {len(done & set(send))} of {len(send)}")
    print(f"checked {len(send)} location(s) as {slot}: " + ", ".join(names_by_id[i] for i in send)
          + (f" ({len(names) - len(send)} already checked)" if len(send) < len(names) else ""))


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]))
