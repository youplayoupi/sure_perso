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
    get tax_report_path

    assert_response :ok
    assert_select "body", text: /Everything is sold on/
  end

  # The largest assumption on the page used to arrive in the query string and
  # default to something, which meant nearly every report was computed from a
  # figure nobody had chosen while looking exactly like one they had. It is now
  # a stored fact, nil until stated, and the report has to say which of the two
  # it is showing -- in the assumptions, where a reader is looking for it.
  test "an undeclared marginal rate is disclosed as a placeholder" do
    assert_nil Tax::Household.marginal_rate_for(@family),
               "the fixture household has declared a rate; this test cannot see the undeclared case"

    get tax_report_path

    assert_select "body", text: /That is a placeholder, not your rate/

    # And it says where to fix it. Named by its own wording rather than by the
    # href alone, because the report links to the Taxes page from more than one
    # place and only this one is the offer to replace the placeholder.
    assert_select "a[href=?]", settings_taxes_path,
                  text: I18n.t("tax_reports.show.assumption_marginal_rate_link")
  end

  test "a declared rate is named as the household's own and is the rate on the page" do
    declare_marginal_rate "0.41"

    get tax_report_path

    assert_select "body", text: /marginal rate of 41.0%, which you have set/
    assert_select "body", text: /That is a placeholder/, count: 0
  end

  # The disclosure has to follow the fact, not a page load: a household that
  # sets its rate and comes back must not still be told it is on a placeholder.
  test "declaring a rate changes what the report computes, not just what it says" do
    taxable_account

    # A rule taxing the payments in at the household's own rate, so that the
    # declared figure reaches the arithmetic rather than only the prose. The
    # shipped securities rule runs on published rates alone and would print the
    # same total at any marginal rate at all.
    Tax::CustomRule.where(family: @family).destroy_all
    Tax::CustomRule.create!(
      family: @family, account: taxable_account, kind: "composed",
      params: { "name" => "PER", "terms" => [ { "base" => "full_value", "rate" => "household_rate" } ] }
    )

    placeholder = tax_totals

    declare_marginal_rate "0.41"

    assert_not_equal placeholder, tax_totals,
                     "the report ignored the rate the household declared"
  end

  # The rate multiplies the largest bases the module computes, and it is stored
  # per family, so a leak would put one household's income tax on another's
  # portfolio.
  test "one household's declared rate does not reach another's report" do
    declare_marginal_rate "0.41"

    other = families(:empty)
    other.update!(country: "FR", currency: "EUR")

    assert_nil Tax::Household.marginal_rate_for(other)
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

  # The projection knobs are still URL parameters, because they are a question
  # being asked rather than a fact being declared. A question typed into a
  # query string is a question that can be typed wrong.
  test "a nonsense projection parameter falls back rather than erroring" do
    get tax_report_path(expected_return: "abc", inflation: "xyz", horizon: "999")

    assert_response :ok
  end

  # The rate is not one of them any more, and the old parameters must not come
  # back to life quietly: a report that still honoured `flat_rate=0.05` would
  # give two households looking at the same portfolio two different answers,
  # with nothing on either page to say why.
  test "the retired rate parameters no longer change anything" do
    declare_marginal_rate "0.41"

    get tax_report_path
    declared = css_select("main").to_s

    get tax_report_path(tmi_mode: "flat", flat_rate: "0.05", other_income: "90000", parts: "3")

    assert_response :ok
    assert_equal declared, css_select("main").to_s,
                 "a query string overrode the rate the household declared"
  end

  # The audit list is the one place the report contradicts Sure out loud, so
  # filing a note under the wrong account is worse than not raising it at all:
  # it sends the reader to check an account that is fine.
  #
  # `apply_all` sorts its input before taxing it, while the subject builder
  # orders by name alone, so the two lists diverge as soon as accountable types
  # interleave alphabetically. The report used to zip them positionally, which
  # compared one account's classification against another account's tax. It
  # went unnoticed because the list is empty for most portfolios -- the pairing
  # is only wrong where it has something to say.
  test "an audit note is filed under the account it is about" do
    declare_marginal_rate "0.30"

    # First by name and last by accountable type, so its subject and its result
    # sit at opposite ends of the two orderings. Sure calls a Roth IRA tax
    # exempt; the pinned rule taxes it anyway, which is precisely the
    # disagreement this list exists to report.
    exempt = @family.accounts.create!(
      name: "AAA Exempt", balance: 1000, currency: "EUR",
      accountable: Investment.new(subtype: "roth_ira")
    )
    Tax::CustomRule.create!(
      family: @family, account: exempt, kind: "composed",
      params: {
        "name" => "Taxed anyway",
        "terms" => [ { "base" => "full_value", "rate" => "household_rate" } ]
      }
    )

    get tax_report_path

    assert_response :ok
    assert_select "li", text: /\AAAA Exempt: Sure classifies this account as tax exempt/,
                  count: 1
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

  test "a corrected rate is the rate the report computes with" do
    # A correction that shows on the settings page and changes no figure would
    # be worse than offering no corrections at all, because it looks like it
    # worked. Asserted on the figures the page prints rather than on the
    # markup around them: the report is drawn twice, once shipped and once
    # corrected, and the two have to differ.
    #
    # The fixture household is taxed nothing at all -- no rule is assigned and
    # no account has declared what was paid into it -- so a correction could
    # not move a figure whatever the controller did. One taxable account is the
    # precondition for the assertion, not decoration on it.
    taxable_account

    before = tax_totals
    assert_not_equal "€0.00", before.second, "nothing is taxed, so nothing can be corrected"

    # Dated to the entry currently in force, not to the start of the schedule.
    # Correcting 2018 would change nothing today, and the test would fail
    # against a controller that is working perfectly.
    Tax::RateCorrection.create!(
      family: @family,
      country: "FR",
      overrides: { "social_charges" => [ { "effective_from" => "2026-01-01", "rate" => 0.99 } ] }
    )

    assert_not_equal before, tax_totals,
                     "the report ignored the family's rate correction"
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

    # Stored as a fraction, the way the column holds it. The percent-to-
    # fraction conversion is the form's job and is tested where it lives, in
    # test/controllers/settings/tax_households_controller_test.rb; going
    # through the form here would make every one of these tests fail when that
    # conversion breaks, and none of them say anything about it.
    def declare_marginal_rate(fraction)
      Tax::Household.create!(family: @family, marginal_rate: BigDecimal(fraction))
    end

    # An account the report can actually put a figure against: a rule that
    # taxes the gain, and a declared amount paid in for the gain to be measured
    # over. Without both, every result is a refusal and every total is zero.
    def taxable_account
      @taxable_account ||= @family.accounts.visible
                                  .where(accountable_type: "Investment")
                                  .first
                                  .tap do |account|
        Tax::CustomRule.create!(
          family: @family, account: account, kind: "fr_securities"
        )
        Tax::Profile.create!(
          account: account, opened_on: Date.new(2015, 1, 1), paid_in: 1000
        )
      end
    end

    # The four headline figures, read off the page rather than out of an
    # instance variable, so the assertion is about what the household is shown
    # and not about how the controller happens to be wired.
    def tax_totals
      get tax_report_path
      assert_response :ok

      figures = css_select("p.text-xl").map { |node| node.text.strip }
      assert figures.any?, "the report rendered no headline figures at all"
      figures
    end
end
