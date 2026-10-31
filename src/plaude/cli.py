"""Click CLI — sync, list, scan, transcribe, config."""

import asyncio
import datetime
import sys
from pathlib import Path

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
        client = PlaudClient(address, token, verbose=verbose,
                             creds_path=cfg["device"].get("creds_path", "~/plaud-credentials.md"))
        try:
            await client.connect()
            await client.handshake()
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
@click.argument("session", required=False)
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation")
@click.pass_context
def delete(ctx, session, yes):
    """Delete recording(s) on the device.

    SESSION is an index (from `plaude list`) or 'all' to delete everything.
    Deletion uses the SDK's cmd 0x1A delete-shaped payload: [now][session][0].
    """
    cfg = load_config()
    address = cfg["device"]["address"]
    token = cfg["device"]["token"]
    if not address or not token:
        click.echo("Error: Device address and token must be configured. Run: plaude config init", err=True)
        sys.exit(1)
    verbose = ctx.obj["verbose"]

    async def _delete():
        from .ble.client import PlaudClient
        client = PlaudClient(address, token, verbose=verbose,
                             creds_path=cfg["device"].get("creds_path", "~/plaud-credentials.md"))
        try:
            await client.connect()
            await client.handshake()
            await client.time_sync()
            sessions = await client.get_sessions()
            if not sessions:
                click.echo("No recordings on device.")
                return
            click.echo(f"{len(sessions)} recording(s):")
            for i, s in enumerate(sessions):
                ts = datetime.datetime.fromtimestamp(s["session_id"])
                click.echo(f"  [{i}] {ts.strftime('%Y-%m-%d %H:%M:%S')}  "
                           f"{s['file_size'] / 1024:.1f} KB  session_id={s['session_id']}")

            targets = []
            if session is None:
                click.echo("Pass an index (from the list) or 'all' to delete.")
                return
            if session == "all":
                targets = [s["session_id"] for s in sessions]
            else:
                try:
                    idx = int(session)
                    targets = [sessions[idx]["session_id"]]
                except (ValueError, IndexError):
                    click.echo(f"Invalid session: {session} (use an index or 'all')", err=True)
                    sys.exit(1)

            if not yes:
                click.confirm(f"Delete {len(targets)} recording(s)? This cannot be undone.", abort=True)

            for sid in targets:
                await client.delete_session(sid)
                remaining = await client.get_sessions()
                if any(s["session_id"] == sid for s in remaining):
                    click.echo(
                        f"  Session {sid} is still on the device. This firmware has no "
                        f"BLE delete command — recordings are removed by the device "
                        f"itself once a transfer completes.")
                else:
                    click.echo(f"  Deleted {sid}; {len(remaining)} recording(s) remain.")
        finally:
            await client.disconnect()

    try:
        asyncio.run(_delete())
    except KeyboardInterrupt:
        click.echo("\nInterrupted.")
        sys.exit(130)
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)

@main.command("bind")
@click.option("--historical-user-id", default=None,
              help="Historical user id the device is locked to (recovery rebind). "
                   "Defaults to the configured device token.")
@click.option("--save", "save_creds", is_flag=True,
              help="Write the new credentials to the configured creds path.")
@click.pass_context
def bind(ctx, historical_user_id, save_creds):
    """Re-key the device to a fresh RSA keypair (self-bind).

    Runs the PLAUD offline-rebind recipe: recovery connect with the
    historical user id pinned + force-clear, depair, then reconnect so the
    device stores a newly generated RSA public key. Future recordings will
    be encrypted to it and become decryptable.
    """
    cfg = load_config()
    address = cfg["device"]["address"]
    token = cfg["device"]["token"]
    creds_path = cfg["device"].get("creds_path", "~/plaud-credentials.md")
    verbose = ctx.obj["verbose"]

    async def _bind():
        from .ble.bind import recovery_rebind, write_creds_file
        result = await recovery_rebind(
            address, token, creds_path,
            historical_user_id=historical_user_id,
            verbose=verbose,
        )
        click.echo("Device re-bound successfully.")
        if save_creds:
            write_creds_file(result["creds"], creds_path)
            click.echo(f"New credentials written to {creds_path}")
        else:
            click.echo("New credentials (save with --save):")
            click.echo(f"  creds_path: {result['creds_path']}")
        return result

    try:
        asyncio.run(_bind())
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

@main.command("export")
@click.option("--out", "-o", type=click.Path(),
              help="Output directory (default: <base>/markdown, or output.markdown_dir)")
@click.option("--force", "-f", is_flag=True,
              help="Overwrite existing .md files")
@click.pass_context
def export_markdown(ctx, out, force):
    """Export existing transcript JSON to Markdown (Obsidian-friendly)."""
    import json
    from .config import get_output_dirs
    from .markdown import write_markdown

    cfg = load_config()
    dirs = get_output_dirs(cfg)
    src = dirs["transcripts"]
    dest = Path(out).expanduser() if out else dirs["markdown"]
    dest.mkdir(parents=True, exist_ok=True)

    written = skipped = failed = 0
    for jf in sorted(src.glob("*.json")):
        md = dest / f"{jf.stem}.md"
        if md.exists() and not force:
            skipped += 1
            continue
        try:
            result = json.loads(jf.read_text())
        except Exception as e:
            click.echo(f"  skip {jf.name}: unreadable ({e})", err=True)
            failed += 1
            continue
        if not (result.get("text") or "").strip():
            skipped += 1
            continue
        audio = dirs["audio"] / f"{jf.stem}.wav"
        raw = dirs["raw"] / f"{jf.stem}.opus"
        write_markdown(
            result, jf.stem, dest,
            audio_name=audio.name if audio.exists() else None,
            raw_name=raw.name if raw.exists() else None,
        )
        written += 1
        click.echo(f"  {jf.stem}.md")

    click.echo(f"\n{dest}")
    click.echo(f"{written} written, {skipped} skipped (existing or empty), {failed} failed")

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
