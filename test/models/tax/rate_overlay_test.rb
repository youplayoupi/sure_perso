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

    # Every section of the shipped file is correctable, discovered by shape
    # rather than by name. This is the whole of what makes a second country a
    # YAML file: nothing in the overlay, the form or the validator has to learn
    # that a country calls one of its rates `social_charges`.
    def test_every_dated_section_of_the_shipped_file_can_be_corrected
      Tax::RateOverlay.dated_sections(shipped).each do |section|
        merged = table(section => [ { "effective_from" => "2026-01-01", "rate" => 0.42 } ])

        assert_equal BigDecimal("0.42"), merged.rate(section, ON_2026),
                     "#{section} did not take a correction"
      end
    end

    # A section a country invents behaves like one France happens to have. The
    # file is the authority on what rates exist, so a name this module has
    # never seen has to merge, validate and resolve on the same path.
    def test_a_section_this_module_has_never_heard_of_merges_like_any_other
      invented = shipped.merge(
        "regional_surcharge" => [ { "effective_from" => "2020-01-01", "rate" => 0.03 } ]
      )
      merged = Tax::RateTable.new(
        Tax::RateOverlay.apply(
          invented, "regional_surcharge" => [ { "effective_from" => "2026-01-01", "rate" => 0.05 } ]
        )
      )

      assert_includes Tax::RateOverlay.dated_sections(invented), "regional_surcharge"
      assert_equal BigDecimal("0.03"), merged.rate("regional_surcharge", ON_2025)
      assert_equal BigDecimal("0.05"), merged.rate("regional_surcharge", ON_2026)
    end

    # The identity keys and the derived ones are not rate schedules and must
    # not be offered as correctable, or the form would draw a date-and-rate
    # table over the country code.
    def test_the_non_rate_keys_are_not_mistaken_for_sections
      sections = Tax::RateOverlay.dated_sections(shipped)

      refute_includes sections, "products"
      refute_includes sections, "composites"
      refute_includes sections, "country"
      refute_includes sections, "currency"
    end

    # The composite is computed from its parts, so it is a rate the table can
    # resolve but not a section anyone can edit. Correcting a total whose parts
    # disagree with it is a contradiction the file should not be able to hold.
    def test_a_composite_is_a_rate_but_not_an_editable_section
      refute_includes Tax::RateOverlay.dated_sections(shipped), "flat_tax"
      assert_includes Tax::RateTable.new(shipped).rate_names, "flat_tax"
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
        { "social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 18.6 } ] }
      )

      assert_match(/not between 0 and 1/, errors.join)
      assert_match(/18.6% is 0.186/, errors.join)
    end

    def test_an_entry_with_no_effective_date_is_rejected
      errors = Tax::RateOverlay.errors({ "social_charges" => [ { "rate" => 0.2 } ] })

      assert_match(/no date it takes effect from/, errors.join)
    end

    def test_an_unparseable_effective_date_is_rejected
      errors = Tax::RateOverlay.errors(
        { "social_charges" => [ { "effective_from" => "soon", "rate" => 0.2 } ] }
      )

      assert_match(/is not a date/, errors.join)
    end

    def test_a_misspelled_section_is_reported_rather_than_silently_ignored
      # Merging it would do nothing while looking saved, which is the failure
      # mode where someone believes a correction is in force and it is not.
      errors = Tax::RateOverlay.errors(
        { "social_charge" => [] }, known_sections: Tax::RateOverlay.dated_sections(shipped)
      )

      assert_match(/is not a section of the rate file/, errors.join)
    end

    # Without the shipped file to check against, a name cannot be judged: this
    # module does not know what rates a country publishes, and refusing an
    # unfamiliar one would be refusing every country but France. The shape is
    # still checked. Every caller inside the app passes the sections, so the
    # strict branch above is the one that runs in practice.
    def test_an_unfamiliar_section_is_taken_on_trust_when_no_file_is_given
      assert_empty Tax::RateOverlay.errors(
        { "regional_surcharge" => [ { "effective_from" => "2026-01-01", "rate" => 0.03 } ] }
      )
    end

    def test_the_message_names_the_sections_that_would_have_worked
      errors = Tax::RateOverlay.errors(
        { "social_charge" => [] }, known_sections: Tax::RateOverlay.dated_sections(shipped)
      )

      assert_match(/social_charges/, errors.join)
    end

    # `products` is not a rate section and is never in `dated_sections`, so a
    # caller passing that list has to still be able to correct a ceiling.
    def test_products_survives_the_section_check
      assert_empty Tax::RateOverlay.errors(
        { "products" => { "pea" => { "maturity_years" => 8 } } },
        known_sections: Tax::RateOverlay.dated_sections(shipped)
      )
    end

    def test_an_implausible_maturity_is_rejected
      errors = Tax::RateOverlay.errors({ "products" => { "pea" => { "maturity_years" => 500 } } })

      assert_match(/not plausible/, errors.join)
    end

    def test_a_product_key_the_module_does_not_read_is_reported
      errors = Tax::RateOverlay.errors({ "products" => { "pea" => { "colour" => "blue" } } })

      assert_match(/is not a value this module reads/, errors.join)
    end

    def test_every_problem_is_reported_at_once
      # One save should show the author everything wrong with the form, not
      # make them find the problems one round trip at a time.
      errors = Tax::RateOverlay.errors(
        {
          "social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 50 } ],
          "products" => { "pea" => { "maturity_years" => -1, "colour" => "blue" } }
        }
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
