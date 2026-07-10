import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import vm from "node:vm"

const source = fs
  .readFileSync(new URL("../../app/javascript/controllers/video_player_controller.js", import.meta.url), "utf8")
  .replace(/^import .*$/m, "class Controller {}")
  .replace("export default class", "globalThis.VideoPlayerController = class")

const context = vm.createContext({
  AbortController,
  URL,
  URLSearchParams,
  clearTimeout,
  console,
  setTimeout,
  window: { location: { origin: "https://streamvault.test" } }
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
  player.subtitleCues = [{ start: 101, end: 103, text: "Hello" }]
  player.hasSubtitleOverlayTarget = false

  player.clearSubtitleCues()

  assert.equal(aborted, true)
  assert.equal(player.subtitleLoadToken, 8)
  assert.equal(player.subtitleLoading, false)
  assert.equal(player.subtitleWindowStart, null)
  assert.equal(player.subtitleWindowEnd, null)
  assert.equal(player.subtitleCues.length, 0)
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
