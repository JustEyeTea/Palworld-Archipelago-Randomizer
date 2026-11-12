"""Sends one Death Link to an Archipelago room, as a text-only client of a slot (for testing the mod's Death Link), or
listens for the room's Death Links (the mod's own deaths).
    <AP venv python> tools/deathlink_send.py <ws://host:port> <slot name> [--password P] [--cause TEXT] [--source NAME]
    <AP venv python> tools/deathlink_send.py <ws://host:port> <slot name> [--password P] --listen
The death is signed with --source (default "deathlink_send"), not the slot's name: the mod ignores a Death Link
whose source is its own slot (death_link.lua's onBounce), and in a one-player room the Palworld slot is the one to
connect as.
Tests: none; it is itself a test tool, run by hand against a room.
"""
import argparse
import asyncio
import json
import pathlib
import sys
import time

import websockets

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from send_checks import connect  # noqa: E402  (beside this file)

DEFAULT_SOURCE = "deathlink_send"     # any name but the mod's own slot, which the mod would ignore
SEND_WAIT = 1                         # seconds to stay connected after sending, so the server passes it on


async def listen(ws, slot):
    """Prints every Death Link the room sends until stopped."""
    print(f"listening for Death Links as {slot} (Ctrl+C to stop)", flush=True)
    while True:
        for packet in json.loads(await ws.recv()):
            if packet["cmd"] == "Bounced" and "DeathLink" in packet.get("tags", []):
                death = packet.get("data", {})
                print(f"{time.strftime('%H:%M:%S')} Death Link from {death.get('source')}: {death.get('cause')}",
                      flush=True)


async def send(ws, source, cause):
    """Sends one Death Link signed by source."""
    await ws.send(json.dumps([{"cmd": "Bounce", "tags": ["DeathLink"],
                               "data": {"time": time.time(), "source": source, "cause": cause}}]))
    await asyncio.sleep(SEND_WAIT)
    print(f"sent a Death Link from {source}: {cause}")


async def main(args):
    async with websockets.connect(args.server, max_size=None) as ws:
        await connect(ws, args.slot, args.password, "", ["TextOnly", "DeathLink"])
        if args.listen:
            await listen(ws, args.slot)
        else:
            await send(ws, args.source, args.cause or f"{args.source} was struck down by a test.")


def read_arguments():
    """The command line; --listen is a flag wherever it is given."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("server", help="the room, ws://host:port")
    parser.add_argument("slot", help="the slot to connect as")
    parser.add_argument("--password", default="")
    parser.add_argument("--cause", default="", help="the death's cause (default: '<source> was struck down...')")
    parser.add_argument("--source", default=DEFAULT_SOURCE, help="who the death is from")
    parser.add_argument("--listen", action="store_true", help="print the room's Death Links instead of sending one")
    return parser.parse_args()


if __name__ == "__main__":
    asyncio.run(main(read_arguments()))
