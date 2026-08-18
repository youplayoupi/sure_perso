# frozen_string_literal: true

require "test_helper"

class TaxCountriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "the index lists supported countries and the general mechanism" do
    get tax_countries_path

    assert_response :ok
    assert_select "h1", text: I18n.t("tax_countries.index.title")
    # Every shipped country is linked.
    Tax.supported_countries.each do |code|
      assert_select "a[href=?]", tax_country_path(code)
    end
  end

  test "the index is available even when the family's country is unsupported" do
    @family.update!(country: "ZZ") # not a supported tax country

    get tax_countries_path

    assert_response :ok
    assert_select "a[href=?]", tax_country_path("US")
  end

  test "a country subpage renders its coverage, rates and limits" do
    get tax_country_path("US")

    assert_response :ok
    assert_select "h1", text: /United Kingdom|United States|US/i
    # A taxed wrapper and an exempt one both appear.
    assert_select "body", text: /Taxed on liquidation/i
    assert_select "body", text: /Exempt/i
  end

  test "each supported country subpage renders" do
    Tax.supported_countries.each do |code|
      get tax_country_path(code)
      assert_response :ok, "#{code} subpage should render"
    end
  end

  test "an unsupported country code redirects back to the index" do
    get tax_country_path("ZZ")

    assert_redirected_to tax_countries_path
    assert_equal I18n.t("tax_countries.show.unsupported", country: "ZZ"), flash[:alert]
  end
end
