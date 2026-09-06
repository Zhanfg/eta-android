#!/usr/bin/env python3
from pathlib import Path
import sys


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: fix_v4_probe.py <patched upstream checkout>")
    root = Path(sys.argv[1]).resolve()
    path = root / "player-apple/src/main/kotlin/io/github/andrealtb/coloroslyrics/provider/apple/AppleLyriconPublisher.kt"
    text = path.read_text(encoding="utf-8")
    old = '''        log(
            "LYRICON_REPLAY_ALL",
            "reason=$reason songSent=$songSent stateSent=$stateSent playing=$playing lines=${latestSong?.lyrics?.size ?: 0}"
        )
'''
    new = '''        val replayLines = latestSong?.lyrics?.size ?: 0
        log(
            "LYRICON_REPLAY_ALL",
            "reason=$reason songSent=$songSent stateSent=$stateSent playing=$playing lines=$replayLines"
        )
        if (songSent && replayLines > 0) {
            toastOnce("replay-song:${latestSong?.id}", "Lyricon 已重放 $replayLines 行歌词")
        }
'''
    if text.count(old) != 1:
        raise RuntimeError(f"replay probe match count={text.count(old)}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("Unified Apple provider v4 replay probe applied successfully")


if __name__ == "__main__":
    main()
