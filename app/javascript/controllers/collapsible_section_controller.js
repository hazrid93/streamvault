import { Controller } from "@hotwired/stimulus"

// Toggles a home section between a horizontal carousel (collapsed) and a
// wrapping grid (expanded).  When expanded the carousel nav buttons are
// hidden via CSS and the track switches to flex-wrap + visible overflow.
export default class extends Controller {
  static targets = ["toggle"]

  connect() {
    this.expanded = false
  }

  toggle() {
    this.expanded = !this.expanded
    this.element.classList.toggle("is-expanded", this.expanded)
    if (this.hasToggleTarget) {
      this.toggleTarget.setAttribute("aria-expanded", String(this.expanded))
      this.toggleTarget.setAttribute("aria-label", this.expanded ? "Collapse section" : "Expand section")
    }
  }
}