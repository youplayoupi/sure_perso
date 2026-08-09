# frozen_string_literal: true

require "test_helper"

# Settings > Taxes > Rates.
#
# The engine's own tests cover what a correction does once stored
# (rate_overlay_test) and what is worth storing (rate_edit_test). This file is
# about the screen: that the shipped figures reach the boxes, that what comes
# back out is the same file, and that the one thing a household cannot see --
# whether a figure still follows the shipped file -- behaves as the page says.
class Settings::TaxRatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @family = @user.family
    @family.update!(country: "FR", currency: "EUR")
  end

  # ---------------------------------------------------------------------------
  # The page

  test "every rate the module ships reaches a box, not just the one in force" do
    get settings_taxes_rates_path
    assert_response :ok

    # Two social-charge entries ship: 17.2% from 2018 and 18.6% from 2026. A
    # page that showed only today's would make the effective dating invisible
    # on the one screen that edits it.
    assert_equal %w[2018-01-01 2026-01-01], field_values("social_charges", "effective_from")
    assert_equal %w[17.2 18.6], field_values("social_charges", "rate")
  end

  test "a fraction in the file is a percentage in the box" do
    get settings_taxes_rates_path

    shipped = Tax.rate_table("FR")
    assert_equal BigDecimal("0.186"), shipped.social_charges(Date.new(2026, 6, 1)),
                 "the fixture rates moved; this test is asserting against stale figures"

    assert_includes field_values("social_charges", "rate"), "18.6"
    refute_includes response.body, "0.186",
                    "the raw fraction reached the page, which is not what a rate is called"
  end

  test "the whole progressive scale is editable, including its open-ended top band" do
    get settings_taxes_rates_path

    upto = css_select("input[name='tax_rates[income_tax_brackets][1][brackets][4][upto]']").first
    rate = css_select("input[name='tax_rates[income_tax_brackets][1][brackets][4][rate]']").first

    assert upto, "the top band has no threshold field"
    assert_nil upto["value"].presence, "the top band must stay open-ended, so its threshold is empty"
    assert_equal "45", rate["value"]
  end

  test "product figures are offered for correction" do
    get settings_taxes_rates_path

    assert_equal "5", input_value("tax_rates[products][pea][maturity_years]")
    assert_equal "150000", input_value("tax_rates[products][pea][ceiling]")
  end

  test "the page speaks the interface language, not the rate file's key names" do
    get settings_taxes_rates_path

    assert_includes response.body, I18n.t("settings.tax_rates.sections.social_charges")
    refute_includes body_text, "flat_tax_income_component"
    refute_includes body_text, "income_tax_brackets"
  end

  # ---------------------------------------------------------------------------
  # Saving

  # The property the whole design rests on. If opening the page and saving it
  # stored the file, every family would be pinned to the rates of the day they
  # first looked, and would never receive a future release's figures.
  test "saving the page untouched stores nothing at all" do
    get settings_taxes_rates_path
    patch settings_taxes_rates_path, params: { tax_rates: submitted_from_page }

    assert_redirected_to settings_taxes_rates_path
    assert_nil Tax::RateCorrection.find_by(family: @family, country: "FR"),
               "opening the page and saving it pinned the family to today's rates"
  end

  test "a corrected rate is stored, and only that" do
    correct("social_charges", 1, "rate" => "20")

    correction = Tax::RateCorrection.find_by(family: @family, country: "FR")
    assert correction, "the correction was not stored"
    assert_equal %w[social_charges], correction.overrides.keys,
                 "correcting one section stored the others too, freezing them against upgrades"
    assert_equal [ { "effective_from" => "2026-01-01", "rate" => "0.2" } ],
                 correction.overrides["social_charges"]
  end

  test "the corrected figure is what the page shows next time, flagged against the shipped one" do
    correct("social_charges", 1, "rate" => "20")

    get settings_taxes_rates_path
    assert_includes field_values("social_charges", "rate"), "20"
    assert_includes body_text,
                    I18n.t("settings.tax_rates.shipped_was", value: "18.6%"),
                    "the page does not say what the figure was before it was corrected"
  end

  # A correction is only worth storing if it reaches the arithmetic. Asserted
  # through the table the report is computed from rather than by reading the
  # document back, because that is the property that matters.
  test "a corrected rate is the rate the engine computes with" do
    correct("social_charges", 1, "rate" => "20")

    assert_equal BigDecimal("0.2"),
                 Tax.rate_table_for(@family, "FR").social_charges(Date.new(2026, 6, 1))
  end

  test "a bracket threshold can be moved, and the rest of the scale survives it" do
    page = submitted_from_page
    page["income_tax_brackets"]["1"]["brackets"]["1"]["upto"] = "30000"
    patch settings_taxes_rates_path, params: { tax_rates: page }

    brackets = Tax.rate_table_for(@family, "FR").brackets(Date.new(2026, 6, 1))

    assert_equal 5, brackets.length, "moving one threshold dropped the rest of the scale"
    assert_equal BigDecimal("30000"), brackets[1].first
    assert_equal BigDecimal("84577"), brackets[2].first, "an untouched band changed"
    assert_nil brackets.last.first, "the scale lost its open-ended top band"
  end

  test "a product ceiling can be corrected without dropping its maturity" do
    page = submitted_from_page
    page["products"]["pea"]["ceiling"] = "160000"
    patch settings_taxes_rates_path, params: { tax_rates: page }

    table = Tax.rate_table_for(@family, "FR")
    assert_equal BigDecimal("160000"), table.ceiling("pea")
    assert_equal 5, table.maturity_years("pea"), "correcting the ceiling dropped the maturity"
    assert_equal "PEA", table.product_label("pea"), "correcting the ceiling dropped the label"
  end

  test "a rate on a date the file does not have is added to the schedule" do
    page = submitted_from_page
    page["social_charges"]["new_0"] = { "effective_from" => "2030-01-01", "rate" => "21" }
    patch settings_taxes_rates_path, params: { tax_rates: page }

    table = Tax.rate_table_for(@family, "FR")
    assert_equal BigDecimal("0.186"), table.social_charges(Date.new(2029, 6, 1)),
                 "a future rate leaked backwards"
    assert_equal BigDecimal("0.21"), table.social_charges(Date.new(2030, 6, 1))
  end

  test "commas are read as decimal points" do
    correct("social_charges", 1, "rate" => "18,9")

    assert_equal BigDecimal("0.189"),
                 Tax.rate_table_for(@family, "FR").social_charges(Date.new(2026, 6, 1))
  end

  # ---------------------------------------------------------------------------
  # Refusing

  test "an unreadable rate is a form error, not a 500 and not a silent zero" do
    page = submitted_from_page
    page["social_charges"]["1"]["rate"] = "eighteen"
    patch settings_taxes_rates_path, params: { tax_rates: page }

    assert_response :unprocessable_entity
    assert_nil Tax::RateCorrection.find_by(family: @family, country: "FR"),
               "an unreadable rate was stored"
  end

  # The mistake this exists for: typing 18.6 into a box that wanted 0.186 was
  # already guarded by the overlay, and the percentage boxes here mean the
  # equivalent slip is typing 1860. Either way it must not save.
  test "a rate over 100 percent is refused" do
    page = submitted_from_page
    page["social_charges"]["1"]["rate"] = "1860"
    patch settings_taxes_rates_path, params: { tax_rates: page }

    assert_response :unprocessable_entity
    assert_nil Tax::RateCorrection.find_by(family: @family, country: "FR")
  end

  test "a scale with no open-ended top band is refused" do
    page = submitted_from_page
    page["income_tax_brackets"]["1"]["brackets"]["4"]["upto"] = "250000"
    patch settings_taxes_rates_path, params: { tax_rates: page }

    assert_response :unprocessable_entity
    assert_nil Tax::RateCorrection.find_by(family: @family, country: "FR"),
               "a scale that would leave the highest incomes untaxed was stored"
  end

  # The refusal has to be readable, or the form is a dead end.
  test "a refusal names the problem in words" do
    page = submitted_from_page
    page["social_charges"]["1"]["rate"] = "1860"
    patch settings_taxes_rates_path, params: { tax_rates: page }

    assert_match(/between 0 and 1/, body_text)
  end

  # Re-rendered from what was submitted, not from what is stored, so someone
  # is not told a figure is wrong while looking at a different figure.
  test "a refused page still shows what was typed" do
    page = submitted_from_page
    page["social_charges"]["1"]["rate"] = "1860"
    patch settings_taxes_rates_path, params: { tax_rates: page }

    assert_includes field_values("social_charges", "rate"), "1860"
  end

  test "a product name the file does not carry is dropped rather than stored" do
    page = submitted_from_page
    page["products"]["not_a_product"] = { "ceiling" => "5000" }
    patch settings_taxes_rates_path, params: { tax_rates: page }

    correction = Tax::RateCorrection.find_by(family: @family, country: "FR")
    assert_nil correction,
               "a correction was stored against a product no rule can ever look up"
  end

  # ---------------------------------------------------------------------------
  # Going back

  test "corrections can be cleared in one action" do
    correct("social_charges", 1, "rate" => "20")
    assert Tax::RateCorrection.find_by(family: @family, country: "FR")

    delete settings_taxes_rates_path

    assert_redirected_to settings_taxes_rates_path
    assert_nil Tax::RateCorrection.find_by(family: @family, country: "FR")
    assert_equal BigDecimal("0.186"),
                 Tax.rate_table_for(@family, "FR").social_charges(Date.new(2026, 6, 1)),
                 "the shipped rate did not come back"
  end

  # Reverting a figure by hand and clearing it are the same operation, because
  # what is stored is the difference. The record should go, not linger empty:
  # the report flags a corrected figure off `edited?`, which would otherwise
  # answer on the presence of a row rather than on its contents.
  test "typing a corrected figure back to its shipped value removes the record" do
    correct("social_charges", 1, "rate" => "20")
    correct("social_charges", 1, "rate" => "18.6")

    assert_nil Tax::RateCorrection.find_by(family: @family, country: "FR")
  end

  test "clearing corrections nobody made is not an error" do
    delete settings_taxes_rates_path

    assert_redirected_to settings_taxes_rates_path
  end

  # ---------------------------------------------------------------------------
  # Whose rates

  test "one family's corrections do not reach another's rates" do
    correct("social_charges", 1, "rate" => "20")

    other = families(:empty)
    other.update!(country: "FR", currency: "EUR")

    assert_equal BigDecimal("0.186"),
                 Tax.rate_table_for(other, "FR").social_charges(Date.new(2026, 6, 1)),
                 "a correction leaked into another household's rates"
  end

  # `Tax.rate_data` memoises the parsed file for the life of the process, so a
  # merge that wrote into it rather than onto a copy would poison every
  # subsequent request. The overlay has a unit test for this; it is repeated
  # here because the controller is where a stray mutation would actually be
  # introduced.
  test "correcting a rate does not alter the shipped file for the process" do
    correct("social_charges", 1, "rate" => "20")

    assert_equal BigDecimal("0.186"), Tax.rate_table("FR").social_charges(Date.new(2026, 6, 1)),
                 "the shipped table was mutated in place"
  end

  test "a household in a country this module has no rates for is sent away" do
    @family.update!(country: "US")

    get settings_taxes_rates_path
    assert_redirected_to settings_profile_path

    patch settings_taxes_rates_path, params: { tax_rates: { "social_charges" => {} } }
    assert_redirected_to settings_profile_path
  end

  # ---------------------------------------------------------------------------

  private
    # The page's own form, read back off the page, as the browser would post
    # it. Building the expected params by hand instead would let the test pass
    # against a form that renders something else entirely.
    def submitted_from_page
      get settings_taxes_rates_path
      assert_response :ok

      params = {}

      css_select("input[name^='tax_rates']").each do |input|
        name = input["name"]

        # Template rows are inside <template> and are never submitted by a
        # browser. Including them would post a row of placeholders.
        next if name.include?("PLACEHOLDER")

        keys = name.scan(/\[([^\]]*)\]/).flatten
        keys.inject(params) do |node, key|
          key == keys.last ? node[key] = input["value"].to_s : node[key] ||= {}
        end
      end

      params
    end

    # Post the page back with one field changed. The rest goes back exactly as
    # rendered, which is the point: a correction has to survive the round trip
    # of every other figure on the page.
    def correct(section, index, changes)
      page = submitted_from_page
      page[section][index.to_s].merge!(changes)

      patch settings_taxes_rates_path, params: { tax_rates: page }
    end

    def field_values(section, field)
      css_select("input[name^='tax_rates[#{section}]'][name$='[#{field}]']")
        .reject { |i| i["name"].include?("PLACEHOLDER") }
        .map { |i| i["value"].to_s }
    end

    def input_value(name)
      css_select(%(input[name="#{name}"])).first&.[]("value")
    end

    def body_text
      Nokogiri::HTML(response.body).css("main").text
    end
end
