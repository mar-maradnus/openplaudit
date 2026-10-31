"""File download over BLE — v20 file-sync protocol (prepare -> head -> stream -> stop)."""

from .client import PlaudClient

class DownloadError(Exception):
    """Raised when a file download fails deterministically."""

async def download_file(
    client: PlaudClient,
    session_id: int,
    file_size: int,
    file_index: int | None = None,
    file_type: int = 0,
    verbose: bool = False,
    start_offset: int = 0,
    progress_path: str | None = None,
) -> bytes:
    """Download a recording from the device.

    The device serves files through the v20 file-sync protocol: cmd 28
    SYNC_FILE_HEAD [sessionId][startPos][fileSize] starts the transfer, data
    arrives as offset-sliced type-0x02 packets (1-byte chunk_len), and cmd 30
    SyncRecFileStop [sessionId] closes the session. There is NO "prepare"
    command — cmd 0x14 is the record command and is never touched here.

    `start_offset` resumes from a previous position.

    `progress_path`: when set, accumulated bytes are written incrementally so
    an interrupted transfer leaves a valid partial to resume from.

    Returns raw Opus bytes.
    """
    if file_index is None:
        entries = await client.get_sessions()
        match = next((e for e in entries if e["session_id"] == session_id), None)
        if match is None:
            raise DownloadError(f"Session {session_id} not found in device file list")
        file_index = match["file_index"]
        file_type = match["file_type"]
        file_size = match["file_size"]
    return await client.download_file(
        session_id,
        file_index,
        file_size,
        file_type=file_type,
        verbose=verbose,
        start_offset=start_offset,
        progress_path=progress_path,
    )
