import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["track", "prevBtn", "nextBtn"]

  connect() {
    this.scrollAmount = 300
    this.updateTimer = null
    this.handleKeydown = this.handleKeydown.bind(this)
    this.scheduleButtonUpdate = this.scheduleButtonUpdate.bind(this)
    this.trackTarget.addEventListener("keydown", this.handleKeydown)
    this.trackTarget.addEventListener("scroll", this.scheduleButtonUpdate, { passive: true })
    window.addEventListener("resize", this.scheduleButtonUpdate)
    this.updateButtons()
  }

  disconnect() {
    this.trackTarget.removeEventListener("keydown", this.handleKeydown)
    this.trackTarget.removeEventListener("scroll", this.scheduleButtonUpdate)
    window.removeEventListener("resize", this.scheduleButtonUpdate)
    if (this.updateTimer) {
      clearTimeout(this.updateTimer)
      this.updateTimer = null
    }
  }

  handleKeydown(event) {
    if (event.key === "ArrowLeft") {
      event.preventDefault()
      this.prev()
    } else if (event.key === "ArrowRight") {
      event.preventDefault()
      this.next()
    }
  }

  scheduleButtonUpdate() {
    if (this.updateTimer) clearTimeout(this.updateTimer)
    this.updateTimer = setTimeout(() => this.updateButtons(), 80)
  }

  prev() {
    this.trackTarget.scrollBy({ left: -this.scrollAmount * 2, behavior: "smooth" })
    this.updateTimer = setTimeout(() => this.updateButtons(), 350)
  }

  next() {
    this.trackTarget.scrollBy({ left: this.scrollAmount * 2, behavior: "smooth" })
    this.updateTimer = setTimeout(() => this.updateButtons(), 350)
  }

  updateButtons() {
    const track = this.trackTarget
    if (!this.hasPrevBtnTarget || !this.hasNextBtnTarget) return
    this.updateTimer = null
    this.prevBtnTarget.classList.toggle("invisible", track.scrollLeft <= 10)
    this.nextBtnTarget.classList.toggle("invisible", track.scrollLeft + track.clientWidth >= track.scrollWidth - 10)
  }
}
