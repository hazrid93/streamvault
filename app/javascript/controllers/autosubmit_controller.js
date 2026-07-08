import { Controller } from "@hotwired/stimulus"

// Submits its <form> on any field change — used by the browse filter
// dropdowns.  Defined as a Stimulus controller (not an inline onchange
// handler) so it survives the app's strict script-src CSP.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}