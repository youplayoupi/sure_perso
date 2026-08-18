import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="tax-rows"
//
// Adds a row to one of the rates screen's lists, following the same
// template-and-placeholder pattern as the rule builder next door: the server
// renders one hidden copy of the row, and this stamps a unique index into it
// on the way in. Rendering the row on the server rather than assembling it
// here is what keeps an added row identical to a stored one, labels and
// translations included.
//
// Generic where tax-formula is specific, because this page has several lists
// -- two rate schedules, the bracket years, and the bands inside each year --
// and they nest. One instance is scoped to each list.
//
// The placeholder is configurable for exactly that nesting. A bracket year and
// the bands inside it are both cloned from templates, so they cannot share a
// token: replacing every IDX_PLACEHOLDER when a year is added would also
// consume the one belonging to the band template it carries, and the first
// band added afterwards would post under the literal string.
//
// The index has to be unique rather than sequential. Rows can be removed from
// the middle, and reusing a position would put two rows under the same key --
// a date silently paired with another row's rate, on a page whose entire
// subject is arithmetic. A counter that only goes up is enough, seeded past
// whatever the server already rendered.
export default class extends Controller {
  static targets = ["template", "list"];
  static values = { placeholder: { type: String, default: "IDX_PLACEHOLDER" } };

  connect() {
    this.nextIndex = this.listTarget.children.length;
  }

  add() {
    const html = this.templateTarget.innerHTML.replaceAll(
      this.placeholderValue,
      `new_${this.nextIndex++}`,
    );

    this.listTarget.insertAdjacentHTML("beforeend", html);
  }
}
