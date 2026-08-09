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

    def flat30
      Tax::Assumptions.new(tmi_mode: :flat, flat_rate: d("0.30"))
    end

    def bareme(other: 0, parts: 1)
      Tax::Assumptions.new(
        tmi_mode: :bareme, other_taxable_income: d(other), parts: d(parts)
      )
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

    def warned?(result, fragment)
      result.warnings.any? { |w| w.include?(fragment) }
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

    def test_first_bracket_is_free
      assert_equal d(0), RATES.income_tax(d(11_000), on: ON)
    end

    def test_progressive_tax_matches_a_hand_computation
      # 2026 brackets: 11 600 @ 0, up to 29 579 @ 11%, up to 84 577 @ 30%.
      # 50 000 -> (29579-11600)*0.11 + (50000-29579)*0.30
      expected = (d(29_579) - d(11_600)) * d("0.11") + (d(50_000) - d(29_579)) * d("0.30")
      assert_equal expected, RATES.income_tax(d(50_000), on: ON)
    end

    def test_quotient_familial_splits_then_multiplies_back
      single = RATES.income_tax(d(60_000), on: ON, parts: d(1))
      couple = RATES.income_tax(d(60_000), on: ON, parts: d(2))
      assert_operator couple, :<, single
      assert_equal RATES.income_tax(d(30_000), on: ON) * 2, couple
    end

    def test_marginal_tax_is_the_difference_not_a_rate
      stacked = RATES.marginal_income_tax(d(20_000), other_income: d(40_000), on: ON)
      alone   = RATES.income_tax(d(20_000), on: ON)
      assert_operator stacked, :>, alone
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

    def test_missing_paid_in_refuses_rather_than_guessing
      line = apply(subject(value: d("250000.00"), paid_in: nil, cost_basis: d("150000.00")))

      assert_nil line.tax
      assert_nil line.net
      refute line.modelled?
      # It must surface the cost basis and explicitly decline to use it.
      assert warned?(line, "is not used here")
    end

    def test_missing_opening_date_assumes_mature_and_shows_the_other_figure
      line = apply(mature_pea(opened_on: nil))

      assert_equal d("18600.00"), line.tax
      assert warned?(line, "clock cannot be checked")
      # The alternative must be quoted, not merely hinted at.
      assert warned?(line, "31400.0")
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

  class DepositRuleTest < EngineTestCase
    def livret(**overrides)
      subject(accountable_type: "Depository", subtype: "savings", value: d(20_000), **overrides)
    end

    def test_livret_a_is_exempt_and_says_so
      line = apply(livret(product: "livret_a"))
      assert_equal d(0), line.tax
      assert line.modelled?
      assert_includes line.basis, "exempt"
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

    def test_progressive_beats_flat_at_low_other_income
      assert_operator run_rule(per, assumptions: bareme).tax, :<, run_rule(per).tax
    end

    def test_progressive_exceeds_flat_at_high_other_income
      high = bareme(other: 100_000)
      assert_operator run_rule(per, assumptions: high).tax, :>, run_rule(per).tax
    end

    def test_missing_paid_in_refuses
      line = run_rule(per(paid_in: nil))
      assert_nil line.tax
      refute line.modelled?
    end

    def test_only_the_deducted_stream_stacks
      assert_equal d("50000.00"), run_rule(per, assumptions: bareme).bareme_income
      assert_equal d(0), run_rule(per).bareme_income, "flat mode must not stack"
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

  class StackingTest < EngineTestCase
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

    def test_stacked_total_exceeds_the_sum_of_isolated_totals
      isolated = subjects.sum { |s| registry_with_per.apply(s, on: ON, rates: RATES, assumptions: bareme).tax }
      stacked  = apply_all(bareme).sum(&:tax)

      assert_operator stacked, :>, isolated
    end

    def test_the_stack_is_flagged_on_the_second_account_only
      flagged = apply_all(bareme).count { |l| warned?(l, "Stacked on") }
      assert_equal 1, flagged
    end

    def test_the_result_does_not_depend_on_input_order
      forward = apply_all(bareme).map(&:tax)
      reverse = apply_all(bareme, subjects.reverse).map(&:tax)

      assert_equal forward, reverse
    end

    def test_flat_mode_does_not_stack
      assert_equal d("24420.00") + d("12210.00"), apply_all(flat30).sum(&:tax)
    end

    def test_an_exempt_account_contributes_nothing_to_the_stack
      livret = Tax::Subject.new(
        id: "L", name: "Livret A", accountable_type: "Depository",
        subtype: "savings", product: "livret_a", value: d(20_000)
      )

      with    = apply_all(bareme, [ livret ] + subjects).find { |l| l.account_name == "PER 1" }
      without = apply_all(bareme, subjects).find { |l| l.account_name == "PER 1" }

      assert_equal without.tax, with.tax
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
          tmi_mode: :flat, flat_rate: d("0.30"),
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

      assert_includes Tax::Treatment.audit(subj, res).first, "does not transfer"
    end

    def test_it_stays_quiet_when_the_two_agree
      subj = subject(tax_treatment: :tax_advantaged, product: "pea")
      res  = Tax::Result.new(account_name: "PEA", gross: d(100), tax: d(10), product: "pea")

      assert_empty Tax::Treatment.audit(subj, res)
    end

    def test_a_tax_advantaged_wrapper_taxed_as_a_plain_cto_is_flagged
      subj = subject(tax_treatment: :tax_deferred)
      res  = Tax::Result.new(account_name: "X", gross: d(100), tax: d(10), product: "cto")

      assert_includes Tax::Treatment.audit(subj, res).first, "needs its own rule"
    end
  end
end
