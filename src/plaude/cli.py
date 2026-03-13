"""Click CLI — sync, list, scan, transcribe, config."""

import asyncio
import datetime
import sys

import click

from .config import load_config, save_config, init_config, config_path, set_nested


@click.group()
@click.option("--verbose", "-v", is_flag=True, help="Verbose BLE output")
@click.option("--quiet", "-q", is_flag=True, help="Minimal output")
@click.pass_context
def main(ctx, verbose, quiet):
    """OpenPlaudit — local-first CLI for PLAUD Note AI recorder."""
    ctx.ensure_object(dict)
    ctx.obj["verbose"] = verbose
    ctx.obj["quiet"] = quiet


@main.command()
@click.pass_context
def sync(ctx):
    """Connect, download new recordings, transcribe, and notify."""
    cfg = load_config()
    from .sync import run_sync
    try:
        asyncio.run(run_sync(cfg, verbose=ctx.obj["verbose"], quiet=ctx.obj["quiet"]))
    except (ValueError, ConnectionError) as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)
    except KeyboardInterrupt:
        click.echo("\nInterrupted.")
        sys.exit(130)


@main.command("list")
@click.pass_context
def list_recordings(ctx):
    """Connect and list recordings on device (no download)."""
    cfg = load_config()
    address = cfg["device"]["address"]
    token = cfg["device"]["token"]
    if not address or not token:
        click.echo("Error: Device address and token must be configured. Run: plaude config init", err=True)
        sys.exit(1)
    verbose = ctx.obj["verbose"]

    async def _list():
        from .ble.client import PlaudClient
        client = PlaudClient(address, token, verbose=verbose)
        try:
            await client.connect()
            if not await client.handshake():
                click.echo("Handshake failed.", err=True)
                return
            await client.time_sync()
            sessions = await client.get_sessions()
            if not sessions:
                click.echo("No recordings on device.")
                return
            click.echo(f"{len(sessions)} recording(s):")
            for i, s in enumerate(sessions):
                ts = datetime.datetime.fromtimestamp(s["session_id"])
                click.echo(f"  [{i}] {ts.strftime('%Y-%m-%d %H:%M:%S')}  "
                           f"{s['file_size'] / 1024:.1f} KB  scene={s['scene']}")
        finally:
            await client.disconnect()

    try:
        asyncio.run(_list())
    except KeyboardInterrupt:
        click.echo("\nInterrupted.")
        sys.exit(130)
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@main.command()
@click.option("--timeout", "-t", default=15.0, help="Scan timeout in seconds")
def scan(timeout):
    """Scan for PLAUD BLE devices."""
    async def _scan():
        from .ble.client import PlaudClient
        click.echo(f"Scanning for PLAUD devices ({timeout}s)...")
        devices = await PlaudClient.scan(timeout=timeout)
        if not devices:
            click.echo("No PLAUD devices found. Ensure device is powered on and not connected to another app.")
            return
        click.echo(f"Found {len(devices)} device(s):")
        for d in devices:
            click.echo(f"  {d['name']}  {d['address']}  RSSI={d['rssi']} dBm")

    try:
        asyncio.run(_scan())
    except KeyboardInterrupt:
        click.echo("\nInterrupted.")
        sys.exit(130)
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@main.command()
@click.argument("file", type=click.Path(exists=True))
@click.option("--output", "-o", type=click.Path(), help="Output directory for transcript")
@click.pass_context
def transcribe(ctx, file, output):
    """Transcribe a local audio file."""
    cfg = load_config()
    from .sync import transcribe_local
    try:
        transcribe_local(file, cfg, output_dir=output, quiet=ctx.obj["quiet"])
    except KeyboardInterrupt:
        click.echo("\nInterrupted.")
        sys.exit(130)
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@main.group()
def config():
    """Manage configuration."""
    pass


@config.command("show")
def config_show():
    """Print current configuration."""
    cfg = load_config()
    path = config_path()
    click.echo(f"Config: {path} {'(exists)' if path.exists() else '(defaults)'}")
    click.echo()

    import tomli_w
    click.echo(tomli_w.dumps(cfg))


@config.command("init")
def config_init():
    """Create default config file."""
    path = init_config()
    click.echo(f"Config file: {path}")


@config.command("set")
@click.argument("key")
@click.argument("value")
def config_set(key, value):
    """Set a config value (e.g. device.address <value>)."""
    cfg = load_config()
    try:
        cfg = set_nested(cfg, key, value)
    except ValueError as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)
    path = save_config(cfg)
    click.echo(f"Set {key} = {value}")


if __name__ == "__main__":
    main()
