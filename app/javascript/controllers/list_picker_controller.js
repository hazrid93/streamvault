import { Controller } from "@hotwired/stimulus"

// "Add to list" dropdown on a poster card.  On open, fetches the user's
// lists from /lists/index_json, renders them as a menu, and POSTs the
// item to the chosen list's add_item endpoint.  Includes a "New list"
// shortcut that links to the new-list form pre-filled with the item.
export default class extends Controller {
  static targets = ["menu", "list", "spinner"]
  static values = {
    imdbId: String,
    title: String,
    posterUrl: String,
    year: String,
    contentType: String
  }

  connect() {
    this.loaded = false
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.menuTarget.classList.contains("hidden")) {
      this.open()
    } else {
      this.close()
    }
  }

  async open() {
    this.menuTarget.classList.remove("hidden")
    if (!this.loaded) {
      await this.loadLists()
    }
  }

  close() {
    this.menuTarget.classList.add("hidden")
  }

  async loadLists() {
    if (this.hasSpinnerTarget) this.spinnerTarget.classList.remove("hidden")
    try {
      const res = await fetch("/lists/index_json", { headers: { "Accept": "application/json" } })
      if (!res.ok) throw new Error("fetch failed")
      const lists = await res.json()
      this.renderLists(lists)
      this.loaded = true
    } catch (e) {
      if (this.hasListTarget) this.listTarget.innerHTML = '<p class="px-3 py-2 text-sv-text-muted">Couldn\'t load lists</p>'
    } finally {
      if (this.hasSpinnerTarget) this.spinnerTarget.classList.add("hidden")
    }
  }

  renderLists(lists) {
    if (!this.hasListTarget) return
    if (lists.length === 0) {
      this.listTarget.innerHTML = '<p class="px-3 py-2 text-sv-text-muted text-xs">No lists yet.</p>'
      return
    }
    this.listTarget.innerHTML = lists.map((l) =>
      `<button type="button" data-action="click->list-picker#addToList" data-list-id="${l.id}" class="block w-full text-left px-3 py-1.5 text-xs text-white hover:bg-sv-accent/20 rounded">${this.escape(l.name)}</button>`
    ).join("")
  }

  async addToList(event) {
    const listId = event.currentTarget.dataset.listId
    const formData = new FormData()
    formData.append("imdb_id", this.imdbIdValue)
    formData.append("title", this.titleValue)
    formData.append("poster_url", this.posterUrlValue)
    formData.append("year", this.yearValue)
    formData.append("content_type", this.contentTypeValue)
    const csrf = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      const res = await fetch(`/lists/${listId}/add_item`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf },
        body: formData
      })
      if (res.ok) {
        event.currentTarget.textContent = "✓ Added"
        event.currentTarget.classList.add("text-sv-accent")
        setTimeout(() => this.close(), 800)
      }
    } catch (e) { /* ignore */ }
  }

  escape(s) {
    const d = document.createElement("div")
    d.textContent = s
    return d.innerHTML
  }
}