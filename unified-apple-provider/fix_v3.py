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
        raise SystemExit("usage: fix_v3.py <patched upstream checkout>")

    root = Path(sys.argv[1]).resolve()

    gradle = root / "player-apple/build.gradle.kts"
    replace_once(
        gradle,
        '        versionCode = 4\n        versionName = "1.1.0-unified2"\n',
        '        versionCode = 5\n        versionName = "1.1.0-unified3"\n',
    )

    bridge = root / "player-apple/src/main/kotlin/io/github/andrealtb/coloroslyrics/provider/apple/AppleLyriconPublisher.kt"
    bridge.write_text(r'''/*
 * Unified Apple Music lyric output bridge.
 *
 * v3 deliberately uses Lyricon's manual playback channel (boolean state +
 * shared-memory position updates), matching the official Apple Music provider.
 * ColorOS native publication remains untouched.
 */
package io.github.andrealtb.coloroslyrics.provider.apple

import android.app.Application
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
    private val lock = Any()
    private val handler = Handler(Looper.getMainLooper())

    @Volatile
    private var provider: LyriconProvider? = null

    @Volatile
    private var latestPlaybackState: PlaybackState? = null

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

            val position = computePosition(state)
            provider?.player?.setPosition(position)
            handler.postDelayed(this, 250L)
        }
    }

    fun initialize(application: Application, playerPackageName: String) {
        if (provider != null) return
        synchronized(lock) {
            if (provider != null) return

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
                            replayPlaybackState()
                        }

                        override fun onReconnected(provider: LyriconProvider) {
                            log("LYRICON_RECONNECTED", provider.providerInfo.toString())
                            replayPlaybackState()
                        }

                        override fun onDisconnected(provider: LyriconProvider) {
                            log("LYRICON_DISCONNECTED", provider.providerInfo.toString())
                        }

                        override fun onConnectTimeout(provider: LyriconProvider) {
                            log("LYRICON_CONNECT_TIMEOUT", provider.providerInfo.toString())
                        }
                    })

                    created.player.setDisplayTranslation(true)
                    val registrationStarted = created.register()
                    provider = created
                    log(
                        "LYRICON_PROVIDER_READY",
                        "player=$playerPackageName registrationStarted=$registrationStarted"
                    )
                }
            }.onFailure { throwable ->
                log("LYRICON_PROVIDER_INIT_FAILED", throwable.stackTraceToString())
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
        val sent = provider?.player?.setSong(song) ?: false
        log("LYRICON_TRACK_UPDATED", "sent=$sent key=$key")
    }

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

        val song = Song(
            id = track.id,
            name = track.title,
            artist = track.artist,
            duration = track.durationMs.coerceAtLeast(0L),
            lyrics = publication.lines.map(::toLyriconLine)
        )
        val sent = provider?.player?.setSong(song) ?: false
        log(
            "LYRICON_LYRIC_PUBLISHED",
            "sent=$sent source=${publication.sourceName} lines=${publication.lines.size}"
        )
    }

    /**
     * Match the official Lyricon Apple provider: explicit playing boolean plus
     * continuously refreshed manual position. This avoids relying on the
     * PlaybackState2 path for StatusBarLyric visibility.
     */
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

    private fun replayPlaybackState() {
        val state = latestPlaybackState ?: return
        val playing = state.state == PlaybackState.STATE_PLAYING
        val player = provider?.player ?: return
        val stateSent = player.setPlaybackState(playing)
        player.setPosition(computePosition(state))
        if (playing) startTicker() else stopTicker()
        log("LYRICON_PLAYBACK_REPLAYED", "sent=$stateSent playing=$playing")
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

    private fun log(event: String, reason: String?) {
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

    print("Unified Apple provider v3 compatibility fix applied successfully")


if __name__ == "__main__":
    main()
