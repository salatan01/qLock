import QtQuick
import QtTest
import "../components"

// Regression tests for the background-audio math and playback health.
//
// The sink applies a CUBIC gain (slider^3), so the stream must divide by
// sink^3.  Crucially, the PINNED (real lock) path must produce the SAME
// output as the unpinned (preview) path at the same `volume`: the old
// anchor-relative formula made the lock ~18 dB quieter than preview at a
// 50% sink, which is exactly why `volume: 5` sounded muted in the lock.
TestCase {
    name: "VideoVolume"
    when: windowShown

    VideoBackground {
        id: bg
        source: ""
        volume: 5
        sinkVolume: 0.46
        pinActive: false
    }

    function init() {
        bg.volume = 5
        bg.sinkVolume = 0.46
        bg.sinkMuted = false
        bg.pinActive = false
        bg.pinMuted = false
        bg.silenced = false
        bg._lastErrorSrc = ""
        bg._resetPlaybackHealth()
    }

    function outputAt(sinkGain) {
        return bg.effectiveVolume * Math.pow(sinkGain, 3)
    }

    function test_targetVolume() {
        compare(bg.targetVolume, 0.05)
    }

    function test_unpinned_compensates_cubic_sink() {
        compare(bg.effectiveVolume, 0.05 / Math.pow(0.46, 3))
        compare(outputAt(0.46), 0.05, "unpinned output must equal the configured fraction")
    }

    function test_pinned_matches_preview_at_anchor() {
        const preview = bg.effectiveVolume
        bg.pinActive = true
        compare(bg.effectiveVolume, preview,
            "the lock must not be quieter than the preview at the same volume/sink")
        compare(outputAt(0.46), 0.05)
    }

    function test_pinned_user_case_volume_five_at_half_sink() {
        bg.volume = 5
        bg.sinkVolume = 0.5
        bg.pinActive = true
        compare(bg.effectiveVolume, 0.05 / Math.pow(0.5, 3),
            "volume 5 with a 50% sink must carry real stream gain, not 0.05")
        compare(outputAt(0.5), 0.05)
    }

    function test_pinned_matches_preview_at_every_sink() {
        bg.volume = 10
        const sinks = [0.2, 0.46, 0.5, 0.8, 1.0, 1.5]
        for (let i = 0; i < sinks.length; i++) {
            bg.sinkVolume = sinks[i]
            bg.pinActive = false
            const preview = bg.effectiveVolume
            bg.pinActive = true
            compare(bg.effectiveVolume, preview,
                "pinned and preview must agree at sink " + sinks[i])
        }
    }

    function test_pinned_transient_sink_drop_compensates() {
        bg.volume = 50
        bg.pinActive = true
        bg.sinkVolume = 0.9
        // A button drop to 0.8 while pinned: target 0.5 is still reachable
        // (0.5 / 0.8^3 = 0.977 < 1.0), so the stream compensates exactly.
        bg.sinkVolume = 0.8
        compare(outputAt(0.8), 0.5,
            "a transient sink drop must not change the configured loudness")
    }

    function test_pinned_very_quiet_sink_saturates_stream() {
        bg.volume = 5
        bg.pinActive = true
        bg.sinkVolume = 0.2
        compare(bg.effectiveVolume, 1.0,
            "the stream cannot exceed Qt's 1.0 volume cap")
        compare(outputAt(0.2), 0.008,
            "0.008 is the physical maximum at a 20% sink; the enforcer snaps back")
    }

    function test_pinned_stays_silent_when_muted_at_lock() {
        bg.pinActive = true
        bg.pinMuted = true
        compare(bg.effectiveVolume, 0)
    }

    function test_pinned_overdrive_anchor_preserves_fraction() {
        bg.pinActive = true
        bg.sinkVolume = 1.5
        compare(bg.effectiveVolume, 0.05 / Math.pow(1.5, 3))
        compare(outputAt(1.5), 0.05,
            "a >1.0 sink anchor must not silently reduce the configured fraction")
    }

    function test_stream_clamp_never_overdrives() {
        bg.volume = 100
        bg.sinkVolume = 0.2
        bg.pinActive = true
        compare(bg.effectiveVolume, 1.0, "stream gain is capped at 1.0")
        verify(outputAt(0.2) <= 1.0)
    }

    // ── Playback health ──────────────────────────────────────────────────
    function test_health_tracks_advancing_position() {
        bg._resetPlaybackHealth()
        compare(bg._evaluatePlaybackHealth(true, false, 100), "ok")
        compare(bg._evaluatePlaybackHealth(true, false, 200), "ok")
        compare(bg._stallTicks, 0)
        compare(bg._stallRetries, 0)
    }

    function test_health_detects_frozen_playing_position() {
        bg._resetPlaybackHealth()
        bg._lastHealthPosition = 1000
        for (let i = 0; i < bg.stallTickLimit - 1; i++)
            compare(bg._evaluatePlaybackHealth(true, false, 1000), "wait")
        compare(bg._evaluatePlaybackHealth(true, false, 1000), "reload",
            "a Playing player whose position never advances is frozen")
        compare(bg._stallRetries, 1)
    }

    function freezeOnce() {
        let result = "wait"
        for (let i = 0; i < bg.stallTickLimit; i++)
            result = bg._evaluatePlaybackHealth(true, false, 0)
        return result
    }

    function test_health_reloads_are_bounded() {
        bg._resetPlaybackHealth()
        bg._lastHealthPosition = 0
        compare(freezeOnce(), "reload")
        compare(freezeOnce(), "reload")
        compare(freezeOnce(), "reload")
        compare(freezeOnce(), "giveup",
            "a permanently dead pipeline must not reload forever")
    }

    function test_health_ignores_end_of_media() {
        bg._resetPlaybackHealth()
        compare(bg._evaluatePlaybackHealth(false, true, 0), "ok")
        compare(bg._evaluatePlaybackHealth(false, true, 0), "ok")
        compare(bg._playbackRetries, 0)
    }

    function test_health_waits_while_source_is_loading() {
        bg._resetPlaybackHealth()
        for (let i = 0; i < bg.maxPlayRetries + 2; i++)
            compare(bg._evaluatePlaybackHealth(false, false, 0, true), "wait")
        compare(bg._playbackRetries, 0,
            "loading must not consume the playback retry budget")
    }

    function test_health_stopped_player_retries_bounded() {
        bg._resetPlaybackHealth()
        for (let i = 0; i < bg.maxPlayRetries; i++)
            compare(bg._evaluatePlaybackHealth(false, false, 0), "retry")
        compare(bg._evaluatePlaybackHealth(false, false, 0), "giveup")
    }

    function test_resume_count_resets_health() {
        bg._healthGivenUp = true
        bg._stallRetries = 2
        bg.resumeCount += 1
        wait(20)
        compare(bg._healthGivenUp, false, "resume re-arms health recovery")
        compare(bg._stallRetries, 0)
    }

    function test_failed_signal_carries_source_url() {
        let seen = null
        const handler = function(reason, sourceUrl) {
            seen = { reason: reason, url: sourceUrl }
        }
        bg.failed.connect(handler)
        bg._handlePlayerError("boom", "file:///a.mp4")
        compare(seen.reason, "boom")
        compare(seen.url, "file:///a.mp4")
        seen = null
        bg._handlePlayerError("duplicate", "file:///a.mp4")
        compare(seen, null, "repeated errors for one URL are deduplicated")
        bg.failed.disconnect(handler)
    }
}
