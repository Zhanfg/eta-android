#!/usr/bin/env python3
from pathlib import Path
import sys


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected exactly one match, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: fix_v4.py <patched upstream checkout>")

    root = Path(sys.argv[1]).resolve()

    gradle = root / "player-apple/build.gradle.kts"
    replace_once(
        gradle,
        '        versionCode = 5\n        versionName = "1.1.0-unified3"\n',
        '        versionCode = 6\n        versionName = "1.1.0-unified4-diag"\n',
    )

    bridge = root / "player-apple/src/main/kotlin/io/github/andrealtb/coloroslyrics/provider/apple/AppleLyriconPublisher.kt"
    bridge.write_text(r'''/*
 * Unified Apple Music -> Lyricon output bridge.
 *
 * v4 diagnostics build:
 * - mirrors only ColorOS-validated publications;
 * - explicitly replays the latest Song and playback state after Binder connect;
 * - emits one-shot Toast probes and a stable logcat tag for field diagnosis.
 */
package io.github.andrealtb.coloroslyrics.provider.apple

import android.app.Application
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.widget.Toast
import io.github.andrealtb.coloroslyrics.provider.core.diagnostics.DiagnosticEvent
import io.github.andrealtb.coloroslyrics.provider.core.diagnostics.StructuredDiagnostics
import io.github.andrealtb.coloroslyrics.provider.core.model.TrackIdentity
import io.github.andrealtb.coloroslyrics.provider.parser.lrc.model.LyricWord as NativeLyricWord
import io.github.andrealtb.coloroslyrics.provider.parser.lrc.model.RichLyricLine as NativeRichLyricLine
import io.github.proify.lyricon.lyric.model.LyricWord as LyriconLyricWord
import io.github.proify.lyricon.lyric.model.RichLyricLine as LyriconRichLyricLine
import io.github.proify.lyricon.lyric.model.Song
import io.github.proify.lyricon.provider.ConnectionListener
import io.github.proify.lyricon.provider.LyriconFactory
import io.github.proify.lyricon.provider.LyriconProvider

object AppleLyriconPublisher {
    private const val TAG = "UnifiedAppleLyricon"

    private val lock = Any()
    private val handler = Handler(Looper.getMainLooper())
    private val shownToastKeys = mutableSetOf<String>()

    @Volatile
    private var application: Application? = null

    @Volatile
    private var provider: LyriconProvider? = null

    @Volatile
    private var latestPlaybackState: PlaybackState? = null

    @Volatile
    private var latestSong: Song? = null

    private var lastTrackKey: String? = null
    private var lastPublicationFingerprint: String? = null
    private var tickerRunning = false

    private val positionTicker = object : Runnable {
        override fun run() {
            val state = latestPlaybackState
            if (state == null || state.state != PlaybackState.STATE_PLAYING) {
                tickerRunning = false
                return
            }
            provider?.player?.setPosition(computePosition(state))
            handler.postDelayed(this, 250L)
        }
    }

    fun initialize(application: Application, playerPackageName: String) {
        if (provider != null) return
        synchronized(lock) {
            if (provider != null) return
            this.application = application

            runCatching {
                LyriconFactory.createProvider(
                    context = application,
                    providerPackageName = BuildConfig.APPLICATION_ID,
                    playerPackageName = playerPackageName
                ).also { created ->
                    created.autoSync = true
                    created.service.addConnectionListener(object : ConnectionListener {
                        override fun onConnected(provider: LyriconProvider) {
                            log("LYRICON_CONNECTED", provider.providerInfo.toString())
                            toastOnce("connected", "Lyricon 已连接")
                            replayAll("connected")
                        }

                        override fun onReconnected(provider: LyriconProvider) {
                            log("LYRICON_RECONNECTED", provider.providerInfo.toString())
                            toastOnce("reconnected", "Lyricon 已重新连接")
                            replayAll("reconnected")
                        }

                        override fun onDisconnected(provider: LyriconProvider) {
                            log("LYRICON_DISCONNECTED", provider.providerInfo.toString())
                        }

                        override fun onConnectTimeout(provider: LyriconProvider) {
                            log("LYRICON_CONNECT_TIMEOUT", provider.providerInfo.toString())
                            toastOnce("timeout", "Lyricon 连接超时")
                        }
                    })

                    created.player.setDisplayTranslation(true)
                    val registrationStarted = created.register()
                    provider = created
                    log(
                        "LYRICON_PROVIDER_READY",
                        "player=$playerPackageName registrationStarted=$registrationStarted package=${BuildConfig.APPLICATION_ID}"
                    )
                }
            }.onFailure { throwable ->
                log("LYRICON_PROVIDER_INIT_FAILED", throwable.stackTraceToString())
                toastOnce("init-failed", "Lyricon 初始化失败")
            }
        }
    }

    fun onTrackChanged(track: TrackIdentity) {
        val key = track.buildStableKey()
        synchronized(lock) {
            if (lastTrackKey == key) return
            lastTrackKey = key
            lastPublicationFingerprint = null
        }

        val song = Song(
            id = track.id,
            name = track.title,
            artist = track.artist,
            duration = track.durationMs.coerceAtLeast(0L),
            lyrics = null
        )
        latestSong = song
        val sent = provider?.player?.setSong(song) ?: false
        log("LYRICON_TRACK_UPDATED", "sent=$sent key=$key")
    }

    /** Called only from ColorOS' validated PUBLISH branch. */
    fun publish(publication: ApplePublication, track: TrackIdentity) {
        val fingerprint = buildString {
            append(track.buildStableKey())
            append('|')
            append(publication.sourceName)
            append('|')
            append(publication.lines.hashCode())
        }

        synchronized(lock) {
            if (lastPublicationFingerprint == fingerprint) return
            lastTrackKey = track.buildStableKey()
            lastPublicationFingerprint = fingerprint
        }

        val lyricLines = publication.lines.map(::toLyriconLine)
        val song = Song(
            id = track.id,
            name = track.title,
            artist = track.artist,
            duration = track.durationMs.coerceAtLeast(0L),
            lyrics = lyricLines
        )
        latestSong = song

        val player = provider?.player
        val sent = player?.setSong(song) ?: false
        latestPlaybackState?.let { state ->
            val playing = state.state == PlaybackState.STATE_PLAYING
            player?.setPlaybackState(playing)
            player?.setPosition(computePosition(state))
        }

        log(
            "LYRICON_LYRIC_PUBLISHED",
            "sent=$sent source=${publication.sourceName} lines=${lyricLines.size} track=${track.buildStableKey()}"
        )
        if (sent) {
            toastOnce("song:${track.buildStableKey()}", "Lyricon 已发送 ${lyricLines.size} 行歌词")
        }
    }

    fun onPlaybackState(state: PlaybackState?) {
        latestPlaybackState = state

        val playing = state?.state == PlaybackState.STATE_PLAYING
        val player = provider?.player
        val stateSent = player?.setPlaybackState(playing) ?: false
        if (state != null) {
            player?.setPosition(computePosition(state))
        }

        if (playing) startTicker() else stopTicker()
        log(
            "LYRICON_PLAYBACK_UPDATED",
            "sent=$stateSent state=${state?.state ?: PlaybackState.STATE_NONE} playing=$playing"
        )
    }

    private fun replayAll(reason: String) {
        val player = provider?.player ?: return
        player.setDisplayTranslation(true)

        val songSent = latestSong?.let { player.setSong(it) } ?: false
        val state = latestPlaybackState
        val playing = state?.state == PlaybackState.STATE_PLAYING
        val stateSent = player.setPlaybackState(playing)
        if (state != null) {
            player.setPosition(computePosition(state))
        }
        if (playing) startTicker() else stopTicker()

        log(
            "LYRICON_REPLAY_ALL",
            "reason=$reason songSent=$songSent stateSent=$stateSent playing=$playing lines=${latestSong?.lyrics?.size ?: 0}"
        )
    }

    private fun startTicker() {
        if (tickerRunning) return
        tickerRunning = true
        handler.removeCallbacks(positionTicker)
        handler.post(positionTicker)
    }

    private fun stopTicker() {
        tickerRunning = false
        handler.removeCallbacks(positionTicker)
    }

    private fun computePosition(state: PlaybackState): Long {
        val base = state.position.coerceAtLeast(0L)
        if (state.state != PlaybackState.STATE_PLAYING) return base
        val updatedAt = state.lastPositionUpdateTime
        if (updatedAt <= 0L) return base
        val elapsed = (SystemClock.elapsedRealtime() - updatedAt).coerceAtLeast(0L)
        return (base + elapsed * state.playbackSpeed).toLong().coerceAtLeast(0L)
    }

    private fun toLyriconLine(line: NativeRichLyricLine): LyriconRichLyricLine =
        LyriconRichLyricLine(
            begin = line.begin,
            end = line.end,
            duration = line.duration,
            isAlignedRight = line.isAlignedRight,
            text = line.text,
            words = line.words?.map(::toLyriconWord),
            translation = line.secondary,
            translationWords = line.secondaryWords?.map(::toLyriconWord)
        )

    private fun toLyriconWord(word: NativeLyricWord): LyriconLyricWord =
        LyriconLyricWord(
            begin = word.begin,
            end = word.end,
            duration = word.duration,
            text = word.text
        )

    private fun toastOnce(key: String, text: String) {
        synchronized(shownToastKeys) {
            if (!shownToastKeys.add(key)) return
        }
        val app = application ?: return
        handler.post {
            runCatching {
                Toast.makeText(app, text, Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun log(event: String, reason: String?) {
        Log.i(TAG, "$event ${reason.orEmpty()}")
        StructuredDiagnostics.logDebug(
            DiagnosticEvent(
                component = ApplePlayerConstants.COMPONENT,
                area = "lyricon",
                event = event,
                reason = reason
            )
        )
    }
}
''', encoding="utf-8")

    hooker = root / "player-apple/src/main/kotlin/io/github/andrealtb/coloroslyrics/provider/apple/ApplePlayerHooker.kt"
    text = hooker.read_text(encoding="utf-8")

    # v2/v3 mirrored before ColorOS' own final publication policy. Remove that
    # extra policy so both outputs use one authoritative decision.
    marker = "        // Lyricon does not depend on ColorOS artwork/session readiness. Mirror the same\n"
    start = text.find(marker)
    if start < 0:
        raise RuntimeError("pre-decision Lyricon publication block not found")
    end_marker = "        when (decision) {\n"
    end = text.find(end_marker, start)
    if end < 0:
        raise RuntimeError("when(decision) not found after Lyricon block")
    text = text[:start] + text[end:]

    # Couple Lyricon directly to the exact same validated publication that
    # ColorOS native output is about to publish.
    needle = (
        "                val publishTrack = effectiveTrack ?: return\n"
        "                val bound = publication.boundTo(publishTrack)\n"
        "                val publishResult = AppleNativePublisher.publish(\n"
    )
    replacement = (
        "                val publishTrack = effectiveTrack ?: return\n"
        "                val bound = publication.boundTo(publishTrack)\n"
        "                AppleLyriconPublisher.publish(bound, publishTrack)\n"
        "                val publishResult = AppleNativePublisher.publish(\n"
    )
    count = text.count(needle)
    if count != 1:
        raise RuntimeError(f"native PUBLISH branch match count={count}")
    text = text.replace(needle, replacement, 1)
    hooker.write_text(text, encoding="utf-8")

    print("Unified Apple provider v4 diagnostic fix applied successfully")


if __name__ == "__main__":
    main()
