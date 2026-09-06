#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

UPSTREAM_SHA = "747a9a0c3ebf3ca33c33d4d38b0243b78263f2d1"


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected exactly one match, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch.py <ColorOS-Live-Lyrics-Providers checkout>")

    root = Path(sys.argv[1]).resolve()
    if not (root / "player-apple").is_dir():
        raise RuntimeError(f"not a provider checkout: {root}")

    # Reuse the exact Lyricon 0.1.70 model version already pinned by ColorOS 4.1.
    catalog = root / "gradle/libs.versions.toml"
    replace_once(
        catalog,
        'lyricon-lyric-model = { module = "io.github.proify.lyricon.lyric:model", version.ref = "lyriconModel" }\n',
        'lyricon-lyric-model = { module = "io.github.proify.lyricon.lyric:model", version.ref = "lyriconModel" }\n'
        'lyricon-provider = { module = "io.github.proify.lyricon:provider", version.ref = "lyriconModel" }\n',
    )

    apple_gradle = root / "player-apple/build.gradle.kts"
    replace_once(
        apple_gradle,
        '    implementation(project(":parser-lrc"))\n\n    implementation(libs.dexkit)\n',
        '    implementation(project(":parser-lrc"))\n\n'
        '    // Unified build: keep ColorOS native output and add Lyricon IPC output.\n'
        '    implementation(libs.lyricon.provider)\n\n'
        '    implementation(libs.dexkit)\n',
    )
    replace_once(
        apple_gradle,
        '        versionCode = 2\n        versionName = "1.1.0"\n',
        '        versionCode = 3\n        versionName = "1.1.0-unified1"\n',
    )

    bridge = root / "player-apple/src/main/kotlin/io/github/andrealtb/coloroslyrics/provider/apple/AppleLyriconPublisher.kt"
    bridge.write_text(r'''/*
 * Unified Apple Music lyric output bridge.
 * ColorOS native publication remains authoritative; this file only mirrors
 * the already-parsed track/lyric/playback state into Lyricon IPC.
 */

package io.github.andrealtb.coloroslyrics.provider.apple

import android.app.Application
import android.media.session.PlaybackState
import io.github.andrealtb.coloroslyrics.provider.core.diagnostics.DiagnosticEvent
import io.github.andrealtb.coloroslyrics.provider.core.diagnostics.StructuredDiagnostics
import io.github.andrealtb.coloroslyrics.provider.core.model.TrackIdentity
import io.github.andrealtb.coloroslyrics.provider.parser.lrc.model.LyricWord as NativeLyricWord
import io.github.andrealtb.coloroslyrics.provider.parser.lrc.model.RichLyricLine as NativeRichLyricLine
import io.github.proify.lyricon.lyric.model.LyricWord as LyriconLyricWord
import io.github.proify.lyricon.lyric.model.RichLyricLine as LyriconRichLyricLine
import io.github.proify.lyricon.lyric.model.Song
import io.github.proify.lyricon.provider.LyriconFactory
import io.github.proify.lyricon.provider.LyriconProvider

object AppleLyriconPublisher {
    private val lock = Any()

    @Volatile
    private var provider: LyriconProvider? = null

    private var lastTrackKey: String? = null
    private var lastPublicationFingerprint: String? = null

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
                    created.player.setDisplayTranslation(true)
                    created.register()
                    provider = created
                }
            }.onSuccess {
                log("LYRICON_PROVIDER_READY", playerPackageName)
            }.onFailure { throwable ->
                log("LYRICON_PROVIDER_INIT_FAILED", throwable.javaClass.simpleName)
            }
        }
    }

    /**
     * Clear the previous song immediately on an authoritative track change.
     * The full lyric payload will follow from [publish] when available.
     */
    fun onTrackChanged(track: TrackIdentity) {
        val key = track.buildStableKey()
        synchronized(lock) {
            if (lastTrackKey == key) return
            lastTrackKey = key
            lastPublicationFingerprint = null
        }
        runCatching {
            provider?.player?.setSong(
                Song(
                    id = track.id,
                    name = track.title,
                    artist = track.artist,
                    duration = track.durationMs.coerceAtLeast(0L),
                    lyrics = null
                )
            )
        }.onFailure { throwable ->
            log("LYRICON_TRACK_UPDATE_FAILED", throwable.javaClass.simpleName)
        }
    }

    /** Mirror one validated ColorOS publication into Lyricon without adding hooks. */
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
        runCatching {
            provider?.player?.setSong(song)
        }.onSuccess {
            log("LYRICON_LYRIC_PUBLISHED", publication.sourceName)
        }.onFailure { throwable ->
            log("LYRICON_LYRIC_PUBLISH_FAILED", throwable.javaClass.simpleName)
        }
    }

    /**
     * Lyricon 0.1.70 can consume Android PlaybackState directly, so the
     * existing MediaSession hook also provides seek/state/realtime progress.
     */
    fun onPlaybackState(state: PlaybackState?) {
        runCatching {
            provider?.player?.setPlaybackState(state)
        }.onFailure { throwable ->
            log("LYRICON_PLAYBACK_STATE_FAILED", throwable.javaClass.simpleName)
        }
    }

    private fun toLyriconLine(line: NativeRichLyricLine): LyriconRichLyricLine =
        LyriconRichLyricLine(
            begin = line.begin,
            end = line.end,
            duration = line.duration,
            isAlignedRight = line.isAlignedRight,
            text = line.text,
            words = line.words?.map(::toLyriconWord),
            // ColorOS AppleSongMapper uses `secondary` specifically for translation.
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

    hooker = root / "player-apple/src/main/kotlin/io/github/andrealtb/coloroslyrics/provider/apple/ApplePlayerHooker.kt"

    replace_once(
        hooker,
        '        val loader = appClassLoader\n        lyricRequester = AppleLyricRequester(loader, application)\n\n        installSessionHooks()\n',
        '        val loader = appClassLoader\n'
        '        lyricRequester = AppleLyricRequester(loader, application)\n'
        '        AppleLyriconPublisher.initialize(application, hostPackage)\n\n'
        '        installSessionHooks()\n',
    )

    replace_once(
        hooker,
        '                        val state = (args.getOrNull(0) as? PlaybackState)?.state\n'
        '                            ?: PlaybackState.STATE_NONE\n'
        '                        sessions.onPlaybackState(session, state)\n'
        '                        drainPendingPublication()\n',
        '                        val playbackState = args.getOrNull(0) as? PlaybackState\n'
        '                        val state = playbackState?.state ?: PlaybackState.STATE_NONE\n'
        '                        sessions.onPlaybackState(session, state)\n'
        '                        AppleLyriconPublisher.onPlaybackState(playbackState)\n'
        '                        drainPendingPublication()\n',
    )

    replace_once(
        hooker,
        '            )\n            publishCachedIfAvailable(track, generation)\n        }\n    }\n\n    private fun publishCachedIfAvailable',
        '            )\n'
        '            AppleLyriconPublisher.onTrackChanged(track)\n'
        '            publishCachedIfAvailable(track, generation)\n'
        '        }\n'
        '    }\n\n'
        '    private fun publishCachedIfAvailable',
    )

    replace_once(
        hooker,
        '        val decision = ApplePendingPublicationPolicy.decide(\n'
        '            publicationTrack = hinted,\n'
        '            currentHostTrack = currentTrack,\n'
        '            liveSessionTrack = liveTrack,\n'
        '            generationValid = currentTrack != null && generationController.acceptsPublication(\n'
        '                currentTrack,\n'
        '                generation\n'
        '            ),\n'
        '            uniqueSessionReady = session != null,\n'
        '            metadataReady = metadata != null,\n'
        '            artworkReady = artworkReady\n'
        '        )\n\n'
        '        when (decision) {\n',
        '        val decision = ApplePendingPublicationPolicy.decide(\n'
        '            publicationTrack = hinted,\n'
        '            currentHostTrack = currentTrack,\n'
        '            liveSessionTrack = liveTrack,\n'
        '            generationValid = currentTrack != null && generationController.acceptsPublication(\n'
        '                currentTrack,\n'
        '                generation\n'
        '            ),\n'
        '            uniqueSessionReady = session != null,\n'
        '            metadataReady = metadata != null,\n'
        '            artworkReady = artworkReady\n'
        '        )\n\n'
        '        // Lyricon does not depend on ColorOS artwork/session readiness. Mirror the same\n'
        '        // validated generation here, while native publication keeps its original policy.\n'
        '        if (decision != ApplePendingPublicationPolicy.Decision.DROP_STALE &&\n'
        '            currentTrack != null &&\n'
        '            generationController.acceptsPublication(currentTrack, generation)\n'
        '        ) {\n'
        '            val lyriconTrack = effectiveTrack ?: currentTrack\n'
        '            if (AppleTrackBindPolicy.unnamedOrSame(currentTrack, lyriconTrack)) {\n'
        '                AppleLyriconPublisher.publish(publication.boundTo(lyriconTrack), lyriconTrack)\n'
        '            }\n'
        '        }\n\n'
        '        when (decision) {\n',
    )

    print("Unified Apple provider patch applied successfully")


if __name__ == "__main__":
    main()
