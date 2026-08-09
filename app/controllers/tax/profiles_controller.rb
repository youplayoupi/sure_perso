# frozen_string_literal: true

module Tax
  # Declaring the facts Sure has nowhere to store, one account at a time.
  #
  # The only writing this module does, and it writes to its own table only.
  class ProfilesController < ApplicationController
    before_action :set_account

    def edit
      @profile = profile_for(@account)
    end

    def update
      @profile = profile_for(@account)

      if @profile.update(profile_params.merge(reviewed_at: Time.current))
        redirect_to tax_report_path, notice: t(".saved", account: @account.name)
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private
      # Scoped through the family, so a profile can only ever be attached to an
      # account the current user can already see.
      def set_account
        @account = Current.family.accounts.find(params[:account_id])
      end

      def profile_for(account)
        Profile.find_or_initialize_by(account_id: account.id)
      end

      def profile_params
        params.require(:tax_profile)
              .permit(:product, :opened_on, :paid_in, :paid_in_deducted, :notes)
      end
  end
end
