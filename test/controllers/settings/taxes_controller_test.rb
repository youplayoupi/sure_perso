# frozen_string_literal: true

require "test_helper"

# Settings > Taxes is the only writable surface this module adds, so the tests
# lean on the two things a write can get wrong: saving something Sure does not
# define, and saving something that belongs to another family.
class Settings::TaxesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @family = @user.family

    # The fixtures are a US family. This module has rules for France only, and
    # the page is deliberately unreachable elsewhere, so a French household is
    # the precondition for every test below rather than a detail of one.
    @family.update!(country: "FR", currency: "EUR")
  end

  # ---- Reading -------------------------------------------------------------

  test "the page renders a rule selector for every product Sure knows about" do
    get settings_taxes_path

    assert_response :ok

    # Held and unheld together, because the unheld half is behind a disclosure
    # rather than dropped -- which is what keeps the promise that a subtype
    # added by a future Sure release turns up here.
    coverage = Tax::Coverage.new(Tax::Registry.new(country: "FR"))
    assert_select "select", minimum: coverage.entries.size
  end

  test "products the family holds lead the page, the world catalogue does not" do
    # Sure's SUBTYPES is a world catalogue -- eighty-odd wrappers across a
    # dozen countries. Rendering all of them at the top would bury the five
    # that matter under Riester-Rente and Kisan Vikas Patra.
    get settings_taxes_path

    assert_response :ok

    held = held_entries
    assert held.any?, "the fixture family holds nothing the report can tax"
    assert_operator unheld_entries.size, :>, held.size

    body = response.body
    first_unheld = body.index(I18n.t("settings.taxes.show.other_title"))

    held.each do |entry|
      at = body.index(escaped(entry.label))
      assert at, "#{entry.label} is held but does not appear on the page"
      assert_operator at, :<, first_unheld, "#{entry.label} is held but sits below the disclosure"
    end
  end

  test "the coverage sentence counts what the family holds, not Sure's catalogue" do
    get settings_taxes_path

    assert_select "body", text: /#{Regexp.escape(
      I18n.t("settings.taxes.show.coverage_summary",
             covered: held_entries.count(&:covered?), total: held_entries.size)
    )}/
  end

  test "a product with a rule set by hand stays visible after the account goes" do
    # Otherwise a stored row becomes unreachable on the only page that can
    # remove it -- a setting you cannot unset.
    patch settings_taxes_path, params: {
      tax_rule: { accountable_type: "Investment", subtype: "pea", kind: "fr_pea" }
    }

    get settings_taxes_path

    # Escaped, because the label Sure gives the PEA has an apostrophe in it and
    # the page is HTML. Searching for the raw string finds nothing and the test
    # passes for the wrong reason.
    body = response.body
    at = body.index(escaped("Plan d'Épargne en Actions"))
    assert at, "a hand-set rule for the PEA left it off the page entirely"
    assert_operator at, :<, body.index(I18n.t("settings.taxes.show.other_title"))
  end

  test "products the report will never look at are not offered a rule" do
    # A tax rule on a credit card is a rule that can never fire. Asserting it
    # here as well as on Coverage itself, because the page is where someone
    # would notice, and the two could drift apart.
    get settings_taxes_path

    assert_response :ok

    Tax::SubjectBuilder::EXCLUDED_TYPES.each do |type|
      assert_select "h3", text: type, count: 0
    end
  end

  test "a country with no rules gets no page rather than a page of French rules" do
    @family.update!(country: "US")

    get settings_taxes_path

    assert_redirected_to settings_profile_path
  end

  test "signed out, the page is not reachable" do
    @user.sessions.each { |session| delete session_path(session) }

    get settings_taxes_path

    assert_redirected_to new_session_path
  end

  # ---- Finding the module's other two pages -------------------------------
  #
  # Rules and Rates hang off Taxes in the settings sidebar. Asserted here, in
  # the module's own file, because the sub-item machinery in
  # `settings/_settings_nav` exists for this module and should be deleted with
  # it. The selector `nav li ul li a` is the desktop rail's nested list and
  # nothing else: the mobile strip puts its sub-items in the top-level `ul`,
  # and the body links on this page are not inside a `nav`.

  test "the sidebar carries Rules and Rates under Taxes while you are in that section" do
    get settings_taxes_path

    assert_response :ok
    assert_select "nav li ul li a[href=?]", settings_taxes_rules_path, count: 1
    assert_select "nav li ul li a[href=?]", settings_taxes_rates_path, count: 1

    # And on a narrow screen too, where the rail is a horizontal strip and the
    # sub-items are ordinary chips beside their parent. Two renderings of the
    # same list, so this is the one place worth asserting both: a change that
    # reaches only the desktop loop leaves phones with no way to the pages.
    assert_select "#mobile-settings-nav a[href=?]", settings_taxes_rules_path, count: 1
    assert_select "#mobile-settings-nav a[href=?]", settings_taxes_rates_path, count: 1
  end

  test "landing on Rules or Rates from a bookmark still shows the way back up" do
    # The whole point of putting them in the rail. Someone who was told to
    # "correct the rate" and saved the link arrives with no parent page in
    # their history; if the rail collapsed to a bare Taxes entry they would
    # have to guess that the other page exists.
    [ settings_taxes_rules_path, settings_taxes_rates_path ].each do |path|
      get path

      assert_response :ok
      assert_select "nav a[href=?]", settings_taxes_path, minimum: 1
      assert_select "nav li ul li a[href=?]", settings_taxes_rules_path, count: 1
      assert_select "nav li ul li a[href=?]", settings_taxes_rates_path, count: 1
    end
  end

  test "elsewhere in settings the rail is unchanged" do
    # Sub-items open with their section. A second level standing open for every
    # reader would lengthen the rail permanently for one entry, and this is
    # shared markup: the cost would fall on people who have no tax module.
    get settings_preferences_path

    assert_response :ok
    assert_select "a[href=?]", settings_taxes_path, minimum: 1
    assert_select "a[href=?]", settings_taxes_rules_path, count: 0
    assert_select "a[href=?]", settings_taxes_rates_path, count: 0
  end

  test "a household outside the module's countries gets no tax entry at all" do
    # Including the sub-items, which are reached through the parent's `if:` and
    # so cannot outlive it.
    @family.update!(country: "US", currency: "USD")

    get settings_preferences_path

    assert_response :ok
    assert_select "a[href=?]", settings_taxes_path, count: 0
    assert_select "a[href=?]", settings_taxes_rules_path, count: 0
    assert_select "a[href=?]", settings_taxes_rates_path, count: 0
  end

  # ---- Writing a per-product rule -----------------------------------------

  test "choosing a rule stores one row for that product" do
    assert_difference -> { Tax::CustomRule.count }, 1 do
      patch settings_taxes_path, params: {
        tax_rule: { accountable_type: "Investment", subtype: "brokerage", kind: "exempt" }
      }
    end

    rule = Tax::CustomRule.sole

    assert_equal @family.id, rule.family_id
    assert_equal "exempt", rule.kind
    assert_nil rule.account_id
    assert_redirected_to settings_taxes_path
  end

  test "choosing a different rule for the same product updates rather than accumulates" do
    patch settings_taxes_path, params: {
      tax_rule: { accountable_type: "Investment", subtype: "brokerage", kind: "exempt" }
    }

    assert_no_difference -> { Tax::CustomRule.count } do
      patch settings_taxes_path, params: {
        tax_rule: { accountable_type: "Investment", subtype: "brokerage", kind: "fr_securities" }
      }
    end

    assert_equal "fr_securities", Tax::CustomRule.sole.kind
  end

  test "clearing a rule deletes the row rather than storing an empty one" do
    patch settings_taxes_path, params: {
      tax_rule: { accountable_type: "Investment", subtype: "brokerage", kind: "exempt" }
    }

    assert_difference -> { Tax::CustomRule.count }, -1 do
      patch settings_taxes_path, params: {
        tax_rule: { accountable_type: "Investment", subtype: "brokerage", kind: "" }
      }
    end
  end

  test "a product Sure does not define is refused" do
    # The page only ever offers real pairs, so this can only arrive by hand --
    # which is exactly why it is checked server-side rather than trusted.
    assert_no_difference -> { Tax::CustomRule.count } do
      patch settings_taxes_path, params: {
        tax_rule: { accountable_type: "Investment", subtype: "not_a_subtype", kind: "exempt" }
      }
    end

    assert_redirected_to settings_taxes_path
    assert_equal I18n.t("settings.taxes.update.unknown_product"), flash[:alert]
  end

  test "a rule this module does not offer is refused" do
    # `kind` is looked up in a frozen catalogue and never constantized, so the
    # worst a forged value can do is fail this validation.
    assert_no_difference -> { Tax::CustomRule.count } do
      patch settings_taxes_path, params: {
        tax_rule: { accountable_type: "Investment", subtype: "brokerage", kind: "Kernel" }
      }
    end

    assert_redirected_to settings_taxes_path
    assert flash[:alert].present?
  end

  test "a rule chosen here is what the report then applies" do
    # The point of the screen, asserted end to end rather than at the seam:
    # the row it writes has to be the row the registry reads.
    patch settings_taxes_path, params: {
      tax_rule: { accountable_type: "Investment", subtype: "brokerage", kind: "exempt" }
    }

    registry = Tax::SubjectBuilder.new(@family.reload).registry

    assert_equal "exempt", registry.rule_for("Investment", "brokerage").rule_id
  end

  # ---- Pinning a rule to one account --------------------------------------

  test "pinning a rule to an account stores it against that account" do
    account = in_scope_account

    assert_difference -> { Tax::CustomRule.pinned.count }, 1 do
      post pinned_rules_settings_taxes_path, params: {
        tax_rule: { account_id: account.id, kind: "fr_capital_and_gains" }
      }
    end

    rule = Tax::CustomRule.pinned.sole

    assert_equal account.id, rule.account_id
    assert_nil rule.accountable_type
    assert_equal I18n.t("settings.taxes.create.pinned"), flash[:notice]
  end

  test "a pinned rule beats the product rule for that one account" do
    # This is the PER bridge in one assertion. Sure has no `per` subtype, so
    # nothing keyed on a product can single the account out; pinning can.
    account = in_scope_account

    patch settings_taxes_path, params: {
      tax_rule: { accountable_type: account.accountable_type, subtype: account.subtype, kind: "exempt" }
    }
    post pinned_rules_settings_taxes_path, params: {
      tax_rule: { account_id: account.id, kind: "fr_capital_and_gains" }
    }

    registry = Tax::SubjectBuilder.new(@family.reload).registry
    subject  = Tax::SubjectBuilder.new(@family, accounts: [ account ]).subjects.sole

    assert_equal "fr_capital_and_gains", registry.resolve(subject).rule_id
  end

  test "another family's account cannot be pinned to" do
    other = families(:empty).accounts.create!(
      name: "Not mine", balance: 100, currency: "EUR",
      accountable: Investment.new, subtype: "brokerage"
    )

    assert_no_difference -> { Tax::CustomRule.count } do
      post pinned_rules_settings_taxes_path, params: {
        tax_rule: { account_id: other.id, kind: "exempt" }
      }
    end

    assert_equal I18n.t("settings.taxes.create.unknown_account"), flash[:alert]
  end

  test "unpinning removes the rule" do
    account = in_scope_account
    post pinned_rules_settings_taxes_path, params: {
      tax_rule: { account_id: account.id, kind: "exempt" }
    }
    rule = Tax::CustomRule.pinned.sole

    assert_difference -> { Tax::CustomRule.count }, -1 do
      delete pinned_rule_settings_taxes_path(id: rule.id)
    end
  end

  test "another family's rule cannot be unpinned" do
    other = families(:empty)
    theirs = Tax::CustomRule.create!(
      family: other, account: other.accounts.create!(
        name: "Theirs", balance: 100, currency: "EUR",
        accountable: Investment.new, subtype: "brokerage"
      ), kind: "exempt"
    )

    assert_no_difference -> { Tax::CustomRule.count } do
      delete pinned_rule_settings_taxes_path(id: theirs.id)
    end
  end

  # ---- The claim the whole module rests on --------------------------------

  test "configuring rules changes nothing about the accounts themselves" do
    account = in_scope_account

    assert_no_changes -> { [ Account.count, Holding.count, Entry.count, Balance.count ] } do
      assert_no_changes -> { account.reload.balance } do
        patch settings_taxes_path, params: {
          tax_rule: { accountable_type: "Investment", subtype: "brokerage", kind: "exempt" }
        }
        post pinned_rules_settings_taxes_path, params: {
          tax_rule: { account_id: account.id, kind: "exempt" }
        }
      end
    end
  end

  private
    # What the page ought to have split the catalogue into, worked out from the
    # family rather than from the response, so the assertions describe the
    # household and not the markup they are checking.
    def coverage
      @coverage ||= Tax::Coverage.new(Tax::Registry.new(country: "FR"))
    end

    # Deliberately not memoised: two of the tests write a rule and then reload
    # the page, and the whole point of one of them is that the split changes
    # when a rule is stored.
    def partition
      coverage.partition_by(held_keys)
    end

    # The accounts half goes through the helper rather than being restated.
    # Restating it once already got the subtype wrong -- `accounts.subtype` is
    # a stale column and the live value is on the accountable -- and a test
    # that reproduces the bug it is meant to catch is worse than no test.
    # TaxReportsHelper is covered on its own in the model suite.
    def held_keys
      Tax::CustomRule.where(family_id: @family.id)
                     .by_key
                     .map { |rule| [ rule.accountable_type, rule.subtype ] }
                     .to_set +
        ApplicationController.helpers.tax_products_held(@family)
    end

    def held_entries = partition.first

    def unheld_entries = partition.last

    def escaped(text) = ERB::Util.html_escape(text)

    def in_scope_account
      @in_scope_account ||= @family.accounts
                                   .visible
                                   .where.not(accountable_type: Tax::SubjectBuilder::EXCLUDED_TYPES)
                                   .order(:name)
                                   .first
    end
end
