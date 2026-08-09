# frozen_string_literal: true

require "test_helper"

class TaxReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @family = @user.family

    # The fixtures are a US family holding dollars. A French household holding
    # dollars is a legitimate case, but it is not this one, and leaving the
    # accounts in USD would mean every test below exercised the
    # no-exchange-rate refusal rather than the rules. That path has its own
    # tests in rails_integration_test.rb.
    @family.update!(country: "FR", currency: "EUR")
    @family.accounts.update_all(currency: "EUR")
  end

  test "the page renders" do
    get tax_report_path

    assert_response :ok
    assert_select "h1", text: I18n.t("tax_reports.show.title")
  end

  test "a country with no rules gets an explanation instead of a blank page" do
    @family.update!(country: "US")

    get tax_report_path

    assert_response :ok
    assert_select "body", text: /no rules for US yet/i
  end

  test "an incomplete portfolio says so above the numbers, not in a footnote" do
    # The fixture family holds a Crypto account and a Property, both of which
    # this module deliberately declines to model, so the report is incomplete
    # by construction.
    get tax_report_path

    assert_response :ok
    assert_select "body", text: /could not be computed/
  end

  test "the net figure is relabelled, not merely footnoted, when incomplete" do
    get tax_report_path

    assert_select "body", text: /#{Regexp.escape(I18n.t('tax_reports.show.net_upper_bound'))}/
  end

  test "assumptions are on the page, because a net without them is meaningless" do
    get tax_report_path(tmi_mode: "flat", flat_rate: "0.30")

    assert_response :ok
    assert_select "body", text: /Everything is sold on/
  end

  test "the page speaks one currency, even when the family displays another" do
    # The first version rendered the headline in euros over rows in dollars,
    # which is the report contradicting itself in the place a reader looks
    # first. The family's display currency is set against the grain here on
    # purpose: French brackets are euro amounts, so the report stays in euros
    # whatever the rest of Sure is showing.
    @family.update!(currency: "USD")

    get tax_report_path

    assert_response :ok
    assert_no_match(/\$/, css_select("main").to_s,
                    "a dollar figure survived on a euro-denominated report")
  end

  test "a nonsense valuation date falls back to today rather than erroring" do
    get tax_report_path(on: "not-a-date")

    assert_response :ok
  end

  test "a nonsense numeric parameter falls back rather than erroring" do
    get tax_report_path(other_income: "abc", parts: "xyz", horizon: "999")

    assert_response :ok
  end

  test "it renders nothing and changes nothing" do
    # A reporting page that can mutate an account is a bug waiting to happen,
    # so the claim is asserted rather than assumed.
    assert_no_changes -> { [ Account.count, Holding.count, Entry.count, Balance.count ] } do
      get tax_report_path
    end
  end

  test "another family's data is not visible" do
    other = families(:empty)
    other.update!(country: "FR")

    get tax_report_path

    assert_response :ok
    assert_select "body" do |body|
      other.accounts.each do |account|
        assert_no_match(/#{Regexp.escape(account.name)}/, body.to_s)
      end
    end
  end

  test "signed out, the page is not reachable" do
    sign_out

    get tax_report_path

    assert_redirected_to new_session_path
  end

  private
    def sign_out
      @user.sessions.each { |session| delete session_path(session) }
    end
end
