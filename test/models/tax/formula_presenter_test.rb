# frozen_string_literal: true

require_relative "engine_test_helper"
require "minitest/autorun"

# What the rules page will say, asserted here rather than through the view.
#
# The presenter is the only place where a rate stops being a name and becomes a
# percentage, which makes it the place where the screen can start disagreeing
# with the engine. So it is tested against the same rate file the engine runs
# on, in the same bare process, and the assertions are on the sentences a
# reader will actually see -- not on whether some hash has the keys it should.
class FormulaPresenterTest < Minitest::Test
  ON = Date.new(2026, 8, 8)

  # 2026 rates: social charges 18.6%, income component 12.8%, so a PFU of 31.4%.
  def rates
    @rates ||= Tax::RateTable.load_file(TaxEngineTestHelper.rate_file("FR"))
  end

  def present(terms, maturity_years: nil, notes: [], product: nil, rates: self.rates, on: ON)
    formula = Tax::Formula.new(terms: terms, maturity_years: maturity_years, notes: notes)
    Tax::FormulaPresenter.new(formula, rates: rates, on: on, product: product)
  end

  # The presenter deals in Tax::Message objects -- a key and its values -- so
  # that TaxReportsHelper can choose a language at the view edge. The English
  # is still the thing under test: it is what a reader with no translation
  # gets, and it is the `default:` every locale falls back to. So the
  # assertions below are written against the sentence, and this is the one
  # place the sentence gets made.
  #
  # A plain String passes through, because some parts genuinely are strings: a
  # formatted percentage, or a note a family typed themselves.
  def english(value) = value.to_s

  # -- resolving a named rate ---------------------------------------------

  def test_a_named_rate_is_shown_as_the_percentage_in_force_on_the_date
    line = present([ { base: "gain_over_paid_in", rate: "social_charges" } ]).lines.first

    assert_equal "18.6% social charges", english(line.rate)
    assert_equal "18.6% social charges on the gain over what was paid in", english(line.sentence)
  end

  # The whole reason rates are looked up at a date rather than frozen into the
  # formula. Same formula, two valuation dates, two percentages on screen.
  def test_the_same_formula_reads_differently_before_and_after_a_rate_change
    terms = [ { base: "gain_over_paid_in", rate: "flat_tax" } ]

    assert_includes english(present(terms, on: Date.new(2025, 6, 1)).lines.first.sentence), "30.0%"
    assert_includes english(present(terms, on: Date.new(2026, 6, 1)).lines.first.sentence), "31.4%"
  end

  def test_a_literal_rate_is_its_own_label
    line = present([ { base: "full_value", rate: "literal", literal_rate: "0.075" } ]).lines.first

    assert_equal "7.5%", english(line.rate)
    assert_equal "7.5% on the whole balance", english(line.sentence)
  end

  # A rate someone typed by hand is a rate they meant, so it is not rounded to
  # the tenth of a point the shipped rates happen to use.
  def test_an_unusual_literal_rate_is_not_rounded_away
    line = present([ { base: "full_value", rate: "literal", literal_rate: "0.0725" } ]).lines.first

    assert_equal "7.25%", english(line.rate)
  end

  # The rules page describes a rule, not a household, so the one rate it cannot
  # resolve even in principle is the household's own. Naming it is the whole
  # answer here: a percentage in this column would be some *other* family's.
  def test_the_household_rate_is_named_rather_than_given_a_percentage
    line = present([ { base: "paid_in_deducted", rate: "household_rate" } ]).lines.first

    assert line.household_rate?
    assert_nil line.percent
    assert_equal "your marginal rate on the deducted payments in", english(line.sentence)
  end

  # Unresolved and household-rate both come out without a number, and the page
  # treats them differently -- one is a gap, the other is the correct rendering
  # -- so the two flags must not collapse into each other.
  def test_the_household_rate_is_not_an_unresolved_rate
    line = present([ { base: "paid_in_deducted", rate: "household_rate" } ]).lines.first

    refute line.unresolved?
  end

  # A rule saved before the barème came out. It reads back under the new name,
  # so the page describes what will actually run rather than what was typed.
  def test_a_rule_stored_under_the_old_name_renders_as_the_household_rate
    line = present([ { base: "paid_in_deducted", rate: "progressive" } ]).lines.first

    assert line.household_rate?
    assert_equal "your marginal rate on the deducted payments in", english(line.sentence)
  end

  # The settings page renders formulas for countries this module ships no rate
  # file for. Naming the rate without a number beats raising on a page whose
  # whole job is to explain something.
  def test_without_a_rate_table_the_rate_is_named_but_not_resolved
    line = present([ { base: "gain_over_paid_in", rate: "social_charges" } ], rates: nil).lines.first

    assert line.unresolved?
    assert_equal "the gain over what was paid in at the social charges rate", english(line.sentence)
  end

  # Same tolerance for a date the shipped file does not reach back to.
  def test_a_date_before_the_rate_file_begins_leaves_the_rate_unresolved
    line = present([ { base: "gain_over_paid_in", rate: "social_charges" } ],
                   on: Date.new(1990, 1, 1)).lines.first

    assert line.unresolved?
    assert_includes english(line.sentence), "social charges"
  end

  # -- the clock -----------------------------------------------------------

  def test_a_conditional_term_states_the_clock_in_years
    lines = present(
      [
        { base: "gain_over_paid_in", rate: "social_charges", condition: "mature" },
        { base: "gain_over_paid_in", rate: "flat_tax", condition: "immature" }
      ],
      maturity_years: 5
    ).lines

    assert_equal "18.6% social charges on the gain over what was paid in, " \
                 "once the account is 5 years old", english(lines[0].sentence)
    assert_equal "31.4% flat tax on the gain over what was paid in, " \
                 "while the account is under 5 years old", english(lines[1].sentence)
  end

  # The failure this guards against is subtle and would be invisible: the page
  # printing the formula's declared clock while Rules::Composed runs the rate
  # file's. Both have to resolve it the same way and from the same place.
  def test_the_rate_file_overrides_the_declared_clock_exactly_as_the_rule_does
    presenter = present(
      [ { base: "gain_over_paid_in", rate: "social_charges", condition: "mature" } ],
      maturity_years: 99, product: "pea"
    )

    assert_equal 5, presenter.maturity_years
    assert_includes english(presenter.lines.first.sentence), "once the account is 5 years old"
  end

  def test_with_no_product_the_declared_clock_stands
    presenter = present(
      [ { base: "gain_over_paid_in", rate: "social_charges", condition: "mature" } ],
      maturity_years: 8
    )

    assert_equal 8, presenter.maturity_years
  end

  # -- the vintage window --------------------------------------------------

  def test_a_bounded_window_is_written_out_in_words
    line = present([
      { base: "gain_over_paid_in", rate: "social_charges",
        opened_from: "2013-01-01", opened_until: "2017-12-31" }
    ]).lines.first

    assert_equal "for accounts opened between 1 January 2013 and 31 December 2017",
                 english(line.window)
  end

  def test_a_half_open_window_says_only_the_bound_it_has
    from = present([
      { base: "full_value", rate: "flat_tax", opened_from: "2018-01-01" }
    ]).lines.first
    till = present([
      { base: "full_value", rate: "flat_tax", opened_until: "2017-09-26" }
    ]).lines.first

    assert_equal "for accounts opened on or after 1 January 2018", english(from.window)
    assert_equal "for accounts opened on or before 26 September 2017", english(till.window)
  end

  # Both narrowings on one term, which is the case the two-gate design exists
  # for: a plan can be old enough to be mature and also of a particular vintage.
  def test_a_term_can_state_both_a_clock_and_a_window
    line = present(
      [ { base: "gain_over_paid_in", rate: "social_charges", condition: "mature",
          opened_from: "2013-01-01", opened_until: "2017-12-31" } ],
      maturity_years: 5
    ).lines.first

    assert_equal "18.6% social charges on the gain over what was paid in, " \
                 "once the account is 5 years old, " \
                 "for accounts opened between 1 January 2013 and 31 December 2017",
                 english(line.sentence)
  end

  # -- the whole formula ---------------------------------------------------

  # The PER shape from the brief: one rate on the amount paid in, another on
  # the gain. This is the sentence that has to be legible to someone deciding
  # whether the rule matches their contract.
  def test_a_two_stream_rule_reads_as_one_sentence
    presenter = present([
      { base: "paid_in_deducted", rate: "household_rate" },
      { base: "gain_over_paid_in", rate: "flat_tax" }
    ])

    assert_equal "Tax is your marginal rate on the deducted payments in " \
                 "and 31.4% flat tax on the gain over what was paid in.",
                 english(presenter.headline)
    assert presenter.uses_household_rate?
  end

  # The elected-barème twin, where both streams take the household's rate. The
  # sentence has to make the difference from the rule above legible at a
  # glance, since choosing between the two is the whole decision.
  def test_the_elected_variant_reads_as_the_household_rate_on_both_streams
    presenter = Tax::FormulaPresenter.new(
      Tax::Rules::Fr::CapitalAndGainsAtHouseholdRate.formula, rates: rates, on: ON
    )

    assert_equal "Tax is your marginal rate on the deducted payments in " \
                 "and your marginal rate on the gain over what was paid in.",
                 english(presenter.headline)
  end

  # A rule that never touches the household's rate must not say it does, or the
  # flag stops meaning anything and the report's disclosure line goes on every
  # account.
  def test_a_rule_on_published_rates_alone_says_it_uses_no_household_rate
    refute present([ { base: "gain_over_paid_in", rate: "flat_tax" } ]).uses_household_rate?
  end

  # "No terms" and "no rule" both produce an empty table, and only one of them
  # means the tax is zero. The presenter has to say which.
  def test_an_empty_formula_says_so_rather_than_saying_nothing
    presenter = present([])

    assert presenter.empty?
    assert_equal "Nothing is taxed when this account is liquidated.", english(presenter.headline)
  end

  def test_the_facts_a_rule_needs_are_listed_in_the_words_the_refusal_uses
    presenter = present([
      { base: "gain_over_cost_basis", rate: "flat_tax" },
      { base: "paid_in", rate: "literal", literal_rate: "0.1", opened_from: "2020-01-01" }
    ])

    assert_equal "Needs the cost basis of what is held, the total paid in " \
                 "and the date the account was opened.", english(presenter.needs_sentence)
  end

  def test_notes_are_carried_through_untouched
    presenter = present([], notes: [ "Assumes a lump sum in one tax year." ])

    assert_equal [ "Assumes a lump sum in one tax year." ], presenter.notes
  end

  def test_an_invalid_formula_reports_its_errors_rather_than_rendering_them
    presenter = present([ { base: "nonsense", rate: "flat_tax" } ])

    refute presenter.valid?
    assert_includes presenter.errors.join(" "), "unknown base"
  end

  # -- against the built-ins ----------------------------------------------

  # Every shipped rule has to render. This is the promise the rules page makes
  # -- that a built-in explains itself in the same vocabulary a family would
  # author with -- and a rule whose formula the presenter cannot describe
  # breaks it silently, by rendering a blank row.
  def test_every_built_in_formula_renders
    Tax::Catalogue.kinds.each do |kind|
      next if Tax::Catalogue.composed?(kind)

      formula = Tax::Catalogue.rule_class(kind).formula
      refute_nil formula, "#{kind} declares no formula"

      presenter = Tax::FormulaPresenter.new(formula, rates: rates, on: ON)
      assert presenter.valid?, "#{kind}: #{presenter.errors.inspect}"
      refute_empty english(presenter.headline), "#{kind} renders an empty headline"

      presenter.lines.each do |line|
        sentence = english(line.sentence)

        refute_empty sentence, "#{kind} renders an empty line"
        # The failure mode a keyed scheme makes newly possible: a term whose
        # base or rate has no entry in Tax::Vocabulary renders as its own
        # identifier, which looks like a sentence to a passing glance and is
        # unreadable to the person it is addressed to.
        refute_match(/\b(gain_over|paid_in|full_value|flat_tax|social_charges)\b/, sentence,
                     "#{kind} leaks a vocabulary key into its sentence: #{sentence}")
      end
    end
  end

  def test_the_pea_rule_reads_the_way_the_page_promises
    presenter = Tax::FormulaPresenter.new(
      Tax::Rules::Fr::Pea.formula, rates: rates, on: ON, product: "pea"
    )

    assert_equal "Tax is 18.6% social charges on the gain over what was paid in, " \
                 "once the account is 5 years old and 31.4% flat tax on the gain " \
                 "over what was paid in, while the account is under 5 years old.",
                 english(presenter.headline)
  end
end
