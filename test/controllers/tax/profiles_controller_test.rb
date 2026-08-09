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
