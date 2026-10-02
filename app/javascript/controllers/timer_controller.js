import { Controller } from "@hotwired/stimulus"

// Ticks the exam clock between page loads. The server's figure is the truth: every page
// starts from the elapsed seconds it rendered, so a reload or a pause never gains time.
// On a timed exam, reaching zero submits the finish form — the server checks the clock
// again and ends the exam there. A rehearsal of the real exam also shows its one
// warning, once, when the time left reaches warnAt.
export default class extends Controller {
  static targets = ["display", "expire"]
  static values = { elapsed: Number, limit: Number, warnAt: Number, warningId: String }

  connect() {
    this.loadedAt = Date.now()
    this.interval = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    clearInterval(this.interval)
  }

  tick() {
    const elapsed = this.elapsedValue + Math.floor((Date.now() - this.loadedAt) / 1000)
    const timed = this.limitValue > 0
    const shown = timed ? Math.max(this.limitValue - elapsed, 0) : elapsed
    this.displayTarget.textContent = this.format(shown)

    const warning = this.warningIdValue && document.getElementById(this.warningIdValue)
    if (timed && warning && !warning.textContent && shown <= this.warnAtValue) {
      warning.textContent = warning.dataset.message
    }

    if (timed && shown === 0) {
      clearInterval(this.interval)
      this.expireTarget.requestSubmit()
    }
  }

  format(seconds) {
    const hours = Math.floor(seconds / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    const secs = String(seconds % 60).padStart(2, "0")
    return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${secs}` : `${minutes}:${secs}`
  }
}
