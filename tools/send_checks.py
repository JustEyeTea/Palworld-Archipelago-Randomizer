"""Checks locations of a slot by name, as a text-only client (for testing: e.g. ChecksFinder tiles holding the Palworld
player's bundles, to fill the mod's mailbox).
    <AP venv python> tools/send_checks.py <ws://host:port> <slot name> <password> "Tile 6" "Tile 14" ...
With no location names it lists the slot's unchecked locations instead.
"""
import asyncio
import json
import sys
import uuid

import websockets


async def main(server, slot, password, names):
    async with websockets.connect(server, max_size=None) as ws:
        json.loads(await ws.recv())                                    # RoomInfo
        await ws.send(json.dumps([{
            "cmd": "Connect", "game": "", "name": slot, "password": password, "uuid": str(uuid.uuid4()),
            "version": {"major": 0, "minor": 6, "build": 8, "class": "Version"}, "items_handling": 0,
            "tags": ["TextOnly"], "slot_data": False}]))
        connected = None
        while connected is None:
            for packet in json.loads(await ws.recv()):
                if packet["cmd"] == "ConnectionRefused":
                    sys.exit(f"refused: {packet.get('errors')}")
                if packet["cmd"] == "Connected":
                    connected = packet
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
        await ws.send(json.dumps([{"cmd": "LocationChecks", "locations": send}]))
        await asyncio.sleep(1)
        print(f"checked {len(send)} location(s) as {slot}: " + ", ".join(names_by_id[i] for i in send)
              + (f" ({len(names) - len(send)} already checked)" if len(send) < len(names) else ""))


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]))
