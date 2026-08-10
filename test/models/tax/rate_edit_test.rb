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
    #
    # Assembled from the sections the shipped file turns out to have, the same
    # way the form assembles itself. Naming France's sections here would mean a
    # country file that grew one had a section the screen drew, the controller
    # posted and this suite never once round-tripped.
    def submitted_unchanged
      Tax::RateOverlay.dated_sections(shipped).each_with_object({}) { |section, out|
        out[section] = shipped[section].map { |e| e.slice("effective_from", "rate") }
      }.merge(
        "products" => shipped["products"].transform_values { |p| p.slice("maturity_years", "ceiling") }
      )
    end

    # A section other than the one a test is correcting, so that "one section
    # moved, the others did not" is asserted against a file with more than one.
    def another_section(besides)
      Tax::RateOverlay.dated_sections(shipped).find { |s| s != besides } ||
        flunk("the fixture has only one dated section; these tests prove nothing")
    end

    # Not called `diff`. Minitest::Assertions defines a two-argument `diff`
    # that it calls to build the message for a failing assertion, and a
    # one-argument override of it turns every failure in this file into an
    # ArgumentError raised from inside the reporter -- the assertion that
    # actually broke never gets named.
    def stored(submitted)
      Tax::RateEdit.diff(shipped, submitted)
    end
  end

  # ---------------------------------------------------------------------------

  # The whole reason this class exists. Everything else in the file is a
  # variation on it.
  class RateEditStoresOnlyChangesTest < RateEditTestCase
    def test_posting_the_shipped_file_back_unchanged_stores_nothing
      assert_empty stored(submitted_unchanged),
                   "opening the screen and saving it would pin the family to today's rates"
    end

    def test_a_section_left_alone_is_absent_even_when_another_is_corrected
      submitted = submitted_unchanged
      submitted["social_charges"] = [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ]

      document = stored(submitted)

      assert_equal %w[social_charges], document.keys,
                   "correcting one section froze the others against future upgrades"
    end

    # The upgrade this is all for, stated end to end: a family corrects social
    # charges, a later release moves a rate they never touched, and they get
    # the new figure without losing their correction.
    def test_an_untouched_section_follows_a_later_release
      other = another_section("social_charges")

      submitted = submitted_unchanged
      submitted["social_charges"] = [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ]
      stored = stored(submitted)

      next_release = Marshal.load(Marshal.dump(shipped))
      next_release[other] << { "effective_from" => "2027-01-01", "rate" => 0.45 }

      merged = Tax::RateTable.new(Tax::RateOverlay.apply(next_release, stored))

      assert_equal BigDecimal("0.2"), merged.rate("social_charges", Date.new(2027, 6, 1)),
                   "the family's correction was lost in the upgrade"
      assert_equal BigDecimal("0.45"), merged.rate(other, Date.new(2027, 6, 1)),
                   "the family did not receive the new #{other}"
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

      assert_empty stored(submitted)
    end

    def test_a_date_written_the_way_the_file_writes_it_matches_a_parsed_one
      submitted = submitted_unchanged
      submitted["social_charges"] = [
        { "effective_from" => Date.new(2018, 1, 1), "rate" => 0.172 },
        { "effective_from" => Date.new(2026, 1, 1), "rate" => 0.186 }
      ]

      assert_empty stored(submitted)
    end

    def test_a_real_change_of_one_thousandth_is_kept
      submitted = submitted_unchanged
      submitted["social_charges"] = [
        { "effective_from" => "2018-01-01", "rate" => "0.172" },
        { "effective_from" => "2026-01-01", "rate" => "0.187" }
      ]

      assert_equal [ { "effective_from" => "2026-01-01", "rate" => "0.187" } ],
                   stored(submitted)["social_charges"]
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

      assert_empty stored(submitted_unchanged)
    end

    # The note belongs to the shipped file, so a corrected row should not carry
    # a stale copy of it into storage either.
    def test_a_corrected_row_stores_only_what_the_form_set
      submitted = submitted_unchanged
      submitted["social_charges"] = [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ]

      assert_equal [ "effective_from", "rate" ], stored(submitted)["social_charges"].first.keys
    end
  end

  # ---------------------------------------------------------------------------

  class RateEditNewEntriesTest < RateEditTestCase
    def test_a_date_the_file_does_not_have_is_always_kept
      submitted = submitted_unchanged
      submitted["social_charges"] += [ { "effective_from" => "2027-01-01", "rate" => "0.19" } ]

      assert_equal [ { "effective_from" => "2027-01-01", "rate" => "0.19" } ],
                   stored(submitted)["social_charges"]
    end

    # Even if it happens to repeat a rate the file already uses on another
    # date. The date is the thing that is new.
    def test_a_new_date_carrying_an_existing_rate_is_still_kept
      submitted = submitted_unchanged
      submitted["social_charges"] += [ { "effective_from" => "2030-01-01", "rate" => 0.186 } ]

      assert_equal 1, stored(submitted)["social_charges"].length
    end
  end

  # ---------------------------------------------------------------------------

  # Every dated section behaves the same, because none of this code knows one
  # section from another. Asserted by looping over whatever the file has rather
  # than by picking a favourite, which is what would let a second country's
  # file be half-supported without anything failing.
  class RateEditTreatsEverySectionAlikeTest < RateEditTestCase
    def sections
      Tax::RateOverlay.dated_sections(shipped)
    end

    def test_the_fixture_has_more_than_one_section_to_compare
      assert_operator sections.length, :>=, 2,
                      "with one section these tests cannot tell generic from hard-coded"
    end

    def test_correcting_any_one_section_stores_that_section_and_no_other
      sections.each do |section|
        submitted = submitted_unchanged
        submitted[section] = [ { "effective_from" => "2026-01-01", "rate" => "0.42" } ]

        assert_equal [ section ], stored(submitted).keys,
                     "correcting #{section} did not store exactly #{section}"
      end
    end

    def test_any_section_posted_back_unchanged_is_not_a_correction
      sections.each do |section|
        submitted = submitted_unchanged
        submitted[section] = shipped[section].map do |entry|
          { "effective_from" => entry["effective_from"].to_s,
            "rate" => entry["rate"].to_s }
        end

        assert_empty stored(submitted), "#{section} differed from itself once retyped"
      end
    end

    # The overlay replaces a dated entry rather than merging into it, so what
    # gets stored for a corrected date has to be the whole entry.
    def test_a_corrected_entry_is_stored_whole
      submitted = submitted_unchanged
      submitted["social_charges"] = [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ]

      entry = stored(submitted)["social_charges"].first

      assert_equal %w[effective_from rate], entry.keys.sort
      merged = Tax::RateTable.new(Tax::RateOverlay.apply(shipped, stored(submitted)))

      # The history either side of the corrected date survives the replacement.
      assert_equal BigDecimal("0.2"), merged.rate("social_charges", Date.new(2026, 6, 1))
      assert_equal BigDecimal("0.172"), merged.rate("social_charges", Date.new(2025, 6, 1))
    end

    # Clearing every row of a section stores nothing, and the section goes on
    # showing what the file ships.
    #
    # Not an oversight, and worth a test of its own because the screen has to
    # say it. Tax::RateOverlay merges: it lays entries over the shipped file
    # and has no way to express "and drop that one". So no override document
    # can mean "this country no longer levies social charges", and a diff that
    # stored an empty list would produce one that merged back to exactly what
    # shipped -- a correction that looks saved and does nothing, which is the
    # failure this whole class exists to prevent.
    def test_clearing_a_section_stores_nothing_because_deletion_cannot_be_expressed
      emptied = submitted_unchanged
      emptied["social_charges"] = []

      assert_empty stored(emptied)

      merged = Tax::RateTable.new(Tax::RateOverlay.apply(shipped, stored(emptied)))
      assert_equal BigDecimal("0.186"), merged.rate("social_charges", Date.new(2026, 6, 1))
    end

    # Zero is how a household says it instead, and it is a statement the
    # overlay can carry all the way through to the composite built on top.
    def test_a_section_zeroed_out_is_a_correction_that_holds
      zeroed = submitted_unchanged
      zeroed["social_charges"] = [ { "effective_from" => "2026-01-01", "rate" => "0" } ]

      merged = Tax::RateTable.new(Tax::RateOverlay.apply(shipped, stored(zeroed)))

      assert_equal BigDecimal("0"), merged.rate("social_charges", Date.new(2026, 6, 1))
      assert_equal BigDecimal("0.128"), merged.rate("flat_tax", Date.new(2026, 6, 1)),
                   "the composite did not follow its corrected part"
    end
  end

  # ---------------------------------------------------------------------------

  class RateEditProductsTest < RateEditTestCase
    def test_the_shipped_products_posted_back_are_not_a_change
      assert_empty stored(submitted_unchanged)
    end

    def test_only_the_key_that_moved_is_stored
      submitted = submitted_unchanged
      submitted["products"] = submitted["products"].transform_values(&:dup)
      submitted["products"]["pea"]["ceiling"] = "160000"

      assert_equal({ "pea" => { "ceiling" => "160000" } }, stored(submitted)["products"])
    end

    # Merged one key at a time by the overlay, so storing a lone ceiling
    # cannot drop the maturity beside it. Asserted through the overlay rather
    # than by reading the document, because that is the property that matters.
    def test_correcting_a_ceiling_leaves_the_maturity_alone
      submitted = submitted_unchanged
      submitted["products"] = submitted["products"].transform_values(&:dup)
      submitted["products"]["pea"]["ceiling"] = "160000"

      merged = Tax::RateTable.new(Tax::RateOverlay.apply(shipped, stored(submitted)))

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

      assert_equal({ "cto" => { "ceiling" => "1000" } }, stored(submitted)["products"])
    end

    # A box left empty on a product that ships nothing there is the overwhelming
    # common case -- most products declare neither key -- and must not be
    # stored as a correction.
    def test_an_empty_box_over_an_absent_value_is_not_a_change
      submitted = submitted_unchanged
      submitted["products"] = submitted["products"].transform_values(&:dup)
      submitted["products"]["cto"] = { "ceiling" => nil, "maturity_years" => nil }

      assert_empty stored(submitted)
    end
  end

  # ---------------------------------------------------------------------------

  class RateEditContractTest < RateEditTestCase
    def test_the_result_is_something_the_overlay_will_accept
      submitted = submitted_unchanged
      submitted["social_charges"] = [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ]
      submitted["products"] = submitted["products"].transform_values(&:dup)
      submitted["products"]["pea"]["ceiling"] = "160000"

      assert_empty Tax::RateOverlay.errors(stored(submitted))
    end

    # A section the form did not post is a section the form does not manage,
    # not a section the family emptied. `unmodelled` and `label` are in the
    # file and are nobody's to correct from here.
    def test_a_section_the_form_never_posts_is_left_out_entirely
      document = stored({ "social_charges" => [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ] })

      assert_equal %w[social_charges], document.keys
    end

    def test_neither_argument_is_mutated
      before = Marshal.dump(shipped)
      submitted = submitted_unchanged
      submitted_before = Marshal.dump(submitted)

      stored(submitted)

      assert_equal before, Marshal.dump(shipped), "the shipped file was mutated"
      assert_equal submitted_before, Marshal.dump(submitted), "the submitted document was mutated"
    end
  end
end
