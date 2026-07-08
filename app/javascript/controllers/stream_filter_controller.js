import { Controller } from "@hotwired/stimulus"

// Client-side filter + sort for the movie streams list on a content
// detail page.  Each stream row carries data-quality (e.g. "1080p") and
// data-size (bytes) attributes; this controller shows/hides and reorders
// the rows as the user picks a quality chip or a sort order.
export default class extends Controller {
  static targets = ["row", "count", "empty"]

  connect() {
    this.activeQuality = "all"
    this.sortMode = "quality" // "quality" | "size"
    this.apply()
  }

  filter(event) {
    this.activeQuality = event.currentTarget.dataset.quality
    this.apply()
  }

  sort(event) {
    this.sortMode = event.currentTarget.dataset.sort
    this.apply()
  }

  apply() {
    const QUALITY_ORDER = { "4K": 0, "1080p": 1, "720p": 2, "480p": 3 }
    let rows = this.rowTargets.slice()

    // Filter by quality.
    if (this.activeQuality !== "all") {
      rows = rows.filter((r) => (r.dataset.quality || "") === this.activeQuality)
    }

    // Sort.
    rows.sort((a, b) => {
      if (this.sortMode === "size") {
        return (parseInt(b.dataset.size, 10) || 0) - (parseInt(a.dataset.size, 10) || 0)
      }
      const qa = QUALITY_ORDER[a.dataset.quality] ?? 99
      const qb = QUALITY_ORDER[b.dataset.quality] ?? 99
      if (qa !== qb) return qa - qb
      return (parseInt(b.dataset.size, 10) || 0) - (parseInt(a.dataset.size, 10) || 0)
    })

    // Hide everything first, then re-append in the new order.  Appending
    // existing DOM nodes moves them (no clone), so the Watch buttons and
    // their CSRF tokens stay intact.
    this.rowTargets.forEach((r) => (r.hidden = true))
    const container = this.rowTargets[0]?.parentElement
    if (container) {
      rows.forEach((r) => {
        r.hidden = false
        container.appendChild(r)
      })
    }

    if (this.hasCountTarget) {
      this.countTarget.textContent = rows.length
    }
    if (this.hasEmptyTarget) {
      this.emptyTarget.hidden = rows.length > 0
    }
  }
}