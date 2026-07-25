import { Controller } from "@hotwired/stimulus"

// Filters independently-loaded provider results. Turbo frames connect rows as
// each provider answers; target callbacks update the count and apply the active
// quality without waiting for every provider.
export default class extends Controller {
  static targets = ["row", "count", "empty"]

  initialize() {
    this.activeQuality = "all"
    this.sortMode = "seeders"
    this.nextOriginalIndex = 0
  }

  connect() {
    this.scheduleApply()
  }

  rowTargetConnected(row) {
    if (!row.dataset.originalIndex) {
      row.dataset.originalIndex = this.nextOriginalIndex++
    }
    this.scheduleApply()
  }

  rowTargetDisconnected() {
    this.scheduleApply()
  }

  filter(event) {
    this.activeQuality = event.currentTarget.dataset.quality
    this.scheduleApply()
  }

  sort(event) {
    this.sortMode = event.currentTarget.dataset.sort
    this.scheduleApply()
  }

  scheduleApply() {
    if (this.applyScheduled) return
    this.applyScheduled = true
    queueMicrotask(() => {
      this.applyScheduled = false
      if (this.element.isConnected) this.apply()
    })
  }

  apply() {
    if (this.applying) return
    this.applying = true

    const rows = this.rowTargets.slice()
    const groups = new Map()
    rows.forEach((row) => {
      const container = row.parentElement
      if (!groups.has(container)) groups.set(container, [])
      groups.get(container).push(row)
    })

    let visibleCount = 0
    groups.forEach((groupRows, container) => {
      const visible = groupRows
        .filter((row) => this.activeQuality === "all" || (row.dataset.quality || "") === this.activeQuality)
        .sort((a, b) => this.compareRows(a, b))

      groupRows.forEach((row) => { row.hidden = true })
      visible.forEach((row) => {
        row.hidden = false
        container.appendChild(row)
      })
      visibleCount += visible.length
    })

    if (this.hasCountTarget) this.countTarget.textContent = visibleCount
    if (this.hasEmptyTarget) this.emptyTarget.hidden = visibleCount > 0 || rows.length === 0
    this.applying = false
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