#!/usr/bin/env python3
"""Bookoo Mini Scale BLE controller for Raspberry Pi."""

import asyncio
import sys
import tty
import termios
import threading
from dataclasses import dataclass, field
from typing import Optional

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice
from rich.console import Console
from rich.live import Live
from rich.table import Table
from rich.panel import Panel
from rich import box

# ── BLE identifiers ──────────────────────────────────────────────────────────
SERVICE_UUID      = "00000ffe-0000-1000-8000-00805f9b34fb"
WEIGHT_CHAR_UUID  = "0000ff11-0000-1000-8000-00805f9b34fb"
COMMAND_CHAR_UUID = "0000ff12-0000-1000-8000-00805f9b34fb"

# ── Pre-built command bytes (checksum verified from protocol doc) ─────────────
CMD_TARE           = bytes([0x03, 0x0A, 0x01, 0x00, 0x00, 0x08])
CMD_START_TIMER    = bytes([0x03, 0x0A, 0x04, 0x00, 0x00, 0x0A])
CMD_STOP_TIMER     = bytes([0x03, 0x0A, 0x05, 0x00, 0x00, 0x0D])
CMD_RESET_TIMER    = bytes([0x03, 0x0A, 0x06, 0x00, 0x00, 0x0C])
CMD_TARE_AND_START = bytes([0x03, 0x0A, 0x07, 0x00, 0x00, 0x00])


# ── Data model ────────────────────────────────────────────────────────────────
@dataclass
class ScaleData:
    weight_g: float = 0.0
    flow_rate: float = 0.0      # g/s
    timer_ms: int = 0
    battery_pct: int = 0
    buzzer_gear: int = 0
    flow_smoothing: bool = False
    connected: bool = False


# ── Protocol parsing ──────────────────────────────────────────────────────────
def xor_checksum(data: bytes, length: int) -> int:
    result = 0
    for b in data[:length]:
        result ^= b
    return result


def parse_weight_packet(data: bytes) -> Optional[ScaleData]:
    """
    20-byte notification from Weight Characteristic (0xFF11):
      [0]  0x03  product number
      [1]  0x0B  type
      [2-4]      timer milliseconds  (24-bit big-endian)
      [5]        weight unit (always grams)
      [6]        weight sign  (0 = positive)
      [7-9]      weight * 100  (24-bit big-endian)
      [10]       flow sign    (0 = positive)
      [11-12]    flow * 100   (16-bit big-endian)
      [13]       battery %
      [14-15]    standby time minutes (16-bit big-endian)
      [16]       buzzer gear
      [17]       flow smoothing (0x01 = on)
      [18]       0x00
      [19]       XOR checksum of bytes 0-18
    """
    if len(data) < 20 or data[0] != 0x03 or data[1] != 0x0B:
        return None

    expected_cs = xor_checksum(data, 19)
    if expected_cs != data[19]:
        # Still parse — some firmware versions may differ
        pass

    timer_ms   = (data[2] << 16) | (data[3] << 8) | data[4]
    weight_raw = (data[7] << 16) | (data[8] << 8) | data[9]
    weight_g   = weight_raw / 100.0 * (-1 if data[6] != 0 else 1)

    flow_raw   = (data[11] << 8) | data[12]
    flow_rate  = flow_raw / 100.0 * (-1 if data[10] != 0 else 1)

    return ScaleData(
        weight_g=weight_g,
        flow_rate=flow_rate,
        timer_ms=timer_ms,
        battery_pct=data[13],
        buzzer_gear=data[16],
        flow_smoothing=(data[17] == 0x01),
        connected=True,
    )


def build_command(data1: int, data2: int, data3: int) -> bytes:
    """Build a 6-byte command with XOR checksum."""
    header = [0x03, 0x0A]
    payload = [data1, data2, data3]
    cs = xor_checksum(bytes(header + payload), 5)
    return bytes(header + payload + [cs])


# ── Display helpers ───────────────────────────────────────────────────────────
def fmt_timer(ms: int) -> str:
    total_s  = ms // 1000
    mins     = total_s // 60
    secs     = total_s % 60
    centis   = (ms % 1000) // 10
    return f"{mins:02d}:{secs:02d}.{centis:02d}"


def fmt_battery(pct: int) -> str:
    color = "green" if pct > 30 else "yellow" if pct > 15 else "red"
    bar_len = pct // 10
    bar = "█" * bar_len + "░" * (10 - bar_len)
    return f"[{color}]{bar} {pct}%[/{color}]"


def build_display(data: ScaleData) -> Panel:
    t = Table(box=box.SIMPLE, show_header=False, padding=(0, 2), expand=True)
    t.add_column("label", style="dim", width=14)
    t.add_column("value", style="bold")

    w_color = "green" if data.weight_g >= 0 else "red"
    t.add_row("Weight",     f"[{w_color}]{data.weight_g:+.2f} g[/{w_color}]")

    f_color = "cyan" if data.flow_rate >= 0 else "magenta"
    t.add_row("Flow rate",  f"[{f_color}]{data.flow_rate:+.2f} g/s[/{f_color}]")
    t.add_row("Timer",      fmt_timer(data.timer_ms))
    t.add_row("Battery",    fmt_battery(data.battery_pct))
    t.add_row("Buzzer",     f"level {data.buzzer_gear}")
    t.add_row("Flow smooth", "on" if data.flow_smoothing else "off")

    help_text = (
        "\n[dim]t[/dim] tare  "
        "[dim]b[/dim] tare+start  "
        "[dim]s[/dim] start  "
        "[dim]p[/dim] pause  "
        "[dim]r[/dim] reset  "
        "[dim]q[/dim] quit"
    )

    status = "[green]● connected[/green]" if data.connected else "[red]● disconnected[/red]"
    return Panel(
        t,
        title=f"[bold]Bookoo Mini Scale[/bold]  {status}",
        subtitle=help_text,
        border_style="green" if data.connected else "red",
    )


# ── Keyboard input (raw, single-char, non-blocking via thread) ────────────────
def _keyboard_thread(queue: asyncio.Queue, loop: asyncio.AbstractEventLoop):
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        while True:
            ch = sys.stdin.read(1)
            asyncio.run_coroutine_threadsafe(queue.put(ch), loop)
            if ch == "q":
                break
    except Exception:
        pass
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


# ── Scanner ───────────────────────────────────────────────────────────────────
async def find_scale(console: Console) -> Optional[str]:
    console.print("[cyan]Scanning for Bookoo Mini Scale (5 s)…[/cyan]")

    # First try matching service UUID directly
    devices = await BleakScanner.discover(timeout=5.0, service_uuids=[SERVICE_UUID])
    if devices:
        d = devices[0]
        console.print(f"[green]Found:[/green] {d.name or 'Unknown'} @ {d.address}")
        return d.address

    # Fallback: name-based scan
    console.print("[yellow]Trying name-based scan…[/yellow]")
    all_devices = await BleakScanner.discover(timeout=5.0)
    for d in all_devices:
        if d.name and "bookoo" in d.name.lower():
            console.print(f"[green]Found:[/green] {d.name} @ {d.address}")
            return d.address

    return None


# ── Main app ──────────────────────────────────────────────────────────────────
async def run(address: Optional[str] = None):
    console = Console()
    current: ScaleData = ScaleData()

    if address is None:
        address = await find_scale(console)
        if address is None:
            console.print(
                "[red]No Bookoo scale found.[/red] "
                "Make sure it is powered on and nearby.\n"
                "You can also supply the address directly with [bold]--address[/bold]."
            )
            return

    key_queue: asyncio.Queue[str] = asyncio.Queue()
    loop = asyncio.get_event_loop()
    kb_thread = threading.Thread(
        target=_keyboard_thread, args=(key_queue, loop), daemon=True
    )
    kb_thread.start()

    def on_notify(_sender, data: bytearray):
        nonlocal current
        parsed = parse_weight_packet(bytes(data))
        if parsed:
            current = parsed

    console.print(f"[cyan]Connecting to {address}…[/cyan]")

    async with BleakClient(address, disconnected_callback=lambda _: None) as client:
        current.connected = True
        console.print("[green]Connected.[/green]")

        await client.start_notify(WEIGHT_CHAR_UUID, on_notify)

        async def send(cmd: bytes):
            try:
                await client.write_gatt_char(COMMAND_CHAR_UUID, cmd, response=False)
            except Exception as e:
                console.print(f"[red]Command error:[/red] {e}")

        with Live(build_display(current), console=console, refresh_per_second=10) as live:
            while True:
                live.update(build_display(current))

                # Drain all pending keystrokes
                try:
                    while True:
                        ch = key_queue.get_nowait()
                        if ch == "q":
                            return
                        elif ch == "t":
                            await send(CMD_TARE)
                        elif ch == "b":
                            await send(CMD_TARE_AND_START)
                        elif ch == "s":
                            await send(CMD_START_TIMER)
                        elif ch == "p":
                            await send(CMD_STOP_TIMER)
                        elif ch == "r":
                            await send(CMD_RESET_TIMER)
                except asyncio.QueueEmpty:
                    pass

                await asyncio.sleep(0.1)

        await client.stop_notify(WEIGHT_CHAR_UUID)


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Bookoo Mini Scale BLE controller")
    parser.add_argument(
        "--address", "-a",
        metavar="ADDR",
        help="BLE MAC address of the scale (skips scanning, e.g. AA:BB:CC:DD:EE:FF)",
    )
    args = parser.parse_args()

    try:
        asyncio.run(run(args.address))
    except KeyboardInterrupt:
        pass
