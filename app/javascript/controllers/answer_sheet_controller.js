import { Controller } from "@hotwired/stimulus"

// The answer sheet beside the booklet on a wide screen, and on a phone a sheet that opens
// over it as a modal dialog: the booklet goes inert behind it, the page stops scrolling,
// focus moves in and comes back to the button, and Escape closes it. It sits under the
// exam bar so the clock stays in sight. Without JavaScript none of this runs and the
// sheet simply follows the booklet. A question number on the sheet is a link back into
// the booklet, so following it closes the sheet.
const WIDE = "(min-width: 64rem)"
const OVERLAY = ["fixed", "inset-x-0", "bottom-0", "top-0", "z-10", "overflow-y-auto", "bg-ground", "px-4", "pb-8", "pt-48", "mt-0"]

export default class extends Controller {
  static targets = ["panel", "booklet", "opener", "closer"]

  connect() {
    this.media = window.matchMedia(WIDE)
    this.layout = () => this.arrange()
    this.media.addEventListener("change", this.layout)
    this.escape = (event) => { if (event.key === "Escape") this.close() }
    this.arrange()
  }

  disconnect() {
    this.media.removeEventListener("change", this.layout)
    this.close()
  }

  arrange() {
    const wide = this.media.matches
    this.openerTarget.classList.toggle("hidden", wide)
    this.panelTarget.classList.toggle("hidden", !wide)
    if (wide) this.close()
  }

  open() {
    this.panelTarget.classList.remove("hidden")
    this.panelTarget.classList.add(...OVERLAY)
    this.panelTarget.setAttribute("role", "dialog")
    this.panelTarget.setAttribute("aria-modal", "true")
    this.closerTarget.classList.remove("hidden")
    this.bookletTarget.inert = true
    this.openerTarget.classList.add("hidden")
    document.body.classList.add("overflow-hidden")
    document.addEventListener("keydown", this.escape)
    this.closerTarget.focus()
  }

  close() {
    if (!this.panelTarget.hasAttribute("role")) return

    this.panelTarget.classList.remove(...OVERLAY)
    this.panelTarget.removeAttribute("role")
    this.panelTarget.removeAttribute("aria-modal")
    this.closerTarget.classList.add("hidden")
    this.bookletTarget.inert = false
    document.body.classList.remove("overflow-hidden")
    document.removeEventListener("keydown", this.escape)
    if (!this.media.matches) {
      this.panelTarget.classList.add("hidden")
      this.openerTarget.classList.remove("hidden")
      this.openerTarget.focus()
    }
  }
}
