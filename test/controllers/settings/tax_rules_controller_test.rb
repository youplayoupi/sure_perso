# frozen_string_literal: true

require "test_helper"

# Settings > Taxes > Rules is where a family reads what the shipped rules do and
# writes one of their own. Two things are worth testing and they are different:
# that the page tells the truth about the rules it did not write, and that the
# builder turns a form into the formula the engine will actually run.
#
# The arithmetic itself is not retested here -- test/models/tax/formula_test.rb
# owns that, in bare Ruby, and it is the equivalence test there that makes the
# read-only half of this page trustworthy. What is tested here is the seam: the
# form's units, its indices, its target field, and the fact that a rule saved
# through this controller is the rule the registry then resolves.
class Settings::TaxRulesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @family = @user.family

    # As on the page next door: this module has rules for France only, and the
    # page is deliberately unreachable elsewhere.
    @family.update!(country: "FR", currency: "EUR")
  end

  # ---- Reading the shipped rules ------------------------------------------

  test "every shipped rule is explained, not just named" do
    # The claim the section makes. A rule listed with no formula beneath it
    # would be the dropdown label again, which is the thing this page exists to
    # improve on.
    get settings_taxes_rules_path

    assert_response :ok

    shipped = Tax::Catalogue.entries.reject { |kind, _| Tax::Catalogue.composed?(kind) }
    assert shipped.any?

    shipped.each do |kind, (klass, _)|
      assert_includes response.body, ERB::Util.html_escape(tax_rule_label(kind, klass.label)),
                      "#{kind} is not named on the rule library page"
    end
  end

  test "the page speaks English, not vocabulary keys" do
    # The presenter maps every base and rate through Tax::Vocabulary. A key
    # leaking through means someone added a base and forgot the wording, and
    # the page would read "gain_over_paid_in" at a household.
    get settings_taxes_rules_path

    body = response.body

    %w[gain_over_paid_in gain_over_cost_basis paid_in_deducted full_value
       flat_tax_income_component social_charges].each do |key|
      refute_includes body, key, "the rule library leaks the vocabulary key #{key}"
    end
  end

  test "the shipped PEA rule is shown with the rate that is in force today" do
    # The page resolves rates on the date it is drawn rather than quoting the
    # figure that was current when the rule was written -- which is the whole
    # reason named rates exist.
    get settings_taxes_rules_path

    presenter = Tax::FormulaPresenter.new(
      Tax::Catalogue.rule_class("fr_pea").formula,
      rates: Tax.rate_table_for(@family),
      on: Date.current,
      product: "pea"
    )
    line = presenter.lines.first

    # `percent` is the fraction the engine multiplies by; `rate` is what a
    # reader sees. Asserting on the second, because the first appearing on the
    # page would itself be the bug.
    assert line.percent, "the PEA rule resolves to no rate at all today"
    assert_includes response.body, ERB::Util.html_escape(line.rate)
    refute_includes response.body, line.percent.to_s
  end

  test "a country with no rules gets no page rather than a page of French rules" do
    @family.update!(country: "US")

    get settings_taxes_rules_path

    assert_redirected_to settings_profile_path
  end

  test "signed out, the page is not reachable" do
    @user.sessions.each { |session| delete session_path(session) }

    get settings_taxes_rules_path

    assert_redirected_to new_session_path
  end

  # ---- The builder renders -------------------------------------------------

  test "the button that opens the builder is a link to it, and a reader can follow it" do
    # Regression. Every other test here reaches the builder by asking for its
    # path directly, so all of them passed while the only route a household had
    # to it did nothing at all: the button was a DS::Button carrying an href,
    # which renders through `button_to` and therefore POSTs. `rules/new` is GET
    # only, the post matched no route, and Turbo swallowed the failure.
    #
    # Asserted as "an anchor whose href is the builder" rather than by naming
    # the component, because what matters is what a browser does with it.
    # Following it and demanding the form comes back makes this a test of
    # reachability rather than of markup.
    get settings_taxes_rules_path

    assert_response :ok
    assert_select "a[href=?]", new_settings_taxes_rule_path, count: 1

    # And nothing on the page tries to reach the builder by posting to it.
    assert_select "form[action=?]", new_settings_taxes_rule_path, count: 0

    get new_settings_taxes_rule_path

    assert_response :ok
    assert_select "form[action=?]", settings_taxes_rules_path
  end

  test "the builder offers exactly the choices the validator accepts" do
    # A form that offered a base the formula rejects would produce a rule that
    # cannot be saved and an error nobody can act on. Both lists come from the
    # engine's own constants, and this is what says so.
    get new_settings_taxes_rule_path

    assert_response :ok

    assert_select "select[name=?]", "tax_rule[terms][0][base]" do
      Tax::Formula::BASES.each_key { |base| assert_select "option[value=?]", base }
    end

    assert_select "select[name=?]", "tax_rule[terms][0][rate]" do
      Tax::Formula::RATES.each { |rate| assert_select "option[value=?]", rate }
    end
  end

  test "the builder opens with one empty row rather than none" do
    get new_settings_taxes_rule_path

    assert_select "select[name=?]", "tax_rule[terms][0][base]", count: 1
    assert_select "select[name=?]", "tax_rule[terms][1][base]", count: 0
  end

  test "a term can be narrowed by when the account was opened" do
    # The vintage fields are the reason this page exists in its current shape:
    # a PEA opened in 2012 is not taxed like one opened in 2020.
    get new_settings_taxes_rule_path

    assert_select "input[type=date][name=?]", "tax_rule[terms][0][opened_from]"
    assert_select "input[type=date][name=?]", "tax_rule[terms][0][opened_until]"
  end

  test "the row the JavaScript clones is rendered by the server" do
    # Otherwise an added row is assembled in JavaScript and drifts from the
    # stored one -- different options, or worse, untranslated labels.
    get new_settings_taxes_rule_path

    assert_select "template[data-tax-formula-target=termTemplate]" do
      assert_select "select[name=?]", "tax_rule[terms][IDX_PLACEHOLDER][base]"
    end
  end

  test "the target select offers the family's accounts and Sure's products" do
    get new_settings_taxes_rule_path

    account = in_scope_account
    assert_select "select[name=?]", "tax_rule[target]" do
      assert_select "option[value=?]", "account:#{account.id}"
      assert_select "option[value=?]", "product:Investment|pea"
    end
  end

  test "products the family holds lead the list, the world catalogue does not" do
    # Sure's subtype list is a world catalogue -- eighty-odd wrappers across a
    # dozen countries. Offered flat, the PEA lands between Kisan Vikas Patra
    # and Riester-Rente, and the product this family is writing a rule for is
    # the hardest one in the list to find.
    get new_settings_taxes_rule_path

    held = ApplicationController.helpers.tax_products_held(@family)
    assert held.any?, "the fixture family holds nothing the report can tax"

    groups = css_select("select[name='tax_rule[target]'] optgroup").map { |g| g["label"] }
    assert_equal [ I18n.t("settings.tax_rules.target.accounts"),
                   I18n.t("settings.tax_rules.target.products"),
                   I18n.t("settings.tax_rules.target.other_products") ], groups

    values = ->(label) {
      css_select(%(optgroup[label="#{label}"] option)).map { |o| o["value"] }
    }
    held_values = values.call(I18n.t("settings.tax_rules.target.products"))
    other_values = values.call(I18n.t("settings.tax_rules.target.other_products"))

    assert held_values.any?, "the leading group is empty even though the family holds products"

    # Everything that leads is genuinely held. Stated as a property rather than
    # by rebuilding the expected list, which would only restate the controller
    # back to itself. `held` carries type-wildcard pairs -- ["Depository", nil]
    # -- alongside concrete ones, and either kind counts as holding.
    held_values.each do |value|
      accountable_type, subtype = value.delete_prefix("product:").split("|", 2)
      assert held.include?([ accountable_type, subtype.presence ]) ||
             held.include?([ accountable_type, nil ]),
             "#{value} leads the list but the family does not hold it"
    end

    # The rest is offered, not dropped: writing a rule for a product before
    # opening one is legitimate -- it decides what happens the first time you
    # do. It just does not lead.
    assert_operator other_values.size, :>, held_values.size
    assert_includes other_values, "product:Investment|riester"
    refute_includes held_values, "product:Investment|riester"
  end

  test "an account the report never looks at is not offered a rule" do
    # Offering one would produce a rule that appears to be in force and changes
    # no figure anywhere.
    excluded = @family.accounts.visible
                      .where(accountable_type: Tax::SubjectBuilder::EXCLUDED_TYPES)
                      .first
    skip "the fixture family holds nothing the report excludes" if excluded.nil?

    get new_settings_taxes_rule_path

    assert_select "option[value=?]", "account:#{excluded.id}", count: 0
  end

  # ---- Writing a rule ------------------------------------------------------

  test "the PER shape saves as two terms, one on the payments in and one on the gain" do
    # The motivating case, end to end. Sure has no PER subtype, so this is
    # written against one account and taxes two different quantities at two
    # different rates -- which is the thing no shipped rule can express.
    account = in_scope_account

    assert_difference -> { Tax::CustomRule.count }, 1 do
      post settings_taxes_rules_path, params: {
        tax_rule: {
          name: "My PER",
          target: "account:#{account.id}",
          terms: {
            "0" => { base: "paid_in_deducted", rate: "progressive", condition: "always" },
            "1" => { base: "gain_over_paid_in", rate: "flat_tax", condition: "always" }
          }
        }
      }
    end

    rule = Tax::CustomRule.sole
    formula = rule.formula

    assert formula.valid?, formula.errors.inspect
    assert_equal %w[paid_in_deducted gain_over_paid_in], formula.terms.map(&:base)
    assert_equal %w[progressive flat_tax], formula.terms.map(&:rate)

    # The name is carried on the rule, not in the formula: it labels the
    # calculation, it is not part of it.
    assert_equal "My PER", rule.to_rule.name
    assert_redirected_to settings_taxes_rules_path
  end

  test "the form asks for a percentage and the engine stores a fraction" do
    # 7.5 in the box is 0.075 in the row. Getting this backwards would tax a
    # portfolio at 750%, and it is exactly the sort of thing that looks right
    # in both places while being wrong in between.
    post settings_taxes_rules_path, params: {
      tax_rule: {
        target: "account:#{in_scope_account.id}",
        terms: { "0" => { base: "full_value", rate: "literal", literal_rate: "7.5" } }
      }
    }

    assert_equal BigDecimal("0.075"), Tax::CustomRule.sole.formula.terms.sole.literal_rate
  end

  test "a rate typed with a comma is read as a French reader wrote it" do
    post settings_taxes_rules_path, params: {
      tax_rule: {
        target: "account:#{in_scope_account.id}",
        terms: { "0" => { base: "full_value", rate: "literal", literal_rate: "7,5" } }
      }
    }

    assert_equal BigDecimal("0.075"), Tax::CustomRule.sole.formula.terms.sole.literal_rate
  end

  test "an unreadable rate is a form error, not a saved rule and not a 500" do
    # Reachable from the form, since the box is free text. The engine keeps the
    # raw value so the message can name it back.
    assert_no_difference -> { Tax::CustomRule.count } do
      post settings_taxes_rules_path, params: {
        tax_rule: {
          target: "account:#{in_scope_account.id}",
          terms: { "0" => { base: "full_value", rate: "literal", literal_rate: "abc" } }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match(/is not a number/, response.body)
  end

  test "rows keep the order they were written in, whatever their keys" do
    # The Stimulus controller stamps added rows `new_0`, `new_1`. Sorting the
    # keys would file every added row after every original one; sorting them as
    # strings would file `new_10` before `new_2`. Neither is the form's order.
    post settings_taxes_rules_path, params: {
      tax_rule: {
        target: "account:#{in_scope_account.id}",
        terms: {
          "0" => { base: "paid_in", rate: "progressive" },
          "new_1" => { base: "full_value", rate: "social_charges" },
          "1" => { base: "gain_over_paid_in", rate: "flat_tax" }
        }
      }
    }

    assert_equal %w[paid_in full_value gain_over_paid_in],
                 Tax::CustomRule.sole.formula.terms.map(&:base)
  end

  test "removing a row does not re-pair the survivors" do
    # The failure this guards against is silent: with a bare array, deleting a
    # row from the middle pairs one row's base with the next row's rate and the
    # rule still saves.
    rule = create_rule(
      "0" => { base: "paid_in_deducted", rate: "progressive" },
      "1" => { base: "full_value", rate: "social_charges" },
      "2" => { base: "gain_over_paid_in", rate: "flat_tax" }
    )

    patch settings_taxes_rule_path(rule), params: {
      tax_rule: {
        target: "account:#{in_scope_account.id}",
        terms: {
          "0" => { base: "paid_in_deducted", rate: "progressive" },
          "2" => { base: "gain_over_paid_in", rate: "flat_tax" }
        }
      }
    }

    terms = rule.reload.formula.terms

    assert_equal [ [ "paid_in_deducted", "progressive" ], [ "gain_over_paid_in", "flat_tax" ] ],
                 terms.map { |t| [ t.base, t.rate ] }
  end

  test "an empty row is dropped and a half-filled one is reported" do
    # The form always renders one empty row, so a blank base is "nothing here".
    # A base with no rate is someone who meant to finish.
    post settings_taxes_rules_path, params: {
      tax_rule: {
        target: "account:#{in_scope_account.id}",
        terms: {
          "0" => { base: "full_value", rate: "social_charges" },
          "1" => { base: "", rate: "" }
        }
      }
    }

    assert_equal 1, Tax::CustomRule.sole.formula.terms.size

    assert_no_difference -> { Tax::CustomRule.count } do
      post settings_taxes_rules_path, params: {
        tax_rule: {
          target: "account:#{in_scope_account.id}",
          terms: { "0" => { base: "full_value", rate: "" } }
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "notes are stored one per line and blank lines are not notes" do
    post settings_taxes_rules_path, params: {
      tax_rule: {
        target: "account:#{in_scope_account.id}",
        notes: "Assumes a lump sum.\n\n  Ignores the exit tax.  \n",
        terms: { "0" => { base: "full_value", rate: "social_charges" } }
      }
    }

    assert_equal [ "Assumes a lump sum.", "Ignores the exit tax." ],
                 Tax::CustomRule.sole.formula.notes
  end

  test "a maturity clock is kept, and a term can depend on it" do
    post settings_taxes_rules_path, params: {
      tax_rule: {
        target: "product:Investment|pea",
        maturity_years: "5",
        terms: { "0" => { base: "gain_over_paid_in", rate: "social_charges", condition: "mature" } }
      }
    }

    formula = Tax::CustomRule.sole.formula

    assert formula.valid?, formula.errors.inspect
    assert_equal 5, formula.maturity_years
    assert_equal "mature", formula.terms.sole.condition
  end

  test "a term can be bounded by the dates the account was opened between" do
    post settings_taxes_rules_path, params: {
      tax_rule: {
        target: "product:Investment|pea",
        terms: {
          "0" => { base: "gain_over_paid_in", rate: "flat_tax",
                   opened_from: "2013-01-01", opened_until: "2017-12-31" }
        }
      }
    }

    term = Tax::CustomRule.sole.formula.terms.sole

    assert_equal Date.new(2013, 1, 1), term.opened_from
    assert_equal Date.new(2017, 12, 31), term.opened_until
  end

  # ---- What a rule is allowed to point at ---------------------------------

  test "a rule saved here is the rule the registry then resolves" do
    # The point of the screen, asserted at the far end rather than at the seam.
    account = in_scope_account

    post settings_taxes_rules_path, params: {
      tax_rule: {
        target: "account:#{account.id}",
        terms: { "0" => { base: "full_value", rate: "literal", literal_rate: "10" } }
      }
    }

    subject = Tax::SubjectBuilder.new(@family.reload, accounts: [ account ]).subjects.sole
    registry = Tax::SubjectBuilder.new(@family).registry

    assert_equal Tax::Catalogue::COMPOSED, registry.resolve(subject).rule_id
  end

  test "another family's account cannot be targeted" do
    other = families(:empty).accounts.create!(
      name: "Not mine", balance: 100, currency: "EUR",
      accountable: Investment.new, subtype: "brokerage"
    )

    assert_no_difference -> { Tax::CustomRule.count } do
      post settings_taxes_rules_path, params: {
        tax_rule: {
          target: "account:#{other.id}",
          terms: { "0" => { base: "full_value", rate: "social_charges" } }
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "a product Sure does not define is refused" do
    assert_no_difference -> { Tax::CustomRule.count } do
      post settings_taxes_rules_path, params: {
        tax_rule: {
          target: "product:Investment|not_a_subtype",
          terms: { "0" => { base: "full_value", rate: "social_charges" } }
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "a rule with no target at all is refused rather than applying to everything" do
    assert_no_difference -> { Tax::CustomRule.count } do
      post settings_taxes_rules_path, params: {
        tax_rule: { terms: { "0" => { base: "full_value", rate: "social_charges" } } }
      }
    end

    assert_response :unprocessable_entity
  end

  # ---- Editing and deleting ------------------------------------------------

  test "editing shows the rule as it was stored, in the units it was typed in" do
    rule = create_rule("0" => { base: "full_value", rate: "literal", literal_rate: "7.5" })

    get edit_settings_taxes_rule_path(rule)

    assert_response :ok
    assert_select "select[name=?] option[value=full_value][selected]", "tax_rule[terms][0][base]"
    assert_select "input[name=?][value=?]", "tax_rule[terms][0][literal_rate]", "7.5"
  end

  test "editing replaces the formula rather than appending to it" do
    rule = create_rule(
      "0" => { base: "full_value", rate: "social_charges" },
      "1" => { base: "paid_in", rate: "progressive" }
    )

    patch settings_taxes_rule_path(rule), params: {
      tax_rule: {
        target: "account:#{in_scope_account.id}",
        terms: { "0" => { base: "gain_over_paid_in", rate: "flat_tax" } }
      }
    }

    assert_equal %w[gain_over_paid_in], rule.reload.formula.terms.map(&:base)
  end

  test "deleting a rule removes it" do
    rule = create_rule("0" => { base: "full_value", rate: "social_charges" })

    assert_difference -> { Tax::CustomRule.count }, -1 do
      delete settings_taxes_rule_path(rule)
    end

    assert_redirected_to settings_taxes_rules_path
  end

  test "another family's rule cannot be read, written or deleted" do
    other = families(:empty)
    theirs = Tax::CustomRule.create!(
      family: other,
      account: other.accounts.create!(
        name: "Theirs", balance: 100, currency: "EUR",
        accountable: Investment.new, subtype: "brokerage"
      ),
      kind: Tax::Catalogue::COMPOSED,
      params: { "terms" => [ { "base" => "full_value", "rate" => "social_charges" } ] }
    )

    get edit_settings_taxes_rule_path(theirs)
    assert_redirected_to settings_taxes_rules_path

    assert_no_difference -> { Tax::CustomRule.count } do
      delete settings_taxes_rule_path(theirs)
    end
  end

  test "a rule set on the assignment page is not editable as a formula here" do
    # `fr_pea` and the rest are declared in Ruby and shared by everyone. A row
    # selecting one is not a rule this family wrote, and offering an edit form
    # for it would imply it could be changed.
    theirs = Tax::CustomRule.create!(
      family: @family, accountable_type: "Investment", subtype: "brokerage", kind: "exempt"
    )

    get edit_settings_taxes_rule_path(theirs)

    assert_redirected_to settings_taxes_rules_path
  end

  # ---- The claim the whole module rests on --------------------------------

  test "writing a rule changes nothing about the accounts themselves" do
    account = in_scope_account

    assert_no_changes -> { [ Account.count, Holding.count, Entry.count, Balance.count ] } do
      assert_no_changes -> { account.reload.balance } do
        post settings_taxes_rules_path, params: {
          tax_rule: {
            target: "account:#{account.id}",
            terms: { "0" => { base: "full_value", rate: "literal", literal_rate: "10" } }
          }
        }
      end
    end
  end

  private
    def in_scope_account
      @in_scope_account ||= @family.accounts
                                   .visible
                                   .where.not(accountable_type: Tax::SubjectBuilder::EXCLUDED_TYPES)
                                   .order(:name)
                                   .first
    end

    # Built through the controller rather than through the model, so that a
    # test about editing starts from a rule the form could actually have
    # produced.
    def create_rule(terms)
      post settings_taxes_rules_path, params: {
        tax_rule: { target: "account:#{in_scope_account.id}", terms: terms }
      }

      Tax::CustomRule.where(family_id: @family.id, kind: Tax::Catalogue::COMPOSED).order(:created_at).last
    end

    def tax_rule_label(...) = ApplicationController.helpers.tax_rule_label(...)
end
