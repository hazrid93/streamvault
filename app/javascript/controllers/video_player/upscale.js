// Client-side Anime4K upscaling (WebGL or WebGPU) for the video player:
// engine/profile preferences, lazy module loading, canvas layout, health
// checks with fallback, and the upscaler menu. Mixed into the video player
// controller, so every method runs with the controller as `this` and uses
// its Stimulus targets.

// Anime4K client-side upscaling is opt-in (heavier GPU feature than HDR).
const UPSCALE_PREFERENCE_KEY = "streamvault:upscale-enabled"
const UPSCALE_ENGINE_PREFERENCE_KEY = "streamvault:upscale-engine"
const UPSCALE_PROFILE_PREFERENCE_KEY = "streamvault:upscale-profile"
// Profile ids shared by both engine bundles.
const UPSCALE_PROFILE_IDS = ["balanced", "balancedPlus", "quality", "ultra2x", "ultra4x"]
// WebGPU video upload paths are young in WebKit: if the engine renders
// nothing (or blank frames) shortly after start, fall back this fast.
const UPSCALE_HEALTH_CHECK_DELAY_MS = 1200

export const UpscaleMixin = (Base) => class extends Base {
  loadUpscalePreference() {
    try {
      return window.localStorage.getItem(UPSCALE_PREFERENCE_KEY) === "1"
    } catch {
      return false
    }
  }

  loadUpscaleEnginePreference() {
    try {
      const saved = window.localStorage.getItem(UPSCALE_ENGINE_PREFERENCE_KEY)
      return saved === "webgpu" ? "webgpu" : "webgl"
    } catch {
      return "webgl"
    }
  }

  saveUpscalePreference(enabled) {
    try {
      window.localStorage.setItem(UPSCALE_PREFERENCE_KEY, enabled ? "1" : "0")
    } catch {}
  }

  saveUpscaleEnginePreference(engineId) {
    try {
      window.localStorage.setItem(UPSCALE_ENGINE_PREFERENCE_KEY, engineId)
    } catch {}
  }

  loadUpscaleProfilePreference() {
    try {
      const saved = window.localStorage.getItem(UPSCALE_PROFILE_PREFERENCE_KEY)
      return UPSCALE_PROFILE_IDS.includes(saved) ? saved : "balanced"
    } catch {
      return "balanced"
    }
  }

  saveUpscaleProfilePreference(profileId) {
    try {
      window.localStorage.setItem(UPSCALE_PROFILE_PREFERENCE_KEY, profileId)
    } catch {}
  }

  // Quality tiers offered in the 4K menu; shared ids across both engines.
  upscaleProfiles() {
    return [
      { id: "balanced", hint: "2x · fast, Mode A (M+M)" },
      { id: "balancedPlus", hint: "2x · VL restore + M upscale — quality where it's visible (~1.6x cost)" },
      { id: "quality", hint: "2x · VL+VL — ~4x cost" },
      { id: "ultra2x", hint: "2x · UL+UL — heaviest 2x" },
      { id: "ultra4x", hint: "4x · low-res sources only (≤720p)" }
    ]
  }

  // Engine registry for the 4K menu. Both render the same Anime4K SIMPLE_M
  // chain (ClampHighlights -> Restore CNNM -> 2x CNN upscale) client-side;
  // they differ only in GPU API and device reach:
  // - WebGL: virtually every desktop/Android browser (needs float textures).
  // - WebGPU: newer browsers; notably the ONLY option on iOS (26+), whose
  //   WebGL lacks the float textures the WebGL engine requires.
  upscaleEngines() {
    return [
      { id: "webgl", hint: "2x · most devices", supported: this.upscaleWebglSupported() },
      { id: "webgpu", hint: "2x · newer devices, incl. iPhone (iOS 26+)", supported: this.webgpuApiPresent() && !this.upscaleWebgpuFailed }
    ]
  }

  upscaleEngineById(engineId) {
    return this.upscaleEngines().find((engine) => engine.id === engineId)
  }

  webgpuApiPresent() {
    return typeof navigator !== "undefined" && Boolean(navigator.gpu)
  }

  // Mirrors Anime4K.js VideoUpscaler.isSupported() exactly: WebGL with
  // float textures (the CNN shaders need them). Deliberately no stricter —
  // an extra extension check here would disable the engine on browsers the
  // library itself supports.
  upscaleWebglSupported() {
    if (this.upscaleWebglSupportedResult === undefined) {
      try {
        const canvas = document.createElement("canvas")
        const gl = canvas.getContext("webgl")
        this.upscaleWebglSupportedResult = Boolean(
          gl &&
          gl.getExtension("OES_texture_float") &&
          gl.getExtension("OES_texture_float_linear")
        )
      } catch {
        this.upscaleWebglSupportedResult = false
      }
    }
    return this.upscaleWebglSupportedResult
  }

  // Overridable for tests; resolved through the import map in the browser.
  // The 4x profile lives in separate lazy bundles (~2MB of model weights)
  // so only viewers who pick 4x download it.
  // NOTE: import-map pin names are anime4k / anime4k-webgpu / *-ultra —
  // engine ids ("webgl"/"webgpu") are NOT valid module specifiers.
  upscaleModuleSpecifier(engineId, profileId) {
    const base = engineId === "webgpu" ? "anime4k-webgpu" : "anime4k"
    return profileId === "ultra4x" ? `${base}-ultra` : base
  }

  loadUpscaleModule(engineId, profileId) {
    return import(this.upscaleModuleSpecifier(engineId, profileId))
  }

  // ── Upscale canvas letterboxing ───────────────────────────────────

  // Place both upscale canvases exactly over the video's displayed picture,
  // derived from MEASUREMENT, not assumptions: the video element's actual
  // rect (getBoundingClientRect) + intrinsic aspect give the true contain-fit
  // picture box, whatever the engine did with the flex container,
  // percentage heights, 100vw/dvh or safe areas. Translated into the canvas's
  // own containing block, with inset:auto so no over-constrained CSS
  // (inset-0 + m-auto + max-*) participates — those resolve differently
  // across engines (the iOS stretch/cutoff). Re-run on resize and metadata
  // changes.
  layoutUpscaleCanvas() {
    const video = this.videoTarget
    if (!video || !video.videoWidth || !video.videoHeight) return
    const canvases = [
      this.hasUpscaleWebglCanvasTarget ? this.upscaleWebglCanvasTarget : null,
      this.hasUpscaleWebgpuCanvasTarget ? this.upscaleWebgpuCanvasTarget : null
    ].filter(Boolean)
    const videoAspect = video.videoWidth / video.videoHeight
    const videoRect = video.getBoundingClientRect()
    for (const canvas of canvases) {
      const anchor = canvas.offsetParent || canvas.parentElement
      const anchorRect = anchor ? anchor.getBoundingClientRect() : { left: 0, top: 0 }
      // Contain-fit of the video's aspect inside the video element's box.
      let w = videoRect.width
      let h = videoRect.width / videoAspect
      if (h > videoRect.height) {
        h = videoRect.height
        w = videoRect.height * videoAspect
      }
      canvas.style.inset = "auto"
      canvas.style.left = `${(videoRect.left - anchorRect.left) + (videoRect.width - w) / 2}px`
      canvas.style.top = `${(videoRect.top - anchorRect.top) + (videoRect.height - h) / 2}px`
      canvas.style.width = `${w}px`
      canvas.style.height = `${h}px`
      canvas.style.margin = "0"
      canvas.style.maxWidth = "none"
      canvas.style.maxHeight = "none"
    }
    this.updateUpscaleStats()
  }

  // Menu-facing labels for the info readout — ids are for storage, not eyes.
  upscaleProfileLabel(profileId) {
    return {
      balanced: "Balanced",
      balancedPlus: "Balanced+",
      quality: "Quality",
      ultra2x: "Ultra 2x",
      ultra4x: "4x"
    }[profileId] || profileId
  }

  // Stream info readout: engine · profile · bitmap size → on-screen box.
  // Lets the viewer confirm at a glance what is actually rendering (and
  // report it if the picture looks wrong).
  updateUpscaleStats() {
    if (!this.hasUpscaleStatsTarget) return
    if (!this.upscaleEnabled || !this.activeUpscaleEngineId) {
      this.upscaleStatsTarget.textContent = "off"
      return
    }
    const canvas = this.activeUpscaleEngineId === "webgl" ? this.upscaleWebglCanvasTarget : this.upscaleWebgpuCanvasTarget
    const bitmap = canvas && canvas.width ? `${canvas.width}×${canvas.height}` : "—"
    const box = canvas && canvas.style.width ? `${canvas.style.width}×${canvas.style.height}` : "css"
    const engine = this.activeUpscaleEngineId === "webgpu" ? "WebGPU" : "WebGL"
    this.upscaleStatsTarget.textContent = `${engine} · ${this.upscaleProfileLabel(this.upscaleProfileId)} · ${bitmap} → ${box}`
  }

  // ── Startup failure diagnostics ───────────────────────────────────

  // Persistent panel with the full failure details + copy button, so a
  // viewer on a phone (no devtools) can capture and report the real reason.
  showUpscaleDiagnostic() {
    if (!this.upscaleStartError || !this.hasUpscaleDiagnosticTarget || !this.hasUpscaleDiagnosticTextTarget) return
    const e = this.upscaleStartError
    this.upscaleDiagnosticTextTarget.textContent =
      `StreamVault upscaler failed to start\n` +
      `engine: ${e.engine} (profile: ${e.profile})\n` +
      `${e.gpu}\n` +
      `error: ${e.message}\n` +
      `user agent: ${e.userAgent}`
    this.upscaleDiagnosticTarget.classList.remove("hidden")
  }

  closeUpscaleDiagnostic() {
    if (this.hasUpscaleDiagnosticTarget) this.upscaleDiagnosticTarget.classList.add("hidden")
  }

  async copyUpscaleDiagnostic() {
    const text = this.hasUpscaleDiagnosticTextTarget ? this.upscaleDiagnosticTextTarget.textContent : ""
    if (!text) return
    let copied = false
    try {
      await navigator.clipboard.writeText(text)
      copied = true
    } catch {
      // Fallback for browsers without the async clipboard API.
      try {
        const area = document.createElement("textarea")
        area.value = text
        area.style.position = "fixed"
        area.style.opacity = "0"
        document.body.appendChild(area)
        area.select()
        copied = document.execCommand("copy")
        area.remove()
      } catch {}
    }
    this.showPlayerNotice(copied ? "Diagnostic copied to clipboard" : "Copy failed — long-press the text to select it")
  }

  // ── FPS readout ───────────────────────────────────────────────────

  // Measures the video's effective presentation rate through
  // requestVideoFrameCallback — the same per-frame hook the upscalers use.
  // If upscaling can't keep up, this number drops, which is exactly the
  // impact the viewer wants to see. Rolling ~4s window, display-only.
  startFpsMonitor() {
    if (!this.hasFpsStatsTarget) return
    const video = this.videoTarget
    if (!video || typeof video.requestVideoFrameCallback !== "function") return
    this.fpsFrameTimes = []
    const FPS_WINDOW_MS = 4000
    const tick = (now) => {
      if (this.fpsFrameTimes === null) return
      this.fpsFrameTimes.push(now)
      while (this.fpsFrameTimes.length > 2 && now - this.fpsFrameTimes[0] > FPS_WINDOW_MS) {
        this.fpsFrameTimes.shift()
      }
      if (this.fpsFrameTimes.length >= 2) {
        const span = now - this.fpsFrameTimes[0]
        if (span > 0) {
          const fps = (this.fpsFrameTimes.length - 1) * 1000 / span
          this.fpsStatsTarget.textContent = fps >= 10 ? fps.toFixed(0) : fps.toFixed(1)
        }
      }
      video.requestVideoFrameCallback(tick)
    }
    video.requestVideoFrameCallback(tick)
  }

  stopFpsMonitor() {
    this.fpsFrameTimes = null
  }

  // ── 4K menu ───────────────────────────────────────────────────────

  toggleUpscalerMenu() {
    if (this.hasUpscaleMenuTarget) {
      this.upscaleMenuTarget.classList.toggle("hidden")
    }
  }

  closeUpscalerMenu() {
    if (this.hasUpscaleMenuTarget) this.upscaleMenuTarget.classList.add("hidden")
  }

  upscaleMenuOpen() {
    return Boolean(this.hasUpscaleMenuTarget && !this.upscaleMenuTarget.classList.contains("hidden"))
  }

  // Menu row action: "off" or an engine id. Disabled rows explain themselves
  // instead of silently ignoring the tap.
  async selectUpscalerEngine(event) {
    const row = event.currentTarget
    if (row.getAttribute("aria-disabled") === "true") {
      const label = row.dataset.upscaleEngine === "webgpu" ? "WebGPU upscaling" : "WebGL upscaling"
      this.showPlayerNotice(`${label} is not supported in this browser`)
      return
    }
    // Ignore taps while a previous switch is still applying (spinner up).
    if (this.upscaleApplying) return
    const engineId = row.dataset.upscaleEngine
    this.closeUpscalerMenu()

    if (engineId === "off" || !engineId) {
      this.upscalePreferenceEnabled = false
      this.saveUpscalePreference(false)
      if (this.upscaleEnabled) this.disableUpscale()
      // If enabling the upscaler switched HDR playback off, switching it
      // back off restores HDR.
      if (this.hdrDisabledByUpscale) {
        this.hdrDisabledByUpscale = false
        if (!this.hdrEnabled && this.hdrAvailable) this.toggleHdr()
      }
      this.renderUpscaleControls()
      return
    }

    const engine = this.upscaleEngineById(engineId)
    if (!engine || !engine.supported) return
    // Same engine already running: nothing to do.
    if (this.upscaleEnabled && this.activeUpscaleEngineId === engineId) return

    this.upscaleEngineId = engineId
    this.saveUpscaleEnginePreference(engineId)
    // Upscaled frames are SDR: when HDR playback is active, switch to SDR
    // first. The viewer accepted the trade — 4K on, HDR off.
    this.hdrDisabledByUpscale = false
    if (this.hdrEnabled) {
      this.hdrDisabledByUpscale = true
      this.toggleHdr()
    }
    this.upscalePreferenceEnabled = true
    this.saveUpscalePreference(true)
    // Engine switch: tear the running engine down before starting the new
    // one (a canvas can hold only one context type, ever).
    if (this.upscaleEnabled) this.disableUpscale()
    const ok = await this.enableUpscale()
    if (!ok) {
      this.upscalePreferenceEnabled = false
      this.saveUpscalePreference(false)
      // Only show a generic toast when the failure path didn't already
      // present the diagnostic panel (e.g. HDR raced on mid-start).
      if (!this.upscaleStartError) {
        this.showPlayerNotice("Upscaling failed to start on this device — playing the original video.")
      }
    }
  }

  // Menu row action for the quality section: "balanced" / "quality" /
  // "ultra4x". Applies immediately (engine restart) when upscaling runs,
  // and always persists for future playback.
  async selectUpscalerProfile(event) {
    const row = event.currentTarget
    if (row.getAttribute("aria-disabled") === "true") {
      this.showPlayerNotice("Upscaling is not supported in this browser")
      return
    }
    if (this.upscaleApplying) return
    const profileId = row.dataset.upscaleProfile
    if (!UPSCALE_PROFILE_IDS.includes(profileId) || profileId === this.upscaleProfileId) return
    this.closeUpscalerMenu()

    this.upscaleProfileId = profileId
    this.saveUpscaleProfilePreference(profileId)
    if (!this.upscaleEnabled) {
      this.renderUpscaleControls()
      return
    }
    // Restart the running engine with the new chain.
    this.disableUpscale()
    const ok = await this.enableUpscale()
    if (!ok) {
      this.upscalePreferenceEnabled = false
      this.saveUpscalePreference(false)
      if (!this.upscaleStartError) {
        this.showPlayerNotice("Upscaling failed to start on this device — playing the original video.")
      }
    }
  }

  // Attaches the selected engine's Anime4K pipeline to its canvas overlay:
  // clamp highlights, restore (line-art reconstruction) then a 2x CNN
  // upscale — the SIMPLE_M profile. Fails softly (unsupported browser,
  // module load error, HDR switched on mid-load): the plain video keeps
  // playing.
  async enableUpscale() {
    // Single-flight: internal callers (restoreUpscale via HDR/track control
    // rendering, failWebgpuUpscale's fallback) can fire while a previous
    // start is still awaiting adapter/device on slow devices — a re-entrant
    // call would see the not-yet-sized canvas and kill the healthy start.
    if (this.upscaleApplying) return false
    if (this.upscaleEnabled || this.hdrEnabled) return false
    this.upscaleStartError = null
    const engineId = this.upscaleEngineId
    const profileId = this.upscaleProfileId
    const engine = this.upscaleEngineById(engineId)
    if (!engine || !engine.supported) return false
    const canvas = engineId === "webgl" ? this.upscaleWebglCanvasTarget : this.upscaleWebgpuCanvasTarget
    if (!canvas) return false
    this.upscaleApplying = true
    this.showUpscaleSpinner()
    try {
      const module = await this.loadUpscaleModule(engineId, profileId)
      // HDR may have been switched on while the module loaded.
      if (this.hdrEnabled) return false
      const shaderChain = module.PROFILES?.[profileId] || module.PROFILES?.balanced
      if (!shaderChain) return false
      if (!this.upscaler) {
        this.upscaler = engineId === "webgl"
          ? new module.VideoUpscaler(shaderChain)
          : new module.WebGPUUpscaler(shaderChain)
      }
      const upscaler = this.upscaler
      upscaler.attachVideo(this.videoTarget, canvas)
      // Letterbox the canvas to the video's displayed box BEFORE revealing
      // it: WebKit ignores object-fit on canvas, so without this the bitmap
      // stretches edge-to-edge over the video's letterboxed picture.
      this.layoutUpscaleCanvas()
      canvas.classList.remove("hidden")
      // Async GPU failure hooks must be wired BEFORE start(): adapter /
      // device requests can fail (or the device be lost) during start.
      if (engineId === "webgpu" && typeof upscaler.renderingHealthy === "function") {
        upscaler.onError = (error) => {
          const text = error && (error.message || error.reason) ? String(error.message || error.reason) : String(error || "unknown")
          this.failWebgpuUpscale(`async rendering error: ${text}`, `frames=${upscaler.framesProcessed}`)
        }
      }
      // Await start(): adapter/device requests and first shader compilation
      // can take over a second on phones; a rejected start() must land in
      // this catch block, not become an unhandled rejection.
      await upscaler.start()
      // The engine may have died (onError -> disableUpscale) or been
      // replaced while awaiting start.
      if (this.upscaler !== upscaler || this.hdrEnabled) return false
      // The WebGPU canvas bitmap must share the video's aspect ratio —
      // layoutUpscaleCanvas assumes it. A padded or mis-sized output
      // texture would stretch the picture INSIDE the letterbox box, which
      // looks exactly like the layout bug; report it distinctly instead.
      // (WebGL excluded: that library sizes its own canvas asynchronously.)
      // A never-sized canvas (browser default 300x150) is not an aspect
      // failure — start() sizing it is what this await was for.
      if (engineId === "webgpu" && canvas.width > 1 && canvas.height > 1 && this.videoTarget.videoWidth) {
        const videoAspect = this.videoTarget.videoWidth / this.videoTarget.videoHeight
        const canvasAspect = canvas.width / canvas.height
        if (Math.abs(canvasAspect - videoAspect) > 0.01) {
          this.upscaleStartError = {
            engine: engineId,
            profile: profileId,
            message: `output texture ${canvas.width}x${canvas.height} does not match video aspect ${this.videoTarget.videoWidth}x${this.videoTarget.videoHeight} (would stretch inside the letterbox)`,
            gpu: this.webgpuApiPresent() ? "navigator.gpu present" : "navigator.gpu missing",
            userAgent: (typeof navigator !== "undefined" && navigator.userAgent) || "unknown"
          }
          this.disableUpscale()
          this.showUpscaleDiagnostic()
          return false
        }
      }
      this.upscaleEnabled = true
      this.activeUpscaleEngineId = engineId
      this.renderUpscaleControls()
      // Watchdog only AFTER start() resolved — scheduling it earlier kills
      // healthy engines that are still compiling shaders on mobile GPUs
      // (the exact symptom of 4K silently reverting to Off on iOS).
      if (engineId === "webgpu" && typeof upscaler.renderingHealthy === "function") {
        this.upscaleHealthTimer = setTimeout(() => this.checkWebgpuUpscaleHealth(upscaler), UPSCALE_HEALTH_CHECK_DELAY_MS)
      }
      // Reflect the switch immediately on a paused video: rVFC never fires
      // while paused, so nothing would visibly change until playback.
      if (this.videoTarget && this.videoTarget.paused) {
        if (typeof upscaler.renderOnce === "function") upscaler.renderOnce()
        this.nudgePausedVideo()
      }
      return true
    } catch (error) {
      console.warn("[VideoPlayer] Anime4K upscaling unavailable", error)
      // Full details go to the persistent diagnostic panel (with a copy
      // button) — a truncated toast can't be read off-screen and generic
      // messages hide the actual reason.
      this.upscaleStartError = {
        engine: engineId,
        profile: profileId,
        message: error && error.message ? String(error.message) : String(error),
        gpu: engineId === "webgpu"
          ? (this.webgpuApiPresent() ? "navigator.gpu present" : "navigator.gpu missing")
          : (this.upscaleWebglSupported() ? "WebGL float textures OK" : "WebGL float textures missing"),
        userAgent: (typeof navigator !== "undefined" && navigator.userAgent) || "unknown"
      }
      this.disableUpscale()
      this.showUpscaleDiagnostic()
      return false
    } finally {
      this.upscaleApplying = false
      this.hideUpscaleSpinner()
    }
  }

  disableUpscale() {
    clearTimeout(this.upscaleHealthTimer)
    this.upscaleHealthTimer = null
    this.upscaleEnabled = false
    this.activeUpscaleEngineId = null
    if (this.upscaler) {
      try {
        this.upscaler.stop()
        this.upscaler.detachVideo()
      } catch {}
      this.upscaler = null
    }
    if (this.hasUpscaleWebglCanvasTarget) this.upscaleWebglCanvasTarget.classList.add("hidden")
    if (this.hasUpscaleWebgpuCanvasTarget) this.upscaleWebgpuCanvasTarget.classList.add("hidden")
    this.renderUpscaleControls()
  }

  // Watchdog: the WebGPU engine started but may still render nothing (dead
  // loop) or all-black frames (WebKit copyExternalImageToTexture bug). Both
  // leave the viewer staring at a blank/stuck canvas, so verify and fall
  // back to plain video (or the WebGL engine) with a notice.
  async checkWebgpuUpscaleHealth(upscaler) {
    this.upscaleHealthTimer = null
    if (!this.upscaleEnabled || this.activeUpscaleEngineId !== "webgpu" || this.upscaler !== upscaler) return

    const video = this.videoTarget
    const videoState = `paused=${video && video.paused} currentTime=${video ? Math.floor(video.currentTime || 0) : "?"} readyState=${video ? video.readyState : "?"} frames=${upscaler.framesProcessed}`

    const playing = video && !video.paused && (video.currentTime || 0) > 0
    if (playing && upscaler.framesProcessed === 0) {
      this.failWebgpuUpscale("rendered no frames while playing", videoState)
      return
    }
    if (upscaler.framesProcessed > 0 && typeof upscaler.renderingHealthy === "function") {
      // Engine contract: {healthy, detail} (older bundles: boolean).
      const verdict = await upscaler.renderingHealthy()
      const healthy = typeof verdict === "boolean" ? verdict : verdict.healthy
      const detail = typeof verdict === "object" && verdict.detail ? verdict.detail : "no detail"
      // Engine may have changed while awaiting the readback.
      if (!this.upscaleEnabled || this.activeUpscaleEngineId !== "webgpu" || this.upscaler !== upscaler) return
      if (!healthy) this.failWebgpuUpscale(`blank output (${detail})`, videoState)
    }
  }

  // Blacklist the WebGPU engine for this session and keep the viewer
  // watching: fall back to WebGL when available, otherwise plain video.
  // Watchdog failures open the diagnostic panel too (reason + video/frames
  // state) — a toast alone can't distinguish dead-loop from blank output.
  failWebgpuUpscale(reason, extraState = null) {
    if (this.upscaleWebgpuFailed) return
    this.upscaleWebgpuFailed = true
    console.warn(`[VideoPlayer] WebGPU upscaling failed (${reason}) — falling back`)
    if (extraState) {
      this.upscaleStartError = {
        engine: "webgpu",
        profile: this.upscaleProfileId,
        message: `engine failed after start: ${reason}${extraState ? `; ${extraState}` : ""}`,
        gpu: this.webgpuApiPresent() ? "navigator.gpu present" : "navigator.gpu missing",
        userAgent: (typeof navigator !== "undefined" && navigator.userAgent) || "unknown"
      }
    }
    this.disableUpscale()
    if (this.upscaleWebglSupported()) {
      this.upscaleEngineId = "webgl"
      this.saveUpscaleEnginePreference("webgl")
      this.enableUpscale().then((ok) => {
        this.showPlayerNotice(ok
          ? "WebGPU upscaling failed on this device — switched to the WebGL engine."
          : "WebGPU upscaling failed on this device — playing the original video.")
      })
    } else {
      this.upscalePreferenceEnabled = false
      this.saveUpscalePreference(false)
      this.showPlayerNotice("WebGPU upscaling failed on this device — playing the original video.")
    }
    if (extraState) this.showUpscaleDiagnostic()
  }


  // ── Upscaler apply feedback ────────────────────────────────────────

  // "Applying" spinner shown while a module downloads or an engine starts —
  // engine starts can take seconds (adapter + shader compilation), and the
  // 4x profile pulls ~2MB of model weights on first pick.
  showUpscaleSpinner() {
    if (!this.hasUpscaleSpinnerTarget) return
    this.upscaleSpinnerTarget.classList.remove("hidden")
    this.upscaleSpinnerTarget.classList.add("inline-flex")
  }

  hideUpscaleSpinner() {
    if (!this.hasUpscaleSpinnerTarget) return
    this.upscaleSpinnerTarget.classList.add("hidden")
    this.upscaleSpinnerTarget.classList.remove("inline-flex")
  }

  // Both engines render on requestVideoFrameCallback, which never fires
  // while the video is paused. A tiny seek presents one frame, so the
  // WebGL engine's loop renders the current picture after a switch. (The
  // WebGPU engine renders directly via renderOnce(); this nudge also
  // refreshes it harmlessly.)
  nudgePausedVideo() {
    const video = this.videoTarget
    if (!video || !video.paused || !video.duration) return
    try {
      const target = Math.min((video.currentTime || 0) + 0.001, video.duration - 0.001)
      video.currentTime = target
    } catch {}
  }

  async restoreUpscale() {
    if (!this.upscalePreferenceEnabled || this.upscaleEnabled) return
    if (this.hdrEnabled) return
    let engine = this.upscaleEngineById(this.upscaleEngineId)
    if (!engine || !engine.supported) {
      // Saved engine unusable here (e.g. WebGL saved, opened on iOS):
      // fall back to any supported engine so the preference still applies.
      engine = this.upscaleEngines().find((candidate) => candidate.supported)
      if (!engine) return
      this.upscaleEngineId = engine.id
      this.saveUpscaleEnginePreference(engine.id)
    }
    await this.enableUpscale()
  }

  // The upscale canvases render SDR frames, so while HDR playback is active
  // they are suspended (an SDR canvas over an HDR stream would wash the
  // picture out) and resume when HDR is switched back off. Called from
  // renderHdrControls, which runs on every HDR state change.
  syncUpscaleControls() {
    if (this.hdrEnabled && this.upscaleEnabled) this.disableUpscale()
    if (!this.hdrEnabled && this.upscalePreferenceEnabled && !this.upscaleEnabled) {
      this.restoreUpscale()
    }
    this.renderUpscaleControls()
  }

  renderUpscaleControls() {
    if (!this.hasUpscaleControlsTarget || !this.hasUpscaleButtonTarget || !this.hasUpscaleButtonStateTarget) return
    // Always visible: on browsers where no engine can run (rare) the button
    // renders disabled with an explanatory tooltip instead of vanishing.
    this.upscaleControlsTarget.classList.remove("hidden")
    const anySupported = this.upscaleEngines().some((engine) => engine.supported)
    const enabled = this.upscaleEnabled
    this.upscaleButtonTarget.disabled = !anySupported
    this.upscaleButtonTarget.setAttribute("aria-pressed", enabled ? "true" : "false")
    this.upscaleButtonTarget.setAttribute("aria-expanded", this.upscaleMenuOpen() ? "true" : "false")
    this.upscaleButtonTarget.setAttribute("aria-haspopup", "menu")
    this.upscaleButtonTarget.title = !anySupported
      ? "Anime4K upscaling not supported in this browser"
      : (enabled ? "Anime4K upscaling on (SDR)" : "Anime4K upscaling (client-side, 2x — switches HDR off)")
    this.upscaleButtonStateTarget.textContent = enabled ? "ON" : "OFF"
    this.upscaleButtonTarget.classList.toggle("border-indigo-400/70", enabled)
    this.upscaleButtonTarget.classList.toggle("bg-indigo-500/15", enabled)
    this.upscaleButtonTarget.classList.toggle("text-indigo-300", enabled)
    this.upscaleButtonTarget.classList.toggle("opacity-40", !anySupported)
    this.upscaleButtonTarget.classList.toggle("cursor-not-allowed", !anySupported)
    this.upscaleButtonTarget.classList.toggle("border-white/20", !enabled)
    this.upscaleButtonTarget.classList.toggle("bg-black/60", !enabled)
    this.upscaleButtonTarget.classList.toggle("text-sv-text-muted", !enabled)
    // The 4K icon turns blue while upscaling runs.
    if (this.hasUpscaleIconTarget) {
      this.upscaleIconTarget.classList.toggle("text-indigo-400", enabled)
      this.upscaleIconTarget.classList.toggle("text-sv-text-muted", !enabled)
    }
    this.updateUpscaleStats()
    this.renderUpscaleMenu()
  }

  renderUpscaleMenu() {
    if (!this.hasUpscaleMenuTarget) return
    const anySupported = this.upscaleEngines().some((engine) => engine.supported)
    const rows = this.upscaleMenuTarget.querySelectorAll("[data-upscale-engine], [data-upscale-profile]")
    rows.forEach((row) => {
      const engineId = row.dataset.upscaleEngine
      const profileId = row.dataset.upscaleProfile
      const check = row.querySelector("[data-upscale-check]")
      if (profileId) {
        // Quality rows: selectable whenever any engine can run; the choice
        // persists and applies to whatever engine is active.
        const selected = profileId === this.upscaleProfileId
        row.setAttribute("aria-disabled", anySupported ? "false" : "true")
        row.classList.toggle("opacity-40", !anySupported)
        row.classList.toggle("cursor-not-allowed", !anySupported)
        row.classList.toggle("hover:bg-white/5", anySupported)
        row.classList.toggle("hover:text-white", anySupported)
        row.classList.toggle("text-indigo-300", selected)
        row.classList.toggle("bg-indigo-500/10", selected)
        if (check) check.classList.toggle("hidden", !selected)
        return
      }
      if (engineId === "off") {
        const selected = !this.upscaleEnabled
        row.classList.toggle("text-indigo-300", selected)
        row.classList.toggle("bg-indigo-500/10", selected)
        if (check) check.classList.toggle("hidden", !selected)
        return
      }
      const engine = this.upscaleEngineById(engineId)
      const supported = Boolean(engine && engine.supported)
      const selected = this.upscaleEnabled && this.activeUpscaleEngineId === engineId
      row.setAttribute("aria-disabled", supported ? "false" : "true")
      row.classList.toggle("opacity-40", !supported)
      row.classList.toggle("cursor-not-allowed", !supported)
      row.classList.toggle("hover:bg-white/5", supported)
      row.classList.toggle("hover:text-white", supported)
      row.classList.toggle("text-indigo-300", selected)
      row.classList.toggle("bg-indigo-500/10", selected)
      if (check) check.classList.toggle("hidden", !selected)
      const hint = row.querySelector("[data-upscale-hint]")
      if (hint) hint.textContent = supported ? engine.hint : "Not supported in this browser"
    })
  }
}
