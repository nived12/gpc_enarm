import { Controller } from "@hotwired/stimulus"

// Opens the answer sheet over the booklet on a phone and closes it again. On a wide
// screen the sheet sits beside the booklet and these do nothing visible. A question
// number on the sheet is a link back into the booklet, so following it closes the sheet.
export default class extends Controller {
  static targets = ["panel"]

  open() {
    this.panelTarget.classList.remove("hidden")
  }

  close() {
    this.panelTarget.classList.add("hidden")
  }
}
