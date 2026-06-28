import { Controller } from "@hotwired/stimulus"

const MIN_VALID_DURATION_SECONDS = 60
const SUBTITLE_STARTUP_WINDOW_SECONDS = 5
const SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS = 2
const SUBTITLE_WINDOW_SECONDS = 15
const SUBTITLE_LOOK_BEHIND_SECONDS = 5
const EXTERNAL_SUBTITLE_WINDOW_SECONDS = 60
const SUBTITLE_PREFETCH_SECONDS = 10
const STREAM_STALL_TIMEOUT_MS = 60000
const PROGRESS_STALL_TIMEOUT_MS = 20000
const PROGRESS_WATCHDOG_INTERVAL_MS = 3000
const STREAM_MAX_RECOVERY_ATTEMPTS = 3
const BUFFER_AHEAD_SECONDS = 30
const BUFFER_AHEAD_MAX_WAIT_MS = 15000
// After a stall, rebuild a meaningful buffer before resuming so ffmpeg
// can catch up.  When the transcode rate is below 1× (HEVC source, slow
// server), resuming with a tiny buffer causes a rapid stall-resume-stall
// cycle = periodic black screen.  5s gives ffmpeg enough runway to
// produce a meaningful burst before playback resumes.
const REBUFFER_AHEAD_SECONDS = 5
// Stall watchdog timeout for rebuffer stalls (playback already started).
// Must be longer than the time to accumulate REBUFFER_AHEAD_SECONDS at a
// reasonable source speed, so trickling data doesn't trigger a reconnect
// before the rebuffer gate has a chance to resume.  15s is long enough
// for slow-but-alive sources, short enough that a truly dead fetch
// (server closed the response) doesn't leave the user staring at
// "Buffering" for too long.
const REBUFFER_STALL_TIMEOUT_MS = 30000
// Maximum time to wait for the rebuffer gate (REBUFFER_AHEAD_SECONDS)
// before resuming with whatever buffer has accumulated.  On a slow
// or trickling source, data arrives in small bursts that never reach
// the gate threshold — without a deadline, the video would sit on
// "Buffering" forever while the stall watchdog keeps getting reset by
// each trickle.  10s gives ffmpeg time to build 5s of buffer on a
// sub-1× source; the stall watchdog handles a genuinely dead source.
const REBUFFER_MAX_WAIT_MS = 10000
const INTERACTIVE_SELECTOR = "button, a, input, textarea, select, [contenteditable='true']"

export default class extends Controller {
  static get targets() {
    return [
      "video", "controls", "seekBar", "seekFilled", "seekBuffered", "seekHandle",
      "playButton", "playIcon", "pauseIcon", "currentTime", "durationDisplay",
      "volumeIcon", "muteIcon", "startupOverlay", "seekingOverlay",
      "seekingOverlayMessage", "sourceInfo", "sourceToggle", "sourceDetails", "sourceUrl", "sourceFilename", "backButton",
      "audioControls", "audioMenu", "audioOptions", "audioButtonLabel",
      "subtitleControls", "subtitleMenu", "subtitleOptions", "subtitleButtonLabel", "subtitleOverlay"
    ]
  }
  static get values() {
    return {
      streamingUrl: String, directUrl: String, filename: String, imdbId: String, type: String,
      season: String, episode: String, resumeAt: String, startSeconds: Number,
      title: String, duration: Number, posterUrl: String,
      defaultLanguage: String, preferredLanguages: String,
      tracksUrl: String, subtitlesUrl: String, resumeUrl: String
    }
  }

  connect() {
    this.progressInterval = null
    this.uiHideTimer = null
    this.knownDuration = this.validDuration(this.durationValue) ? this.durationValue : 0
    this.isSeeking = false
    this.isDragging = false
    this.mouseMoveHandler = this.onMouseMove.bind(this)
    this.keydownHandler = this.onKeyDown.bind(this)
    this.videoClickHandler = this.onVideoClick.bind(this)
    this.documentClickHandler = this.onDocumentClick.bind(this)
    this.updatePlayIconHandler = this.updatePlayIcon.bind(this)
    this.timeUpdateHandler = this.onTimeUpdate.bind(this)
    this.progressHandler = this.onProgress.bind(this)
    this.volumeChangeHandler = this.updateVolumeIcon.bind(this)
    this.videoWaitingHandler = () => this.onVideoWaiting()
    this.videoReadyHandler = () => this.onVideoReady()
    this.audioTracks = []
    this.subtitleTracks = []
    this.selectedAudioStream = this.currentUrlParam("audio_stream")
    this.selectedSubtitleStream = this.currentUrlParam("subtitle_stream")
    this.subtitleCues = []
    this.subtitleWindowStart = null
    this.subtitleWindowEnd = null
    this.subtitleLoading = false
    this.subtitleLoadToken = 0
    this.subtitleAbortController = null
    this.subtitleRetryAfter = 0
    this.subtitlePrefetches = new Map()
    this.subtitlePrefetchResults = new Map()
    this.subtitlePlaybackHoldToken = null
    this.startupOverlayHideTimer = null
    this.dragMoveHandler = null
    this.suppressNextSeekClick = false
    this.suppressSeekClickTimer = null
    this.mediaSource = null
    this.sourceBuffer = null
    this.fetchController = null
    this.pendingSeekSeconds = null
    this.stallWatchdogTimer = null
    this.bufferingOverlayTimer = null
    this.lastProgressTime = 0
    this.lastProgressPosition = 0
    this.progressWatchdogArmed = false
    this.streamRecoveryActive = false
    this.playbackStarted = false
    this.isStalled = false
    // True when the user deliberately paused (button/spacebar). The
    // rebuffer gate in maybeStartPlayback must never auto-resume a
    // user pause — only a rebuffer pause (buffer ran dry).
    this.userPaused = false
    // True once navigateBack has saved progress and aborted the fetch;
    // suppresses the duplicate save in the beforeunload handler.
    this.navigatingAway = false
    this.bufferAheadDeadline = null
    this.rebufferDeadline = null
    this.mseSupported = window.MediaSource && MediaSource.isTypeSupported('video/mp4; codecs="avc1.42E01E,mp4a.40.2"')
    this.hlsSessionId = null

    this.ensureVideoSource()

    // Show source info
    this.sourceInfoTarget.classList.remove("hidden")
    this.sourceUrlTarget.textContent = this.streamingUrlValue
    this.sourceFilenameTarget.textContent = this.filenameValue || "Unknown"
    this.showOverlayUi()
    this.element.addEventListener("mousemove", this.mouseMoveHandler)
    document.addEventListener("keydown", this.keydownHandler)
    document.addEventListener("click", this.documentClickHandler)
    // Video event listeners
    this.videoTarget.addEventListener("click", this.videoClickHandler)
    this.videoTarget.addEventListener("play", this.updatePlayIconHandler)
    this.videoTarget.addEventListener("pause", this.updatePlayIconHandler)
    this.videoTarget.addEventListener("timeupdate", this.timeUpdateHandler)
    this.videoTarget.addEventListener("progress", this.progressHandler)
    this.videoTarget.addEventListener("volumechange", this.volumeChangeHandler)
    this.videoTarget.addEventListener("waiting", this.videoWaitingHandler)
    this.videoTarget.addEventListener("playing", this.videoReadyHandler)
    // canplay is intentionally NOT listened to — it fires when the browser
    // has just one frame, which hides the buffering overlay prematurely
    // during a stall.  Only "playing" (actual playback resuming) hides it.
    this.videoEndedHandler = () => this.onVideoEnded()
    this.videoTarget.addEventListener("ended", this.videoEndedHandler)
    this.videoErrorHandler = (e) => this.onVideoError(e)
    this.videoTarget.addEventListener("error", this.videoErrorHandler)

    // Resume: transcode streams already start at the resume position
    // via ffmpeg -ss, so no client-side seek needed.

    // Duration: probe in the background via AJAX — never block video
    // playback. The video starts immediately; the seek bar populates
    // when the probe completes (usually a few seconds).
    this.currentTimeTarget.textContent = this.formatTime(this.startSecondsValue)
    this.updateDurationDisplay()
    this.onTimeUpdate()
    this.syncStartupOverlay()
    this.probeDuration()
    this.loadMediaTracks()

    // Save progress on page unload — but skip if navigateBack already
    // saved (navigatingAway flag prevents a duplicate save).
    this.beforeUnloadHandler = () => { if (!this.navigatingAway) this.saveProgressSync() }
    window.addEventListener("beforeunload", this.beforeUnloadHandler)

    // Track progress every 5s
    this.startProgressTracking()
  }

  disconnect() {
    this.stopHlsSession()
    this.stopProgressTracking()
    // Save progress only if navigateBack hasn't already done it.
    if (!this.navigatingAway) this.saveProgressSync()
    this.clearUiHideTimer()
    this.clearStartupOverlayTimer()
    this.clearSuppressSeekClickTimer()
    this.clearStallWatchdog()
    if (this.bufferingOverlayTimer) clearTimeout(this.bufferingOverlayTimer)
    this.stopProgressWatchdog()
    this.playbackStarted = false
    this.bufferAheadDeadline = null
    this.rebufferDeadline = null
    this.cancelSeekDrag()
    this.element.removeEventListener("mousemove", this.mouseMoveHandler)
    document.removeEventListener("keydown", this.keydownHandler)
    document.removeEventListener("click", this.documentClickHandler)
    this.videoTarget.removeEventListener("click", this.videoClickHandler)
    this.videoTarget.removeEventListener("play", this.updatePlayIconHandler)
    this.videoTarget.removeEventListener("pause", this.updatePlayIconHandler)
    this.videoTarget.removeEventListener("timeupdate", this.timeUpdateHandler)
    this.videoTarget.removeEventListener("progress", this.progressHandler)
    this.videoTarget.removeEventListener("volumechange", this.volumeChangeHandler)
    this.videoTarget.removeEventListener("waiting", this.videoWaitingHandler)
    this.videoTarget.removeEventListener("playing", this.videoReadyHandler)
    this.videoTarget.removeEventListener("ended", this.videoEndedHandler)
    this.videoTarget.removeEventListener("error", this.videoErrorHandler)
    window.removeEventListener("beforeunload", this.beforeUnloadHandler)
    this.removeTextSubtitleTrack()
    if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
    this.bufferQueue = []
    this.pendingSeekSeconds = null
    // Skip video element teardown when navigating away — the page is
    // being destroyed and pauseAndDetachVideo's videoTarget.load()
    // forces a synchronous decode-pipeline flush that blocks the
    // main thread, delaying the new page from rendering.  The browser
    // tears down the video element during unload.
    if (!this.navigatingAway) this.pauseAndDetachVideo()
  }

  async probeDuration() {
    try {
      const rawUrl = this.extractRawUrl()
      if (!rawUrl) return

      const response = await fetch(`/transcode/duration?url=${encodeURIComponent(rawUrl)}`)
      const data = await response.json()
      const probedDuration = Number(data.duration)
      if (this.validDuration(probedDuration)) {
        this.knownDuration = probedDuration
        this.updateDurationDisplay()
        // Now that we know the duration, position the seek bar at the
        // current playback point (which starts at startSecondsValue).
        this.onTimeUpdate()
      }
    } catch (e) {
      console.warn("Duration probe failed:", e)
    }
  }

  extractRawUrl() {
    try {
      const url = new URL(this.streamingUrlValue, window.location.origin)
      return url.searchParams.get("url")
    } catch {
      return null
    }
  }

  currentUrlParam(name) {
    try {
      const url = new URL(this.streamingUrlValue || this.videoTarget.currentSrc || this.videoTarget.src, window.location.origin)
      return url.searchParams.get(name)
    } catch {
      return null
    }
  }
  ensureVideoSource() {
    if (!this.streamingUrlValue) return
    if (this.isIOS()) {
      this.startHlsPlayback()
    } else if (this.mseSupported) {
      this.setupMseSource(this.streamingUrlValue)
    } else if (!this.videoTarget.getAttribute("src")) {
      this.videoTarget.src = this.streamingUrlValue
    }
  }
  setupMseSource(streamUrl) {
    // Abort current fetch and clear queue
    if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
    this.bufferQueue = []
    this.playbackStarted = false
    this.isStalled = false
    this.userPaused = false
    this.bufferAheadDeadline = null
    this.rebufferDeadline = null
    // Clear any stall watchdog from the previous connection so a
    // pending timer can't fire into the new MSE pipeline.
    this.clearStallWatchdog()

    // Tear down old MediaSource
    if (this.mediaSource) {
      if (this.mediaSource.readyState === "open") { try { this.mediaSource.endOfStream() } catch {} }
      this.mediaSource = null
      this.sourceBuffer = null
    }
    if (this.videoTarget.src.startsWith("blob:")) URL.revokeObjectURL(this.videoTarget.src)

    const mimeType = 'video/mp4; codecs="avc1.42E01E,mp4a.40.2"'
    if (!this.mseSupported) {
      this.videoTarget.src = streamUrl
      this.videoTarget.load()
      const p = this.videoTarget.play(); if (p?.catch) p.catch(() => {})
      return
    }

    this.mediaSource = new MediaSource()
    this.videoTarget.src = URL.createObjectURL(this.mediaSource)
    this.mediaSource.addEventListener("sourceopen", () => {
      this.sourceBuffer = this.mediaSource.addSourceBuffer(mimeType)
      this.sourceBuffer.mode = "segments"
      this.sourceBuffer.addEventListener("updateend", () => this.onBufferUpdateEnd())
      this.startStreamingFetch(streamUrl)
    }, { once: true })
  }

  // iPhone and iPod Touch don't support MediaSource Extensions.
  // iPad (iPadOS 17.1+) supports ManagedMediaSource, so the MSE
  // path works there — exclude it explicitly.
  isIOS() {
    const ua = navigator.userAgent
    return /iPhone|iPod/.test(ua) && !/iPad/.test(ua)
  }

  // True when using native HLS playback (iOS).  All MSE-specific
  // machinery (stall watchdog, progress watchdog, reconnect, buffer
  // management) must be skipped on this path — MediaSource doesn't
  // exist on iPhone Safari, and the native HLS player handles its
  // own buffering and recovery.
  isHls() {
    return !!this.hlsSessionId
  }

  // iOS-only fallback: start a server-side HLS transcode and hand the
  // playlist to Safari's native player.  iOS Safari can't play the
  // chunked fMP4 stream the MSE pipeline produces, so ffmpeg segments
  // to .ts and serves an .m3u8 playlist instead.
  async startHlsPlayback() {
    const directUrl = this.directUrlValue || this.extractRawUrl()
    if (!directUrl) {
      console.warn('HLS: no direct URL available')
      return
    }

    try {
      const params = new URLSearchParams({ url: directUrl })
      if (this.startSecondsValue && this.startSecondsValue > 0) {
        params.set('start_seconds', this.startSecondsValue)
      }
      const audioStream = this.currentUrlParam('audio_stream')
      if (audioStream) params.set('audio_stream', audioStream)
      const subtitleStream = this.currentUrlParam('subtitle_stream')
      if (subtitleStream) params.set('subtitle_stream', subtitleStream)

      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      const response = await fetch('/hls/start', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-Token': csrfToken },
        body: params.toString()
      })

      if (!response.ok) {
        console.warn('HLS: start failed', response.status)
        return
      }

      const data = await response.json()
      this.hlsSessionId = data.session_id

      // Poll the playlist URL until ffmpeg has produced the first
      // segment (200) or failed (424).  The server returns 202
      // (Accepted) while the playlist isn't ready yet.  This avoids
      // setting a video src that points to a non-existent playlist,
      // which would cause iOS Safari to fail silently.
      const playlistReady = await this.waitForPlaylist(data.playlist_url)
      if (!playlistReady) {
        console.warn('HLS: playlist not ready or ffmpeg failed')
        if (this.hasStartupOverlayTarget) {
          const label = this.startupOverlayTarget.querySelector("span.text-white")
          const sub = this.startupOverlayTarget.querySelector("span.text-sv-text-muted")
          if (label) label.textContent = "Stream failed to start"
          if (sub) sub.textContent = "Try going back and selecting another stream"
        }
        return
      }

      // Native HLS playback — iOS Safari handles the playlist natively.
      this.videoTarget.src = data.playlist_url
      this.videoTarget.load()
      const p = this.videoTarget.play()
      if (p?.catch) p.catch((err) => {
        // iOS autoplay policy may block play() when not in a user
        // gesture context (the async fetch broke the gesture chain).
        // Show a tap-to-play overlay — the user's tap provides the
        // gesture needed to start playback.  Keep the spinner visible
        // so the user sees something is loading, and show the spinner
        // again after the tap while play() resolves.
        console.warn('HLS: autoplay blocked, showing tap-to-play', err)
        if (this.hasStartupOverlayTarget) {
          this.startupOverlayTarget.classList.remove("hidden", "opacity-0", "pointer-events-none")
          this.startupOverlayTarget.setAttribute("aria-hidden", "false")
          const spinner = this.startupOverlayTarget.querySelector(".animate-spin")
          const label = this.startupOverlayTarget.querySelector("span.text-white")
          const sub = this.startupOverlayTarget.querySelector("span.text-sv-text-muted")
          if (label) label.textContent = "Tap to play"
          if (sub) sub.textContent = "Tap anywhere to start"
          const onTap = (e) => {
            e.preventDefault()
            e.stopPropagation()
            // Show a loading spinner immediately so the user sees
            // feedback — play() may take a moment to resolve.
            if (spinner) spinner.style.display = ""
            if (label) label.textContent = "Starting playback"
            if (sub) sub.textContent = "Loading stream..."
            this.videoTarget.play().then(() => {
              // Don't hide the overlay here — onVideoReady will hide
              // it once the video is actually playing.  This covers
              // the gap between play() resolving and the first frame.
              this.startupOverlayTarget.removeEventListener("click", onTap)
            }).catch((playErr) => {
              console.warn('HLS: play() failed after tap, will retry', playErr)
              if (spinner) spinner.style.display = "none"
              if (label) label.textContent = "Tap to retry"
              if (sub) sub.textContent = "Tap anywhere to try again"
              // Keep the listener — user can tap again
            })
          }
          this.startupOverlayTarget.addEventListener("click", onTap)
        }
      })
    } catch (e) {
      console.warn('HLS: start error', e)
    }
  }

  // Poll the HLS playlist URL until enough segments are ready, ffmpeg
  // fails (424), or a timeout is reached.  Waiting for at least 2
  // segments (instead of 1) gives iOS Safari a buffer head start: by
  // the time it fetches and decodes the first segment, ffmpeg has
  // already produced the second and is working on the third.  This
  // reduces the periodic black-screen underruns that happen when
  // playback starts with a single segment buffer and the transcode
  // throughput dips.  Falls back to 1 segment if the timeout is nearly
  // reached, so a slow source doesn't fail entirely.
  async waitForPlaylist(playlistUrl) {
    const maxAttempts = 150  // 150 × 200ms = 30s max wait
    const pollInterval = 200
    const minSegments = 2
    // After this many attempts, accept 1 segment rather than timing out.
    const fallbackAttempts = 100  // 20s
    for (let i = 0; i < maxAttempts; i++) {
      try {
        // GET (not HEAD) so we can count segments in the playlist body.
        // The playlist is small (a few KB), so fetching it is cheap.
        const res = await fetch(playlistUrl)
        if (res.status === 424) {
          try {
            const body = await res.json()
            console.warn('HLS: ffmpeg failed:', body.error)
          } catch {}
          return false
        }
        if (res.status === 200) {
          const text = await res.text()
          const segmentCount = (text.match(/#EXTINF/g) || []).length
          const minNeeded = i >= fallbackAttempts ? 1 : minSegments
          if (segmentCount >= minNeeded) return true
        }
        // 202 (Accepted) — playlist not ready yet, keep polling
      } catch {
        // network error — keep polling
      }
      await new Promise(resolve => setTimeout(resolve, pollInterval))
    }
    console.warn('HLS: playlist poll timed out after', maxAttempts * pollInterval / 1000, 's')
    return false
  }

  // Restart the HLS transcode from a new position (seek).
  // Stops the current session, starts a new one with the updated
  // start_seconds, and swaps the video source to the new playlist.
  async restartHlsSession(startSeconds) {
    // Pause the video immediately so it doesn't keep playing the
    // old stream behind the seeking overlay.
    this.videoTarget.pause()

    // Fire the stop request without awaiting — it runs in parallel
    // with the new session start.  The old ffmpeg process is killed
    // server-side; we don't need to wait for that before starting
    // the new transcode.
    this.stopHlsSession()

    const directUrl = this.directUrlValue || this.extractRawUrl()
    if (!directUrl) {
      console.warn('HLS seek: no direct URL available')
      this.isSeeking = false
      this.hideSeekingOverlay()
      return
    }

    try {
      const params = new URLSearchParams({ url: directUrl })
      if (startSeconds > 0) {
        params.set('start_seconds', startSeconds)
      }
      const audioStream = this.currentUrlParam('audio_stream')
      if (audioStream) params.set('audio_stream', audioStream)
      const subtitleStream = this.currentUrlParam('subtitle_stream')
      if (subtitleStream) params.set('subtitle_stream', subtitleStream)

      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      const response = await fetch('/hls/start', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-Token': csrfToken },
        body: params.toString()
      })

      if (!response.ok) {
        console.warn('HLS seek: start failed', response.status)
        this.isSeeking = false
        this.hideSeekingOverlay()
        return
      }

      const data = await response.json()
      this.hlsSessionId = data.session_id

      // Wait for the playlist to be ready before swapping the video
      // source — same as initial playback.
      const playlistReady = await this.waitForPlaylist(data.playlist_url)
      if (!playlistReady) {
        console.warn('HLS seek: playlist not ready or ffmpeg failed')
        this.isSeeking = false
        this.hideSeekingOverlay()
        return
      }

      // Swap to the new playlist.  iOS Safari handles the source
      // change and starts playing from the beginning of the new
      // HLS stream (which starts at the seek position thanks to
      // ffmpeg -ss).
      this.videoTarget.src = data.playlist_url
      this.videoTarget.load()
      const p = this.videoTarget.play()
      if (p?.catch) p.catch(() => {})

      // Hide the seeking overlay once playback actually starts.
      const onPlaying = () => {
        this.isSeeking = false
        this.hideSeekingOverlay()
        this.videoTarget.removeEventListener('playing', onPlaying)
      }
      this.videoTarget.addEventListener('playing', onPlaying, { once: true })

      // Safety: hide overlay after 30s even if 'playing' never fires
      setTimeout(() => {
        if (this.isSeeking) {
          this.isSeeking = false
          this.hideSeekingOverlay()
        }
      }, 30000)
    } catch (e) {
      console.warn('HLS seek: error', e)
      this.isSeeking = false
      this.hideSeekingOverlay()
    }
  }

  // Best-effort: tell the backend to kill the ffmpeg HLS process for
  // the current session.  Fire-and-forget — disconnect must not block,
  // and the session TTL cleans up if the request never lands.
  async stopHlsSession() {
    if (!this.hlsSessionId) return
    const sessionId = this.hlsSessionId
    this.hlsSessionId = null
    try {
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      await fetch(`/hls/${sessionId}/stop`, {
        method: 'POST',
        headers: { 'X-CSRF-Token': csrfToken }
      })
    } catch {
      // Best-effort — don't block teardown
    }
  }

  async startStreamingFetch(url) {
    this.fetchController = new AbortController()
    // Arm the stall watchdog before awaiting the fetch.  If the source
    // is dead (e.g. an expired RealDebrid link) the server returns a
    // 502 after its first-data timeout, and the only thing that will
    // trigger recovery is this watchdog — neither onBufferUpdateEnd nor
    // a fresh "waiting" event will fire when no data ever arrives.
    this.startStallWatchdog()
    try {
      const response = await fetch(url, { signal: this.fetchController.signal })
      if (!response.ok) {
        console.warn("Stream fetch failed:", response.status)
        // A 502 means ffmpeg couldn't open the source (expired link,
        // auth failure).  Trigger recovery instead of leaving the
        // video frozen on "Buffering…".
        this.handleStreamStall()
        return
      }
      const reader = response.body.getReader()
      let firstChunk = true
      while (true) {
        // No per-chunk timeout: ffmpeg transcodes in bursts, and
        // pausing between bursts is normal. The stall watchdog on the
        // video element detects true playback stalls (buffer ran dry
        // with no new data arriving).
        const { done, value } = await reader.read()
        if (done) {
          // The server closed the response early (e.g. Cloudflare 100s
          // origin timeout, or ffmpeg exited mid-stream). If the video
          // is not actually near the end, recover by reconnecting.
          this.handlePrematureStreamEnd()
          break
        }
        if (firstChunk) {
          firstChunk = false
          this.streamRecoveryAttempts = 0
          this.streamRecoveryActive = false
          // Set a deadline: if the buffer-ahead threshold isn't reached
          // within BUFFER_AHEAD_MAX_WAIT_MS, start playback with whatever
          // we have — better to play with a small buffer than stall on
          // a slow source forever.
          this.bufferAheadDeadline = Date.now() + BUFFER_AHEAD_MAX_WAIT_MS
        }
        this.queueBufferChunk(value)
      }
    } catch (e) {
      if (e.name === "AbortError") return
      console.warn("Stream fetch failed:", e)
    }
  }

  // ── Stall watchdog ────────────────────────────────────────────────
  //
  // The watchdog monitors the VIDEO ELEMENT, not the network fetch.
  // When the video fires "waiting" (buffer ran dry), we start a timer.
  // If the video doesn't fire "playing"/"canplay" within
  // STREAM_STALL_TIMEOUT_MS, the stream is truly stalled — the fetch
  // is not delivering data fast enough to sustain playback. We then
  // reconnect from the current position. If the video resumes before
  // the timer fires, the timer is cancelled and no recovery occurs.
  //
  // This avoids false recoveries during normal transcoding pauses:
  // ffmpeg may pause between bursts, but as long as the MSE buffer
  // has enough data to keep the video playing, no "waiting" event
  // fires and the watchdog never triggers.

  onVideoWaiting() {
    // In HLS mode, iOS Safari manages its own buffering and the MSE
    // stall watchdog can't reconnect (no MediaSource on iPhone).  But
    // we still show the buffering overlay so the user sees feedback
    // instead of a bare black screen during a buffer underrun, and
    // arm the progress watchdog so a dead ffmpeg (playlist stopped
    // growing) is detected and recovered instead of hanging forever.
    if (this.isHls()) {
      // Debounce like the MSE path — sub-200ms waits are visual noise.
      clearTimeout(this.bufferingOverlayTimer)
      this.bufferingOverlayTimer = setTimeout(() => {
        this.bufferingOverlayTimer = null
        if (!this.videoTarget.paused && this.hasBufferedAhead()) return
        this.showBufferingOverlay()
        this.startProgressWatchdog()
      }, 200)
      return
    }
    // Browsers fire "waiting" when they anticipate an underrun — even
    // if 0.5s of buffer remains, playback will stall within that window.
    // Skipping the overlay here leaves a bare black frame when the
    // stall actually hits 0.5s later.  The 200ms debounce below filters
    // genuinely transient waits; don't pre-filter on hasBufferedAhead.
    // Debounce: wait 200ms before showing the overlay.  Many stalls
    // resolve in under 200ms (ffmpeg burst arrived, MSE appended).
    // Showing a spinner for a sub-200ms gap is visual noise, but
    // 200ms is short enough that the user rarely sees a bare black
    // frame (the previous 500ms left a visible black gap).
    clearTimeout(this.bufferingOverlayTimer)
    this.bufferingOverlayTimer = setTimeout(() => {
      this.bufferingOverlayTimer = null
      // Re-check: the video may have resumed during the 200ms delay.
      // If currentTime advanced or buffer is now available, the stall
      // resolved — don't show the overlay or start the watchdog.
      if (!this.videoTarget.paused && this.hasBufferedAhead()) {
        return
      }
      this.stopProgressWatchdog()
      this.isStalled = true
      this.showBufferingOverlay()
      // Set a rebuffer deadline: if the gate threshold isn't reached
      // within REBUFFER_MAX_WAIT_MS, resume with whatever we have.
      // Without this, a trickling source keeps resetting the stall
      // watchdog on each tiny burst and the video hangs on "Buffering"
      // forever because the rebuffer gate is never reached.
      if (!this.rebufferDeadline) {
        this.rebufferDeadline = Date.now() + REBUFFER_MAX_WAIT_MS
      }
      // After a stall with playback already started, use a shorter
      // stall watchdog timeout — the 60s default is for initial
      // connection; a rebuffer stall means the fetch may have ended
      // and no data is arriving, so reconnect sooner.
      this.startStallWatchdog(this.playbackStarted ? REBUFFER_STALL_TIMEOUT_MS : STREAM_STALL_TIMEOUT_MS)
    }, 200)
  }

  // Returns true if there's at least `minSeconds` (default 0.5s) of
  // buffered data ahead of the current position.
  hasBufferedAhead(minSeconds = 0.5) {
    const video = this.videoTarget
    if (!video) return false
    const ranges = video.buffered
    if (!ranges || ranges.length === 0) return false
    const pos = video.currentTime
    for (let i = 0; i < ranges.length; i++) {
      if (ranges.start(i) <= pos && ranges.end(i) > pos + minSeconds) {
        return true
      }
    }
    return false
  }

  startStallWatchdog(timeoutMs = STREAM_STALL_TIMEOUT_MS) {
    this.clearStallWatchdog()
    this.stallWatchdogTimer = setTimeout(() => {
      this.stallWatchdogTimer = null
      // Re-check before firing recovery: the video may have resumed
      // from buffer without firing "playing" (the media element
      // doesn't always emit it when transitioning between buffered
      // ranges). If there's buffer ahead and the video isn't paused,
      // the stall resolved — don't reconnect.
      if (!this.videoTarget.paused && this.hasBufferedAhead()) {
        this.hideSeekingOverlay()
        this.startProgressWatchdog()
        return
      }
      this.handleStreamStall()
    }, timeoutMs)
  }

  clearStallWatchdog() {
    if (this.stallWatchdogTimer) {
      clearTimeout(this.stallWatchdogTimer)
      this.stallWatchdogTimer = null
    }
  }

  // ── Progress watchdog (silent freeze detector) ──────────────────
  //
  // The `waiting`-based watchdog only fires when the browser emits a
  // "waiting" event.  In practice, browsers do NOT reliably emit
  // "waiting" when playback reaches the end of buffered data after a
  // fetch has ended early (e.g. the server/Cloudflare closed the
  // response, or ffmpeg exited mid-burst).  The video element sits on
  // the last buffered frame with readyState >= 2, paused === false,
  // and currentTime frozen — and never fires "waiting".  The result
  // is a permanent frozen frame with no "Buffering" indicator, which
  // only recovers when the user manually seeks.
  //
  // This watchdog polls currentTime on a timer.  While the video is
  // supposedly playing (not paused, not ended, not seeking), if
  // currentTime does not advance for PROGRESS_STALL_TIMEOUT_MS, the
  // stream is treated as a silent stall and recovered via the same
  // handleStreamStall() path.  It complements the `waiting` watchdog:
  //   - `waiting` fires → progress watchdog is disarmed, `waiting`
  //     watchdog owns the 60s countdown.
  //   - silent freeze (no `waiting`) → progress watchdog detects it
  //     in PROGRESS_STALL_TIMEOUT_MS instead.
  // The baseline is reset whenever new data is appended, so normal
  // transcoding bursts (which DO keep currentTime advancing) never
  // trip it.

  startProgressWatchdog() {
    if (this.progressWatchdogArmed) return
    this.lastProgressPosition = this.videoTarget.currentTime
    this.lastProgressTime = Date.now()
    this.progressWatchdogArmed = true
    this.tickProgressWatchdog()
  }

  tickProgressWatchdog() {
    this.progressWatchdogTimer = setTimeout(() => {
      this.progressWatchdogTimer = null
      this.checkProgressStall()
      if (this.progressWatchdogArmed) this.tickProgressWatchdog()
    }, PROGRESS_WATCHDOG_INTERVAL_MS)
  }

  checkProgressStall() {
    if (!this.progressWatchdogArmed) return
    if (this.streamRecoveryActive || this.isSeeking) return
    // A deliberate user pause is not a stall — the watchdog is
    // disarmed in togglePlay, but guard anyway in case it was armed
    // by onVideoReady before the pause landed.
    if (this.userPaused) return
    // Only meaningful while the video is supposedly playing.
    if (this.videoTarget.paused || this.videoTarget.ended) return
    // Don't count a stall before playback has actually begun.
    if (!this.playbackStarted) return

    const now = Date.now()
    const pos = this.videoTarget.currentTime
    const elapsed = now - this.lastProgressTime

    // currentTime advanced → playback is alive.  Reset the baseline.
    if (pos > this.lastProgressPosition + 0.1) {
      this.lastProgressPosition = pos
      this.lastProgressTime = now
      return
    }

    // currentTime has not advanced since the last tick.  If this has
    // persisted longer than the threshold, treat it as a silent stall.
    // The watchdog is only armed once the video is actually playing
    // (onVideoReady), so the initial buffer-fill window is excluded.
    if (elapsed >= PROGRESS_STALL_TIMEOUT_MS) {
      console.warn(`Silent freeze detected — currentTime stuck at ${pos} for ${Math.round(elapsed / 1000)}s`)
      this.progressWatchdogArmed = false
      if (this.isHls()) {
        this.handleHlsStall()
      } else {
        this.handleStreamStall()
      }
    }
  }

  resetProgressBaseline() {
    if (!this.progressWatchdogArmed) return
    this.lastProgressPosition = this.videoTarget.currentTime
    this.lastProgressTime = Date.now()
  }

  stopProgressWatchdog() {
    this.progressWatchdogArmed = false
    if (this.progressWatchdogTimer) {
      clearTimeout(this.progressWatchdogTimer)
      this.progressWatchdogTimer = null
    }
  }

  // Called when the stall watchdog fires — the video element has been
  // waiting for data longer than STREAM_STALL_TIMEOUT_MS. Aborts the
  // current fetch and reconnects from the current playback position,
  // up to STREAM_MAX_RECOVERY_ATTEMPTS times.
  handleStreamStall() {
    // Never trigger recovery while the user has deliberately paused.
    // The stall watchdog and progress watchdog can fire long after a
    // user pause (60s/30s), and reconnectFromCurrentPosition resets
    // userPaused=false via setupMseSource — which would auto-resume
    // playback the user explicitly paused.
    if (this.userPaused) {
      this.clearStallWatchdog()
      this.stopProgressWatchdog()
      return
    }
    if (this.isHls()) return  // iOS HLS handles its own recovery
    if (this.streamRecoveryActive) return
    if (this.streamRecoveryAttempts >= STREAM_MAX_RECOVERY_ATTEMPTS) {
      console.warn("Stream recovery limit reached — giving up.")
      this.showSeekingOverlay("Stream stalled — try seeking to resume.")
      return
    }

    this.streamRecoveryAttempts += 1
    this.streamRecoveryActive = true
    console.warn(`Stream stalled — recovering (attempt ${this.streamRecoveryAttempts}/${STREAM_MAX_RECOVERY_ATTEMPTS})`)
    this.reconnectFromCurrentPosition()
  }

  // HLS stall recovery (iOS).  When the progress watchdog detects
  // that currentTime has frozen for PROGRESS_STALL_TIMEOUT_MS while
  // the video is supposedly playing, the ffmpeg HLS process has
  // likely died or the upstream source stalled.  Restart the HLS
  // transcode from the current playback position — the same path a
  // user seek takes — so playback resumes instead of hanging on a
  // frozen frame or "Buffering" forever.
  handleHlsStall() {
    if (this.userPaused) return
    if (this.isSeeking) return
    if (this.streamRecoveryAttempts >= STREAM_MAX_RECOVERY_ATTEMPTS) {
      console.warn("HLS recovery limit reached — giving up.")
      this.showSeekingOverlay("Stream stalled — tap to retry")
      const overlay = this.seekingOverlayTarget
      const onRetry = () => {
        overlay.removeEventListener("click", onRetry)
        this.hideSeekingOverlay()
        this.streamRecoveryAttempts = 0
        this.handleHlsStall()
      }
      overlay.addEventListener("click", onRetry)
      return
    }

    this.streamRecoveryAttempts += 1
    console.warn(`HLS stall detected — restarting session (attempt ${this.streamRecoveryAttempts}/${STREAM_MAX_RECOVERY_ATTEMPTS})`)
    const targetSeconds = Math.floor(this.currentPlaybackPosition())
    this.isSeeking = true
    this.showSeekingOverlay("Reconnecting...")
    this.clearSubtitleCues()
    this.restartHlsSession(targetSeconds)
  }

  // Called when the server closes the stream response early (done=true)
  // while the video still has content to play.
  //
  // For a slow remote source, ffmpeg transcodes a burst, the upstream
  // stalls, and ffmpeg exits — this is normal.  The MSE buffer may
  // still have plenty of data to keep the video playing for a while.
  // Reconnecting immediately would discard that buffer and restart from
  // the current position, creating a stuttering cycle.
  //
  // Instead, we do nothing here.  The video keeps playing from the
  // buffer.  If the buffer eventually runs dry, the stall watchdog
  // (60s of no data) handles reconnection from the current position.
  // If the video reaches the end naturally, onVideoEnded handles it.
  handlePrematureStreamEnd() {
    // Only trigger recovery if we're near the end (no more content
    // to play) AND the fetch ended — that's a genuine end-of-stream.
    if (this.knownDuration > 0) {
      const currentPos = this.currentPlaybackPosition()
      if (currentPos >= this.knownDuration - 5) return
    }

    // If playback never started (or there's no buffered data), there
    // is no buffer to play through — waiting would hang forever.
    // Recover immediately instead.
    if (!this.playbackStarted || !this.sourceBuffer || this.sourceBuffer.buffered.length === 0) {
      console.warn("Stream fetch ended early with no buffer — recovering.")
      this.handleStreamStall()
      return
    }

    // Not near the end — the fetch ended but we may have buffered data.
    // Don't reconnect; let the video play through the buffer.  The
    // stall watchdog will reconnect if the buffer truly runs dry.
    console.warn("Stream fetch ended early — continuing from buffer.")
  }

  // Abort the current fetch, tear down the MSE pipeline, and restart
  // from the current playback position. This is the same machinery
  // a manual seek uses, but triggered automatically by the watchdog.
  //
  // The recovery *attempt counter* is preserved across the restart so
  // repeated stalls eventually give up (STREAM_MAX_RECOVERY_ATTEMPTS)
  // instead of looping forever.  The *active* flag is NOT preserved:
  // restartPlaybackAt and setupMseSource already clear it, and
  // restoring it to true afterwards would permanently block all
  // further recovery if the reconnect fetch produces no data (the
  reconnectFromCurrentPosition() {
    const targetSeconds = Math.floor(this.currentPlaybackPosition())
    const savedAttempts = this.streamRecoveryAttempts

    // Don't show the "Seeking..." overlay for automatic recovery —
    // it sets isSeeking=true which blocks the seek bar and shows a
    // jarring "Seeking" message for what is actually a rebuffer.
    // Instead, keep the existing "Buffering..." overlay (already
    // shown by showBufferingOverlay, which has pointer-events-none).
    // We only set isSeeking + show "Seeking..." for explicit user
    // seeks (performSeek → restartPlaybackAt).
    this.streamRecoveryAttempts = 0
    this.streamRecoveryActive = false
    this.startSecondsValue = targetSeconds
    this.element.dataset.videoPlayerStartSecondsValue = targetSeconds.toString()

    const url = new URL(this.streamingUrlValue, window.location.origin)
    if (targetSeconds > 0) {
      url.searchParams.set("start_seconds", targetSeconds)
    } else {
      url.searchParams.delete("start_seconds")
    }

    if (this.selectedAudioStream) {
      url.searchParams.set("audio_stream", this.selectedAudioStream)
    } else {
      url.searchParams.delete("audio_stream")
    }

    if (this.burnedSubtitleSelected()) {
      url.searchParams.set("subtitle_stream", this.selectedSubtitleStream)
    } else {
      url.searchParams.delete("subtitle_stream")
    }

    const nextSrc = url.pathname + url.search
    this.streamingUrlValue = nextSrc
    this.element.dataset.videoPlayerStreamingUrlValue = nextSrc

    this.setupMseSource(nextSrc)

    this.clearSubtitleCues()
    this.streamRecoveryAttempts = savedAttempts
  }

  queueBufferChunk(chunk) {
    this.bufferQueue.push(chunk)
    this.flushBufferQueue()
  }

  flushBufferQueue() {
    if (this.bufferAppending || !this.sourceBuffer || this.sourceBuffer.updating) return
    if (this.bufferQueue.length === 0) return
    this.bufferAppending = true
    const chunk = this.bufferQueue.shift()
    try {
      this.sourceBuffer.appendBuffer(chunk)
    } catch (e) {
      this.bufferAppending = false
      if (e.name === "QuotaExceededError") {
        this.evictOldBuffer()
      } else {
        // Any other append error (InvalidStateError from a closed
        // MediaSource, parse error on a malformed fragment) means the
        // current MSE pipeline is broken. Clear the queue and trigger
        // a full reconnect from the current playback position.
        console.warn("appendBuffer failed, recovering:", e.name)
        this.bufferQueue = []
        this.handleStreamStall()
      }
    }
  }

  onBufferUpdateEnd() {
    this.bufferAppending = false
    this.evictOldBuffer()
    // Data arrived — the fetch is alive.  Restart the stall watchdog.
    // If the video is paused (rebuffering), use the shorter timeout so
    // trickling data doesn't keep resetting the 60s timer indefinitely —
    // the rebuffer gate may never reach REBUFFER_AHEAD_SECONDS on a
    // slow source, and the shorter timeout triggers recovery sooner.
    // If the video is playing, use the default 60s.
    const stalled = this.videoTarget.paused && !this.userPaused && this.playbackStarted
    this.startStallWatchdog(stalled ? REBUFFER_STALL_TIMEOUT_MS : STREAM_STALL_TIMEOUT_MS)
    this.resetProgressBaseline()
    this.maybeStartPlayback()
    this.flushBufferQueue()
  }

  // Start (or resume) playback once the buffer holds at least
  // BUFFER_AHEAD_SECONDS ahead of the current position.  This runs on
  // every appendBuffer completion — not just the initial start — so it
  // also gates rebuffering: when the video stalls (buffer ran dry),
  // it stays paused until enough data accumulates to sustain playback
  // for a while, rather than resuming on a trickle and immediately
  // re-stalling.
  //
  // For the initial start, a max-wait deadline (BUFFER_AHEAD_MAX_WAIT_MS
  // from the first chunk) ensures we don't stall forever on a very slow
  // source: if the threshold isn't reached in time, we start with
  // whatever we have.
  maybeStartPlayback() {
    if (!this.sourceBuffer || this.sourceBuffer.buffered.length === 0) return

    const bufferedEnd = this.sourceBuffer.buffered.end(this.sourceBuffer.buffered.length - 1)
    const bufferedAhead = bufferedEnd - this.videoTarget.currentTime

    // Initial start: wait for the buffer-ahead threshold (or deadline).
    if (!this.playbackStarted) {
      const deadlineReached = this.bufferAheadDeadline && Date.now() >= this.bufferAheadDeadline
      if (bufferedAhead >= BUFFER_AHEAD_SECONDS || deadlineReached) {
        this.playbackStarted = true
        this.bufferAheadDeadline = null
        const p = this.videoTarget.play()
        if (p?.catch) p.catch(() => {})
      }
      return
    }

    // Rebuffering: the video paused because the buffer ran dry.
    // Resume only when enough buffer has accumulated to sustain playback
    // for a while (REBUFFER_AHEAD_SECONDS).  Resuming with a tiny buffer
    // (bufferedAhead > 0) causes a rapid stall-resume-stall cycle when
    // ffmpeg transcodes below 1× — the video plays for a fraction of a
    // second, stalls again, and the user sees periodic black screen.
    // A rebuffer deadline (REBUFFER_MAX_WAIT_MS) ensures we don't sit on
    // "Buffering" forever on a very slow source — after the deadline,
    // resume with whatever we have.
    // Never auto-resume a deliberate user pause (button/spacebar): the
    // Rebuffering: the buffer ran dry and the video stalled.
    // In Chrome, the video element does NOT set paused=true when the
    // MSE buffer runs dry — it stays "playing" but frozen (currentTime
    // stops advancing).  So we can't rely on paused to detect a rebuffer
    // stall.  Instead, use the isStalled flag set by onVideoWaiting.
    // Resume only when enough buffer has accumulated (REBUFFER_AHEAD_SECONDS).
    // A rebuffer deadline ensures we don't sit on "Buffering" forever
    // on a very slow source.
    // Never auto-resume a deliberate user pause (userPaused) or while a
    // subtitle load holds playback (isSeeking).
    if (this.isStalled && !this.videoTarget.ended && !this.userPaused && !this.isSeeking) {
      const deadlineReached = this.rebufferDeadline && Date.now() >= this.rebufferDeadline
      if (bufferedAhead >= REBUFFER_AHEAD_SECONDS || deadlineReached) {
        this.rebufferDeadline = null
        this.isStalled = false
        const p = this.videoTarget.play()
        if (p?.catch) p.catch(() => {})
      }
    }
  }

  evictOldBuffer() {
    if (!this.sourceBuffer || this.sourceBuffer.updating) return
    const evictBefore = this.videoTarget.currentTime - 30
    if (evictBefore <= 0) return
    for (let i = 0; i < this.sourceBuffer.buffered.length; i++) {
      const start = this.sourceBuffer.buffered.start(i)
      const end = this.sourceBuffer.buffered.end(i)
      if (start < evictBefore) {
        try { this.sourceBuffer.remove(start, Math.min(end, evictBefore)) } catch {}
        return
      }
    }
  }

  // ── Play / pause ──────────────────────────────────────────────────

  togglePlay() {
    if (this.videoTarget.paused) {
      this.userPaused = false
      const playPromise = this.videoTarget.play()
      if (playPromise?.catch) playPromise.catch(() => {})
    } else {
      this.userPaused = true
      this.videoTarget.pause()
      // A deliberate pause must not be auto-resumed by the stall or
      // progress watchdogs firing later, nor by the rebuffer deadline.
      // Clear them so the video stays paused until the user resumes.
      this.clearStallWatchdog()
      this.stopProgressWatchdog()
      this.isStalled = false
      this.rebufferDeadline = null
    }
  }
  onVideoClick(event) {
    event.preventDefault()
    this.togglePlay()
    this.showOverlayUi()
  }

  onKeyDown(event) {
    if (event.key !== " " && event.key !== "Spacebar") return
    if (event.repeat || this.isInteractiveElement(event.target)) return

    event.preventDefault()
    this.togglePlay()
    this.showOverlayUi()
  }

  isInteractiveElement(element) {
    return element instanceof Element && element.closest(INTERACTIVE_SELECTOR)
  }

  navigateBack(event) {
    event.preventDefault()
    event.stopImmediatePropagation()
    const href = event.currentTarget.href
    this.stopPlaybackForNavigation()
    window.location.href = href
  }

  // Tear down playback before navigating away.  The ONLY thing that
  // must happen synchronously is aborting the fetch so the backend
  // kills ffmpeg (TranscodeService ensure block on ClientDisconnected).
  // The video element teardown (pause, revokeObjectURL, src="", load)
  // is skipped: it forces a synchronous media-engine pipeline flush
  // that blocks the main thread for a noticeable moment — especially
  // with a deep MSE buffer and hardware decoding — and the page is
  // being destroyed anyway.  The beforeunload handler is skipped to
  // avoid a duplicate save (navigateBack already saved).
  stopPlaybackForNavigation() {
    this.stopHlsSession()
    this.stopProgressTracking()
    this.saveProgressSync()
    this.navigatingAway = true
    if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
    this.bufferQueue = []
  }

  // Auto-advance to the next episode when the current one finishes.
  // Only applies to shows — movies just stop (progress already saved).
  async onVideoEnded() {
    if (this.typeValue !== "show") return

    // Flush final progress so the finished episode crosses 95%.
    await this.saveProgress()

    if (this.resumeUrlValue) {
      const url = `${this.resumeUrlValue}?type=show&show_imdb_id=${encodeURIComponent(this.imdbIdValue)}`
      window.location.href = url
    }
  }

  onVideoError(e) {
    const video = this.videoTarget
    const err = video.error
    if (!err) return

    console.error("Video error:", {
      code: err.code,
      message: err.message,
      src: video.src,
      currentSrc: video.currentSrc,
      readyState: video.readyState,
      networkState: video.networkState,
      isHls: this.isHls()
    })

    if (this.isHls()) {
      // In HLS mode, a media error usually means the playlist or
      // segments can't be loaded/decoded.  Show an error message
      // instead of leaving the user on a black screen.
      this.showSeekingOverlay("Stream error — tap to retry")
      const overlay = this.seekingOverlayTarget
      const onRetry = () => {
        overlay.removeEventListener("click", onRetry)
        this.hideSeekingOverlay()
        // Reload the playlist
        if (this.hlsSessionId) {
          video.load()
          video.play().catch(() => {})
        } else {
          this.startHlsPlayback()
        }
      }
      overlay.addEventListener("click", onRetry)
    }
  }

  pauseAndDetachVideo() {
    if (!this.hasVideoTarget) return
    try {
      if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
      this.bufferQueue = []
      if (this.mediaSource) {
        if (this.mediaSource.readyState === "open") { try { this.mediaSource.endOfStream() } catch {} }
        this.mediaSource = null
        this.sourceBuffer = null
      }
      this.videoTarget.pause()
      if (this.videoTarget.src.startsWith("blob:")) URL.revokeObjectURL(this.videoTarget.src)
      this.videoTarget.src = ""
      this.videoTarget.removeAttribute("src")
      this.videoTarget.load()
    } catch {}
  }

  updatePlayIcon() {
    if (this.videoTarget.paused) {
      this.playIconTarget.classList.remove("hidden")
      this.pauseIconTarget.classList.add("hidden")
      // Disarm the progress watchdog on a deliberate pause —
      // currentTime won't advance, but this is not a stall.
      this.stopProgressWatchdog()
    } else {
      this.playIconTarget.classList.add("hidden")
      this.pauseIconTarget.classList.remove("hidden")
      // Re-arm on resume (also covers recovery from a rebuffer pause
      // gated by maybeStartPlayback).
      this.startProgressWatchdog()
    }
  }

  onVideoReady() {
    // Only hide overlays and cancel the watchdog when the video is
    // actually playing.  If the video is paused (deliberate rebuffer
    // gate in maybeStartPlayback), don't interfere — the "Buffering..."
    // overlay should stay visible until we resume playback.
    if (this.videoTarget.paused) return

    // Don't hide the overlay if the buffer is critically low.  Chrome
    // fires "playing" on a tiny trickle of data, then immediately
    // stalls again — if we hide the overlay here, the user sees a
    // rapid freeze-resume-freeze cycle with no spinner.  Keep the
    // overlay visible until there's at least 2s of buffer ahead.
    if (!this.hasBufferedAhead(2)) return

    // Cancel a pending buffering-overlay debounce — the video resumed
    // before the 200ms delay elapsed, so no overlay should be shown.
    clearTimeout(this.bufferingOverlayTimer)
    this.bufferingOverlayTimer = null
    this.isStalled = false
    this.clearStallWatchdog()
    // Playback is actually playing — any stall recovery succeeded
    // (or this is a fresh start).  Reset the attempt counter so a
    // future stall gets a fresh quota instead of being permanently
    // blocked by prior failures.
    this.streamRecoveryAttempts = 0
    this.streamRecoveryActive = false
    this.startProgressWatchdog()
    this.hideSeekingOverlay()
    this.hideStartupOverlay()
  }

  syncStartupOverlay() {
    if (!this.hasStartupOverlayTarget) return

    if (!this.videoTarget.paused && this.videoTarget.currentTime > 0) {
      this.hideStartupOverlay()
      return
    }

    this.clearStartupOverlayTimer()
    this.startupOverlayHideTimer = setTimeout(() => {
      if (!this.hasVideoTarget) return
      if (!this.videoTarget.paused && this.videoTarget.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
        this.hideStartupOverlay()
      }
    }, 0)
  }

  hideStartupOverlay() {
    if (!this.hasStartupOverlayTarget) return

    this.startupOverlayTarget.classList.add("opacity-0", "pointer-events-none")
    this.startupOverlayTarget.setAttribute("aria-hidden", "true")
    this.clearStartupOverlayTimer()
    this.startupOverlayHideTimer = setTimeout(() => {
      if (this.hasStartupOverlayTarget) this.startupOverlayTarget.classList.add("hidden")
    }, 220)
  }

  clearStartupOverlayTimer() {
    if (!this.startupOverlayHideTimer) return

    clearTimeout(this.startupOverlayHideTimer)
    this.startupOverlayHideTimer = null
  }

  // ── Volume / mute ─────────────────────────────────────────────────

  toggleMute() {
    this.videoTarget.muted = !this.videoTarget.muted
  }

  updateVolumeIcon() {
    if (this.videoTarget.muted || this.videoTarget.volume === 0) {
      this.volumeIconTarget.classList.add("hidden")
      this.muteIconTarget.classList.remove("hidden")
    } else {
      this.volumeIconTarget.classList.remove("hidden")
      this.muteIconTarget.classList.add("hidden")
    }
  }

  // ── Audio / subtitles ─────────────────────────────────────────────

  async loadMediaTracks() {
    if (!this.hasTracksUrlValue) return

    const rawUrl = this.extractRawUrl()
    if (!rawUrl) return

    try {
      const url = new URL(this.tracksUrlValue, window.location.origin)
      url.searchParams.set("url", rawUrl)
      this.addContentMetadataParams(url)
      const response = await fetch(url.pathname + url.search, { headers: { "Accept": "application/json" } })
      if (!response.ok) return

      const data = await response.json()
      this.audioTracks = Array.isArray(data.audio) ? data.audio : []
      this.subtitleTracks = Array.isArray(data.subtitles) ? data.subtitles : []
      this.selectedAudioStream ||= this.preferredAudioTrack()?.index?.toString() || null
      if (this.selectedSubtitleStream && !this.subtitleTrackForStream(this.selectedSubtitleStream)) {
        this.selectedSubtitleStream = null
      }
      this.renderTrackControls()
      if (this.textSubtitleSelected()) this.loadSubtitleTrack(this.currentPlaybackPosition(), {
        durationSeconds: SUBTITLE_STARTUP_WINDOW_SECONDS,
        lookBehindSeconds: SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS,
        holdPlayback: true
      })
    } catch (e) {
      console.warn("Track probe failed:", e)
    }
  }

  preferredAudioTrack() {
    const languagePriority = this.languagePriority()
    const preferredTracks = this.audioTracks
      .filter((track) => languagePriority.includes(track.language))
      .sort((a, b) => {
        const languageDelta = languagePriority.indexOf(a.language) - languagePriority.indexOf(b.language)
        if (languageDelta !== 0) return languageDelta
        return Number(a.position || 0) - Number(b.position || 0)
      })

    return preferredTracks[0] || this.audioTracks.find((track) => track.default) || this.audioTracks[0]
  }

  languagePriority() {
    const languages = [this.defaultLanguageValue, ...this.preferredLanguages()]
    return [...new Set(languages.map((language) => language?.toString().toUpperCase()).filter(Boolean))]
  }

  preferredLanguages() {
    try {
      const parsed = JSON.parse(this.preferredLanguagesValue || "[]")
      return Array.isArray(parsed) ? parsed : []
    } catch {
      return []
    }
  }

  renderTrackControls() {
    this.renderAudioControls()
    this.renderSubtitleControls()
  }

  renderAudioControls() {
    if (!this.hasAudioControlsTarget || !this.hasAudioOptionsTarget) return
    if (this.audioTracks.length <= 1) {
      this.audioControlsTarget.classList.add("hidden")
      return
    }

    this.audioControlsTarget.classList.remove("hidden")
    this.audioOptionsTarget.replaceChildren()
    this.audioTracks.forEach((track) => {
      this.audioOptionsTarget.appendChild(this.trackOptionButton({
        label: track.label || "Audio",
        selected: track.index?.toString() === this.selectedAudioStream,
        datasetName: "audioStream",
        datasetValue: track.index,
        action: "click->video-player#selectAudioTrack"
      }))
    })
    this.updateAudioButtonLabel()
  }

  renderSubtitleControls() {
    if (!this.hasSubtitleControlsTarget || !this.hasSubtitleOptionsTarget) return
    if (this.subtitleTracks.length === 0) {
      this.subtitleControlsTarget.classList.add("hidden")
      return
    }

    this.subtitleControlsTarget.classList.remove("hidden")
    this.subtitleOptionsTarget.replaceChildren()
    this.subtitleOptionsTarget.appendChild(this.trackOptionButton({
      label: "Off",
      selected: !this.selectedSubtitleStream,
      datasetName: "subtitleStream",
      datasetValue: "",
      action: "click->video-player#selectSubtitleTrack"
    }))

    this.subtitleTracks.forEach((track) => {
      this.subtitleOptionsTarget.appendChild(this.trackOptionButton({
        label: track.label || "Subtitle",
        selected: track.index?.toString() === this.selectedSubtitleStream,
        datasetName: "subtitleStream",
        datasetValue: track.index,
        action: track.external === true
          ? "click->video-player#selectSubtitleTrack pointerenter->video-player#prefetchSubtitleTrack focus->video-player#prefetchSubtitleTrack"
          : "click->video-player#selectSubtitleTrack"
      }))
    })
    this.updateSubtitleButtonLabel()
  }

  trackOptionButton({ label, selected, datasetName, datasetValue, action }) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = `block w-full text-left px-2 py-1.5 rounded transition-colors ${selected ? "bg-sv-accent text-white" : "hover:bg-sv-surface-hover text-sv-text-muted hover:text-white"}`
    button.dataset[datasetName] = datasetValue?.toString() || ""
    button.dataset.action = action
    button.textContent = label
    return button
  }

  selectAudioTrack(event) {
    const selectedStream = event.currentTarget.dataset.audioStream
    if (!selectedStream || selectedStream === this.selectedAudioStream) {
      this.closeTrackMenus()
      return
    }

    this.selectedAudioStream = selectedStream
    this.renderAudioControls()
    this.closeTrackMenus()

    const targetSeconds = Math.floor(this.videoTarget.currentTime + this.startSecondsValue)
    this.restartPlaybackAt(targetSeconds)
  }

  selectSubtitleTrack(event) {
    const previousBurnedSubtitle = this.burnedSubtitleSelected()
    const selectedStream = event.currentTarget.dataset.subtitleStream || null
    if (selectedStream === this.selectedSubtitleStream) {
      this.closeTrackMenus()
      return
    }

    this.selectedSubtitleStream = selectedStream
    this.subtitleRetryAfter = 0
    this.clearSubtitleCues()
    this.renderSubtitleControls()
    this.closeTrackMenus()

    const targetSeconds = Math.floor(this.currentPlaybackPosition())
    if (previousBurnedSubtitle || this.burnedSubtitleSelected()) {
      this.restartPlaybackAt(targetSeconds)
    } else if (this.textSubtitleSelected()) {
      this.loadSubtitleTrack(targetSeconds, {
        durationSeconds: SUBTITLE_STARTUP_WINDOW_SECONDS,
        lookBehindSeconds: SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS,
        holdPlayback: true
      })
    }
  }

  currentPlaybackPosition() {
    return this.videoTarget.currentTime + this.startSecondsValue
  }

  selectedSubtitleTrack() {
    if (!this.selectedSubtitleStream) return null

    return this.subtitleTrackForStream(this.selectedSubtitleStream)
  }

  subtitleTrackForStream(subtitleStream) {
    if (!subtitleStream) return null

    return this.subtitleTracks.find((track) => track.index?.toString() === subtitleStream) || null
  }

  textSubtitleSelected() {
    return this.selectedSubtitleTrack()?.text_supported === true
  }

  burnedSubtitleSelected() {
    if (!this.selectedSubtitleStream) return false

    const track = this.selectedSubtitleTrack()
    return !track || track.text_supported !== true
  }

  externalSubtitleSelected() {
    return this.selectedSubtitleTrack()?.external === true
  }

  prefetchSubtitleTrack(event) {
    this.prefetchSubtitleStream(event.currentTarget.dataset.subtitleStream)
  }

  prefetchLikelyExternalSubtitle() {
    const selectedTrack = this.subtitleTrackForStream(this.selectedSubtitleStream)
    const track = selectedTrack?.external === true ? selectedTrack : this.subtitleTracks.find((candidate) => candidate.external === true)
    this.prefetchSubtitleStream(track?.index?.toString())
  }

  prefetchSubtitleStream(subtitleStream) {
    const track = this.subtitleTrackForStream(subtitleStream)
    if (track?.external !== true) return

    const rawUrl = this.extractRawUrl()
    if (!rawUrl) return

    const durationSeconds = EXTERNAL_SUBTITLE_WINDOW_SECONDS
    const windowStart = Math.max(
      0,
      Math.floor(this.currentPlaybackPosition()) - this.subtitleLookBehind(SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS, durationSeconds)
    )
    const requestKey = this.subtitleRequestKey(subtitleStream, windowStart, durationSeconds)
    if (this.subtitlePrefetchResults.has(requestKey) || this.subtitlePrefetches.has(requestKey)) return

    const url = this.subtitleRequestUrl(rawUrl, subtitleStream, windowStart, durationSeconds)
    const prefetch = this.fetchSubtitleResponse(url)
      .then((response) => {
        this.rememberPrefetchedSubtitleResponse(requestKey, response)
        return response
      })
      .catch(() => null)
      .finally(() => this.subtitlePrefetches.delete(requestKey))

    this.subtitlePrefetches.set(requestKey, prefetch)
  }

  addContentMetadataParams(url) {
    const params = {
      imdb_id: this.imdbIdValue,
      type: this.typeValue,
      season: this.seasonValue,
      episode: this.episodeValue,
      title: this.titleValue,
      filename: this.filenameValue
    }

    Object.entries(params).forEach(([key, value]) => {
      if (value === undefined || value === null || value.toString() === "") return

      url.searchParams.set(key, value.toString())
    })
  }

  async loadSubtitleTrack(
    currentPosition = this.currentPlaybackPosition(),
    {
      durationSeconds = SUBTITLE_WINDOW_SECONDS,
      lookBehindSeconds = SUBTITLE_LOOK_BEHIND_SECONDS,
      holdPlayback = false
    } = {}
  ) {
    if (!this.hasSubtitlesUrlValue || !this.textSubtitleSelected()) return

    const rawUrl = this.extractRawUrl()
    if (!rawUrl) return

    const requestedSubtitleStream = this.selectedSubtitleStream
    const externalSubtitle = this.externalSubtitleSelected()
    const requestedDurationSeconds = externalSubtitle ? EXTERNAL_SUBTITLE_WINDOW_SECONDS : this.subtitleWindowDuration(durationSeconds)
    const shouldPrimeContinuation = !externalSubtitle && requestedDurationSeconds < SUBTITLE_WINDOW_SECONDS
    const windowStart = Math.max(0, Math.floor(currentPosition) - this.subtitleLookBehind(lookBehindSeconds, requestedDurationSeconds))
    if (this.subtitleLoading && this.subtitleWindowStart === windowStart) return

    const loadToken = this.subtitleLoadToken + 1
    this.subtitleLoadToken = loadToken
    this.subtitleLoading = true
    this.subtitleWindowStart = windowStart
    this.subtitleWindowEnd = windowStart + requestedDurationSeconds
    this.abortSubtitleLoad()
    const abortController = new AbortController()
    this.subtitleAbortController = abortController
    this.beginSubtitlePlaybackHold(holdPlayback, loadToken)

    const requestKey = this.subtitleRequestKey(requestedSubtitleStream, windowStart, requestedDurationSeconds)
    const cachedPrefetch = this.subtitlePrefetchResults.get(requestKey)
    const pendingPrefetch = this.subtitlePrefetches.get(requestKey)
    const url = this.subtitleRequestUrl(rawUrl, requestedSubtitleStream, windowStart, requestedDurationSeconds)

    try {
      const prefetchedResponse = cachedPrefetch || (pendingPrefetch ? await pendingPrefetch : null)
      const response = prefetchedResponse || await this.fetchSubtitleResponse(url, abortController.signal)
      if (this.selectedSubtitleStream !== requestedSubtitleStream || this.subtitleLoadToken !== loadToken) return
      this.applySubtitleResponse(response, windowStart)
    } catch (e) {
      if (e.name === "AbortError") return

      console.warn("Subtitle load failed:", e)
      this.resetSubtitleWindow()
      this.scheduleSubtitleRetry()
    } finally {
      const requestStillCurrent = this.subtitleLoadToken === loadToken
      if (requestStillCurrent) this.subtitleLoading = false
      if (this.subtitleAbortController === abortController) this.subtitleAbortController = null
      this.finishSubtitlePlaybackHold(loadToken)
      if (requestStillCurrent && shouldPrimeContinuation) this.primeSubtitleContinuation(requestedSubtitleStream)
    }
  }

  subtitleRequestUrl(rawUrl, subtitleStream, windowStart, durationSeconds) {
    const url = new URL(this.subtitlesUrlValue, window.location.origin)
    url.searchParams.set("url", rawUrl)
    url.searchParams.set("subtitle_stream", subtitleStream)
    url.searchParams.set("start_seconds", windowStart.toString())
    url.searchParams.set("duration_seconds", durationSeconds.toString())
    return url
  }

  subtitleRequestKey(subtitleStream, windowStart, durationSeconds) {
    return `${subtitleStream}:${windowStart}:${durationSeconds}`
  }

  async fetchSubtitleResponse(url, signal) {
    const response = await fetch(url.pathname + url.search, {
      headers: { "Accept": "text/vtt" },
      signal
    })
    const text = response.status === 204 ? "" : await response.text()
    return { ok: response.ok, status: response.status, text }
  }

  rememberPrefetchedSubtitleResponse(requestKey, response) {
    if (!response) return

    this.subtitlePrefetchResults.set(requestKey, response)
    while (this.subtitlePrefetchResults.size > 8) {
      this.subtitlePrefetchResults.delete(this.subtitlePrefetchResults.keys().next().value)
    }
  }

  applySubtitleResponse(response, windowStart) {
    if (response.status === 204) {
      this.subtitleRetryAfter = 0
      this.subtitleCues = this.pruneSubtitleCues(this.subtitleCues, this.currentPlaybackPosition())
      this.updateSubtitleOverlay(this.currentPlaybackPosition())
      return
    }

    if (!response.ok) {
      this.resetSubtitleWindow()
      this.scheduleSubtitleRetry()
      return
    }

    const incomingCues = this.parseWebVtt(response.text, windowStart)
    this.subtitleCues = this.mergeSubtitleCues(this.subtitleCues, incomingCues, this.currentPlaybackPosition())
    this.subtitleRetryAfter = 0
    this.updateSubtitleOverlay(this.currentPlaybackPosition())
  }

  beginSubtitlePlaybackHold(holdPlayback, loadToken) {
    if (!holdPlayback || this.videoTarget.paused || this.videoTarget.ended) return

    this.subtitlePlaybackHoldToken = loadToken
    this.isSeeking = true
    this.videoTarget.pause()
    this.showSeekingOverlay("Loading subtitles...")
  }

  finishSubtitlePlaybackHold(loadToken) {
    if (this.subtitlePlaybackHoldToken !== loadToken) return

    this.subtitlePlaybackHoldToken = null
    this.hideSeekingOverlay()
    // Only resume if the stall was caused by the subtitle hold, not by
    // the user pausing in the meantime.  Without this check, a subtitle
    // load completing while the user has paused would auto-resume.
    if (this.userPaused) return
    const playPromise = this.videoTarget.play()
    if (playPromise?.catch) playPromise.catch(() => {})
  }

  removeTextSubtitleTrack() {
    this.subtitleLoadToken += 1
    this.abortSubtitleLoad()
    this.clearSubtitleCues()
    this.subtitleWindowStart = null
    this.subtitleWindowEnd = null
    this.subtitleLoading = false
    this.subtitleRetryAfter = 0
  }

  resetSubtitleWindow() {
    this.subtitleWindowStart = null
    this.subtitleWindowEnd = null
  }

  subtitleWindowDuration(value) {
    const seconds = Number(value)
    if (!Number.isFinite(seconds) || seconds <= 0) return SUBTITLE_WINDOW_SECONDS

    return Math.max(SUBTITLE_STARTUP_WINDOW_SECONDS, Math.min(60, Math.floor(seconds)))
  }

  subtitleLookBehind(value, durationSeconds) {
    const seconds = Number(value)
    const lookBehindSeconds = Number.isFinite(seconds) && seconds >= 0 ? Math.floor(seconds) : SUBTITLE_LOOK_BEHIND_SECONDS

    return Math.min(lookBehindSeconds, Math.max(0, durationSeconds - 1))
  }

  scheduleSubtitleRetry(delayMs = 5000) {
    this.subtitleRetryAfter = Date.now() + delayMs
  }

  primeSubtitleContinuation(requestedSubtitleStream) {
    if (this.subtitleRetryAfter) return
    if (this.subtitleWindowEnd === null) return
    if (this.selectedSubtitleStream !== requestedSubtitleStream) return
    if (!this.textSubtitleSelected()) return

    this.loadSubtitleTrack(this.subtitleWindowEnd, { durationSeconds: SUBTITLE_WINDOW_SECONDS })
  }

  abortSubtitleLoad() {
    if (!this.subtitleAbortController) return

    this.subtitleAbortController.abort()
    this.subtitleAbortController = null
  }

  clearSubtitleCues() {
    this.subtitleCues = []
    if (this.hasSubtitleOverlayTarget) {
      this.subtitleOverlayTarget.textContent = ""
      this.subtitleOverlayTarget.classList.add("hidden")
    }
  }

  mergeSubtitleCues(existingCues, incomingCues, currentPosition) {
    const cuesByKey = new Map()
    const keepAfter = currentPosition - 5
    const combinedCues = [...existingCues, ...incomingCues]
    combinedCues.forEach((cue) => {
      if (cue.end < keepAfter) return

      cuesByKey.set(`${cue.start}|${cue.end}|${cue.text}`, cue)
    })

    return [...cuesByKey.values()].sort((a, b) => a.start - b.start || a.end - b.end)
  }

  pruneSubtitleCues(cues, currentPosition) {
    const keepAfter = currentPosition - 5
    return cues.filter((cue) => cue.end >= keepAfter)
  }

  parseWebVtt(text, offsetSeconds = 0) {
    const cues = text
      .replace(/^\uFEFF/, "")
      .split(/\r?\n\s*\r?\n/)
      .filter((block) => block.includes("-->"))
      .map((block) => this.parseWebVttCue(block))
      .filter(Boolean)

    if (offsetSeconds <= 0 || cues.some((cue) => cue.start >= offsetSeconds - 30)) {
      return cues
    }

    return cues.map((cue) => ({
      ...cue,
      start: cue.start + offsetSeconds,
      end: cue.end + offsetSeconds
    }))
  }

  parseWebVttCue(block) {
    const lines = block.split(/\r?\n/).map((line) => line.trim()).filter(Boolean)
    const timingIndex = lines.findIndex((line) => line.includes("-->"))
    if (timingIndex < 0) return null

    const [startText, endAndSettings] = lines[timingIndex].split("-->").map((part) => part.trim())
    const endText = endAndSettings?.split(/\s+/)[0]
    const start = this.parseCueTimestamp(startText)
    const end = this.parseCueTimestamp(endText)
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return null

    const cueText = lines
      .slice(timingIndex + 1)
      .map((line) => this.cleanCueText(line))
      .join("\n")
      .trim()

    if (!cueText) return null
    return { start, end, text: cueText }
  }

  parseCueTimestamp(value) {
    const parts = value?.split(":") || []
    if (parts.length < 2 || parts.length > 3) return NaN

    const seconds = Number(parts.pop().replace(",", "."))
    const minutes = Number(parts.pop())
    const hours = parts.length === 1 ? Number(parts.pop()) : 0
    if (![hours, minutes, seconds].every(Number.isFinite)) return NaN

    return (hours * 3600) + (minutes * 60) + seconds
  }

  cleanCueText(text) {
    return text
      .replace(/<[^>]+>/g, "")
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, "\"")
      .replace(/&#39;/g, "'")
  }

  updateSubtitleOverlay(currentPos) {
    if (!this.hasSubtitleOverlayTarget) return
    this.ensureSubtitleWindow(currentPos)
    if (this.subtitleCues.length === 0) return

    const activeCues = this.subtitleCues
      .filter((cue) => currentPos >= cue.start && currentPos <= cue.end)
      .map((cue) => cue.text)

    if (activeCues.length === 0) {
      this.subtitleOverlayTarget.textContent = ""
      this.subtitleOverlayTarget.classList.add("hidden")
      return
    }

    this.subtitleOverlayTarget.textContent = activeCues.join("\n")
    this.subtitleOverlayTarget.classList.remove("hidden")
  }

  ensureSubtitleWindow(currentPos) {
    if (!this.textSubtitleSelected() || this.subtitleLoading) return
    if (this.subtitleRetryAfter && Date.now() < this.subtitleRetryAfter) return

    // Skip if we already have a window covering the current position
    if (this.subtitleWindowStart !== null && this.subtitleWindowEnd !== null &&
        currentPos >= this.subtitleWindowStart - 2 && currentPos < this.subtitleWindowEnd) return

    const missingWindow = this.subtitleWindowStart === null || this.subtitleWindowEnd === null
    const beforeWindow = !missingWindow && currentPos < this.subtitleWindowStart
    const windowLength = missingWindow ? SUBTITLE_WINDOW_SECONDS : this.subtitleWindowEnd - this.subtitleWindowStart
    const prefetchSeconds = Math.min(SUBTITLE_PREFETCH_SECONDS, Math.max(1, windowLength / 2))
    const nearWindowEnd = !missingWindow && currentPos >= this.subtitleWindowEnd - prefetchSeconds

    if (missingWindow || beforeWindow) {
      this.loadSubtitleTrack(currentPos, {
        durationSeconds: SUBTITLE_STARTUP_WINDOW_SECONDS,
        lookBehindSeconds: SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS
      })
    } else if (nearWindowEnd) {
      this.loadSubtitleTrack(this.subtitleWindowEnd, { durationSeconds: SUBTITLE_WINDOW_SECONDS })
    }
  }

  updateAudioButtonLabel() {
    if (!this.hasAudioButtonLabelTarget) return

    const selectedTrack = this.audioTracks.find((track) => track.index?.toString() === this.selectedAudioStream)
    this.audioButtonLabelTarget.textContent = selectedTrack?.language_label || "Audio"
  }

  updateSubtitleButtonLabel() {
    if (!this.hasSubtitleButtonLabelTarget) return

    const selectedTrack = this.subtitleTracks.find((track) => track.index?.toString() === this.selectedSubtitleStream)
    this.subtitleButtonLabelTarget.textContent = selectedTrack?.language_label || "CC"
  }

  toggleAudioMenu(event) {
    event.stopPropagation()
    this.toggleTrackMenu(this.audioMenuTarget, this.hasSubtitleMenuTarget ? this.subtitleMenuTarget : null)
  }

  toggleSubtitleMenu(event) {
    event.stopPropagation()
    this.toggleTrackMenu(this.subtitleMenuTarget, this.hasAudioMenuTarget ? this.audioMenuTarget : null)
    if (!this.subtitleMenuTarget.classList.contains("hidden")) this.prefetchLikelyExternalSubtitle()
  }

  toggleTrackMenu(menu, otherMenu) {
    otherMenu?.classList.add("hidden")
    menu.classList.toggle("hidden")
    this.showOverlayUi()
    if (!menu.classList.contains("hidden")) this.clearUiHideTimer()
  }

  closeTrackMenus() {
    if (this.hasAudioMenuTarget) this.audioMenuTarget.classList.add("hidden")
    if (this.hasSubtitleMenuTarget) this.subtitleMenuTarget.classList.add("hidden")
    this.scheduleUiHide()
  }

  trackMenuOpen() {
    return (this.hasAudioMenuTarget && !this.audioMenuTarget.classList.contains("hidden")) ||
      (this.hasSubtitleMenuTarget && !this.subtitleMenuTarget.classList.contains("hidden"))
  }

  onDocumentClick(event) {
    if (!this.trackMenuOpen()) return
    if (this.hasAudioControlsTarget && this.audioControlsTarget.contains(event.target)) return
    if (this.hasSubtitleControlsTarget && this.subtitleControlsTarget.contains(event.target)) return

    this.closeTrackMenus()
  }

  // ── Fullscreen ────────────────────────────────────────────────────

  toggleFullscreen() {
    // Standard Fullscreen API — works on desktop and Android.
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else if (this.element.requestFullscreen) {
      this.element.requestFullscreen()
    } else {
      // iOS Safari (including PWA standalone mode) doesn't support
      // the Fullscreen API on arbitrary elements.  Use the video
      // element's native webkitEnterFullscreen instead — it enters
      // iOS's built-in fullscreen video player.
      const video = this.videoTarget
      if (video.webkitEnterFullscreen) {
        video.webkitEnterFullscreen()
      }
    }
  }

  // ── Seek bar ──────────────────────────────────────────────────────

  // The seek bar shows the position within the full movie (not within
  // the current transcode fragment).  For transcode streams, seeking
  // restarts ffmpeg with -ss at the new position.
  seek(event) {
    if (this.suppressNextSeekClick) {
      this.suppressNextSeekClick = false
      return
    }
    if (this.isDragging) return // drag handler manages this
    const percent = this.seekPercentFromEvent(event)
    this.performSeek(percent)
  }

  startSeekDrag(event) {
    this.cancelSeekDrag()
    this.isDragging = true
    event.preventDefault()
    this.dragMoveHandler = (e) => this.onSeekDragMove(e)
    document.addEventListener("mousemove", this.dragMoveHandler)
    document.addEventListener("touchmove", this.dragMoveHandler)
  }

  onSeekDragMove(event) {
    if (!this.isDragging) return
    const percent = this.seekPercentFromEvent(event)
    this.updateSeekVisuals(percent)
  }

  stopSeekDrag(event) {
    if (!this.isDragging) return
    const percent = this.seekPercentFromEvent(event)
    this.cancelSeekDrag()
    this.suppressNextSeekClick = true
    this.clearSuppressSeekClickTimer()
    this.suppressSeekClickTimer = setTimeout(() => {
      this.suppressNextSeekClick = false
      this.suppressSeekClickTimer = null
    }, 250)
    this.performSeek(percent)
  }

  cancelSeekDrag() {
    this.isDragging = false
    if (!this.dragMoveHandler) return

    document.removeEventListener("mousemove", this.dragMoveHandler)
    document.removeEventListener("touchmove", this.dragMoveHandler)
    this.dragMoveHandler = null
  }

  clearSuppressSeekClickTimer() {
    if (!this.suppressSeekClickTimer) return

    clearTimeout(this.suppressSeekClickTimer)
    this.suppressSeekClickTimer = null
  }

  seekPercentFromEvent(event) {
    const rect = this.seekBarTarget.getBoundingClientRect()
    const point = event.changedTouches?.[0] || event.touches?.[0] || event
    const clientX = point.clientX ?? rect.left
    const percent = (clientX - rect.left) / rect.width
    return Math.max(0, Math.min(1, percent))
  }

  performSeek(percent) {
    if (this.knownDuration <= 0) return
    const targetSeconds = Math.floor(percent * this.knownDuration)
    if (targetSeconds === this.startSecondsValue) return

    if (this.isSeeking) {
      this.pendingSeekSeconds = targetSeconds
      return
    }
    this.restartPlaybackAt(targetSeconds)
    this.currentTimeTarget.textContent = this.formatTime(targetSeconds)
    this.updateSeekVisuals(targetSeconds / this.knownDuration)
  }

  restartPlaybackAt(targetSeconds) {
    // In HLS mode (iOS), seeking requires restarting the ffmpeg HLS
    // transcode with a new start_seconds.  The HLS timeline always
    // starts at 0 (ffmpeg -ss shifts the source), so setting
    // video.currentTime to an absolute position doesn't work — the
    // content at that position may not have been transcoded yet.
    // Instead: stop the current session, start a new one from the
    // target position, and set video.src to the new playlist.
    if (this.isHls()) {
      this.isSeeking = true
      this.showSeekingOverlay("Seeking...")
      this.startSecondsValue = targetSeconds
      this.element.dataset.videoPlayerStartSecondsValue = targetSeconds.toString()
      this.clearSubtitleCues()
      this.restartHlsSession(targetSeconds)
      return
    }

    this.isSeeking = true
    console.warn("[SEEK DEBUG] restartPlaybackAt called", {
      targetSeconds,
      currentTime: this.videoTarget.currentTime,
      paused: this.videoTarget.paused,
      bufferedRanges: this.bufferedRangesDebug(),
      streamRecoveryAttempts: this.streamRecoveryAttempts,
      streamRecoveryActive: this.streamRecoveryActive,
      stack: new Error().stack?.split("\n").slice(1, 4).map(s => s.trim()).join(" | ")
    })
    this.showSeekingOverlay()
    // A deliberate restart (user seek or auto-advance) resets the
    // stall-recovery counter — this is not an automatic recovery.
    this.streamRecoveryAttempts = 0
    this.streamRecoveryActive = false
    this.startSecondsValue = targetSeconds
    this.element.dataset.videoPlayerStartSecondsValue = targetSeconds.toString()

    const url = new URL(this.streamingUrlValue, window.location.origin)
    if (targetSeconds > 0) {
      url.searchParams.set("start_seconds", targetSeconds)
    } else {
      url.searchParams.delete("start_seconds")
    }

    if (this.selectedAudioStream) {
      url.searchParams.set("audio_stream", this.selectedAudioStream)
    } else {
      url.searchParams.delete("audio_stream")
    }

    if (this.burnedSubtitleSelected()) {
      url.searchParams.set("subtitle_stream", this.selectedSubtitleStream)
    } else {
      url.searchParams.delete("subtitle_stream")
    }

    const nextSrc = url.pathname + url.search
    this.streamingUrlValue = nextSrc
    this.element.dataset.videoPlayerStreamingUrlValue = nextSrc

    this.setupMseSource(nextSrc)

    this.clearSubtitleCues()
    if (this.textSubtitleSelected()) {
      this.loadSubtitleTrack(targetSeconds, {
        durationSeconds: SUBTITLE_STARTUP_WINDOW_SECONDS,
        lookBehindSeconds: SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS,
        holdPlayback: true
      })
    }
  }

  // ── Time / progress updates ───────────────────────────────────────

  onTimeUpdate() {
    const currentPos = this.videoTarget.currentTime + this.startSecondsValue
    const duration = this.effectiveDuration()

    this.currentTimeTarget.textContent = this.formatTime(currentPos)
    this.updateSubtitleOverlay(currentPos)
    if (duration > 0) {
      this.updateSeekVisuals(currentPos / duration)
    }
  }

  onProgress() {
    const video = this.videoTarget
    if (!video.buffered.length || this.knownDuration <= 0) return

    const bufferedEnd = video.buffered.end(video.buffered.length - 1)
    const totalWithOffset = bufferedEnd + this.startSecondsValue
    const percent = (totalWithOffset / this.knownDuration) * 100
    this.seekBufferedTarget.style.width = `${Math.min(100, percent)}%`
  }

  updateSeekVisuals(fraction) {
    const percent = Math.max(0, Math.min(1, fraction)) * 100
    this.seekFilledTarget.style.width = `${percent}%`
    this.seekHandleTarget.style.left = `${percent}%`
  }

  effectiveDuration() {
    if (this.knownDuration > 0) return this.knownDuration
    const d = this.videoTarget.duration
    return this.validDuration(d) ? d + this.startSecondsValue : 0
  }

  updateDurationDisplay() {
    const duration = this.effectiveDuration()
    this.durationDisplayTarget.textContent = duration > 0 ? this.formatTime(duration) : "--:--"
  }

  validDuration(seconds) {
    return Number.isFinite(seconds) && seconds >= MIN_VALID_DURATION_SECONDS
  }

  formatTime(seconds) {
    if (!seconds || !isFinite(seconds) || seconds < 0) return "0:00"
    const h = Math.floor(seconds / 3600)
    const m = Math.floor((seconds % 3600) / 60)
    const s = Math.floor(seconds % 60)
    if (h > 0) return `${h}:${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`
    return `${m}:${s.toString().padStart(2, "0")}`
  }

  // ── Seeking overlay ───────────────────────────────────────────────

  showSeekingOverlay(message = "Seeking...") {
    console.warn("[SEEK DEBUG] showSeekingOverlay called", { message, isSeeking: this.isSeeking })
    if (this.hasSeekingOverlayMessageTarget) this.seekingOverlayMessageTarget.textContent = message
    if (this.isSeeking) {
      // Seeking/error overlays ARE interactive (e.g. onVideoError
      // adds a click-to-retry handler). Remove pointer-events-none
      // that showBufferingOverlay may have set.
      this.seekingOverlayTarget.classList.remove("pointer-events-none")
      this.seekingOverlayTarget.classList.remove("hidden")
    }
  }

  bufferedRangesDebug() {
    const r = this.videoTarget.buffered
    if (!r || r.length === 0) return "empty"
    return Array.from({ length: r.length }, (_, i) =>
      `[${r.start(i).toFixed(1)}-${r.end(i).toFixed(1)}]`
    ).join(" ")
  }

  // Show the overlay with a "Buffering..." message — used when the
  // video element runs out of data mid-playback (not a user seek).
  showBufferingOverlay() {
    console.warn("[SEEK DEBUG] showBufferingOverlay called", {
      paused: this.videoTarget.paused,
      bufferedRanges: this.bufferedRangesDebug(),
      currentTime: this.videoTarget.currentTime
    })
    if (this.hasSeekingOverlayMessageTarget) this.seekingOverlayMessageTarget.textContent = "Buffering..."
    // pointer-events-none so the user can still seek/click while the
    // buffering spinner is visible — the overlay is visual feedback,
    // not a modal.
    this.seekingOverlayTarget.classList.add("pointer-events-none")
    this.seekingOverlayTarget.classList.remove("hidden")
  }

  hideSeekingOverlay() {
    if (this.subtitlePlaybackHoldToken !== null) return
    this.isSeeking = false
    this.seekingOverlayTarget.classList.add("hidden")
    this.seekingOverlayTarget.classList.remove("pointer-events-none")

    if (this.pendingSeekSeconds !== null) {
      const target = this.pendingSeekSeconds
      this.pendingSeekSeconds = null
      this.restartPlaybackAt(target)
    }
  }

  // ── Overlay UI (auto-hide) ────────────────────────────────────────

  showOverlayUi() {
    this.backButtonTarget.style.opacity = "1"
    this.backButtonTarget.style.pointerEvents = "auto"
    this.sourceInfoTarget.style.opacity = "1"
    this.sourceInfoTarget.style.pointerEvents = "auto"
    this.controlsTarget.style.opacity = "1"
    this.controlsTarget.style.pointerEvents = "auto"
    this.scheduleUiHide()
  }

  hideOverlayUi() {
    if (!this.videoTarget.paused && !this.trackMenuOpen()) {
      this.backButtonTarget.style.opacity = "0"
      this.backButtonTarget.style.pointerEvents = "none"
      this.sourceInfoTarget.style.opacity = "0"
      this.sourceInfoTarget.style.pointerEvents = "none"
      this.controlsTarget.style.opacity = "0"
      this.controlsTarget.style.pointerEvents = "none"
    }
  }

  scheduleUiHide() {
    this.clearUiHideTimer()
    this.uiHideTimer = setTimeout(() => this.hideOverlayUi(), 4000)
  }

  clearUiHideTimer() {
    if (this.uiHideTimer) {
      clearTimeout(this.uiHideTimer)
      this.uiHideTimer = null
    }
  }

  onMouseMove() {
    this.showOverlayUi()
  }

  toggleSourceInfo() {
    this.sourceDetailsTarget.classList.toggle("hidden")
    this.clearUiHideTimer()
    if (!this.sourceDetailsTarget.classList.contains("hidden")) {
      this.backButtonTarget.style.opacity = "1"
      this.sourceInfoTarget.style.opacity = "1"
      this.controlsTarget.style.opacity = "1"
    } else {
      this.scheduleUiHide()
    }
  }

  // ── Progress tracking ─────────────────────────────────────────────

  startProgressTracking() {
    this.progressInterval = setInterval(() => {
      if (this.videoTarget && !this.videoTarget.paused) this.saveProgress()
    }, 5000)
  }

  stopProgressTracking() {
    if (this.progressInterval) {
      clearInterval(this.progressInterval)
      this.progressInterval = null
    }
  }

  async saveProgress() {
    const video = this.videoTarget
    if (!video) return
    const progressSeconds = Math.floor(video.currentTime + this.startSecondsValue)
    const durationSeconds = this.saveableDurationSeconds()
    if (progressSeconds <= 0) return

    try {
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      await fetch(`/streaming/play/progress`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
        body: JSON.stringify({
          imdb_id: this.imdbIdValue,
          progress_seconds: progressSeconds,
          duration_seconds: durationSeconds,
          type: this.typeValue,
          season: this.seasonValue,
          episode: this.episodeValue,
          title: this.titleValue || null,
          poster_url: this.posterUrlValue || null
        })
      })
    } catch (e) {
      console.warn("Progress save failed:", e)
    }
  }

  saveProgressSync() {
    const payload = this.progressPayload()
    if (!payload) return

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    fetch(`/streaming/play/progress`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
      body: JSON.stringify(payload),
      keepalive: true
    })
  }
  progressPayload() {
    const video = this.videoTarget
    if (!video) return null
    const progressSeconds = Math.floor(video.currentTime + this.startSecondsValue)
    const durationSeconds = this.saveableDurationSeconds()
    if (progressSeconds <= 0) return null

    return {
      imdb_id: this.imdbIdValue,
      progress_seconds: progressSeconds,
      duration_seconds: durationSeconds,
      type: this.typeValue,
      season: this.seasonValue,
      episode: this.episodeValue,
      title: this.titleValue || null,
      poster_url: this.posterUrlValue || null
    }
  }

  saveableDurationSeconds() {
    const duration = Math.floor(this.effectiveDuration())
    return duration > 0 ? duration : 0
  }
}
