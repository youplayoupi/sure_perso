# frozen_string_literal: true

require "test_helper"

# Settings > Taxes: the one field that is about the household rather than
# about its accounts.
#
# There is more test here than there is controller, deliberately. This single
# number multiplies the largest bases the module ever computes -- a whole PER
# withdrawal, not just its growth -- so a slip of two decimal places between
# the box and the column is the difference between a 30% bill and a 0.3% one,
# and nothing downstream would object to either. The conversion is therefore
# asserted from both ends: what a typed percentage becomes in the column, and
# what a stored fraction looks like back in the box.
class Settings::TaxHouseholdsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @family = @user.family
    @family.update!(country: "FR", currency: "EUR")
  end

  # ---------------------------------------------------------------------------
  # Percentages in, fractions out

  test "a percentage in the box is a fraction in the column" do
    declare "30"

    assert_equal BigDecimal("0.3"), Tax::Household.find_by(family: @family).marginal_rate
  end

  test "a fraction in the column is a percentage in the box" do
    declare "30"

    get settings_taxes_path

    assert_equal "30", input_value("tax_household[marginal_rate]"),
                 "the stored fraction reached the box, which is not what a tax rate is called"
  end

  test "a rate with a decimal survives the round trip unrounded" do
    declare "11.5"

    assert_equal BigDecimal("0.115"), Tax::Household.find_by(family: @family).marginal_rate

    get settings_taxes_path
    assert_equal "11.5", input_value("tax_household[marginal_rate]")
  end

  test "commas are read as decimal points" do
    declare "41,5"

    assert_equal BigDecimal("0.415"), Tax::Household.find_by(family: @family).marginal_rate
  end

  # People copy the figure off an assessment, and assessments print the sign.
  test "a percent sign and stray whitespace are tolerated" do
    declare "  30 % "

    assert_equal BigDecimal("0.3"), Tax::Household.find_by(family: @family).marginal_rate
  end

  test "saving a second time corrects the rate rather than adding a row" do
    declare "30"
    declare "41"

    assert_equal 1, Tax::Household.where(family: @family).count
    assert_equal BigDecimal("0.41"), Tax::Household.find_by(family: @family).marginal_rate
  end

  # ---------------------------------------------------------------------------
  # Going back to undeclared

  # Blank is a statement, not a failed edit. Undeclared is the state the report
  # says out loud, so it has to be reachable from the form that left it.
  test "clearing the field puts the household back to undeclared" do
    declare "30"

    declare ""

    assert_nil Tax::Household.find_by(family: @family),
               "an emptied row was kept as a tombstone; a null rate and no row mean the same thing"
    assert_nil Tax::Household.marginal_rate_for(@family)
    assert_equal I18n.t("settings.tax_households.update.cleared"), flash[:notice]
  end

  test "clearing a rate nobody declared is not an error" do
    declare ""

    assert_redirected_to settings_taxes_path
    assert_nil Tax::Household.find_by(family: @family)
  end

  # ---------------------------------------------------------------------------
  # Refusing

  # The failure this guards is specific: the column is a decimal, so "abc"
  # casts to zero without complaint. A household asserted to be on a 0% marginal
  # rate computes confidently and wrongly, which is the one output this module
  # exists to refuse -- and unlike an undeclared rate, it would not be flagged.
  test "an unreadable rate is refused by name rather than cast to zero" do
    declare "thirty"

    assert_nil Tax::Household.find_by(family: @family)
    assert_equal I18n.t("settings.tax_households.update.unreadable", value: "thirty"), flash[:alert]
  end

  test "an unreadable rate does not overwrite the one already declared" do
    declare "30"

    declare "thirty percent"

    assert_equal BigDecimal("0.3"), Tax::Household.find_by(family: @family).marginal_rate,
                 "a typo replaced a good rate"
  end

  # 130 is what a slipped keystroke looks like; the column would take it and
  # every PER withdrawal would be taxed above its own value.
  test "a rate over one hundred percent is refused" do
    declare "130"

    assert_nil Tax::Household.find_by(family: @family)
    assert flash[:alert].present?, "an impossible rate was stored without a word"
  end

  test "a negative rate is refused" do
    declare "-5"

    assert_nil Tax::Household.find_by(family: @family)
  end

  # Not a mistake: a household can have no income tax to pay. The boundary is
  # on the list because it is the value most likely to be excluded by a
  # validation written in a hurry.
  test "zero is a rate, not a blank" do
    declare "0"

    household = Tax::Household.find_by(family: @family)

    assert household, "zero was read as clearing the field"
    assert_equal BigDecimal("0"), household.marginal_rate
    assert household.declared?, "a household on a zero rate has still said something"
  end

  test "one hundred percent is allowed at the boundary" do
    declare "100"

    assert_equal BigDecimal("1"), Tax::Household.find_by(family: @family).marginal_rate
  end

  # ---------------------------------------------------------------------------
  # Whose rate

  test "one household's rate does not reach another's" do
    declare "41"

    other = families(:empty)
    other.update!(country: "FR", currency: "EUR")

    assert_nil Tax::Household.marginal_rate_for(other)
  end

  test "a household in a country this module has no rules for is sent away" do
    @family.update!(country: "US")

    patch settings_taxes_household_path, params: { tax_household: { marginal_rate: "30" } }

    assert_redirected_to settings_profile_path
    assert_nil Tax::Household.find_by(family: @family)
  end

  # ---------------------------------------------------------------------------
  # What the page says about it

  # The rate is an assumption the report leans on, so the page that sets it has
  # to say which of the two states it is in. Silence reads as "declared".
  test "the page says whether the rate has been declared" do
    get settings_taxes_path
    assert_includes body_text, I18n.t("settings.taxes.show.household_undeclared")

    declare "30"

    get settings_taxes_path
    assert_includes body_text, I18n.t("settings.taxes.show.household_declared")
  end

  # ---------------------------------------------------------------------------

  private
    def declare(value)
      patch settings_taxes_household_path, params: { tax_household: { marginal_rate: value } }
    end

    def input_value(name)
      css_select(%(input[name="#{name}"])).first&.[]("value")
    end

    def body_text
      Nokogiri::HTML(response.body).css("main").text
    end
end
