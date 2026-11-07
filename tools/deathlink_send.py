"""Sends one Death Link to an Archipelago room, as a text-only client of a slot (for testing the mod's Death Link).
    <AP venv python> tools/deathlink_send.py <ws://host:port> <slot name> [password] [cause]
With --listen instead of a cause, it stays connected and prints every Death Link the room sends (the mod's own deaths).
"""
import asyncio
import json
import sys
import time
import uuid

import websockets


async def main(server, slot, password, cause):
    async with websockets.connect(server, max_size=None) as ws:
        json.loads(await ws.recv())                                    # RoomInfo
        await ws.send(json.dumps([{
            "cmd": "Connect", "game": "", "name": slot, "password": password, "uuid": str(uuid.uuid4()),
            "version": {"major": 0, "minor": 6, "build": 8, "class": "Version"}, "items_handling": 0,
            "tags": ["TextOnly", "DeathLink"], "slot_data": False}]))
        while True:
            for packet in json.loads(await ws.recv()):
                if packet["cmd"] == "ConnectionRefused":
                    sys.exit(f"refused: {packet.get('errors')}")
                if packet["cmd"] == "Connected" and cause == "--listen":
                    print(f"listening for Death Links as {slot} (Ctrl+C to stop)", flush=True)
                elif packet["cmd"] == "Bounced" and "DeathLink" in packet.get("tags", []):
                    d = packet.get("data", {})
                    print(f"{time.strftime('%H:%M:%S')} Death Link from {d.get('source')}: {d.get('cause')}", flush=True)
                elif packet["cmd"] == "Connected":
                    await ws.send(json.dumps([{"cmd": "Bounce", "tags": ["DeathLink"],
                                               "data": {"time": time.time(), "source": slot, "cause": cause}}]))
                    await asyncio.sleep(1)
                    print(f"sent a Death Link from {slot}: {cause}")
                    return


if __name__ == "__main__":
    args = sys.argv[1:] + [""] * 4
    asyncio.run(main(args[0], args[1], args[2], args[3] or f"{args[1]} was struck down by a test."))
