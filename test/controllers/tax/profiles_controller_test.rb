# frozen_string_literal: true

require "test_helper"

module Tax
  # The only writing this module does. The tests that matter here are the ones
  # about what it refuses to write: another family's account, a column nobody
  # offered, a value the model rejects.
  class ProfilesControllerTest < ActionDispatch::IntegrationTest
    setup do
      ensure_tailwind_build
      sign_in @user = users(:family_admin)
      @family = @user.family
      @family.update!(country: "FR")
      @account = @family.accounts.order(:name).first
    end

    test "the form renders for an account with nothing declared yet" do
      get edit_tax_account_profile_path(account_id: @account.id)

      assert_response :ok
      assert_select "form"
    end

    # What the form asks for, and what it merely keeps.
    #
    # The rule attached to an account decides this -- see
    # ProfilesController#set_relevant_facts -- so these are tests about a
    # promise rather than about four particular fields: a field the rule reads
    # is asked for, a field it does not is not offered as an input, and a
    # figure already stored under a rule that no longer reads it is shown with
    # a way to remove it. Neither the rules nor Tax::Profile::DECLARABLE are
    # named here, only the effect.
    #
    # `[name=]` rather than `[id=]` because the name is the wire format the
    # patch tests below already depend on, and the id is the form builder's
    # business.
    def field(fact) = "input[name='tax_profile[#{fact}]']"

    def clear_box(fact) = "input[name='clear_facts[]'][value='#{fact}']"

    # The subtype goes on the accountable, not on the account.
    #
    # `Account#subtype=` writes through to the accountable, but only once there
    # is one: given `subtype:` before `accountable:` it stashes the value and
    # waits for `accountable_type=` to be called, which assigning the record
    # itself does not do. The value is then silently dropped, every account
    # here resolves to Rules::Unknown, and these tests pass for the wrong
    # reason -- an untyped account genuinely is asked for nothing.
    def account_with(subtype:, accountable_class:)
      @family.accounts.create!(
        name: "Fixture #{subtype}", balance: 10_000, currency: "EUR",
        accountable: accountable_class.new(subtype: subtype)
      )
    end

    test "a wrapper whose rule reads a figure is asked for it up front" do
      account = account_with(subtype: "pea", accountable_class: Investment)

      get edit_tax_account_profile_path(account_id: account.id)

      assert_response :ok
      # Once. The count is half the assertion: the form is assembled from a
      # list, and a fact that appeared in it twice would post two values under
      # one name.
      #
      # Fr::Pea refuses without this figure, so it is the one question on the
      # page standing between the account and a number.
      assert_select field(:paid_in), 1
    end

    test "a fact this rule does not read is not asked for" do
      account = account_with(subtype: "savings", accountable_class: Depository)

      get edit_tax_account_profile_path(account_id: account.id)

      assert_response :ok
      # Fr::Deposit taxes interest as it arises and asks for no figure, but it
      # does need to know which livret this is -- three products with different
      # answers sit behind Sure's one "savings" subtype.
      assert_select "select[name='tax_profile[product]']", 1

      # Not demoted into a disclosure, which is what this used to assert. Three
      # empty boxes behind a summary, collecting figures no rule would read,
      # were worse than no boxes: they implied the module wanted four numbers
      # from a Livret A when it wanted one.
      assert_select field(:paid_in), 0
      # Scoped to the form: the surrounding chrome uses `details` for its own
      # menus, and an unscoped count would be asserting something about the
      # layout rather than about this page.
      assert_select "form details", 0
    end

    test "a fact this rule does not read but which already holds a value is still shown" do
      account = account_with(subtype: "savings", accountable_class: Depository)
      Profile.create!(account: account, paid_in: 4_200)

      get edit_tax_account_profile_path(account_id: account.id)

      assert_response :ok
      # Shown as a value with a way to remove it, not as an input. The rule on
      # an account can be changed from the Taxes screen, and a figure typed
      # under the old one must not end up sitting in the database affecting
      # nothing and visible nowhere.
      assert_select field(:paid_in), 0
      assert_select clear_box(:paid_in), 1
      assert_select "body", text: /4200/
    end

    test "a figure with no rule left to read it can be cleared from the form" do
      account = account_with(subtype: "savings", accountable_class: Depository)
      profile = Profile.create!(account: account, paid_in: 4_200)

      patch tax_account_profile_path(account_id: account.id),
            params: { tax_profile: { notes: "" }, clear_facts: [ "paid_in" ] }

      assert_redirected_to tax_report_path
      assert_nil profile.reload.paid_in
    end

    test "a fact the form did offer is not clearable through the same channel" do
      account = account_with(subtype: "pea", accountable_class: Investment)
      profile = Profile.create!(account: account, paid_in: 4_200)

      # `clear_facts` is a list of attribute names arriving from a form as
      # strings, so it is checked against DECLARABLE rather than trusted. This
      # is the test for that: a name outside the list writes nothing, and the
      # figure the form did ask for is untouched by a request that named
      # something else.
      patch tax_account_profile_path(account_id: account.id),
            params: { tax_profile: { notes: "" }, clear_facts: [ "reviewed_at", "id" ] }

      assert_redirected_to tax_report_path
      assert_equal 4_200, profile.reload.paid_in
    end

    test "an opening date Sure already knows is offered with what Sure has" do
      account = account_with(subtype: "pea", accountable_class: Investment)
      Account::OpeningBalanceManager.new(account)
                                    .set_opening_balance(balance: 0, date: Date.new(2010, 1, 1))

      get edit_tax_account_profile_path(account_id: account.id)

      assert_response :ok
      # Offered rather than removed: an anchor is a balance's starting point
      # and can legitimately sit later than the first payment in, which is what
      # the five-year clock actually runs from. What the page must not do is
      # ask for a date it is already using without saying it is already using
      # one.
      assert_select field(:opened_on), 1

      # And the date is said out loud rather than pre-filled into the box.
      # Pre-filling would make Sure's answer look like one the reader had
      # given, and the two are treated differently by SubjectBuilder.
      assert_select field(:opened_on) + "[value]", 0
      assert_select "body", text: /#{Regexp.escape(I18n.t("tax.profiles.fields.opened_on.from_sure", date: I18n.l(Date.new(2010, 1, 1), format: :long)))}/
    end

    test "an anchor that is only a lower bound is offered as a bound, not as the date" do
      account = account_with(subtype: "pea", accountable_class: Investment)
      Account::OpeningBalanceManager.new(account)
                                    .set_opening_balance(balance: 1_000, date: Date.new(2010, 1, 1))

      get edit_tax_account_profile_path(account_id: account.id)

      assert_response :ok
      assert_select field(:opened_on), 1

      # Money was already in the account on that date, so the account existed
      # before it and the date is a floor rather than an answer. Saying "that
      # is the date used" here would be false -- SubjectBuilder does not use it
      # as one.
      assert_select "body", text: /#{Regexp.escape(I18n.t("tax.profiles.fields.opened_on.known_since", date: I18n.l(Date.new(2010, 1, 1), format: :long)))}/
      assert_select "body", { text: /#{Regexp.escape(I18n.t("tax.profiles.fields.opened_on.from_sure", date: I18n.l(Date.new(2010, 1, 1), format: :long)))}/, count: 0 }
    end

    test "declaring facts creates the profile and returns to the report" do
      assert_difference -> { Profile.count }, 1 do
        patch tax_account_profile_path(account_id: @account.id),
              params: { tax_profile: { paid_in: "1234.56", opened_on: "2015-01-01" } }
      end

      assert_redirected_to tax_report_path
      profile = Profile.find_by(account_id: @account.id)
      assert_equal BigDecimal("1234.56"), profile.paid_in
      assert_equal Date.new(2015, 1, 1), profile.opened_on
    end

    test "saving stamps reviewed_at, so the report can tell declared from defaulted" do
      patch tax_account_profile_path(account_id: @account.id),
            params: { tax_profile: { paid_in: "100" } }

      assert Profile.find_by(account_id: @account.id).reviewed?
    end

    test "an invalid declaration re-renders instead of silently dropping it" do
      assert_no_difference -> { Profile.count } do
        patch tax_account_profile_path(account_id: @account.id),
              params: { tax_profile: { product: "livretA" } }
      end

      assert_response :unprocessable_entity
      assert_select "body", text: /not a product this module knows about/
    end

    test "another family's account cannot be declared against" do
      # The scoping is a one-liner in the controller, which is exactly the kind
      # of line that gets refactored away by someone who does not know why it
      # was there. The :empty fixture family owns no accounts, so one is built
      # here rather than skipping -- a skipped test is an untested claim.
      other_account = families(:empty).accounts.create!(
        name: "Someone else's brokerage",
        balance: 1000,
        currency: "EUR",
        subtype: "brokerage",
        accountable: Investment.new
      )

      # 404 rather than a raise: Rails turns RecordNotFound into a response
      # before it reaches the test, and the status is what a client would
      # actually see. Note it is not a 403 -- confirming the account exists
      # would itself leak something.
      get edit_tax_account_profile_path(account_id: other_account.id)

      assert_response :not_found
    end

    test "and neither can it be written to" do
      other_account = families(:empty).accounts.create!(
        name: "Someone else's brokerage",
        balance: 1000,
        currency: "EUR",
        subtype: "brokerage",
        accountable: Investment.new
      )

      assert_no_difference -> { Profile.count } do
        patch tax_account_profile_path(account_id: other_account.id),
              params: { tax_profile: { paid_in: "1" } }
      end

      assert_response :not_found
    end

    test "a column the form does not offer cannot be set through it" do
      # reviewed_at is set by the controller, never by the request. If mass
      # assignment ever opens up, a client could backdate its own review.
      patch tax_account_profile_path(account_id: @account.id),
            params: { tax_profile: { paid_in: "100", reviewed_at: "2001-01-01" } }

      assert_response :redirect
      assert_operator Profile.find_by(account_id: @account.id).reviewed_at, :>,
                      1.hour.ago
    end

    test "declaring changes nothing about the account itself" do
      assert_no_changes -> { [ Account.count, Holding.count, Entry.count, Balance.count ] } do
        patch tax_account_profile_path(account_id: @account.id),
              params: { tax_profile: { paid_in: "100" } }
      end
    end

    test "signed out, the form is not reachable" do
      @user.sessions.each { |session| delete session_path(session) }

      get edit_tax_account_profile_path(account_id: @account.id)

      assert_redirected_to new_session_path
    end
  end
end
