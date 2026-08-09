# frozen_string_literal: true

# Corrections laid over the shipped rate file.
#
# Runs with or without Rails, like the rest of the engine:
#
#   bin/rails test test/models/tax/rate_overlay_test.rb
#   ruby -Itest test/models/tax/rate_overlay_test.rb
#
require_relative "engine_test_helper"
require "minitest/autorun"

module Tax
  class RateOverlayTestCase < Minitest::Test
    ON_2026 = Date.new(2026, 6, 1)
    ON_2025 = Date.new(2025, 6, 1)

    def shipped
      YAML.safe_load_file(TaxEngineTestHelper.rate_file, permitted_classes: [ Date ])
    end

    def table(overrides)
      Tax::RateTable.new(Tax::RateOverlay.apply(shipped, overrides))
    end
  end

  # ---------------------------------------------------------------------------

  class RateOverlayMergeTest < RateOverlayTestCase
    def test_no_overrides_leaves_the_shipped_file_exactly_as_it_is
      assert_equal Tax::RateOverlay.apply(shipped, {}), Tax::RateOverlay.apply(shipped, nil)
      assert_equal shipped["social_charges"].length,
                   Tax::RateOverlay.apply(shipped, {})["social_charges"].length
    end

    def test_an_override_on_a_date_the_file_already_has_replaces_that_entry
      # The tie case, and the reason the merge is keyed on the date rather than
      # appending. Two entries dated 2026-01-01 would leave RateTable#effective
      # picking whichever came first in the list.
      merged = table("social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 0.20 } ])

      assert_equal BigDecimal("0.20"), merged.social_charges(ON_2026)
      assert_equal shipped["social_charges"].length,
                   Tax::RateOverlay.apply(shipped, "social_charges" => [
                     { "effective_from" => "2026-01-01", "rate" => 0.20 }
                   ])["social_charges"].length
    end

    def test_history_before_the_corrected_date_is_untouched
      # A correction to 2026 must not rewrite what a 2025 valuation says. The
      # whole point of an effective-dated file is that last year's report still
      # reproduces.
      merged = table("social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 0.20 } ])

      assert_equal BigDecimal("0.172"), merged.social_charges(ON_2025)
    end

    def test_an_override_on_a_new_date_is_added_to_the_schedule
      merged = table("social_charges" => [ { "effective_from" => "2027-01-01", "rate" => 0.21 } ])

      assert_equal BigDecimal("0.186"), merged.social_charges(ON_2026)
      assert_equal BigDecimal("0.21"), merged.social_charges(Date.new(2027, 6, 1))
    end

    def test_the_flat_tax_stays_derived_from_its_two_parts
      # flat_tax is income component plus social charges, computed rather than
      # stored, so correcting either one has to move it. If this ever fails the
      # two numbers have been allowed to drift apart somewhere.
      merged = table("social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 0.20 } ])

      assert_equal BigDecimal("0.328"), merged.flat_tax(ON_2026)
    end

    def test_correcting_one_product_leaves_the_others_alone
      merged = table("products" => { "pea" => { "maturity_years" => 8 } })

      assert_equal 8, merged.maturity_years("pea")
      assert_equal 5, merged.maturity_years("pea_pme")
      assert_equal BigDecimal("22950"), merged.ceiling("livret_a")
    end

    def test_correcting_one_key_of_a_product_leaves_its_other_keys_alone
      merged = table("products" => { "pea" => { "maturity_years" => 8 } })

      assert_equal BigDecimal("150000"), merged.ceiling("pea"),
                   "correcting the maturity should not have dropped the ceiling"
    end

    def test_symbol_keys_and_string_keys_mean_the_same_thing
      # A hash built in a controller arrives with symbols; the same hash read
      # back out of jsonb arrives with strings. They must not merge differently.
      from_symbols = Tax::RateOverlay.apply(shipped, products: { pea: { maturity_years: 9 } })
      from_strings = Tax::RateOverlay.apply(shipped, "products" => { "pea" => { "maturity_years" => 9 } })

      assert_equal from_symbols, from_strings
    end

    def test_the_shipped_file_is_not_mutated
      # Tax.rate_table memoises the parsed file for the whole process. A merge
      # that wrote into it would leak one family's corrections into every other
      # family's report, which is the worst bug this module could have.
      base = shipped
      before = base["social_charges"].map { |e| e["rate"] }

      Tax::RateOverlay.apply(base, "social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 0.99 } ])

      assert_equal before, base["social_charges"].map { |e| e["rate"] }
    end

    def test_income_tax_brackets_can_be_corrected_wholesale
      merged = table(
        "income_tax_brackets" => [
          {
            "effective_from" => "2026-01-01",
            "brackets" => [ { "upto" => 10_000, "rate" => 0.0 }, { "upto" => nil, "rate" => 0.50 } ]
          }
        ]
      )

      # 30k taxable, one part: first 10k free, 20k at 50%.
      assert_equal BigDecimal("10000"), merged.income_tax(BigDecimal("30000"), on: ON_2026)
    end
  end

  # ---------------------------------------------------------------------------

  class RateOverlayValidationTest < RateOverlayTestCase
    def test_nothing_to_correct_is_valid
      assert Tax::RateOverlay.valid?({})
      assert Tax::RateOverlay.valid?(nil)
    end

    def test_a_percentage_written_as_a_percentage_is_rejected
      # 18.6 where 0.186 was meant. Without this the report would show a tax
      # bill eighteen times the balance and nothing downstream would object.
      errors = Tax::RateOverlay.errors(
        "social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 18.6 } ]
      )

      assert_match(/not between 0 and 1/, errors.join)
      assert_match(/18.6% is 0.186/, errors.join)
    end

    def test_an_entry_with_no_effective_date_is_rejected
      errors = Tax::RateOverlay.errors("social_charges" => [ { "rate" => 0.2 } ])

      assert_match(/no date it takes effect from/, errors.join)
    end

    def test_an_unparseable_effective_date_is_rejected
      errors = Tax::RateOverlay.errors(
        "social_charges" => [ { "effective_from" => "soon", "rate" => 0.2 } ]
      )

      assert_match(/is not a date/, errors.join)
    end

    def test_a_misspelled_section_is_reported_rather_than_silently_ignored
      # Merging it would do nothing while looking saved, which is the failure
      # mode where someone believes a correction is in force and it is not.
      errors = Tax::RateOverlay.errors("social_charge" => [])

      assert_match(/is not a section of the rate file/, errors.join)
    end

    def test_brackets_without_an_open_ended_top_are_rejected
      errors = Tax::RateOverlay.errors(
        "income_tax_brackets" => [
          { "effective_from" => "2026-01-01", "brackets" => [ { "upto" => 10_000, "rate" => 0.1 } ] }
        ]
      )

      assert_match(/no final open-ended bracket/, errors.join)
    end

    def test_an_implausible_maturity_is_rejected
      errors = Tax::RateOverlay.errors("products" => { "pea" => { "maturity_years" => 500 } })

      assert_match(/not plausible/, errors.join)
    end

    def test_a_product_key_the_module_does_not_read_is_reported
      errors = Tax::RateOverlay.errors("products" => { "pea" => { "colour" => "blue" } })

      assert_match(/is not a value this module reads/, errors.join)
    end

    def test_every_problem_is_reported_at_once
      # One save should show the author everything wrong with the form, not
      # make them find the problems one round trip at a time.
      errors = Tax::RateOverlay.errors(
        "social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 50 } ],
        "products" => { "pea" => { "maturity_years" => -1, "colour" => "blue" } }
      )

      assert_operator errors.length, :>=, 2
    end

    def test_edited_sections_names_what_the_family_has_touched
      edited = Tax::RateOverlay.edited_sections(
        "social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 0.2 } ],
        "products" => {}
      )

      assert_equal [ "social_charges" ], edited
    end
  end
end
