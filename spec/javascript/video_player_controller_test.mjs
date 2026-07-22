import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import vm from "node:vm"

const source = fs
  .readFileSync(new URL("../../app/javascript/controllers/video_player_controller.js", import.meta.url), "utf8")
  .replace(/^import .*$/m, "class Controller {}")
  .replace("export default class", "globalThis.VideoPlayerController = class")

class TestVTTCue {
  constructor(startTime, endTime, text) {
    this.startTime = startTime
    this.endTime = endTime
    this.text = text
  }
}

const testDocument = {
  fullscreenElement: null,
  webkitFullscreenElement: null,
  exitFullscreen() {}
}

const context = vm.createContext({
  AbortController,
  URL,
  URLSearchParams,
  clearTimeout,
  console,
  document: testDocument,
  navigator: { userAgent: "Mozilla/5.0 Chrome/138.0" },
  setTimeout,
  window: { location: { origin: "https://streamvault.test" }, VTTCue: TestVTTCue }
})
vm.runInContext(source, context)
const VideoPlayerController = context.VideoPlayerController

test("native direct play uses absolute media time while fragment streams add their offset", () => {
  const player = new VideoPlayerController()
  player.videoTarget = { currentTime: 300 }
  player.startSecondsValue = 300
  player.directPlayActive = true
  player.remuxDirectPlay = false

  assert.equal(player.currentPlaybackPosition(), 300)

  player.remuxDirectPlay = true
  assert.equal(player.currentPlaybackPosition(), 600)

  player.directPlayActive = false
  player.remuxDirectPlay = false
  assert.equal(player.currentPlaybackPosition(), 600)
})

test("subtitle clock stays on media time when playback rate changes", () => {
  const player = new VideoPlayerController()
  player.videoTarget = { currentTime: 15, playbackRate: 2 }
  player.startSecondsValue = 120
  player.directPlayActive = false

  assert.equal(player.currentPlaybackPosition(), 135)

  player.videoTarget.playbackRate = 0.5
  assert.equal(player.currentPlaybackPosition(), 135)
})

test("desktop fullscreen uses the player container and exits through the document API", () => {
  testDocument.fullscreenElement = null
  let entered = 0
  let exited = 0
  testDocument.exitFullscreen = () => { exited += 1; testDocument.fullscreenElement = null }

  const player = new VideoPlayerController()
  player.element = {
    requestFullscreen: () => {
      entered += 1
      testDocument.fullscreenElement = player.element
      return Promise.resolve()
    }
  }
  player.videoTarget = { webkitDisplayingFullscreen: false }

  player.toggleFullscreen()
  assert.equal(entered, 1)

  player.toggleFullscreen()
  assert.equal(exited, 1)
})

test("iOS fullscreen uses native controls and keeps text subtitles on the media timeline", () => {
  let entered = 0
  let exited = 0
  const nativeTrack = {
    cues: [],
    mode: "disabled",
    addCue(cue) { this.cues.push(cue) },
    removeCue(cue) { this.cues = this.cues.filter((candidate) => candidate !== cue) }
  }
  const player = new VideoPlayerController()
  player.isIOS = () => true
  player.element = {}
  player.videoTarget = {
    controls: false,
    webkitDisplayingFullscreen: false,
    webkitEnterFullscreen: () => { entered += 1 },
    webkitExitFullscreen: () => { exited += 1 },
    addTextTrack: () => nativeTrack
  }
  player.nativeFullscreenActive = false
  player.nativeFullscreenControls = null
  player.nativeFullscreenTextTrack = null
  player.selectedSubtitleStream = "4"
  player.subtitleTracks = [{ index: 4, label: "English", language: "en", text_supported: true }]
  player.subtitleCues = [{ start: 121, end: 123, text: "Native caption" }]
  player.subtitleOffset = 0
  player.startSecondsValue = 120
  player.directPlayActive = false
  player.remuxDirectPlay = false

  player.toggleFullscreen()

  assert.equal(entered, 1)
  assert.equal(player.nativeFullscreenActive, true)
  assert.equal(player.videoTarget.controls, true)
  assert.equal(nativeTrack.mode, "showing")
  assert.equal(nativeTrack.cues.length, 1)
  assert.equal(nativeTrack.cues[0].startTime, 1)
  assert.equal(nativeTrack.cues[0].endTime, 3)
  assert.equal(nativeTrack.cues[0].text, "Native caption")

  player.toggleFullscreen()
  assert.equal(exited, 1)
  player.onNativeFullscreenEnd()
  assert.equal(player.nativeFullscreenActive, false)
  assert.equal(player.videoTarget.controls, false)
  assert.equal(nativeTrack.mode, "disabled")
  assert.equal(nativeTrack.cues.length, 0)
})

test("fullscreen reports unsupported native APIs instead of throwing", () => {
  const player = new VideoPlayerController()
  player.isIOS = () => true
  player.element = {}
  player.videoTarget = { controls: false, webkitDisplayingFullscreen: false }
  player.nativeFullscreenActive = false
  player.nativeFullscreenControls = null
  player.nativeFullscreenTextTrack = null

  assert.doesNotThrow(() => player.toggleFullscreen())
  assert.equal(player.nativeFullscreenActive, false)
  assert.equal(player.videoTarget.controls, false)
})

test("HLS playing clears buffering without requiring MSE buffer ranges", () => {
  const player = new VideoPlayerController()
  let bufferingHidden = 0
  let watchdogStarted = 0
  player.videoTarget = { paused: false, currentTime: 42, buffered: { length: 0 } }
  player.hlsSessionId = "ios-session"
  player.directPlayActive = false
  player.isSeeking = false
  player.isStalled = true
  player.userPaused = false
  player.subtitlePlaybackHoldToken = null
  player.pendingSeekSeconds = null
  player.hideStartupOverlay = () => {}
  player.hideSeekingOverlay = () => { bufferingHidden += 1; player.isStalled = false }
  player.resetProgressBaseline = () => {}
  player.startProgressWatchdog = () => { watchdogStarted += 1 }

  player.onVideoReady()

  assert.equal(player.playbackStarted, true)
  assert.equal(bufferingHidden, 1)
  assert.equal(watchdogStarted, 1)
  assert.equal(player.isStalled, false)
})

test("native fullscreen subtitle refresh keeps the selected track showing", () => {
  let addedCues = 0
  const modeChanges = []
  const nativeTrack = {
    cues: [new TestVTTCue(1, 2, "Old caption")],
    _mode: "showing",
    get mode() { return this._mode },
    set mode(value) { this._mode = value; modeChanges.push(value) },
    addCue(cue) { addedCues += 1; this.cues.push(cue) },
    removeCue(cue) { this.cues = this.cues.filter((candidate) => candidate !== cue) }
  }
  const player = new VideoPlayerController()
  player.nativeFullscreenActive = true
  player.nativeFullscreenControls = false
  player.nativeFullscreenTextTrack = nativeTrack
  player.nativeFullscreenCueSignature = null
  player.videoTarget = { controls: true, addTextTrack: () => nativeTrack }
  player.selectedSubtitleStream = "4"
  player.subtitleTracks = [{ index: 4, label: "English", language: "en", text_supported: true }]
  player.subtitleCues = [{ start: 121, end: 123, text: "Fresh caption" }]
  player.subtitleOffset = 0
  player.startSecondsValue = 120
  player.directPlayActive = false
  player.remuxDirectPlay = false

  player.syncNativeFullscreenSubtitles()

  assert.equal(nativeTrack.mode, "showing")
  assert.equal(modeChanges.includes("disabled"), false)
  assert.equal(nativeTrack.cues.length, 1)
  assert.equal(nativeTrack.cues[0].text, "Fresh caption")

  player.syncNativeFullscreenSubtitles()
  assert.equal(addedCues, 1)
  assert.equal(nativeTrack.mode, "showing")

  modeChanges.length = 0
  player.finishNativeFullscreen()
  assert.equal(modeChanges.includes("disabled"), true)
})


test("direct-play errors preserve the absolute playhead when falling back", () => {
  const player = new VideoPlayerController()
  player.videoTarget = {
    currentTime: 360,
    currentSrc: "https://streamvault.test/direct",
    error: { code: 3, message: "decode failed" },
    src: "https://streamvault.test/direct"
  }
  player.startSecondsValue = 300
  player.directPlayActive = true
  player.remuxDirectPlay = false
  player.hlsSessionId = null
  player.element = {
    dataset: { videoPlayerStreamingUrlValue: "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mp4&start_seconds=300" }
  }

  let restartPosition
  player.restartPlaybackAt = (position) => { restartPosition = position }
  player.onVideoError({})

  assert.equal(restartPosition, 360)
  assert.equal(player.directPlayActive, false)
})

test("bitmap subtitle selection leaves native direct play for the transcode path", () => {
  const player = new VideoPlayerController()
  player.hlsSessionId = null
  player.directPlayActive = true
  player.remuxDirectPlay = false
  player.videoTarget = { currentTime: 300 }
  player.startSecondsValue = 0
  player.element = { dataset: {} }
  player.streamingUrlValue = "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mp4"
  player.selectedAudioStream = null
  player.selectedSubtitleStream = "4"
  player.subtitleTracks = [{ index: 4, text_supported: false }]
  player.showSeekingOverlay = () => {}
  player.clearSubtitleCues = () => {}
  player.reloadTextSubtitlesAt = () => {}

  let transcodeUrl
  player.setupMseSource = (url) => { transcodeUrl = url }
  player.restartPlaybackAt(420)

  assert.equal(player.directPlayActive, false)
  assert.match(transcodeUrl, /start_seconds=420/)
  assert.match(transcodeUrl, /subtitle_stream=4/)
})

test("clearing cues cancels stale loads and invalidates the remembered window", () => {
  const player = new VideoPlayerController()
  let aborted = false
  player.subtitleLoadToken = 7
  player.subtitleAbortController = { abort: () => { aborted = true } }
  player.subtitleLoading = true
  player.subtitleWindowStart = 100
  player.subtitleWindowEnd = 115
  player.subtitlePendingWindowStart = 115
  player.subtitlePendingWindowEnd = 175
  player.subtitleCues = [{ start: 101, end: 103, text: "Hello" }]
  player.hasSubtitleOverlayTarget = false

  player.clearSubtitleCues()

  assert.equal(aborted, true)
  assert.equal(player.subtitleLoadToken, 8)
  assert.equal(player.subtitleLoading, false)
  assert.equal(player.subtitleWindowStart, null)
  assert.equal(player.subtitleWindowEnd, null)
  assert.equal(player.subtitlePendingWindowStart, null)
  assert.equal(player.subtitlePendingWindowEnd, null)
  assert.equal(player.subtitleCues.length, 0)
})

test("subtitle windows cover a full minute even for short startup requests", () => {
  const player = new VideoPlayerController()

  assert.equal(player.subtitleWindowDuration(5), 60)
  assert.equal(player.subtitleWindowDuration(15), 60)
  assert.equal(player.subtitleWindowDuration(60), 60)
})

test("subtitle continuation starts before the loaded window expires", () => {
  const player = new VideoPlayerController()
  const loads = []
  player.subtitleLoading = false
  player.subtitleRetryAfter = 0
  player.subtitleWindowStart = 100
  player.subtitleWindowEnd = 160
  player.textSubtitleSelected = () => true
  player.loadSubtitleTrack = (position, options) => loads.push({ position, options })

  player.ensureSubtitleWindow(139)
  assert.equal(loads.length, 0)

  player.ensureSubtitleWindow(140)
  assert.equal(loads.length, 1)
  assert.equal(loads[0].position, 160)
  assert.equal(loads[0].options.durationSeconds, 60)
})

test("completed continuation windows extend rather than replace current coverage", () => {
  const player = new VideoPlayerController()
  player.subtitleWindowStart = 100
  player.subtitleWindowEnd = 160

  player.rememberSubtitleWindow(160, 60)

  assert.equal(player.subtitleWindowStart, 100)
  assert.equal(player.subtitleWindowEnd, 220)
})

test("failed continuation keeps the subtitle range already loaded", () => {
  const player = new VideoPlayerController()
  player.subtitleWindowStart = 100
  player.subtitleWindowEnd = 160
  player.scheduleSubtitleRetry = () => {}

  const applied = player.applySubtitleResponse({ ok: false, status: 502, text: "" })

  assert.equal(applied, false)
  assert.equal(player.subtitleWindowStart, 100)
  assert.equal(player.subtitleWindowEnd, 160)
})

test("subtitle parser preserves absolute timestamps after seeking", () => {
  const player = new VideoPlayerController()
  const serverVtt = "WEBVTT\n\n00:02:01.000 --> 00:02:02.000\nServer timestamp\n"

  const [cue] = player.normalizeSubtitleCueTimeline(player.parseWebVtt(serverVtt), 120, 180)

  assert.equal(cue.start, 121, "absolute cues must not be shifted after seeking")
  assert.equal(cue.end, 122, "absolute cues must not be shifted after seeking")
})

test("subtitle guard rebases unambiguous window-relative timestamps", () => {
  const player = new VideoPlayerController()
  const relativeVtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nWindow-relative timestamp\n"

  const [cue] = player.normalizeSubtitleCueTimeline(player.parseWebVtt(relativeVtt), 120, 180)

  assert.equal(cue.start, 121, "relative cues must follow the requested media window")
  assert.equal(cue.end, 122, "relative cue duration must remain unchanged")
})

test("subtitle guard leaves ambiguous early absolute cues unchanged", () => {
  const player = new VideoPlayerController()
  const earlyVtt = "WEBVTT\n\n00:00:25.000 --> 00:00:27.000\nEarly absolute timestamp\n"

  const [cue] = player.normalizeSubtitleCueTimeline(player.parseWebVtt(earlyVtt), 30, 90)

  assert.equal(cue.start, 25, "ambiguous cues must not be guessed into another timeline")
  assert.equal(cue.end, 27, "ambiguous cue end must remain unchanged")
})

test("subtitle responses use the guarded timeline before cue merging", () => {
  const player = new VideoPlayerController()
  player.subtitleCues = []
  player.videoTarget = { currentTime: 121 }
  player.currentPlaybackPosition = () => 121
  player.hasSubtitleOverlayTarget = false

  const applied = player.applySubtitleResponse({
    ok: true,
    status: 200,
    text: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nWindow-relative response\n"
  }, 120, 180)

  assert.equal(applied, true)
  assert.equal(player.subtitleCues.length, 1)
  assert.equal(player.subtitleCues[0].start, 121)
  assert.equal(player.subtitleCues[0].end, 122)
  assert.equal(player.subtitleCues[0].text, "Window-relative response")
})

test("subtitle text renders inside the centered caption box", () => {
  const player = new VideoPlayerController()
  const classes = new Set(["hidden"])
  player.hasSubtitleOverlayTarget = true
  player.hasSubtitleTextTarget = true
  player.subtitleOverlayTarget = {
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name)
    }
  }
  player.subtitleTextTarget = { textContent: "" }
  player.subtitleCues = [{ start: 10, end: 20, text: "Centered on the TV" }]
  player.subtitleOffset = 0
  player.ensureSubtitleWindow = () => {}

  player.updateSubtitleOverlay(15)

  assert.equal(player.subtitleTextTarget.textContent, "Centered on the TV")
  assert.equal(classes.has("hidden"), false)
})

test("HLS receives selected audio and bitmap subtitle tracks but not text overlays", () => {
  const player = new VideoPlayerController()
  player.selectedAudioStream = "2"
  player.selectedSubtitleStream = "4"
  player.subtitleTracks = [{ index: 4, text_supported: false }]

  const bitmapParams = new URLSearchParams()
  player.appendSelectedHlsTracks(bitmapParams)
  assert.equal(bitmapParams.get("audio_stream"), "2")
  assert.equal(bitmapParams.get("subtitle_stream"), "4")

  player.selectedSubtitleStream = "3"
  player.subtitleTracks = [{ index: 3, text_supported: true }]
  const textParams = new URLSearchParams()
  player.appendSelectedHlsTracks(textParams)
  assert.equal(textParams.get("audio_stream"), "2")
  assert.equal(textParams.has("subtitle_stream"), false)
})

test("iOS loads track metadata before starting HLS playback", async () => {
  const player = new VideoPlayerController()
  const calls = []
  player.streamingUrlValue = "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mkv"
  player.isIOS = () => true
  player.loadMediaTracks = async () => { calls.push("tracks") }
  player.startHlsPlayback = () => { calls.push("hls") }

  await player.ensureVideoSource()

  assert.deepEqual(calls, ["tracks", "hls"])
})

test("stale HLS playlist polls stop before touching the current session", async () => {
  const player = new VideoPlayerController()
  player.hlsPlaybackToken = 3

  const ready = await player.waitForPlaylist("/hls/stale/playlist.m3u8", 2)

  assert.equal(ready, false)
})

test("HLS restart updates the subtitle media timeline before loading", async () => {
  const player = new VideoPlayerController()
  player.videoTarget = { pause() {} }
  player.element = { dataset: {} }
  player.startSecondsValue = 100
  player.isSeeking = true
  player.directUrlValue = ""
  player.extractRawUrl = () => null
  player.clearSubtitleCues = () => {}
  player.reloadTextSubtitlesAt = () => {}
  player.stopHlsSession = () => {}
  player.hideSeekingOverlay = () => {}

  await player.restartHlsSession(420)

  assert.equal(player.startSecondsValue, 420)
  assert.equal(player.element.dataset.videoPlayerStartSecondsValue, "420")
})
