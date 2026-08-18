import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="tax-formula"
//
// Adds a term to the rule builder, following the same template-and-placeholder
// pattern as the transaction rules form: the server renders one hidden copy of
// the row, and this stamps a unique index into it on the way in.
//
// The index has to be unique rather than sequential. Rows can be removed from
// the middle, and reusing a position would have two rows submitting under the
// same key -- one base silently paired with another row's rate, in a form whose
// entire subject is arithmetic. A counter that only ever goes up is enough,
// seeded past whatever the server already rendered so an added row can never
// collide with an existing one.
export default class extends Controller {
  static targets = ["termTemplate", "termsList"];

  connect() {
    this.nextIndex = this.termsListTarget.children.length;
  }

  addTerm() {
    const html = this.termTemplateTarget.innerHTML.replaceAll(
      "IDX_PLACEHOLDER",
      `new_${this.nextIndex++}`,
    );

    this.termsListTarget.insertAdjacentHTML("beforeend", html);
  }
}
