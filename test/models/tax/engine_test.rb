# frozen_string_literal: true

# The rule engine, tested without Rails.
#
# Every class under test is a pure function over value objects, so this file
# boots in a bare Ruby process in about a tenth of a second. That is not a
# micro-optimisation: it means the tax arithmetic can be exercised and diffed
# against the reference implementation without a database, which is the only
# reason the numbers below could be verified at all.
#
#   bin/rails test test/models/tax/engine_test.rb     # inside Rails
#   ruby -Itest test/models/tax/engine_test.rb        # standalone
#
require_relative "engine_test_helper"
require "minitest/autorun"

module Tax
  class EngineTestCase < Minitest::Test
    ON = Date.new(2026, 8, 8)
    RATES = Tax::RateTable.load_file(TaxEngineTestHelper.rate_file)

    # A household that has stated 30%. Named for the number rather than for
    # the mechanism, because the mechanism is now the only one there is: the
    # module asks for a marginal rate and multiplies by it.
    def flat30
      Tax::Assumptions.new(marginal_rate: d("0.30"))
    end

    def at_rate(rate)
      Tax::Assumptions.new(marginal_rate: d(rate))
    end

    # A household that has not said. Distinct from `flat30` even though the
    # placeholder happens to be 30% today, because what is being tested is that
    # the report says so rather than what the figure is.
    def undeclared
      Tax::Assumptions.new(marginal_rate: nil)
    end

    def d(value)
      value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
    end

    def subject(**overrides)
      defaults = {
        id: "acct-1", name: "Test", currency: "EUR",
        accountable_type: "Investment", subtype: "pea", product: "pea",
        value: d(100_000)
      }
      Tax::Subject.new(**defaults.merge(overrides))
    end

    def registry(custom_rules: [])
      Tax::Registry.new(country: "FR", custom_rules: custom_rules)
    end

    def apply(subj, on: ON, assumptions: nil)
      registry.apply(subj, on: on, rates: RATES, assumptions: assumptions || flat30)
    end

    # Warnings are Tax::Message objects now, not strings: the engine names its
    # sentences so they can be translated and renders the English only when
    # asked. Asserting on the rendered English is still the right test -- it is
    # what the crosscheck script prints and what a reader with no translation
    # gets -- so this is where the rendering happens.
    def warned?(result, fragment)
      result.warnings.any? { |w| w.to_s.include?(fragment) }
    end
  end

  # -------------------------------------------------------------------------

  # The household's own rate, and what the module does when it does not have
  # one. This is the hinge the whole rewrite turns on: the module may not
  # refuse to draw the report (a blank page helps nobody), and it may not
  # present a guess with the same confidence as a figure off the rate file.
  # The resolution is that it computes and announces.
  class AssumptionsTest < EngineTestCase
    def test_a_declared_rate_is_used_and_known_to_be_declared
      a = Tax::Assumptions.new(marginal_rate: d("0.41"))

      assert_equal d("0.41"), a.marginal_rate
      assert a.marginal_rate_declared?
      assert_nil a.marginal_rate_caveat
    end

    def test_an_undeclared_rate_falls_back_and_says_so
      a = Tax::Assumptions.new(marginal_rate: nil)

      assert_equal Tax::Assumptions::PLACEHOLDER_MARGINAL_RATE, a.marginal_rate
      refute a.marginal_rate_declared?
      assert_includes a.marginal_rate_caveat.to_s, "30%"
    end

    # Zero is a rate. A household below the first taxable band has genuinely
    # declared 0%, and treating that as "nothing said" would silently tax them
    # at the placeholder -- the one direction of error the module must not make
    # quietly, since it produces a bill out of nowhere.
    def test_zero_is_a_declaration_not_an_absence
      a = Tax::Assumptions.new(marginal_rate: d(0))

      assert a.marginal_rate_declared?
      assert_equal d(0), a.marginal_rate
      assert_equal d(0), a.income_tax_on(d(50_000))
    end

    # Discarded rather than clamped. A stored 1.5 is a row somebody wrote by
    # hand or a bug, and clamping it to 100% would compute a confident,
    # enormous, wrong answer -- while falling back to the placeholder computes
    # a plausible one that announces itself as a guess.
    def test_a_rate_outside_zero_to_one_is_discarded
      refute Tax::Assumptions.new(marginal_rate: d("1.5")).marginal_rate_declared?
      refute Tax::Assumptions.new(marginal_rate: d("-0.1")).marginal_rate_declared?
      refute Tax::Assumptions.new(marginal_rate: "not a number").marginal_rate_declared?
    end

    def test_with_carries_the_rate_through
      a = Tax::Assumptions.new(marginal_rate: d("0.41")).with(horizon_years: 30)

      assert_equal d("0.41"), a.marginal_rate
      assert a.marginal_rate_declared?
      assert_equal 30, a.horizon_years
    end

    def test_income_tax_on_a_loss_or_nothing_is_zero
      a = Tax::Assumptions.new(marginal_rate: d("0.30"))

      assert_equal d(0), a.income_tax_on(nil)
      assert_equal d(0), a.income_tax_on(d(-100))
    end
  end

  # -------------------------------------------------------------------------

  class RateTableTest < EngineTestCase
    def test_social_charges_step_at_2026
      assert_equal d("0.172"), RATES.social_charges(Date.new(2025, 12, 31))
      assert_equal d("0.186"), RATES.social_charges(Date.new(2026, 1, 1))
    end

    def test_flat_tax_is_derived_not_stored
      assert_equal d("0.300"), RATES.flat_tax(Date.new(2025, 6, 1))
      assert_equal d("0.314"), RATES.flat_tax(Date.new(2026, 6, 1))
    end

    def test_a_date_before_every_entry_raises_rather_than_guessing
      assert_raises(Tax::RateError) { RATES.social_charges(Date.new(2001, 1, 1)) }
    end

    # The generic lookup, which is what makes a second country a YAML file.
    # Nothing in RateTable knows the string "social_charges"; it knows that a
    # section of dated entries can be asked for its rate on a date.
    def test_a_rate_is_looked_up_by_the_name_the_file_gives_it
      assert_equal RATES.social_charges(ON), RATES.rate("social_charges", ON)
      assert_equal RATES.flat_tax(ON), RATES.rate("flat_tax", ON)
    end

    def test_a_composite_is_the_sum_of_its_declared_parts
      assert_equal(
        RATES.rate("flat_tax_income_component", ON) + RATES.rate("social_charges", ON),
        RATES.rate("flat_tax", ON)
      )
    end

    # The question the rule builder and the presenter both ask before they
    # offer or resolve a rate. It has to be true for composites too, or the
    # headline flat tax would be missing from the menu that offers rates.
    def test_rate_names_covers_both_dated_sections_and_composites
      assert_includes RATES.rate_names, "social_charges"
      assert_includes RATES.rate_names, "flat_tax_income_component"
      assert_includes RATES.rate_names, "flat_tax"

      RATES.rate_names.each { |name| assert RATES.rate?(name), "#{name} not recognised" }
    end

    def test_an_unknown_rate_is_not_recognised
      refute RATES.rate?("wealth_tax")
    end

    # The brackets went, and with them the household's other income and its
    # number of parts. This asserts the absence rather than leaving it to be
    # noticed: a rate file that grew an `income_tax_brackets` section again
    # would be reintroducing a calculation the module deliberately dropped
    # because it could only be fed by defaults nobody set.
    def test_the_income_tax_scale_is_gone
      refute_respond_to RATES, :income_tax
      refute_respond_to RATES, :brackets
      refute_includes RATES.rate_names, "income_tax_brackets"
    end

    def test_ceilings_are_read_from_data
      assert_equal d(150_000), RATES.ceiling("pea")
      assert_equal d(20_000), RATES.ceiling("pea_jeune")
      assert_nil RATES.ceiling("cto")
    end
  end

  # -------------------------------------------------------------------------

  class PeaRuleTest < EngineTestCase
    def mature_pea(**overrides)
      subject(
        value: d("250000.00"), paid_in: d("150000.00"),
        opened_on: Date.new(2010, 1, 1), **overrides
      )
    end

    def test_mature_plan_pays_social_charges_only
      line = apply(mature_pea)
      assert_equal d("100000.00"), line.taxable_base
      assert_equal d("18600.00"), line.tax          # 18.6%
      assert_equal d("231400.00"), line.net
    end

    def test_immature_plan_pays_the_full_flat_tax
      line = apply(mature_pea(opened_on: Date.new(2024, 1, 1)))
      assert_equal (d("100000.00") * d("0.314")).round(2, half: :even), line.tax
      assert warned?(line, "under 5")
    end

    def test_the_five_year_mark_is_a_real_step
      just_under = apply(mature_pea(opened_on: Date.new(2021, 9, 1)))
      just_over  = apply(mature_pea(opened_on: Date.new(2021, 7, 1)))
      assert_operator just_under.tax, :>, just_over.tax
    end

    # This used to be a refusal, and the change is the point of Part 4.
    #
    # The old behaviour was right about the arithmetic and wrong about the
    # reader. Measuring the gain against the cost basis understates it, so the
    # rule declined and the row stayed blank -- and a blank row tells nobody
    # anything, least of all that the number they never saw would have been too
    # low. Now the near-miss is used and labelled, which gives the reader
    # something to disbelieve and a box to correct it in.
    #
    # What must not change is the direction of the error, so this pins it: the
    # tax comes out on the low side, and the sentence beside it says so.
    def test_missing_paid_in_falls_back_to_cost_basis_and_says_so
      line = apply(subject(value: d("250000.00"), paid_in: nil, cost_basis: d("150000.00")))

      # 250000 - 150000 at social charges, the plan being mature.
      assert_equal d("100000.00"), line.taxable_base
      assert_equal d("18600.00"), line.tax
      assert line.modelled?

      assert warned?(line, "150000.0")
      assert warned?(line, "least this plan could owe")

      # A gap rather than a note: the figure stands, and declaring the
      # versements would move it.
      assert_equal :gap, line.warnings.find { |w|
        w.respond_to?(:key) && w.key == "fr_pea.computed_from_cost_basis"
      }.severity
    end

    # The refusal survives, narrowed to the case where genuinely nothing is
    # known: no versements and no holdings to price.
    def test_neither_figure_still_refuses
      line = apply(subject(value: d("250000.00"), paid_in: nil, cost_basis: nil))

      assert_nil line.tax
      assert_nil line.net
      refute line.modelled?

      # Stated twice: once as prose for the reader, once as a symbol, so the
      # report can decide whether to offer a link to the form without matching
      # on a sentence that changes with the language.
      assert_equal [ :paid_in ], line.missing_facts
    end

    def test_missing_opening_date_assumes_mature_and_shows_the_other_figure
      line = apply(mature_pea(opened_on: nil))

      assert_equal d("18600.00"), line.tax
      assert warned?(line, "clock cannot be checked")
      # The alternative must be quoted, not merely hinted at.
      assert warned?(line, "31400.0")
    end

    # A lower bound settles the clock in one direction and one only.
    #
    # Sure knows, for an account it has held a balance on, a date the account
    # certainly predates. That is not an opening date and Tax::SubjectBuilder
    # is careful never to pass it as one -- but it is enough to prove a
    # five-year clock has run, and proving it beats assuming it and asking the
    # reader for a date in order to reach a conclusion already available.
    def test_a_lower_bound_past_the_clock_settles_it_without_a_date
      line = apply(mature_pea(opened_on: nil, known_since: Date.new(2015, 1, 1)))

      assert_equal d("18600.00"), line.tax
      assert warned?(line, "already held money")
      # And it must stop asking, because there is nothing left to ask about.
      refute warned?(line, "clock cannot be checked")
    end

    # The bound cannot settle it the other way. "At least two years old" says
    # nothing about whether it is six, so a bound short of the clock has to
    # fall through to the same assumption as no information at all -- and to
    # the same request for a date.
    #
    # It must not fall through to the same *sentence*, though, and that is what
    # the last two assertions are for. A reader in this state has an opening
    # date on the account in Sure; told only that "the opening date is not
    # declared" they will go and check, find the date, and conclude the module
    # cannot see it. Every account in the household that reported this had an
    # anchor dated the day it was imported, carrying its full balance -- a
    # floor four days wide. The sentence has to name the date it declined to
    # use, or the report reads as broken rather than as short of a fact.
    def test_a_lower_bound_short_of_the_clock_proves_nothing
      line = apply(mature_pea(opened_on: nil, known_since: Date.new(2024, 1, 1)))

      assert_equal d("18600.00"), line.tax
      refute warned?(line, "already held money")
      assert warned?(line, "1 January 2024")
      assert warned?(line, "a floor, not an opening date")
    end

    # And with no bound at all there is no date to name, so the older sentence
    # is still the right one. Both are gaps asking for the same fact; they
    # differ only in what they can tell the reader about why.
    def test_no_date_and_no_bound_says_so_without_inventing_one
      line = apply(mature_pea(opened_on: nil, known_since: nil))

      assert_equal d("18600.00"), line.tax
      assert warned?(line, "clock cannot be checked")
      refute warned?(line, "a floor, not an opening date")

      asking = line.warnings.select { |w|
        w.respond_to?(:asks_for) && w.asks_for == :opened_on
      }
      assert_equal 1, asking.size, "one sentence about the clock, not two"
      assert_equal :gap, asking.first.severity
    end

    # A declared date outranks the bound even when the two disagree, because
    # one of them is a statement by the household and the other is an
    # inference from a balance.
    def test_a_declared_date_wins_over_the_bound
      line = apply(mature_pea(opened_on: Date.new(2024, 1, 1),
                              known_since: Date.new(2010, 1, 1)))

      assert_equal (d("100000.00") * d("0.314")).round(2, half: :even), line.tax
      assert warned?(line, "under 5")
    end

    def test_a_loss_is_not_taxed
      line = apply(subject(value: d(90_000), paid_in: d(120_000), opened_on: Date.new(2010, 1, 1)))
      assert_equal d(0), line.tax
      assert warned?(line, "below the amount paid in")
    end

    def test_ceiling_is_checked_against_paid_in_not_value
      # Worth far above the ceiling, paid in below it: no breach.
      refute warned?(apply(mature_pea(paid_in: d(120_000))), "ceiling")
      # Paid in above it: breach.
      assert warned?(apply(mature_pea(value: d(160_000), paid_in: d(155_000))), "ceiling")
    end

    def test_taux_historiques_window_warns
      assert warned?(apply(mature_pea(opened_on: Date.new(2015, 6, 1))), "2013 and 2017")
    end

    def test_pea_pme_uses_its_own_ceiling
      line = apply(mature_pea(subtype: "pea_pme", product: "pea_pme", paid_in: d(200_000)))
      refute warned?(line, "ceiling"), "200k is under the 225k PEA-PME ceiling"
    end
  end

  # -------------------------------------------------------------------------

  class SecuritiesRuleTest < EngineTestCase
    def cto(**overrides)
      subject(subtype: "brokerage", product: "cto", value: d("100000.00"), **overrides)
    end

    def test_gain_taxed_at_the_flat_rate_on_cost_basis
      line = apply(cto(cost_basis: d("80000.00")))
      assert_equal d("6280.00"), line.tax
      assert_equal d("20000.00"), line.taxable_base
    end

    def test_no_cost_basis_and_nothing_declared_refuses
      line = apply(cto(cost_basis: nil))
      assert_nil line.tax
      refute line.modelled?

      # Named, and deliberately not a fact any form collects: cost basis is
      # derived from Sure's own holdings. A caller offering a "declare this"
      # link intersects this list with what it can actually ask for, so this
      # row gets an explanation rather than an invitation to fix it.
      assert_equal [ :cost_basis ], line.missing_facts
    end

    def test_a_2025_valuation_uses_the_old_thirty_percent
      line = apply(cto(value: d(110_000), cost_basis: d(100_000)), on: Date.new(2025, 12, 31))
      assert_equal d(10_000) * d("0.30"), line.tax
    end

    def test_declared_figure_wins_but_is_flagged
      line = apply(cto(cost_basis: d(90_000), paid_in: d(80_000)))
      assert_equal (d(20_000) * d("0.314")).round(2, half: :even), line.tax
      assert warned?(line, "check the declared value")
    end

    def test_latent_loss_is_reported_and_not_taxed
      line = apply(cto(value: d(80_000), cost_basis: d(100_000)))
      assert_equal d(0), line.tax
      assert warned?(line, "Latent loss")
    end
  end

  # -------------------------------------------------------------------------

  # Which figure the gain was actually measured against, reported on the result
  # rather than left for a reader to infer.
  #
  # Two accounts on the same page can carry the same rule name, the same rate
  # and the same shape of figure and mean different things by the number in the
  # middle: one measured against what the household declared, the other against
  # a floor this module substituted because nothing was declared. The warning
  # says so at length, and by the time the row is otherwise fine that warning is
  # behind a disclosure triangle -- so the substitution has to survive as a
  # fact, not only as a sentence.
  class BasisSourceTest < EngineTestCase
    def test_a_declared_figure_is_reported_as_declared
      line = apply(subject(paid_in: d(80_000), opened_on: Date.new(2010, 1, 1)))

      assert_equal :paid_in, line.basis_source
    end

    def test_a_substituted_cost_basis_is_reported_as_substituted
      line = apply(subject(paid_in: nil, cost_basis: d(80_000),
                           opened_on: Date.new(2010, 1, 1)))

      assert_equal :cost_basis, line.basis_source
    end

    # The same two answers on a CTO, where the cascade runs the same way round
    # and means the opposite: here the cost basis is the base in law and the
    # declared figure is the household correcting it. Which is exactly why the
    # result carries the symbol and lets the page pick the words, rather than
    # carrying a sentence written by whichever rule got there first.
    def test_a_brokerage_account_reports_its_own_answer
      assert_equal :cost_basis, apply(cto(cost_basis: d(80_000))).basis_source
      assert_equal :paid_in,
                   apply(cto(cost_basis: d(90_000), paid_in: d(80_000))).basis_source
    end

    # A rule that never asks the question leaves it unanswered rather than
    # guessing. A cash balance is untaxed on withdrawal and no gain is measured
    # against anything, so a provenance line under it would be qualifying a
    # method that was never used.
    def test_a_rule_with_no_gain_to_measure_reports_nothing
      line = apply(subject(accountable_type: "Depository", subtype: "checking",
                           product: nil, value: d(5_000)))

      assert_nil line.basis_source
    end

    private
      def cto(**overrides)
        subject(subtype: "brokerage", product: "cto", value: d(100_000), **overrides)
      end
  end

  # -------------------------------------------------------------------------

  class DepositRuleTest < EngineTestCase
    def livret(**overrides)
      subject(accountable_type: "Depository", subtype: "savings", value: d(20_000), **overrides)
    end

    def test_livret_a_is_exempt_and_says_so
      line = apply(livret(product: "livret_a"))
      assert_equal d(0), line.tax
      assert line.modelled?
      assert_includes line.basis.to_s, "exempt"
    end

    def test_undeclared_savings_is_still_zero_on_liquidation_but_flags_the_ambiguity
      line = apply(livret(product: nil))

      # Withdrawing cash is not a taxable event whatever the livret is, so
      # refusing here would be false caution.
      assert_equal d(0), line.tax
      assert line.modelled?
      assert warned?(line, "taxed as it arises")
      assert warned?(line, "Declare the product")
    end

    def test_taxable_livret_warns_that_interest_is_out_of_scope
      line = apply(livret(product: "taxable_savings"))
      assert_equal d(0), line.tax
      assert warned?(line, "not shown here")
    end

    def test_balance_far_above_the_ceiling_is_questioned
      line = apply(livret(product: "livret_a", value: d(60_000)))
      assert warned?(line, "ceiling")
    end
  end

  # -------------------------------------------------------------------------

  class CapitalAndGainsRuleTest < EngineTestCase
    RULE = Tax::Rules::Fr::CapitalAndGains.new

    def per(**overrides)
      subject(
        accountable_type: "Investment", subtype: "per_custom", product: "per",
        value: d("80000.00"), paid_in: d("50000.00"), **overrides
      )
    end

    def run_rule(subj, assumptions: nil, on: ON)
      RULE.call(subj, on: on, rates: RATES, assumptions: assumptions || flat30)
    end

    def test_lump_sum_splits_capital_from_growth
      # 50000.00 * 30% = 15000.00 ; 30000.00 * 31.4% = 9420.00
      assert_equal d("24420.00"), run_rule(per).tax
    end

    def test_non_deducted_payments_come_back_untaxed
      full    = run_rule(per)
      partial = run_rule(per(paid_in_deducted: d("20000.00")))

      assert_operator partial.tax, :<, full.tax
      assert_equal d(30_000) * d("0.30"), full.tax - partial.tax
    end

    def test_undeclared_deduction_assumes_the_worse_case_and_says_so
      assert warned?(run_rule(per), "higher-tax assumption")
    end

    def test_deducted_above_total_is_capped_not_crashed
      line = run_rule(per(paid_in_deducted: d(60_000)))
      assert_equal run_rule(per).tax, line.tax
      assert warned?(line, "Capped at the total")
    end

    def test_a_lower_household_rate_lowers_the_capital_half_only
      cheap = run_rule(per, assumptions: at_rate("0.11"))

      # The growth is on the flat tax in this rule, so only the 50 000 of
      # deducted capital moves: 50000 * (0.30 - 0.11).
      assert_equal d(50_000) * (d("0.30") - d("0.11")), run_rule(per).tax - cheap.tax
    end

    def test_missing_paid_in_and_no_holdings_refuses
      line = run_rule(per(paid_in: nil))
      assert_nil line.tax
      refute line.modelled?
    end

    # The substitution, and the property that makes it defensible.
    #
    # Where the versements are undeclared, what the holdings cost stands in for
    # them -- in the capital term as well as in the growth term. The two
    # together then still tax the whole value, exactly as they would with real
    # versements, which is the invariant this pins: whatever the stand-in is,
    # the taxable base is the value.
    #
    # Put the stand-in in the growth term alone, as the obvious reading of "use
    # the cost basis for the gain" would, and a slice the size of the cost
    # basis falls out of the calculation entirely. That is a discount, granted
    # silently, to precisely the accounts this module knows least about.
    def test_undeclared_versements_fall_back_to_cost_basis_in_both_terms
      line = run_rule(per(paid_in: nil, cost_basis: d("60000.00")))

      assert_equal d("80000.00"), line.taxable_base, "the two terms must still sum to the value"
      # 60000 deducted at 30% = 18000 ; 20000 of growth at 31.4% = 6280.
      assert_equal d("24280.00"), line.tax
      assert warned?(line, "60000.0")
      assert warned?(line, "most this wrapper could owe")
    end

    # And the direction of the error. The cost basis is the larger of the two
    # figures whenever the wrapper has gained, so the stand-in moves money from
    # the flat tax up to the household's rate. Where the household's rate is
    # the higher of the two -- which is when the difference is worth anything
    # -- that is an overstatement, and an overstatement is the only kind of
    # error this module is willing to make without being asked.
    def test_the_substitution_never_understates_at_a_rate_above_the_flat_tax
      truth    = run_rule(per(paid_in: d("50000.00"), cost_basis: d("60000.00")),
                          assumptions: at_rate("0.41"))
      guessed  = run_rule(per(paid_in: nil, cost_basis: d("60000.00")),
                          assumptions: at_rate("0.41"))

      assert_operator guessed.tax, :>, truth.tax
    end

    # What the report totals to say how much of the bill rests on a number the
    # household typed rather than on the country's rate file. For this rule it
    # is the deducted capital and nothing else, because the growth goes to the
    # flat tax.
    def test_only_the_capital_rests_on_the_household_rate
      assert_equal d("50000.00"), run_rule(per).household_rate_income
    end

    def test_an_undeclared_rate_still_computes_but_says_so
      line = run_rule(per, assumptions: undeclared)

      assert_equal run_rule(per).tax, line.tax, "the placeholder is 30%"
      assert warned?(line, "No household marginal rate has been set")
    end

    def test_a_declared_rate_does_not_carry_the_placeholder_warning
      refute warned?(run_rule(per), "No household marginal rate has been set")
    end
  end

  # -------------------------------------------------------------------------

  # The other PER shape: the household elected the progressive scale over the
  # flat tax, so the growth is taxed at its rate too. Same wrapper, one rate
  # swapped -- which is the whole reason it is a subclass rather than a second
  # implementation.
  class CapitalAndGainsAtHouseholdRateTest < EngineTestCase
    RULE = Tax::Rules::Fr::CapitalAndGainsAtHouseholdRate.new
    DEFAULT = Tax::Rules::Fr::CapitalAndGains.new

    def per(**overrides)
      subject(
        accountable_type: "Investment", subtype: "per_custom", product: "per",
        value: d("80000.00"), paid_in: d("50000.00"), **overrides
      )
    end

    def run_rule(rule, rate)
      rule.call(per, on: ON, rates: RATES, assumptions: at_rate(rate))
    end

    def test_everything_is_taxed_at_the_household_rate
      # 80 000 of which 50 000 was paid in and deducted: the whole lot at 30%.
      assert_equal d("24000.00"), run_rule(RULE, "0.30").tax
    end

    def test_it_beats_the_flat_tax_below_the_flat_tax
      # The flat tax is 31.4% in 2026, so an 11% household is better off here.
      assert_operator run_rule(RULE, "0.11").tax, :<, run_rule(DEFAULT, "0.11").tax
    end

    def test_it_loses_to_the_flat_tax_above_the_flat_tax
      assert_operator run_rule(RULE, "0.41").tax, :>, run_rule(DEFAULT, "0.41").tax
    end

    def test_the_two_agree_on_the_capital_half
      # Whatever the election, the deducted payments go to the household rate.
      # If these ever disagreed, one of the two rules would be taxing the
      # capital as though it were growth.
      assert_equal(
        d(50_000) * d("0.30"),
        run_rule(RULE, "0.30").tax - (d(30_000) * d("0.30"))
      )
    end

    def test_the_whole_bill_rests_on_the_household_rate
      assert_equal d("80000.00"), run_rule(RULE, "0.30").household_rate_income
    end

    # The election covers all of a household's investment income for the year,
    # so it cannot apply to one account and not another. The module computes
    # the mixture anyway rather than refusing -- it cannot see the tax return
    # -- and says so.
    def test_it_says_the_election_is_all_or_nothing
      assert warned?(run_rule(RULE, "0.30"), "cannot apply to this account alone")
    end
  end

  # -------------------------------------------------------------------------

  class UnknownAndFallbackTest < EngineTestCase
    def test_an_unrecognised_subtype_returns_nil_not_zero
      line = apply(subject(accountable_type: "Investment", subtype: "brand_new_2027", product: nil))

      assert_nil line.tax
      assert_nil line.net
      refute line.modelled?
      assert warned?(line, "No tax rule for Investment/brand_new_2027")
    end

    def test_it_reports_sure_s_own_classification_and_suggests_a_rule
      line = apply(subject(subtype: "future_pension", product: nil, tax_treatment: :tax_deferred))

      assert warned?(line, "tax deferred")
      assert warned?(line, "fr_capital_and_gains")
    end

    def test_a_type_level_rule_catches_every_subtype_of_that_type
      line = apply(subject(accountable_type: "Crypto", subtype: "wallet", product: nil))
      assert_nil line.tax
      assert warned?(line, "portfolio-wide formula")
    end

    def test_assurance_vie_is_deliberately_not_modelled
      line = apply(subject(subtype: "assurance_vie", product: nil, value: d(50_000)))
      refute line.modelled?
      assert warned?(line, "annual allowance")
    end
  end

  # -------------------------------------------------------------------------

  # What replaced the stacking loop.
  #
  # The registry used to run the accounts in order, carrying the income each
  # one sent to the progressive scale forward into the next, so that two PERs
  # liquidated together crossed bands the way they would in a real tax year.
  # With a single marginal rate that machinery is not merely unnecessary, it is
  # arithmetically a no-op -- one rate over a sum is the sum of that rate over
  # each part -- and it emitted a "stacked on" warning about brackets nobody
  # was crossing. These tests pin the property that made it removable, so that
  # anyone reintroducing an order-dependent total has to break one of them
  # first.
  class IndependenceTest < EngineTestCase
    def per(name, value, paid_in)
      Tax::Subject.new(
        id: name, name: name, currency: "EUR",
        accountable_type: "Investment", subtype: "per_custom", product: "per",
        value: d(value), paid_in: d(paid_in)
      )
    end

    def registry_with_per
      Tax::Registry.new(
        country: "FR",
        custom_rules: [ TaxEngineTestHelper::FakeCustomRule.new(
          accountable_type: "Investment", subtype: "per_custom",
          rule: Tax::Rules::Fr::CapitalAndGains.new
        ) ]
      )
    end

    def subjects
      [ per("PER 1", "80000.00", "50000.00"), per("PER 2", "40000.00", "25000.00") ]
    end

    def apply_all(assumptions, list = subjects)
      registry_with_per.apply_all(list, on: ON, rates: RATES, assumptions: assumptions)
    end

    def test_the_total_is_the_sum_of_the_accounts_taken_alone
      isolated = subjects.sum { |s|
        registry_with_per.apply(s, on: ON, rates: RATES, assumptions: flat30).tax
      }

      assert_equal isolated, apply_all(flat30).sum(&:tax)
    end

    def test_the_result_does_not_depend_on_input_order
      forward = apply_all(flat30).map { |l| [ l.account_name, l.tax ] }.sort
      reverse = apply_all(flat30, subjects.reverse).map { |l| [ l.account_name, l.tax ] }.sort

      assert_equal forward, reverse
    end

    # Nothing carries between accounts any more, so nothing should claim to.
    # A warning that says one account was affected by another would be false
    # under this arrangement, and false in a way a reader cannot check.
    def test_no_account_is_told_it_was_stacked_on_another
      refute apply_all(flat30).any? { |l| warned?(l, "Stacked on") }
    end

    def test_an_exempt_account_changes_nothing_about_the_others
      livret = Tax::Subject.new(
        id: "L", name: "Livret A", accountable_type: "Depository",
        subtype: "savings", product: "livret_a", value: d(20_000)
      )

      with    = apply_all(flat30, [ livret ] + subjects).find { |l| l.account_name == "PER 1" }
      without = apply_all(flat30, subjects).find { |l| l.account_name == "PER 1" }

      assert_equal without.tax, with.tax
    end

    def test_two_pers_come_to_the_hand_computed_total
      assert_equal d("24420.00") + d("12210.00"), apply_all(flat30).sum(&:tax)
    end
  end

  # -------------------------------------------------------------------------

  class SnapshotTest < EngineTestCase
    def line(name, gross, tax, modelled: true)
      Tax::Result.new(
        account_name: name, gross: d(gross), tax: tax.nil? ? nil : d(tax), modelled: modelled
      )
    end

    def test_unknown_tax_contributes_gross_but_no_tax
      snap = Tax::Snapshot.new(
        on: ON, results: [ line("A", 100, 30), line("B", 50, nil, modelled: false) ]
      )

      assert_equal d(150), snap.gross
      assert_equal d(30), snap.tax
      assert_equal d(120), snap.net       # an upper bound, and flagged as one
      refute snap.complete?
      assert_equal d(50), snap.unmodelled_gross
      assert_equal d(100), snap.modelled_gross
    end

    def test_the_modelled_rate_is_the_honest_headline_when_incomplete
      snap = Tax::Snapshot.new(
        on: ON, results: [ line("A", 100, 30), line("B", 100, nil, modelled: false) ]
      )

      assert_equal d("0.15"), snap.effective_rate
      assert_equal d("0.30"), snap.modelled_effective_rate
    end

    def test_a_fully_modelled_portfolio_is_complete
      snap = Tax::Snapshot.new(on: ON, results: [ line("A", 100, 30), line("B", 50, 0) ])
      assert snap.complete?
    end
  end

  # -------------------------------------------------------------------------

  class ProjectionTest < EngineTestCase
    def pea
      Tax::Subject.new(
        id: "p", name: "PEA", accountable_type: "Investment", subtype: "pea",
        product: "pea", value: d(100_000), paid_in: d(80_000),
        opened_on: Date.new(2010, 1, 1)
      )
    end

    def projection(horizon: 5, ret: "0.05")
      Tax::Projection.new(
        registry: registry, rates: RATES,
        assumptions: Tax::Assumptions.new(
          marginal_rate: d("0.30"),
          expected_return: d(ret), horizon_years: horizon
        )
      )
    end

    def test_it_returns_one_snapshot_per_year_inclusive
      assert_equal 6, projection(horizon: 5).run([ pea ], from: ON).size
    end

    def test_value_compounds_but_payments_in_do_not
      grown = projection.grow(pea, 10)

      assert_equal (d(100_000) * (d("1.05") ** 10)).round(2, half: :even), grown.value
      assert_equal d(80_000), grown.paid_in, "payments in must not grow"
    end

    def test_the_taxable_gap_widens_because_of_that
      snaps = projection(horizon: 10).run([ pea ], from: ON)
      first = snaps.first.results.first.taxable_base
      last  = snaps.last.results.first.taxable_base

      assert_operator last, :>, first * 2
    end

    def test_a_zero_return_leaves_the_tax_flat
      snaps = projection(horizon: 3, ret: "0").run([ pea ], from: ON)
      assert_equal 1, snaps.map { |s| s.tax }.uniq.size
    end

    def test_deflating_expresses_a_future_amount_in_today_s_money
      assert_equal d("1000"), Tax::Projection.deflate(d(1000), years: 0, inflation: d("0.02"))
      assert_operator Tax::Projection.deflate(d(1000), years: 10, inflation: d("0.02")), :<, d(1000)
    end
  end

  # -------------------------------------------------------------------------

  class TreatmentTest < EngineTestCase
    def test_it_suggests_a_rule_from_sure_s_classification
      assert_equal "exempt", Tax::Treatment.suggested_rule_id(:tax_exempt)
      assert_equal "fr_capital_and_gains", Tax::Treatment.suggested_rule_id(:tax_deferred)
      assert_nil Tax::Treatment.suggested_rule_id(nil)
    end

    def test_it_flags_a_product_sure_calls_exempt_that_we_tax
      subj = subject(tax_treatment: :tax_exempt)
      res  = Tax::Result.new(account_name: "X", gross: d(100), tax: d(10))

      assert_includes Tax::Treatment.audit(subj, res).first.to_s, "does not transfer"
    end

    def test_it_stays_quiet_when_the_two_agree
      subj = subject(tax_treatment: :tax_advantaged, product: "pea")
      res  = Tax::Result.new(account_name: "PEA", gross: d(100), tax: d(10), product: "pea")

      assert_empty Tax::Treatment.audit(subj, res)
    end

    def test_a_tax_advantaged_wrapper_taxed_as_a_plain_cto_is_flagged
      subj = subject(tax_treatment: :tax_deferred)
      res  = Tax::Result.new(account_name: "X", gross: d(100), tax: d(10), product: "cto")

      assert_includes Tax::Treatment.audit(subj, res).first.to_s, "needs its own rule"
    end
  end
end
