# frozen_string_literal: true

# Tax::CountryGuide, tested without Rails.
#
#   ruby -Itest test/models/tax/country_guide_test.rb
#
require_relative "engine_test_helper"
require "minitest/autorun"

module Tax
  class CountryGuideTest < Minitest::Test
    ON = Date.new(2026, 8, 8)

    def guide(country)
      rt = Tax::RateTable.load_file(TaxEngineTestHelper.rate_file(country))
      Tax::CountryGuide.new(country, rate_table: rt)
    end

    def test_reports_currency_and_rate_sections
      g = guide("US")
      assert_equal "USD", g.currency

      names = g.rate_sections(on: ON).map(&:name)
      assert_includes names, "long_term_gains"

      ltg = g.rate_sections(on: ON).find { |s| s.name == "long_term_gains" }
      assert_equal BigDecimal("0.15"), ltg.current_rate
    end

    def test_composites_resolve_to_the_sum_of_their_parts
      c = guide("US").composites(on: ON).find { |x| x.name == "long_term_gains_with_niit" }
      assert_equal %w[long_term_gains niit], c.parts
      assert_equal BigDecimal("0.188"), c.current_rate # 0.15 + 0.038
    end

    def test_groups_wrappers_by_rule_and_classifies_them
      groups = guide("US").coverage_groups
      by_class = groups.group_by(&:classification)

      # Brokerage/UGMA/UTMA/etc. taxed together under one securities rule.
      taxed = by_class.fetch(:taxed).find { |g| g.rule_id == "us_securities" }
      assert_includes taxed.pairs, [ "Investment", "brokerage" ]

      # Roth is exempt, not taxed and not "unknown".
      assert by_class.fetch(:exempt).any? { |g| g.pairs.include?([ "Investment", "roth_ira" ]) }

      # A pre-tax IRA is deferred-style: taxed on the whole balance.
      assert by_class.fetch(:taxed).any? { |g| g.rule_id == "us_deferred" }
    end

    def test_not_modelled_wrappers_carry_a_reason
      groups = guide("IN").coverage_groups
      nm = groups.select { |g| g.classification == :not_modelled }

      assert nm.any?, "India ships NotModelled debt/NPS rules"
      assert nm.all? { |g| g.reason.to_s.length.positive? }, "each NotModelled group states why"
      # Debt and NPS are two rows, not one lumped group.
      assert_operator nm.size, :>=, 2
    end

    def test_unmodelled_list_is_exposed
      assert guide("GB").unmodelled.any? { |u| u["id"] == "dividend_income" }
    end

    def test_counts_tally_each_bucket
      counts = guide("GB").counts
      assert_operator counts[:taxed], :>, 0
      assert_operator counts[:exempt], :>, 0
    end

    def test_all_shipped_countries_build_a_guide
      %w[US GB IN FR].each do |c|
        g = guide(c)
        assert g.coverage_groups.any?, "#{c} should map at least one wrapper"
        assert g.currency.length == 3, "#{c} has an ISO currency"
      end
    end
  end
end
