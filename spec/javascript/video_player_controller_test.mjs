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
  visibilityState: "visible",
  fullscreenElement: null,
  webkitFullscreenElement: null,
  exitFullscreen() {},
  querySelector(selector) {
    return selector === 'meta[name="csrf-token"]' ? { content: "csrf-token" } : null
  }
}
const fetchRequests = []

const context = vm.createContext({
  AbortController,
  URL,
  URLSearchParams,
  clearTimeout,
  console,
  document: testDocument,
  fetch: async (...args) => { fetchRequests.push(args); return { ok: true } },
  navigator: { userAgent: "Mozilla/5.0 Chrome/138.0" },
  setTimeout,
  window: { location: { origin: "https://streamvault.test" }, VTTCue: TestVTTCue }
})
vm.runInContext(source, context)
const VideoPlayerController = context.VideoPlayerController

test("leaving a local player sends one authenticated keepalive stop", () => {
  fetchRequests.length = 0
  const player = new VideoPlayerController()
  player.localTorrentHashValue = "a".repeat(40)
  player.localTorrentSessionValue = "session-token"
  player.localStopUrlValue = "/local_torrent/stop"
  player.localStopSent = false
  player.localStatusInterval = null

  player.stopLocalTorrent()
  player.stopLocalTorrent()

  assert.equal(fetchRequests.length, 1)
  const [url, options] = fetchRequests[0]
  assert.equal(url, "/local_torrent/stop")
  assert.equal(options.method, "POST")
  assert.equal(options.keepalive, true)
  assert.equal(options.headers["X-CSRF-Token"], "csrf-token")
  assert.deepEqual(JSON.parse(options.body), {
    info_hash: "a".repeat(40),
    session_token: "session-token"
  })
})

test("returning to mobile Chrome reloads subtitles at the resumed absolute position", () => {
  const player = new VideoPlayerController()
  let cleared = 0
  let reloadedAt = null
  let leaseRefreshes = 0
  player.textSubtitleSelected = () => true
  player.currentPlaybackPosition = () => 187.25
  player.clearSubtitleCues = () => { cleared += 1 }
  player.reloadTextSubtitlesAt = (position) => { reloadedAt = position }
  player.refreshLocalTorrentStatus = () => { leaseRefreshes += 1 }

  testDocument.visibilityState = "hidden"
  player.onVisibilityChange()
  assert.equal(cleared, 0)
  assert.equal(reloadedAt, null)

  testDocument.visibilityState = "visible"
  player.onVisibilityChange()
  assert.equal(leaseRefreshes, 2)
  assert.equal(cleared, 1)
  assert.equal(reloadedAt, 187.25)
})

test("cast button opens the native AirPlay target picker on Apple browsers", async () => {
  const player = new VideoPlayerController()
  let pickerCalls = 0
  const video = { webkitShowPlaybackTargetPicker() { pickerCalls += 1 } }
  Object.defineProperty(player, "videoTarget", { value: video })
  player.airPlayAvailable = true
  player.googleCastAvailable = false

  await player.castToDevice()

  assert.equal(pickerCalls, 1)
})

test("an iOS NotSupported HLS response automatically rebuilds instead of showing tap to retry", () => {
  const originalSetTimeout = context.setTimeout
  let scheduled
  context.setTimeout = (callback) => { scheduled = callback; return 1 }
  try {
    const player = new VideoPlayerController()
    const abortController = new AbortController()
    player.hlsPlaybackToken = 4
    player.hlsStartAbortController = abortController
    player.startSecondsValue = 58
    player.hasStartupOverlayTarget = false
    player.reportStall = () => {}
    player.currentPlaybackPosition = () => 91
    let restartedAt = null
    player.restartHlsSession = (position) => { restartedAt = position }

    player.recoverUnsupportedHls(4, abortController)

    assert.equal(player.hlsUnsupportedRecoveries, 1)
    assert.equal(typeof scheduled, "function")
    scheduled()
    assert.equal(restartedAt, 91)
  } finally {
    context.setTimeout = originalSetTimeout
  }
})

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

test("tap controls and subtitles follow the overlay visibility state", () => {
  const player = new VideoPlayerController()
  const styleTarget = () => ({ style: {} })
  player.backButtonTarget = styleTarget()
  player.sourceInfoTarget = styleTarget()
  player.controlsTarget = styleTarget()
  player.topControlsTarget = styleTarget()
  player.subtitleOverlayTarget = styleTarget()
  player.hasSubtitleOverlayTarget = true
  player.videoTarget = { paused: false }
  player.trackMenuOpen = () => false
  player.scheduleUiHide = () => {}

  player.showOverlayUi()
  assert.equal(player.controlsTarget.style.opacity, "1")
  assert.equal(player.controlsTarget.style.pointerEvents, "auto")
  assert.equal(player.topControlsTarget.style.opacity, "1")
  assert.equal(player.topControlsTarget.style.pointerEvents, "auto")
  assert.equal(player.subtitleOverlayTarget.style.bottom, "6.5rem")

  player.hideOverlayUi()
  assert.equal(player.controlsTarget.style.opacity, "0")
  assert.equal(player.controlsTarget.style.pointerEvents, "none")
  assert.equal(player.topControlsTarget.style.opacity, "0")
  assert.equal(player.topControlsTarget.style.pointerEvents, "none")
  assert.equal(
    player.subtitleOverlayTarget.style.bottom,
    "calc(env(safe-area-inset-bottom, 0px) + 1.5rem)"
  )
})

test("all play and pause icons stay synchronized", () => {
  const player = new VideoPlayerController()
  const icon = (hidden) => {
    const classes = new Set(hidden ? ["hidden"] : [])
    return {
      classes,
      classList: {
        add: (name) => classes.add(name),
        remove: (name) => classes.delete(name)
      }
    }
  }
  const playIcons = [icon(true), icon(true)]
  const pauseIcons = [icon(false), icon(false)]
  player.playIconTargets = playIcons
  player.pauseIconTargets = pauseIcons
  player.stopProgressWatchdog = () => {}
  player.startProgressWatchdog = () => {}

  player.videoTarget = { paused: true }
  player.updatePlayIcon()
  assert.equal(playIcons.every((item) => !item.classes.has("hidden")), true)
  assert.equal(pauseIcons.every((item) => item.classes.has("hidden")), true)

  player.videoTarget.paused = false
  player.updatePlayIcon()
  assert.equal(playIcons.every((item) => item.classes.has("hidden")), true)
  assert.equal(pauseIcons.every((item) => !item.classes.has("hidden")), true)
})

test("ten-second skip controls seek in both directions and keep controls visible", () => {
  const player = new VideoPlayerController()
  const skips = []
  let overlayShows = 0
  player.skip = (seconds) => skips.push(seconds)
  player.showOverlayUi = () => { overlayShows += 1 }

  player.skipBack()
  player.skipForward()

  assert.deepEqual(skips, [-10, 10])
  assert.equal(overlayShows, 2)
})

test("seek preview shows the selected time and stays clamped above the slider", () => {
  const player = new VideoPlayerController()
  const classes = new Set(["hidden"])
  const attributes = new Map()
  let scheduledSecond = null
  player.knownDuration = 1000
  player.thumbnailUrlValue = "/transcode/thumbnail"
  player.extractRawUrl = () => "https://download.real-debrid.com/video.mkv"
  player.controlsTarget = { style: {} }
  player.seekBarTarget = {
    getBoundingClientRect: () => ({ left: 20, width: 200 })
  }
  player.seekPreviewTarget = {
    offsetWidth: 100,
    style: {},
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name)
    },
    setAttribute: (name, value) => attributes.set(name, value)
  }
  player.seekPreviewPointerTarget = { style: {} }
  player.seekPreviewTimeTarget = { textContent: "" }
  player.scheduleSeekThumbnail = (second) => { scheduledSecond = second }

  player.showSeekPreview(0.98)

  assert.equal(classes.has("hidden"), false)
  assert.equal(attributes.get("aria-hidden"), "false")
  assert.equal(player.seekPreviewTimeTarget.textContent, "16:20")
  assert.equal(scheduledSecond, 980)
  assert.equal(player.seekPreviewTarget.style.left, "150px")
  assert.equal(player.seekPreviewPointerTarget.style.left, "90px")
  assert.equal(player.controlsTarget.style.zIndex, "25")
})

test("continuous seek movement still requests the latest frame on the throttle interval", async () => {
  const player = new VideoPlayerController()
  const classes = { add() {}, remove() {} }
  const requested = []
  player.displayedThumbnailSecond = null
  player.thumbnailDebounceTimer = null
  player.thumbnailRequestInFlight = false
  player.thumbnailDesiredSecond = 10
  player.seekPreviewImageTarget = { classList: classes, getAttribute: () => null }
  player.seekPreviewLoadingTarget = { classList: classes }
  player.loadSeekThumbnail = (second) => requested.push(second)

  player.scheduleSeekThumbnail(10)
  await new Promise((resolve) => setTimeout(resolve, 150))
  player.thumbnailDesiredSecond = 20
  player.scheduleSeekThumbnail(20)
  await new Promise((resolve) => setTimeout(resolve, 140))

  assert.deepEqual(requested, [20])
})

test("seek thumbnail loading keeps only one request in flight and skips stale frames", () => {
  const player = new VideoPlayerController()
  const imageClasses = new Set(["hidden"])
  const loadingClasses = new Set()
  const requestedSources = []
  let imageSource = ""
  const image = {
    onload: null,
    onerror: null,
    classList: {
      add: (name) => imageClasses.add(name),
      remove: (name) => imageClasses.delete(name)
    },
    getAttribute: (name) => name === "src" ? imageSource : null,
    set src(value) {
      imageSource = value
      requestedSources.push(value)
    }
  }
  player.thumbnailUrlValue = "/transcode/thumbnail"
  player.extractRawUrl = () => "https://download.real-debrid.com/video.mkv?token=secret"
  player.seekPreviewImageTarget = image
  player.seekPreviewLoadingTarget = {
    classList: {
      add: (name) => loadingClasses.add(name),
      remove: (name) => loadingClasses.delete(name)
    }
  }
  player.thumbnailPreviewActive = true
  player.thumbnailRequestInFlight = false
  player.thumbnailRequestToken = 0
  player.thumbnailDesiredSecond = 10
  // Keep this unit test synchronous while still exercising the production
  // latest-only handoff (scheduleSeekThumbnail owns the real 250ms throttle).
  player.scheduleSeekThumbnail = (second) => player.loadSeekThumbnail(second)

  player.loadSeekThumbnail(10)
  const firstLoad = image.onload
  player.thumbnailDesiredSecond = 25
  player.loadSeekThumbnail(25)

  assert.equal(requestedSources.length, 1)
  assert.match(requestedSources[0], /timestamp=10/)
  assert.match(requestedSources[0], /url=https%3A%2F%2Fdownload\.real-debrid\.com/)

  firstLoad()
  assert.equal(requestedSources.length, 2)
  assert.match(requestedSources[1], /timestamp=25/)
  assert.equal(imageClasses.has("hidden"), true)

  image.onload()
  assert.equal(player.displayedThumbnailSecond, 25)
  assert.equal(imageClasses.has("hidden"), false)
  assert.equal(loadingClasses.has("hidden"), true)
})

test("playback time updates do not overwrite the seek position while dragging", () => {
  const player = new VideoPlayerController()
  let visualUpdates = 0
  player.isDragging = true
  player.isStalled = false
  player.currentTimeTarget = { textContent: "" }
  player.currentPlaybackPosition = () => 30
  player.effectiveDuration = () => 120
  player.updateSubtitleOverlay = () => {}
  player.updateSeekVisuals = () => { visualUpdates += 1 }
  player.updateBufferBar = () => {}

  player.onTimeUpdate()

  assert.equal(player.currentTimeTarget.textContent, "0:30")
  assert.equal(visualUpdates, 0)
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

test("subtitle overlay clears stale text when its cue window becomes empty", () => {
  const player = new VideoPlayerController()
  const classes = new Set()
  player.hasSubtitleOverlayTarget = true
  player.hasSubtitleTextTarget = true
  player.subtitleOverlayTarget = {
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name)
    }
  }
  player.subtitleTextTarget = { textContent: "Old dialogue" }
  player.subtitleCues = []
  player.ensureSubtitleWindow = () => {}

  player.updateSubtitleOverlay(30)

  assert.equal(player.subtitleTextTarget.textContent, "")
  assert.equal(classes.has("hidden"), true)
})

test("subtitle provider rate limits suppress repeated mobile requests", () => {
  const player = new VideoPlayerController()
  let retryDelay = null
  player.scheduleSubtitleRetry = (delay) => { retryDelay = delay }

  const applied = player.applySubtitleResponse({
    ok: false,
    status: 429,
    text: "",
    retryAfter: 3600
  })

  assert.equal(applied, false)
  assert.equal(retryDelay, 3_600_000)
})

test("subtitle delay buttons update the overlay and stay within the supported range", () => {
  const player = new VideoPlayerController()
  const classes = new Set(["hidden"])
  const label = { textContent: "+0.0s" }
  const range = { value: "0" }
  const controls = {
    querySelector(selector) {
      if (selector === "[data-subtitle-offset-label]") return label
      if (selector === "[data-subtitle-offset-range]") return range
      return null
    }
  }
  player.videoTarget = { currentTime: 15, playbackRate: 1 }
  player.startSecondsValue = 0
  player.directPlayActive = true
  player.hasSubtitleOverlayTarget = true
  player.subtitleOffset = 0
  player.hasSubtitleTextTarget = true
  player.subtitleOverlayTarget = {
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name)
    }
  }
  player.subtitleTextTarget = { textContent: "" }
  player.subtitleCues = [{ start: 14, end: 16, text: "Delayed caption" }]
  player.ensureSubtitleWindow = () => {}

  player.adjustSubtitleOffset({
    currentTarget: {
      dataset: { subtitleOffsetDelta: "1" },
      closest: () => controls
    }
  })

  assert.equal(player.subtitleOffset, 1)
  assert.equal(label.textContent, "+1.0s")
  assert.equal(range.value, "10")
  assert.equal(player.subtitleTextTarget.textContent, "Delayed caption")
  assert.equal(classes.has("hidden"), false)

  player.setSubtitleOffset({
    currentTarget: {
      value: "999",
      closest: () => controls
    }
  })
  assert.equal(player.subtitleOffset, 5)
  assert.equal(label.textContent, "+5.0s")
  assert.equal(range.value, "50")

  player.resetSubtitleOffset({ currentTarget: { closest: () => controls } })
  assert.equal(player.subtitleOffset, 0)
  assert.equal(label.textContent, "+0.0s")
  assert.equal(range.value, "0")
})

test("subtitle delay controls shift native fullscreen cue times", () => {
  const player = new VideoPlayerController()
  const label = { textContent: "+0.0s" }
  const range = { value: "0" }
  const controls = {
    querySelector(selector) {
      if (selector === "[data-subtitle-offset-label]") return label
      if (selector === "[data-subtitle-offset-range]") return range
      return null
    }
  }
  let syncs = 0
  player.subtitleOffset = 0
  player.nativeFullscreenActive = true
  player.syncNativeFullscreenSubtitles = () => { syncs += 1 }
  player.playbackTimelineOffset = () => 120

  player.setSubtitleOffset({
    currentTarget: {
      value: "25",
      closest: () => controls
    }
  })

  assert.equal(player.subtitleOffset, 2.5)
  assert.equal(label.textContent, "+2.5s")
  assert.equal(range.value, "25")
  assert.equal(syncs, 1)
  const cueTimes = player.nativeFullscreenCueTimes({ start: 121, end: 123 })
  assert.equal(cueTimes.start, 3.5)
  assert.equal(cueTimes.end, 5.5)
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

test("MSE startup deadline starts playback below the buffer target", () => {
  const player = new VideoPlayerController()
  let played = 0
  player.videoTarget = {
    currentTime: 0,
    ended: false,
    play: () => { played += 1; return Promise.resolve() }
  }
  player.sourceBuffer = { buffered: { length: 1, start: () => 0, end: () => 5 } }
  player.playbackStarted = false
  player.bufferAheadDeadline = Date.now() - 1
  player.userPaused = false
  player.isSeeking = false

  player.maybeStartPlayback()

  assert.equal(played, 1)
  assert.equal(player.playbackStarted, true)
  assert.equal(player.bufferAheadDeadline, null)
  assert.equal(player.bufferAheadTimer, null)
})

test("MSE rebuffer deadline resumes playback without another append event", () => {
  const player = new VideoPlayerController()
  let played = 0
  player.videoTarget = {
    currentTime: 0,
    ended: false,
    play: () => { played += 1; return Promise.resolve() }
  }
  player.sourceBuffer = { buffered: { length: 1, start: () => 0, end: () => 2 } }
  player.playbackStarted = true
  player.isStalled = true
  player.rebufferDeadline = Date.now() - 1
  player.userPaused = false
  player.isSeeking = false

  player.maybeStartPlayback()

  assert.equal(played, 1)
  assert.equal(player.isStalled, false)
  assert.equal(player.rebufferDeadline, null)
  assert.equal(player.rebufferTimer, null)
})

test("direct playback does not reconnect while a full native buffer pauses progress events", () => {
  const player = new VideoPlayerController()
  let recoveries = 0
  player.videoTarget = {
    currentTime: 10,
    paused: false,
    ended: false,
    buffered: { length: 1, start: () => 0, end: () => 30 }
  }
  player.isDirectPlay = () => true
  player.isRemuxDirectPlay = () => false
  player.playbackStarted = true
  player.progressWatchdogArmed = true
  player.lastProgressPosition = 10
  player.lastProgressTime = Date.now() - 21000
  player.lastProgressEventTime = Date.now() - 21000
  player.lastBufferEnd = 30
  player.lastBufferDataTime = Date.now() - 21000
  player.handleStreamStall = () => { recoveries += 1 }

  player.checkProgressStall()

  assert.equal(recoveries, 0)
  assert.equal(player.progressWatchdogArmed, true)
})

test("clearing subtitle cues invalidates an old playback hold", () => {
  const player = new VideoPlayerController()
  let played = 0
  player.videoTarget = {
    paused: true,
    ended: false,
    play: () => { played += 1; return Promise.resolve() }
  }
  player.subtitlePlaybackHoldToken = 7
  player.subtitleLoadToken = 7

  player.clearSubtitleCues()
  player.finishSubtitlePlaybackHold(7)

  assert.equal(player.subtitlePlaybackHoldToken, null)
  assert.equal(played, 0)
})

test("source selection starts from core tracks before optional external subtitle discovery", async () => {
  const player = new VideoPlayerController()
  const events = []
  const previousFetch = context.fetch
  player.streamingUrlValue = "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mp4"
  player.hasTracksUrlValue = true
  player.tracksUrlValue = "/transcode/tracks"
  player.mseSupported = true
  player.isIOS = () => false
  player.extractRawUrl = () => "https://example.test/movie.mp4"
  player.addContentMetadataParams = () => {}
  player.renderTrackControls = () => {}
  player.renderSubtitleControls = () => {}
  player.directPlayEligible = () => true
  player.startDirectPlay = () => { events.push("direct") }
  player.currentPlaybackPosition = () => 0

  context.fetch = async (path) => {
    const includeExternal = new URL(path, "https://streamvault.test").searchParams.get("include_external_subtitles")
    events.push(includeExternal === "0" ? "core" : "external")
    return {
      ok: true,
      json: async () => includeExternal === "0"
        ? {
            audio: [{ index: 0, language: "EN", default: true }],
            subtitles: [{ index: 1, label: "Embedded", text_supported: true }],
            direct_playable: true
          }
        : {
            subtitles: [
              { index: 1, label: "Embedded", text_supported: true },
              { index: "external:subdl:english", label: "English · SubDL", text_supported: true, external: true }
            ]
          }
    }
  }

  try {
    await player.ensureVideoSource()
    await new Promise((resolve) => setImmediate(resolve))

    assert.deepEqual(events, ["core", "direct", "external"])
    assert.equal(Array.from(player.subtitleTracks, (track) => track.index).join(","), "1,external:subdl:english")
  } finally {
    context.fetch = previousFetch
  }
})

test("stale MSE callbacks and reader data cannot mutate a replacement pipeline", async () => {
  const player = new VideoPlayerController()
  const oldMediaSource = {}
  const oldSourceBuffer = { updating: false, buffered: { length: 0 } }
  const newMediaSource = {}
  const newSourceBuffer = { updating: false, buffered: { length: 0 } }
  const previousFetch = context.fetch
  let resolveRead
  player.msePipelineGeneration = 1
  player.mediaSource = oldMediaSource
  player.sourceBuffer = oldSourceBuffer
  player.bufferQueue = []
  player.directPlayActive = false
  player.hlsPlaybackActive = false
  player.hlsSessionId = null
  player.startStallWatchdog = () => {}
  player.handlePrematureStreamEnd = () => {}

  context.fetch = async () => ({
    ok: true,
    body: {
      getReader: () => ({ read: () => new Promise((resolve) => { resolveRead = resolve }) })
    }
  })

  try {
    const fetchPromise = player.startStreamingFetch("/transcode", 1, oldMediaSource, oldSourceBuffer)
    await new Promise((resolve) => setImmediate(resolve))

    player.msePipelineGeneration = 2
    player.mediaSource = newMediaSource
    player.sourceBuffer = newSourceBuffer
    player.bufferQueue = ["new-pipeline-fragment"]
    player.onBufferUpdateEnd(1, oldMediaSource, oldSourceBuffer)
    player.queueBufferChunk(new Uint8Array([0, 0, 0, 8, 109, 111, 111, 118]).buffer, 1, oldMediaSource, oldSourceBuffer)
    assert.equal(typeof resolveRead, "function")
    resolveRead({ done: false, value: new Uint8Array([0, 0, 0, 8, 109, 111, 111, 118]) })
    await fetchPromise

    assert.deepEqual(player.bufferQueue, ["new-pipeline-fragment"])
    assert.equal(player.fmp4BufferSize || 0, 0)
  } finally {
    context.fetch = previousFetch
  }
})

test("MSE retries the rejected quota fragment after eviction and bounds reader backlog", async () => {
  const player = new VideoPlayerController()
  let retainedStart = 0
  let removals = 0
  const fragment = new Uint8Array([7, 8, 9]).buffer
  const attempts = []
  const sourceBuffer = {
    updating: false,
    buffered: {
      get length() { return 1 },
      start: () => retainedStart,
      end: () => 100
    },
    appendBuffer(data) {
      attempts.push(data)
      if (attempts.length === 1) {
        const error = new Error("quota")
        error.name = "QuotaExceededError"
        throw error
      }
    },
    remove() {
      removals += 1
      retainedStart = 10
    }
  }
  const mediaSource = {}
  player.msePipelineGeneration = 1
  player.mediaSource = mediaSource
  player.sourceBuffer = sourceBuffer
  player.bufferQueue = [fragment]
  player.directPlayActive = false
  player.hlsPlaybackActive = false
  player.hlsSessionId = null
  player.videoTarget = { currentTime: 40, ended: false, play: () => Promise.resolve() }
  player.userPaused = true
  player.startStallWatchdog = () => {}

  player.flushBufferQueue(1, mediaSource, sourceBuffer)
  assert.equal(removals, 1)
  assert.equal(player.bufferQueue.length, 1)
  assert.equal(player.bufferQueue[0], fragment)

  player.onBufferUpdateEnd(1, mediaSource, sourceBuffer)
  assert.equal(attempts.length, 2)
  assert.equal(attempts[0], fragment)
  assert.equal(attempts[1], fragment)
  assert.equal(player.bufferQueue.length, 0)

  player.bufferQueue = Array.from({ length: 8 }, () => fragment)
  const capacity = player.waitForMseBacklogCapacity(1, mediaSource, sourceBuffer)
  let capacityResolved = false
  capacity.then(() => { capacityResolved = true })
  await Promise.resolve()
  assert.equal(capacityResolved, false)

  player.bufferQueue.pop()
  player.releaseMseBacklogWaiters()
  assert.equal(await capacity, true)
})

test("MSE starts at the initial 10 second budget and preserves pause and seek guards", () => {
  const player = new VideoPlayerController()
  let plays = 0
  player.videoTarget = {
    currentTime: 0,
    ended: false,
    play: () => { plays += 1; return Promise.resolve() }
  }
  player.sourceBuffer = { buffered: { length: 1, start: () => 0, end: () => 10 } }
  player.playbackStarted = false
  player.userPaused = false
  player.isSeeking = false

  player.maybeStartPlayback()
  assert.equal(plays, 1)
  assert.equal(player.playbackStarted, true)

  player.playbackStarted = false
  player.sourceBuffer.buffered.end = () => 30
  player.userPaused = true
  player.maybeStartPlayback()
  assert.equal(plays, 1)

  player.userPaused = false
  player.isSeeking = true
  player.maybeStartPlayback()
  assert.equal(plays, 1)
})

test("MSE recovery budget survives raw network data and resets only when playback is ready", async () => {
  const player = new VideoPlayerController()
  const mediaSource = {}
  const sourceBuffer = { updating: false, appendBuffer() {}, buffered: { length: 1, start: () => 0, end: () => 3 } }
  const previousFetch = context.fetch
  let reads = 0
  player.mediaSource = mediaSource
  player.sourceBuffer = sourceBuffer
  player.directPlayActive = false
  player.hlsPlaybackActive = false
  player.hlsSessionId = null
  player.streamRecoveryAttempts = 2
  player.streamRecoveryActive = true
  player.startStallWatchdog = () => {}
  player.armBufferAheadDeadline = () => {}
  player.handlePrematureStreamEnd = () => {}
  player.bufferQueue = []
  context.fetch = async () => ({
    ok: true,
    body: {
      getReader: () => ({
        read: async () => reads++ === 0
          ? { done: false, value: new Uint8Array([0, 0, 0, 8, 109, 111, 111, 118]) }
          : { done: true }
      })
    }
  })

  try {
    await player.startStreamingFetch("/transcode", 1, mediaSource, sourceBuffer)
    assert.equal(player.streamRecoveryAttempts, 2)
    assert.equal(player.streamRecoveryActive, true)

    player.videoTarget = {
      paused: false,
      currentTime: 0,
      buffered: { length: 1, start: () => 0, end: () => 3 }
    }
    player.hideStartupOverlay = () => {}
    player.hideSeekingOverlay = () => {}
    player.stopProgressWatchdog = () => {}
    player.startProgressWatchdog = () => {}
    player.clearRebufferTimer = () => {}
    player.clearStallWatchdog = () => {}
    player.isSeeking = false
    player.onVideoReady()

    assert.equal(player.streamRecoveryAttempts, 0)
    assert.equal(player.streamRecoveryActive, false)
  } finally {
    context.fetch = previousFetch
  }
})

test("HLS rate limits honor Retry-After and retry the current operation", async () => {
  const player = new VideoPlayerController()
  const abortController = new AbortController()
  const delays = []
  let retries = 0

  player.hlsPlaybackToken = 7
  player.hlsStartAbortController = abortController
  player.hlsRateLimitRetries = 0
  player.waitForHlsPollInterval = async (delay, signal) => {
    delays.push(delay)
    assert.equal(signal, abortController.signal)
    return true
  }

  const response = {
    status: 429,
    headers: { get: (name) => name === "Retry-After" ? "3" : null }
  }
  const handled = await player.retryRateLimitedHlsStart(
    response,
    7,
    abortController,
    async () => { retries += 1 }
  )

  assert.equal(handled, true)
  assert.deepEqual(delays, [3000])
  assert.equal(retries, 1)
})

test("non-rate-limit HLS errors are not retried", async () => {
  const player = new VideoPlayerController()
  const abortController = new AbortController()
  let retries = 0

  const handled = await player.retryRateLimitedHlsStart(
    { status: 500 },
    1,
    abortController,
    async () => { retries += 1 }
  )

  assert.equal(handled, false)
  assert.equal(retries, 0)
})

test("a newer HLS seek aborts stale bootstrap work and stops its late session", async () => {
  const player = new VideoPlayerController()
  const previousFetch = context.fetch
  const previousSetTimeout = context.setTimeout
  const stoppedSessions = []
  let starts = 0
  let firstStartResponse
  let firstSignal
  player.videoTarget = {
    pause() {},
    load() {},
    play: () => Promise.resolve(),
    addEventListener() {},
    removeEventListener() {}
  }
  player.element = { dataset: {} }
  player.directUrlValue = "https://example.test/movie.mkv"
  player.clearSubtitleCues = () => {}
  player.reloadTextSubtitlesAt = () => {}
  player.hideSeekingOverlay = () => {}
  player.hlsPlaybackToken = 0
  player.hlsSessionId = null
  player.hlsPlaybackActive = true
  testDocument.querySelector = () => null
  player.stopHlsSessionById = async (sessionId) => { stoppedSessions.push(sessionId) }
  context.setTimeout = () => ({})
  context.fetch = (path, options = {}) => {
    if (path === "/hls/start") {
      starts += 1
      if (starts === 1) {
        firstSignal = options.signal
        return new Promise((resolve) => { firstStartResponse = resolve })
      }
      return Promise.resolve({ ok: true, json: async () => ({ session_id: "latest", playlist_url: "/hls/latest/playlist.m3u8" }) })
    }
    if (path === "/hls/latest/playlist.m3u8") {
      return Promise.resolve({ status: 200, text: async () => "#EXTINF:4,\nsegment-1.ts\n#EXTINF:4,\nsegment-2.ts" })
    }
    return Promise.resolve({ ok: true })
  }

  try {
    const firstSeek = player.restartHlsSession(100)
    await new Promise((resolve) => setImmediate(resolve))
    const secondSeek = player.restartHlsSession(200)
    await secondSeek
    firstStartResponse({ ok: true, json: async () => ({ session_id: "late", playlist_url: "/hls/late/playlist.m3u8" }) })
    await firstSeek
    await new Promise((resolve) => setImmediate(resolve))

    assert.equal(firstSignal.aborted, true)
    assert.equal(player.hlsSessionId, "latest")
    assert.equal(player.videoTarget.src, "/hls/latest/playlist.m3u8")
    assert.deepEqual(stoppedSessions, ["late"])
  } finally {
    context.fetch = previousFetch
    context.setTimeout = previousSetTimeout
  }
})
