# frozen_string_literal: true

# Formulas, and the promise that the ones on screen are the ones that ran.
#
# Runs with or without Rails, like the rest of the engine:
#
#   bin/rails test test/models/tax/formula_test.rb
#   ruby -Itest test/models/tax/formula_test.rb
#
require_relative "engine_test_helper"
require "minitest/autorun"
# Only the round-trip test needs this. The engine itself never touches JSON --
# it takes a plain hash and hands one back, and leaves serialising to Rails.
require "json"

module Tax
  class FormulaTestCase < Minitest::Test
    ON = Date.new(2026, 8, 8)
    RATES = Tax::RateTable.load_file(TaxEngineTestHelper.rate_file)

    def d(value)
      value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
    end

    # A household that has declared 30%, which is the flat tax to the decimal
    # and therefore the assumption that makes a household-rate term and a
    # flat-tax term produce the same number. Useful as a default precisely
    # because it hides nothing: a test that only passes at 30% is a test that
    # was not looking at which rate applied. `at_rate` exists for the cases
    # that have to tell them apart.
    def flat30
      Tax::Assumptions.new(marginal_rate: d("0.30"))
    end

    def at_rate(rate)
      Tax::Assumptions.new(marginal_rate: d(rate))
    end

    def subject(**overrides)
      defaults = {
        id: "acct-1", name: "Test", currency: "EUR",
        accountable_type: "Investment", subtype: "pea", product: "pea",
        value: d(100_000)
      }
      Tax::Subject.new(**defaults.merge(overrides))
    end

    def run_rule(rule, subj, assumptions: nil)
      rule.call(subj, on: ON, rates: RATES, assumptions: assumptions || flat30)
    end

    def composed(**params)
      Tax::Rules::Composed.new(**params)
    end

    # Warnings are Tax::Message objects -- a key and its values -- so that the
    # view edge can render them in the reader's language. The English is what
    # is asserted on here: it is what a locale with no entry falls back to, and
    # it is the sentence a reader actually gets. `to_s` is where a Message
    # becomes it.
    def warned?(result, fragment)
      result.warnings.any? { |w| w.to_s.include?(fragment) }
    end
  end

  # ---------------------------------------------------------------------------

  class FormulaValidationTest < FormulaTestCase
    def test_a_formula_with_no_terms_is_valid_and_means_untaxed
      formula = Tax::Formula.new(terms: [])

      assert formula.valid?, formula.errors.inspect
      assert formula.empty?
    end

    def test_an_unknown_base_is_rejected_rather_than_ignored
      formula = Tax::Formula.new(terms: [ { base: "vibes", rate: "flat_tax" } ])

      refute formula.valid?
      assert_match(/unknown base/, formula.errors.join)
    end

    # A rate name is checked against the country's own file when the caller has
    # it, and only for shape when it does not. The looser branch is not
    # laxness: the set of rate names belongs to the country, and a Formula
    # asked to validate itself with no country in hand cannot tell an invented
    # name from a real Belgian one. Every caller inside the app passes a table.
    def test_a_rate_the_country_does_not_publish_is_rejected
      formula = Tax::Formula.new(terms: [ { base: "full_value", rate: "whatever" } ])

      refute formula.valid?(known_rates: RATES.rate_names)
      assert_match(/unknown rate/, formula.errors(known_rates: RATES.rate_names).join)
    end

    def test_a_rate_this_country_does_publish_is_accepted
      formula = Tax::Formula.new(terms: [ { base: "full_value", rate: "social_charges" } ])

      assert formula.valid?(known_rates: RATES.rate_names),
             formula.errors(known_rates: RATES.rate_names).inspect
    end

    # The household's own rate is never in the file -- it is an assertion by
    # the household, not a figure the country publishes -- so it has to pass
    # the check that the file governs.
    def test_the_household_rate_passes_without_being_in_the_file
      formula = Tax::Formula.new(terms: [ { base: "paid_in_deducted", rate: "household_rate" } ])

      refute_includes RATES.rate_names, "household_rate"
      assert formula.valid?(known_rates: RATES.rate_names),
             formula.errors(known_rates: RATES.rate_names).inspect
    end

    # With no table to check against, a name that could not be a section of any
    # rate file is still refused. That is all the loose branch can honestly do.
    def test_a_malformed_rate_name_is_rejected_even_with_no_country_in_hand
      formula = Tax::Formula.new(terms: [ { base: "full_value", rate: "Not A Rate" } ])

      refute formula.valid?
      assert_match(/unknown rate/, formula.errors.join)
    end

    def test_a_literal_rate_must_carry_a_percentage
      formula = Tax::Formula.new(terms: [ { base: "full_value", rate: "literal" } ])

      refute formula.valid?
      assert_match(/needs a percentage/, formula.errors.join)
    end

    def test_a_rate_above_one_is_rejected
      # 30 rather than 0.30 is the mistake this catches, and it would otherwise
      # produce a tax bill thirty times the account balance without complaint.
      formula = Tax::Formula.new(terms: [ { base: "full_value", rate: "literal", literal_rate: "30" } ])

      refute formula.valid?
      assert_match(/not between 0 and 1/, formula.errors.join)
    end

    # Building a Term runs over stored data, once per account, on a page whose
    # other figures are fine. An unreadable rate has to be an error the reader
    # can act on rather than an exception that takes the page down -- the same
    # bargain the unreadable dates already make.
    def test_a_rate_that_is_not_a_number_is_an_error_rather_than_an_exception
      formula = Tax::Formula.new(
        terms: [ { base: "full_value", rate: "literal", literal_rate: "abc" } ]
      )

      refute formula.valid?
      assert_match(/"abc" is not a number/, formula.errors.join)
    end

    # And it survives storage, so the error comes back with it. Dropping the
    # unreadable value on the way out would have the formula validate cleanly
    # on the second load, which is how a rejected edit becomes an accepted one.
    def test_an_unreadable_rate_survives_a_round_trip
      original = Tax::Formula.new(
        terms: [ { base: "full_value", rate: "literal", literal_rate: "abc" } ]
      )
      reloaded = Tax::Formula.from(JSON.parse(JSON.generate(original.to_h)))

      refute reloaded.valid?
      assert_match(/is not a number/, reloaded.errors.join)
    end

    # A percentage typed into a term that takes a named rate is a contradiction
    # rather than a stray keystroke: one of the two fields is wrong and nothing
    # here can tell which.
    def test_a_percentage_on_a_named_rate_survives_a_round_trip_too
      original = Tax::Formula.new(
        terms: [ { base: "full_value", rate: "flat_tax", literal_rate: "0.1" } ]
      )
      reloaded = Tax::Formula.from(JSON.parse(JSON.generate(original.to_h)))

      refute reloaded.valid?
      assert_match(/belongs only on a literal rate/, reloaded.errors.join)
    end

    def test_a_clock_term_without_a_maturity_period_is_rejected
      formula = Tax::Formula.new(
        terms: [ { base: "gain_over_paid_in", rate: "flat_tax", condition: "mature" } ]
      )

      refute formula.valid?
      assert_match(/maturity/, formula.errors.join)
    end

    def test_a_formula_survives_a_round_trip_through_plain_data
      original = Tax::Formula.new(
        terms: [
          { base: "paid_in_deducted", rate: "progressive" },
          { base: "gain_over_paid_in", rate: "literal", literal_rate: "0.128", condition: "mature" }
        ],
        maturity_years: 8,
        notes: [ "a note" ]
      )

      # This is the trip a stored rule actually makes: object -> jsonb -> object.
      restored = Tax::Formula.from(JSON.parse(JSON.generate(original.to_h)))

      assert_equal original.to_h, restored.to_h
      assert restored.valid?, restored.errors.inspect
      assert_equal 8, restored.maturity_years
    end

    def test_needs_reports_every_fact_the_terms_depend_on
      formula = Tax::Formula.new(
        terms: [
          { base: "gain_over_cost_basis", rate: "flat_tax" },
          { base: "paid_in_deducted", rate: "progressive" }
        ]
      )

      assert_equal %i[cost_basis paid_in], formula.needs.sort
    end
  end

  # ---------------------------------------------------------------------------

  # The point of the whole exercise: what the settings page draws for a
  # built-in rule is the arithmetic that rule performs.
  #
  # Each case runs the hand-written rule and a Rules::Composed built from that
  # rule's declared formula over the same account, and demands the same tax to
  # the cent. Change one without the other and this fails.
  class FormulaEquivalenceTest < FormulaTestCase
    # Balances, payments and dates chosen to cross every branch that matters:
    # a gain and a loss, a mature plan and a young one, an undeclared opening
    # date, a fully deducted pot and a partly deducted one.
    def matrix
      [
        { value: 150_000, paid_in: 100_000, cost_basis: 90_000, opened_on: Date.new(2010, 1, 1) },
        { value: 150_000, paid_in: 100_000, cost_basis: 90_000, opened_on: Date.new(2024, 6, 1) },
        { value:  80_000, paid_in: 100_000, cost_basis: 110_000, opened_on: Date.new(2010, 1, 1) },
        { value: 150_000, paid_in: 100_000, cost_basis: 90_000, opened_on: nil },
        { value: 120_000, paid_in: 100_000, cost_basis: 100_000, opened_on: Date.new(2019, 3, 3),
          paid_in_deducted: 60_000 }
      ]
    end

    def assert_equivalent(rule, extra: {}, skip_keys: [], assumptions: nil)
      formula = rule.class.formula
      refute_nil formula, "#{rule.class} declares no formula"
      assert formula.valid?, "#{rule.class}: #{formula.errors.inspect}"

      twin = Tax::Rules::Composed.new(**formula.to_h.transform_keys(&:to_sym))

      matrix.each_with_index do |row, index|
        attrs = row.merge(extra)
        skip_keys.each { |k| attrs.delete(k) }
        attrs = attrs.transform_values { |v| v.is_a?(Integer) ? d(v) : v }

        subj = subject(**attrs)
        mine = run_rule(rule, subj, assumptions: assumptions)
        theirs = run_rule(twin, subj, assumptions: assumptions)

        assert_equal mine.tax, theirs.tax,
                     "#{rule.class} row #{index + 1} #{attrs.inspect}: rule says " \
                     "#{mine.tax.inspect}, its own formula says #{theirs.tax.inspect}"
      end
    end

    def test_pea_matches_its_formula
      assert_equivalent(Tax::Rules::Fr::Pea.new)
    end

    def test_securities_matches_its_formula
      # No declared figure: #acquisition_cost prefers one when it exists, which
      # is a rule about sourcing rather than about what is taxed and so is
      # deliberately not a term. See the comment on the declaration.
      assert_equivalent(
        Tax::Rules::Fr::Securities.new,
        extra: { accountable_type: "Investment", subtype: "brokerage", product: "cto" },
        skip_keys: [ :paid_in ]
      )
    end

    # Run at a household rate that is *not* the flat tax, so that the two terms
    # of this rule are multiplied by two different numbers. At 30% the rule and
    # its formula could disagree about which rate goes on which base and still
    # come to the same total, which is the one bug this test exists to catch.
    def test_capital_and_gains_matches_its_formula_at_a_household_rate
      assert_equivalent(
        Tax::Rules::Fr::CapitalAndGains.new,
        extra: { product: "per", subtype: nil },
        assumptions: at_rate("0.11")
      )
    end

    def test_capital_and_gains_matches_its_formula_at_a_rate_above_the_flat_tax
      assert_equivalent(
        Tax::Rules::Fr::CapitalAndGains.new,
        extra: { product: "per", subtype: nil },
        assumptions: at_rate("0.41")
      )
    end

    # The elected-bareme twin. Both its terms take the household rate, so this
    # is the case where getting the rate wrong is invisible in the split and
    # visible only in the total.
    def test_capital_and_gains_at_the_household_rate_matches_its_formula
      assert_equivalent(
        Tax::Rules::Fr::CapitalAndGainsAtHouseholdRate.new,
        extra: { product: "per", subtype: nil },
        assumptions: at_rate("0.11")
      )
    end

    def test_deposit_matches_its_formula
      assert_equivalent(
        Tax::Rules::Fr::Deposit.new,
        extra: { accountable_type: "Depository", subtype: "checking", product: "cash" }
      )
    end

    def test_exempt_matches_its_formula
      assert_equivalent(
        Tax::Rules::Exempt.new,
        extra: { accountable_type: "Depository", subtype: "savings", product: "livret_a" }
      )
    end

    def test_every_catalogue_rule_either_declares_a_formula_or_is_the_composer
      # A new rule added without a formula would silently get a settings page
      # that cannot explain it. That is allowed -- some arithmetic will not fit
      # the shape -- but it should be a decision, so this lists the exceptions
      # by name and fails when the list goes stale.
      without = Tax::Catalogue.entries.reject { |id, (klass, _)| klass.formula || id == "composed" }

      assert_empty without.keys, "rules with no declared formula: #{without.keys.inspect}"
    end
  end

  # ---------------------------------------------------------------------------

  class ComposedRuleTest < FormulaTestCase
    def test_it_refuses_when_a_term_needs_a_fact_the_account_does_not_have
      rule = composed(terms: [ { base: "gain_over_paid_in", rate: "flat_tax" } ])
      result = run_rule(rule, subject(paid_in: nil, cost_basis: d(90_000)))

      assert_nil result.tax
      refute result.modelled?
      assert warned?(result, "the total paid in")
      # The near-miss is offered as context and pointedly not used.
      assert warned?(result, "For reference only")
    end

    def test_it_refuses_rather_than_raising_on_a_formula_that_does_not_add_up
      rule = composed(terms: [ { base: "nonsense", rate: "flat_tax" } ])
      result = run_rule(rule, subject(paid_in: d(1_000)))

      assert_nil result.tax
      refute result.modelled?
      assert warned?(result, "does not describe a valid calculation")
    end

    def test_a_formula_with_no_terms_reports_a_true_zero
      result = run_rule(composed(terms: []), subject(paid_in: d(50_000)))

      assert_equal 0, result.tax
      assert result.modelled?
    end

    def test_a_literal_rate_is_applied_as_written
      rule = composed(terms: [ { base: "full_value", rate: "literal", literal_rate: "0.10" } ])
      result = run_rule(rule, subject(value: d(20_000)))

      assert_equal d(2_000), result.tax
    end

    # -- vintage: which rules applied when the account was opened -------------
    #
    # Distinct from the maturity clock. The clock asks how old the wrapper is
    # today; the vintage asks when it was opened, and French tax turns on it
    # repeatedly -- a PEA opened between 2013 and 2017 keeps the social-charge
    # rates in force as each year's gain arose, and an assurance-vie signed
    # before 27 September 2017 is taxed on terms withdrawn for later contracts.

    def vintage_rule
      composed(
        terms: [
          { base: "gain_over_paid_in", rate: "literal", literal_rate: "0.15",
            opened_until: "2017-12-31" },
          { base: "gain_over_paid_in", rate: "literal", literal_rate: "0.30",
            opened_from: "2018-01-01" }
        ]
      )
    end

    def test_a_term_fires_only_for_accounts_opened_inside_its_window
      old = run_rule(vintage_rule, subject(value: d(110_000), paid_in: d(100_000),
                                           opened_on: Date.new(2015, 6, 1)))
      new = run_rule(vintage_rule, subject(value: d(110_000), paid_in: d(100_000),
                                           opened_on: Date.new(2020, 6, 1)))

      assert_equal d(1_500), old.tax
      assert_equal d(3_000), new.tax
    end

    def test_a_window_includes_both_of_its_end_dates
      # A statutory window is written as dates people can be on, so "to
      # 2017-12-31" has to cover an account opened on 2017-12-31.
      last_day  = run_rule(vintage_rule, subject(value: d(110_000), paid_in: d(100_000),
                                                 opened_on: Date.new(2017, 12, 31)))
      first_day = run_rule(vintage_rule, subject(value: d(110_000), paid_in: d(100_000),
                                                 opened_on: Date.new(2018, 1, 1)))

      assert_equal d(1_500), last_day.tax
      assert_equal d(3_000), first_day.tax
    end

    def test_a_windowed_rule_refuses_when_the_opening_date_is_unknown
      # There is no defensible guess here, which is why this refuses rather
      # than assuming the way the maturity clock does. Assuming inside the
      # window taxes the account one way and assuming outside taxes it another;
      # nothing about a missing date favours either, so picking one would be
      # inventing a fact rather than reading a cautious default.
      result = run_rule(vintage_rule, subject(value: d(110_000), paid_in: d(100_000),
                                              opened_on: nil))

      assert_nil result.tax
      refute result.modelled?
      assert warned?(result, "the date the account was opened")
    end

    def test_the_vintage_and_the_clock_narrow_a_term_independently
      # Both gates on one term: opened in the 2013-2017 window *and* past its
      # five-year mark. A 2015 account is both; a 2015 account valued in 2016
      # would be the first without the second.
      rule = composed(
        terms: [
          { base: "gain_over_paid_in", rate: "literal", literal_rate: "0.10",
            condition: "mature", opened_until: "2017-12-31" }
        ],
        maturity_years: 5
      )

      inside = run_rule(rule, subject(value: d(110_000), paid_in: d(100_000),
                                      opened_on: Date.new(2015, 6, 1)))
      outside = run_rule(rule, subject(value: d(110_000), paid_in: d(100_000),
                                       opened_on: Date.new(2020, 6, 1)))

      assert_equal d(1_000), inside.tax
      assert_equal 0, outside.tax, "the vintage should have excluded the only term"
    end

    def test_a_window_that_ends_before_it_starts_is_rejected
      formula = Tax::Formula.new(
        terms: [ { base: "full_value", rate: "flat_tax",
                   opened_from: "2020-01-01", opened_until: "2015-01-01" } ]
      )

      refute formula.valid?
      assert_match(/ends .* before it starts/, formula.errors.join)
    end

    def test_an_unreadable_window_bound_is_rejected_and_survives_storage
      # Dropping the bad value on the way to storage would make the formula
      # look valid the next time it was loaded, which turns a rejected edit
      # into an accepted one.
      formula = Tax::Formula.new(
        terms: [ { base: "full_value", rate: "flat_tax", opened_from: "last Tuesday" } ]
      )

      refute formula.valid?
      assert_match(/'opened from' is not a date/, formula.errors.join)
      refute Tax::Formula.from(formula.to_h).valid?
    end

    def test_the_clock_selects_between_terms
      rule = composed(
        terms: [
          { base: "gain_over_paid_in", rate: "literal", literal_rate: "0.10", condition: "mature" },
          { base: "gain_over_paid_in", rate: "literal", literal_rate: "0.50", condition: "immature" }
        ],
        maturity_years: 5
      )

      old = run_rule(rule, subject(value: d(110_000), paid_in: d(100_000), opened_on: Date.new(2000, 1, 1)))
      new = run_rule(rule, subject(value: d(110_000), paid_in: d(100_000), opened_on: Date.new(2025, 1, 1)))

      assert_equal d(1_000), old.tax
      assert_equal d(5_000), new.tax
      assert warned?(new, "under the 5")
    end

    def test_the_rate_file_overrides_the_clock_declared_in_the_formula
      # Rules::Fr::Pea reads the maturity per product from the rate file and
      # only falls back to its own declared 5. If Composed took the declared
      # figure instead, the two would agree on the shipped file and diverge the
      # moment a self-hoster corrected the table -- and the equivalence test
      # would not notice, because it runs on the shipped file. So the twin
      # sources the number from the same place, and this is the proof.
      rates = Tax::RateTable.new(
        YAML.safe_load_file(TaxEngineTestHelper.rate_file, permitted_classes: [ Date ])
            .tap { |d| d["products"]["pea"]["maturity_years"] = 12 }
      )

      rule = composed(
        terms: [
          { base: "gain_over_paid_in", rate: "literal", literal_rate: "0.10", condition: "mature" },
          { base: "gain_over_paid_in", rate: "literal", literal_rate: "0.50", condition: "immature" }
        ],
        maturity_years: 5
      )

      # Opened 2019: past the declared 5, short of the file's 12.
      subj = subject(value: d(110_000), paid_in: d(100_000), opened_on: Date.new(2019, 1, 1))
      result = rule.call(subj, on: ON, rates: rates, assumptions: flat30)

      assert_equal d(5_000), result.tax, "the file's 12-year clock should have won"
      assert warned?(result, "under the 12")
    end

    def test_an_unknown_opening_date_assumes_mature_and_prints_both_figures
      rule = composed(
        terms: [
          { base: "gain_over_paid_in", rate: "literal", literal_rate: "0.10", condition: "mature" },
          { base: "gain_over_paid_in", rate: "literal", literal_rate: "0.50", condition: "immature" }
        ],
        maturity_years: 5
      )

      result = run_rule(rule, subject(value: d(110_000), paid_in: d(100_000), opened_on: nil))

      assert_equal d(1_000), result.tax
      assert warned?(result, "1000.0")
      assert warned?(result, "5000.0"), result.warnings.inspect
    end

    def test_an_undeclared_deducted_portion_is_assumed_whole_and_said_out_loud
      rule = composed(terms: [ { base: "paid_in_deducted", rate: "literal", literal_rate: "0.20" } ])
      result = run_rule(rule, subject(paid_in: d(50_000), paid_in_deducted: nil))

      assert_equal d(10_000), result.tax
      assert warned?(result, "higher-tax assumption")
    end

    def test_a_deducted_portion_larger_than_the_total_is_capped_and_flagged
      rule = composed(terms: [ { base: "paid_in_deducted", rate: "literal", literal_rate: "0.20" } ])
      result = run_rule(rule, subject(paid_in: d(50_000), paid_in_deducted: d(90_000)))

      assert_equal d(10_000), result.tax
      assert warned?(result, "one of the two figures is wrong")
    end

    # `household_rate_income` is disclosure, not arithmetic. It says how much of
    # this account's base was multiplied by a figure the household typed rather
    # than by one the country publishes, so that the report can total it and
    # say how much of the bill rests on that figure. Nothing downstream feeds
    # it back into a calculation -- a single marginal rate distributes over a
    # sum, so there is nothing to stack.
    def test_a_household_rate_term_discloses_the_base_it_rested_on
      rule = composed(terms: [ { base: "paid_in_deducted", rate: "household_rate" } ])
      result = run_rule(rule, subject(paid_in: d(30_000), paid_in_deducted: d(30_000)),
                        assumptions: at_rate("0.11"))

      assert_equal d(3_300), result.tax
      assert_equal d(30_000), result.household_rate_income
    end

    def test_a_published_rate_term_discloses_nothing
      rule = composed(terms: [ { base: "gain_over_paid_in", rate: "flat_tax" } ])
      result = run_rule(rule, subject(value: d(110_000), paid_in: d(100_000)),
                        assumptions: at_rate("0.11"))

      assert_equal 0, result.household_rate_income
    end

    # The old spelling. A household that saved a rule before the barème came
    # out reads back as one asking for their own marginal rate, which is the
    # arithmetic they were asking for either way.
    def test_a_rule_stored_under_the_old_name_still_runs
      rule = composed(terms: [ { base: "paid_in_deducted", rate: "progressive" } ])
      result = run_rule(rule, subject(paid_in: d(30_000), paid_in_deducted: d(30_000)),
                        assumptions: at_rate("0.11"))

      assert_equal d(3_300), result.tax
      assert_equal "household_rate", rule.formula.terms.first.rate
    end

    def test_named_rates_are_read_at_the_valuation_date
      rule = composed(terms: [ { base: "gain_over_paid_in", rate: "social_charges" } ])
      subj = subject(value: d(110_000), paid_in: d(100_000))

      before = rule.call(subj, on: Date.new(2025, 6, 1), rates: RATES, assumptions: flat30)
      after  = rule.call(subj, on: Date.new(2026, 6, 1), rates: RATES, assumptions: flat30)

      # 17.2% through 2025, 18.6% from 2026. A stored rule keeps giving the
      # right answer for a historic valuation after the rates move.
      assert_equal d(1_720), before.tax
      assert_equal d(1_860), after.tax
    end

    def test_the_basis_states_each_term_that_fired
      rule = composed(
        terms: [
          { base: "paid_in_deducted", rate: "literal", literal_rate: "0.10" },
          { base: "gain_over_paid_in", rate: "literal", literal_rate: "0.20" }
        ]
      )
      result = run_rule(rule, subject(value: d(110_000), paid_in: d(100_000), paid_in_deducted: d(100_000)))

      assert_match(/10\.0% on 100000\.0/, result.basis.to_s)
      assert_match(/20\.0% on 10000\.0/, result.basis.to_s)
      assert_equal d(12_000), result.tax
    end
  end
end
