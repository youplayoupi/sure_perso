# frozen_string_literal: true

# Settings > Taxes: the household's own marginal rate of income tax.
#
# One field, no screen of its own. It posts from the card at the top of the
# Taxes page and comes straight back there, because the rate is not a thing
# anyone sets on purpose -- it is a thing they set once, on the way to doing
# something else, and a page they have to find first is a page they will not.
#
# Percentages in, fractions out, the same trade the rates screen and the rule
# builder already make: the column holds 0.3 because that is what the engine
# multiplies by, the box says 30 because that is what a tax rate is called
# everywhere outside this codebase.
class Settings::TaxHouseholdsController < ApplicationController
  layout "settings"

  before_action :require_supported_country

  def update
    household = Tax::Household.for(Current.family)
    submitted = params.dig(:tax_household, :marginal_rate)

    # Blank clears it, and clearing it is a real choice rather than a failed
    # edit: it puts the household back to undeclared, which is the state the
    # report describes out loud instead of quietly filling in. A row with a
    # null rate and no row at all mean the same thing, so an emptied row is
    # deleted rather than kept as a tombstone.
    if submitted.blank?
      household.destroy if household.persisted?

      return redirect_to settings_taxes_path, notice: t(".cleared")
    end

    fraction = fraction(submitted)

    if fraction.nil?
      return redirect_to settings_taxes_path, alert: t(".unreadable", value: submitted)
    end

    household.marginal_rate = fraction

    if household.save
      redirect_to settings_taxes_path, notice: t(".saved")
    else
      redirect_to settings_taxes_path, alert: household.errors.full_messages.to_sentence
    end
  end

  private
    # 30 in the box becomes 0.3 in the column.
    #
    # Returns nil for something that is not a number, and the action turns that
    # into a message naming what was typed. The rates screen passes unreadable
    # input through to be rejected further down instead; the difference is that
    # there the overlay has a validation waiting for it and here the column
    # would simply cast "abc" to zero -- a household on a zero marginal rate,
    # asserted rather than assumed, and no warning anywhere.
    def fraction(value)
      (BigDecimal(value.to_s.tr(",", ".").delete("%").strip) / 100)
    rescue ArgumentError, TypeError
      nil
    end

    # Same test the page it posts to uses.
    def require_supported_country
      return if Tax.supported?(Current.family&.country)

      redirect_to settings_profile_path
    end
end
