# frozen_string_literal: true

# What the rates screen stores, as opposed to what it posts.
#
# Runs with or without Rails, like the rest of the engine:
#
#   bin/rails test test/models/tax/rate_edit_test.rb
#   ruby -Itest test/models/tax/rate_edit_test.rb
#
require_relative "engine_test_helper"
require "minitest/autorun"

module Tax
  class RateEditTestCase < Minitest::Test
    def shipped
      @shipped ||= YAML.safe_load_file(TaxEngineTestHelper.rate_file, permitted_classes: [ Date ])
    end

    # The form posts every figure back, so the honest starting point for most
    # of these tests is "the whole file, unchanged" rather than a fragment.
    def submitted_unchanged
      {
        "social_charges" => shipped["social_charges"].map { |e| e.slice("effective_from", "rate") },
        "flat_tax_income_component" =>
          shipped["flat_tax_income_component"].map { |e| e.slice("effective_from", "rate") },
        "income_tax_brackets" =>
          shipped["income_tax_brackets"].map { |e| e.slice("effective_from", "brackets") },
        "products" => shipped["products"].transform_values { |p| p.slice("maturity_years", "ceiling") }
      }
    end

    def diff(submitted)
      Tax::RateEdit.diff(shipped, submitted)
    end
  end

  # ---------------------------------------------------------------------------

  # The whole reason this class exists. Everything else in the file is a
  # variation on it.
  class RateEditStoresOnlyChangesTest < RateEditTestCase
    def test_posting_the_shipped_file_back_unchanged_stores_nothing
      assert_empty diff(submitted_unchanged),
                   "opening the screen and saving it would pin the family to today's rates"
    end

    def test_a_section_left_alone_is_absent_even_when_another_is_corrected
      submitted = submitted_unchanged
      submitted["social_charges"] = [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ]

      document = diff(submitted)

      assert_equal %w[social_charges], document.keys,
                   "correcting one section froze the others against future upgrades"
    end

    # The upgrade this is all for, stated end to end: a family corrects social
    # charges, a later release ships a new bracket table, and the family gets
    # the new brackets without losing their correction.
    def test_an_untouched_section_follows_a_later_release
      submitted = submitted_unchanged
      submitted["social_charges"] = [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ]
      stored = diff(submitted)

      next_release = Marshal.load(Marshal.dump(shipped))
      next_release["income_tax_brackets"] << {
        "effective_from" => "2027-01-01",
        "brackets" => [ { "upto" => 12_000, "rate" => 0.0 }, { "upto" => nil, "rate" => 0.45 } ]
      }

      merged = Tax::RateTable.new(Tax::RateOverlay.apply(next_release, stored))

      assert_equal BigDecimal("0.2"), merged.social_charges(Date.new(2027, 6, 1)),
                   "the family's correction was lost in the upgrade"
      assert_equal [ [ BigDecimal("12000"), BigDecimal("0") ], [ nil, BigDecimal("0.45") ] ],
                   merged.brackets(Date.new(2027, 6, 1)),
                   "the family did not receive the new brackets"
    end
  end

  # ---------------------------------------------------------------------------

  # 0.186 off the YAML parser is a Float, "0.186" off the form is a String, and
  # "0.1860" is a third spelling. Any of them stored as a correction would be a
  # row that changes nothing and freezes a section for good.
  class RateEditComparesNumbersNotTextTest < RateEditTestCase
    def test_the_same_rate_spelled_differently_is_not_a_change
      submitted = submitted_unchanged
      submitted["social_charges"] = [
        { "effective_from" => "2018-01-01", "rate" => "0.1720" },
        { "effective_from" => "2026-01-01", "rate" => "0.186" }
      ]

      assert_empty diff(submitted)
    end

    def test_a_date_written_the_way_the_file_writes_it_matches_a_parsed_one
      submitted = submitted_unchanged
      submitted["social_charges"] = [
        { "effective_from" => Date.new(2018, 1, 1), "rate" => 0.172 },
        { "effective_from" => Date.new(2026, 1, 1), "rate" => 0.186 }
      ]

      assert_empty diff(submitted)
    end

    def test_a_real_change_of_one_thousandth_is_kept
      submitted = submitted_unchanged
      submitted["social_charges"] = [
        { "effective_from" => "2018-01-01", "rate" => "0.172" },
        { "effective_from" => "2026-01-01", "rate" => "0.187" }
      ]

      assert_equal [ { "effective_from" => "2026-01-01", "rate" => "0.187" } ],
                   diff(submitted)["social_charges"]
    end
  end

  # ---------------------------------------------------------------------------

  class RateEditIgnoresWhatTheFormCannotSetTest < RateEditTestCase
    # Several shipped rows carry `note:` -- prose naming the Finance Act that
    # moved the number. The form neither shows it nor posts it back, so a
    # whole-hash comparison would find every annotated row different from
    # itself and store the entire file.
    def test_a_missing_note_is_not_a_correction
      annotated = shipped["social_charges"].select { |e| e["note"] }
      refute_empty annotated, "the fixture no longer exercises this: no shipped row carries a note"

      assert_empty diff(submitted_unchanged)
    end

    # The note belongs to the shipped file, so a corrected row should not carry
    # a stale copy of it into storage either.
    def test_a_corrected_row_stores_only_what_the_form_set
      submitted = submitted_unchanged
      submitted["social_charges"] = [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ]

      assert_equal [ "effective_from", "rate" ], diff(submitted)["social_charges"].first.keys
    end
  end

  # ---------------------------------------------------------------------------

  class RateEditNewEntriesTest < RateEditTestCase
    def test_a_date_the_file_does_not_have_is_always_kept
      submitted = submitted_unchanged
      submitted["social_charges"] += [ { "effective_from" => "2027-01-01", "rate" => "0.19" } ]

      assert_equal [ { "effective_from" => "2027-01-01", "rate" => "0.19" } ],
                   diff(submitted)["social_charges"]
    end

    # Even if it happens to repeat a rate the file already uses on another
    # date. The date is the thing that is new.
    def test_a_new_date_carrying_an_existing_rate_is_still_kept
      submitted = submitted_unchanged
      submitted["social_charges"] += [ { "effective_from" => "2030-01-01", "rate" => 0.186 } ]

      assert_equal 1, diff(submitted)["social_charges"].length
    end
  end

  # ---------------------------------------------------------------------------

  class RateEditBracketsTest < RateEditTestCase
    def test_the_shipped_brackets_posted_back_are_not_a_change
      assert_empty diff(submitted_unchanged)
    end

    def test_moving_one_threshold_keeps_the_whole_schedule_for_that_date
      submitted = submitted_unchanged
      submitted["income_tax_brackets"] = submitted["income_tax_brackets"].map do |entry|
        next entry unless entry["effective_from"].to_s == "2026-01-01"

        brackets = entry["brackets"].map(&:dup)
        brackets[1]["upto"] = 30_000
        entry.merge("brackets" => brackets)
      end

      kept = diff(submitted)["income_tax_brackets"]

      assert_equal 1, kept.length, "only the schedule that moved should be stored"
      assert_equal "2026-01-01", kept.first["effective_from"].to_s

      # The whole schedule, not just the row that moved: Tax::RateOverlay
      # replaces a dated entry rather than merging into it, so a partial
      # schedule would delete the brackets it left out.
      assert_equal 5, kept.first["brackets"].length
      assert_equal 30_000, kept.first["brackets"][1]["upto"]
    end

    def test_adding_a_bracket_is_a_change
      submitted = submitted_unchanged
      submitted["income_tax_brackets"] = submitted["income_tax_brackets"].map do |entry|
        next entry unless entry["effective_from"].to_s == "2026-01-01"

        entry.merge("brackets" => entry["brackets"] + [ { "upto" => nil, "rate" => 0.5 } ])
      end

      assert_equal 1, diff(submitted)["income_tax_brackets"].length
    end

    # `upto: null` is the open-ended top bracket, and nil is a value here, not
    # an absence. Confusing the two would make every schedule differ from
    # itself.
    def test_the_open_ended_top_bracket_compares_equal_to_itself
      top = shipped["income_tax_brackets"].last["brackets"].last

      assert_nil top["upto"], "the fixture no longer has an open-ended top bracket"
      assert_empty diff(submitted_unchanged)
    end
  end

  # ---------------------------------------------------------------------------

  class RateEditProductsTest < RateEditTestCase
    def test_the_shipped_products_posted_back_are_not_a_change
      assert_empty diff(submitted_unchanged)
    end

    def test_only_the_key_that_moved_is_stored
      submitted = submitted_unchanged
      submitted["products"] = submitted["products"].transform_values(&:dup)
      submitted["products"]["pea"]["ceiling"] = "160000"

      assert_equal({ "pea" => { "ceiling" => "160000" } }, diff(submitted)["products"])
    end

    # Merged one key at a time by the overlay, so storing a lone ceiling
    # cannot drop the maturity beside it. Asserted through the overlay rather
    # than by reading the document, because that is the property that matters.
    def test_correcting_a_ceiling_leaves_the_maturity_alone
      submitted = submitted_unchanged
      submitted["products"] = submitted["products"].transform_values(&:dup)
      submitted["products"]["pea"]["ceiling"] = "160000"

      merged = Tax::RateTable.new(Tax::RateOverlay.apply(shipped, diff(submitted)))

      assert_equal BigDecimal("160000"), merged.ceiling("pea")
      assert_equal 5, merged.maturity_years("pea")
      assert_equal "Livret A", merged.product_label("livret_a")
    end

    def test_a_product_with_no_ceiling_shipped_gains_one_when_set
      assert_nil shipped["products"]["cto"]["ceiling"],
                 "the fixture no longer exercises this: cto ships a ceiling"

      submitted = submitted_unchanged
      submitted["products"] = submitted["products"].transform_values(&:dup)
      submitted["products"]["cto"] = { "ceiling" => "1000" }

      assert_equal({ "cto" => { "ceiling" => "1000" } }, diff(submitted)["products"])
    end

    # A box left empty on a product that ships nothing there is the overwhelming
    # common case -- most products declare neither key -- and must not be
    # stored as a correction.
    def test_an_empty_box_over_an_absent_value_is_not_a_change
      submitted = submitted_unchanged
      submitted["products"] = submitted["products"].transform_values(&:dup)
      submitted["products"]["cto"] = { "ceiling" => nil, "maturity_years" => nil }

      assert_empty diff(submitted)
    end
  end

  # ---------------------------------------------------------------------------

  class RateEditContractTest < RateEditTestCase
    def test_the_result_is_something_the_overlay_will_accept
      submitted = submitted_unchanged
      submitted["social_charges"] = [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ]
      submitted["products"] = submitted["products"].transform_values(&:dup)
      submitted["products"]["pea"]["ceiling"] = "160000"

      assert_empty Tax::RateOverlay.errors(diff(submitted))
    end

    # A section the form did not post is a section the form does not manage,
    # not a section the family emptied. `unmodelled` and `label` are in the
    # file and are nobody's to correct from here.
    def test_a_section_the_form_never_posts_is_left_out_entirely
      document = diff({ "social_charges" => [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ] })

      assert_equal %w[social_charges], document.keys
    end

    def test_neither_argument_is_mutated
      before = Marshal.dump(shipped)
      submitted = submitted_unchanged
      submitted_before = Marshal.dump(submitted)

      diff(submitted)

      assert_equal before, Marshal.dump(shipped), "the shipped file was mutated"
      assert_equal submitted_before, Marshal.dump(submitted), "the submitted document was mutated"
    end
  end
end
