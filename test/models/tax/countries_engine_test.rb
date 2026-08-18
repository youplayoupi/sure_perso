# frozen_string_literal: true

# US / UK / India rules, tested without Rails.
#
# Same contract as engine_test.rb: pure functions over value objects, so this
# boots in a bare Ruby process and the tax arithmetic can be diffed by hand.
#
#   bin/rails test test/models/tax/countries_engine_test.rb   # inside Rails
#   ruby -Itest test/models/tax/countries_engine_test.rb      # standalone
#
require_relative "engine_test_helper"
require "minitest/autorun"

module Tax
  class CountriesEngineTest < Minitest::Test
    ON = Date.new(2026, 8, 8)

    def d(value)
      value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
    end

    def rates(country)
      Tax::RateTable.load_file(TaxEngineTestHelper.rate_file(country))
    end

    def at_rate(rate)
      Tax::Assumptions.new(marginal_rate: d(rate))
    end

    def undeclared
      Tax::Assumptions.new(marginal_rate: nil)
    end

    def subject(country_type: "Investment", **overrides)
      defaults = {
        id: "acct-1", name: "Test", currency: "USD",
        accountable_type: country_type, subtype: "brokerage",
        value: d(100_000)
      }
      Tax::Subject.new(**defaults.merge(overrides))
    end

    def apply(country, subj, assumptions:)
      Tax::Registry.new(country: country)
                   .apply(subj, on: ON, rates: rates(country), assumptions: assumptions)
    end

    # --- United States ---------------------------------------------------

    def test_us_brokerage_taxes_long_term_gain_at_fifteen_percent
      subj = subject(subtype: "brokerage", value: d(100_000), cost_basis: d(60_000))
      result = apply("US", subj, assumptions: at_rate("0.37"))

      # 40,000 gain * 15% assumed long-term rate.
      assert_equal d("6000.0"), result.tax
      assert result.modelled?
      assert result.gaps?, "the assumed-rate and NIIT warnings should register as gaps"
    end

    def test_us_traditional_ira_taxes_whole_balance_at_marginal_rate
      subj = subject(subtype: "ira", value: d(100_000), cost_basis: d(40_000))
      result = apply("US", subj, assumptions: at_rate("0.24"))

      # Whole balance, not the gain: pre-tax money out is ordinary income.
      assert_equal d("24000.0"), result.tax
    end

    def test_us_roth_is_exempt
      subj = subject(subtype: "roth_ira", value: d(100_000), cost_basis: d(40_000))
      result = apply("US", subj, assumptions: at_rate("0.24"))

      assert_equal d(0), result.tax
      assert result.modelled?, "exempt is a fact, not a refusal"
    end

    def test_us_cash_deposit_is_zero_on_liquidation
      subj = subject(country_type: "Depository", subtype: "savings", value: d(50_000))
      result = apply("US", subj, assumptions: at_rate("0.24"))

      assert_equal d(0), result.tax
    end

    # --- United Kingdom --------------------------------------------------

    def test_gb_basic_rate_taxpayer_pays_eighteen_percent
      subj = subject(currency: "GBP", subtype: "brokerage", value: d(100_000), cost_basis: d(60_000))
      result = apply("GB", subj, assumptions: at_rate("0.20"))

      # 40,000 gain * 18% (basic band, inferred from a 20% marginal rate).
      assert_equal d("7200.0"), result.tax
    end

    def test_gb_higher_rate_taxpayer_pays_twenty_four_percent
      subj = subject(currency: "GBP", subtype: "brokerage", value: d(100_000), cost_basis: d(60_000))
      result = apply("GB", subj, assumptions: at_rate("0.40"))

      assert_equal d("9600.0"), result.tax
    end

    def test_gb_pension_taxes_three_quarters_at_marginal_rate
      subj = subject(currency: "GBP", subtype: "sipp", value: d(100_000))
      result = apply("GB", subj, assumptions: at_rate("0.40"))

      # 25% tax-free, 75,000 * 40%.
      assert_equal d("30000.0"), result.tax
    end

    def test_gb_isa_is_exempt
      subj = subject(currency: "GBP", subtype: "isa", value: d(100_000), cost_basis: d(40_000))
      result = apply("GB", subj, assumptions: at_rate("0.40"))

      assert_equal d(0), result.tax
    end

    # --- India -----------------------------------------------------------

    def test_in_equity_taxes_long_term_gain_at_twelve_and_a_half_percent
      subj = subject(currency: "INR", subtype: "indian_equity", value: d(500_000), cost_basis: d(300_000))
      result = apply("IN", subj, assumptions: at_rate("0.30"))

      # 200,000 gain * 12.5% (exemption stated as ignored, not netted).
      assert_equal d("25000.0"), result.tax
      assert result.gaps?
    end

    def test_in_ppf_is_exempt
      subj = subject(currency: "INR", subtype: "ppf", value: d(500_000))
      result = apply("IN", subj, assumptions: at_rate("0.30"))

      assert_equal d(0), result.tax
    end

    def test_in_debt_fund_is_not_modelled_and_excluded_from_total
      subj = subject(currency: "INR", subtype: "fd", value: d(500_000))
      result = apply("IN", subj, assumptions: at_rate("0.30"))

      assert_nil result.tax, "debt is named, not valued: nil keeps it out of the total"
      refute result.modelled?
    end

    # --- Cross-cutting ---------------------------------------------------

    def test_gain_floored_at_zero_when_at_a_loss
      subj = subject(subtype: "brokerage", value: d(50_000), cost_basis: d(80_000))
      result = apply("US", subj, assumptions: at_rate("0.37"))

      assert_equal d(0), result.tax, "a latent loss is not negative tax"
    end
  end
end
