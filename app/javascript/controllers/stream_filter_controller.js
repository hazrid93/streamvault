import { Controller } from "@hotwired/stimulus"

// Client-side filter + sort for the movie streams list on a content
// detail page. Cached Real-Debrid rows always stay grouped first. The
// default order then uses provider-reported seeder counts, while quality
// and size remain available as optional secondary sort modes.
export default class extends Controller {
  static targets = ["row", "count", "empty"]

  connect() {
    this.activeQuality = "all"
    this.sortMode = "seeders"
    this.rowTargets.forEach((row, index) => { row.dataset.originalIndex = index })
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
    let rows = this.rowTargets.slice()

    if (this.activeQuality !== "all") {
      rows = rows.filter((row) => (row.dataset.quality || "") === this.activeQuality)
    }

    rows.sort((a, b) => this.compareRows(a, b))

    // Hide everything first, then re-append in the new order. Appending
    // existing DOM nodes moves them (no clone), so the Watch buttons and
    // their CSRF tokens stay intact.
    this.rowTargets.forEach((row) => { row.hidden = true })
    const container = this.rowTargets[0]?.parentElement
    if (container) {
      rows.forEach((row) => {
        row.hidden = false
        container.appendChild(row)
      })
    }

    if (this.hasCountTarget) this.countTarget.textContent = rows.length
    if (this.hasEmptyTarget) this.emptyTarget.hidden = rows.length > 0
  }

  compareRows(a, b) {
    const rdDifference = this.rdRank(a) - this.rdRank(b)
    if (rdDifference !== 0) return rdDifference

    let difference
    if (this.sortMode === "size") {
      difference = this.size(b) - this.size(a)
      if (difference !== 0) return difference
      difference = this.compareSeeders(a, b)
    } else if (this.sortMode === "quality") {
      difference = this.qualityRank(a) - this.qualityRank(b)
      if (difference !== 0) return difference
      difference = this.compareSeeders(a, b)
    } else {
      difference = this.compareSeeders(a, b)
      if (difference !== 0) return difference
      difference = this.qualityRank(a) - this.qualityRank(b)
      if (difference !== 0) return difference
      difference = this.size(b) - this.size(a)
    }

    if (difference !== 0) return difference
    return this.originalIndex(a) - this.originalIndex(b)
  }

  compareSeeders(a, b) {
    const aSeeders = this.seeders(a)
    const bSeeders = this.seeders(b)
    if (aSeeders === null && bSeeders !== null) return 1
    if (aSeeders !== null && bSeeders === null) return -1
    return (bSeeders || 0) - (aSeeders || 0)
  }

  rdRank(row) {
    return row.dataset.rdPlus === "true" ? 0 : 1
  }

  seeders(row) {
    const value = row.dataset.seeders
    if (value === undefined || value === "") return null
    const parsed = Number.parseInt(value, 10)
    return Number.isFinite(parsed) ? parsed : null
  }

  qualityRank(row) {
    const order = { "4K": 0, "1080p": 1, "720p": 2, "480p": 3 }
    return order[row.dataset.quality] ?? 99
  }

  size(row) {
    return Number.parseInt(row.dataset.size, 10) || 0
  }

  originalIndex(row) {
    return Number.parseInt(row.dataset.originalIndex, 10) || 0
  }
}
