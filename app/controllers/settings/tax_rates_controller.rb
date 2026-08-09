# frozen_string_literal: true

# Settings > Taxes > Rates: the numbers the rules multiply by.
#
# The module has always said rates are data, and that a self-hoster who needs
# to correct one edits config/tax/fr.yml and restarts. That is true for
# whoever deployed the container and false for everyone else in the household,
# and it stops being true for them too at the next upgrade, when the image
# ships its own copy of the file over theirs. Tax::RateCorrection has stored
# the same edit per family since the rates landed; this is the screen that
# writes it, and until it existed the storage was reachable only from a
# console.
#
# The whole shipped file is rendered, not just the parts already corrected,
# because a form that showed only overrides would ask someone to correct a
# figure they cannot see. What is *stored* is only the difference --
# Tax::RateEdit does that, and the long comment there explains why it has to:
# a family who saved the whole table once would be pinned to it forever, and
# would never receive next year's brackets.
#
# Percentages in, fractions out. The file stores 0.186 because that is what
# the engine multiplies by; the boxes say 18.6 because that is what a rate is
# called everywhere else, and the rule builder next door already made the same
# trade.
class Settings::TaxRatesController < ApplicationController
  layout "settings"

  before_action :require_supported_country
  before_action :set_country

  def show
    @correction = Tax::RateCorrection.for(Current.family, @country)
    @shipped = Tax::RateTable.new(shipped_data)
    @mine = table_for(@correction)
  end

  def update
    @correction = Tax::RateCorrection.for(Current.family, @country)
    @correction.overrides = Tax::RateEdit.diff(shipped_data, submitted)

    # Nothing left over the file is not "no corrections stored", it is "this
    # family has no corrections", and the row should go. Leaving an empty
    # document behind would make `edited?` answer on the presence of a record
    # rather than on its contents, and the report flags a corrected figure off
    # exactly that.
    if @correction.overrides.empty?
      @correction.destroy if @correction.persisted?

      return redirect_to settings_taxes_rates_path, notice: t(".unchanged")
    end

    if @correction.save
      redirect_to settings_taxes_rates_path, notice: t(".saved")
    else
      # Re-rendered from what was submitted, not from what is stored, so the
      # figures someone is being told are wrong are the figures still in front
      # of them.
      @shipped = Tax::RateTable.new(shipped_data)
      @mine = preview(@correction)

      render :show, status: :unprocessable_entity
    end
  end

  # Back to the shipped file, in one action.
  #
  # Worth its own button rather than leaving people to clear a dozen boxes by
  # hand: "what does this module ship?" is a question someone asks precisely
  # when they have lost track of what they changed, and the answer should not
  # require them to already know.
  def destroy
    Tax::RateCorrection.for(Current.family, @country).then { |c| c.destroy if c.persisted? }

    redirect_to settings_taxes_rates_path, notice: t(".reset")
  end

  private
    # The table as this family sees it. Falls back to the shipped one when the
    # stored document is unreadable -- which the form cannot produce, but a row
    # written by an older version of this module could -- because a page that
    # 500s is a page nobody can use to fix the row that broke it.
    def table_for(correction)
      return @shipped unless correction.persisted?

      Tax::RateTable.new(Tax::RateOverlay.apply(shipped_data, correction.overrides))
    rescue Tax::Error, ArgumentError, TypeError
      @shipped
    end

    def preview(correction)
      Tax::RateTable.new(Tax::RateOverlay.apply(shipped_data, correction.overrides))
    rescue Tax::Error, ArgumentError, TypeError
      @shipped
    end

    def shipped_data
      @shipped_data ||= Tax.rate_data(@country)
    end

    # The form's shape, turned back into rate-file shape.
    #
    # Nothing here validates. Tax::RateOverlay does, Tax::RateCorrection
    # surfaces it as a form error, and Tax::RateEdit only ever compares. A
    # controller that also had an opinion about what a valid rate is would be
    # the third one, and the third opinion is the one that ends up wrong.
    def submitted
      {
        "social_charges" => dated_rows(:social_charges),
        "flat_tax_income_component" => dated_rows(:flat_tax_income_component),
        "income_tax_brackets" => bracket_rows,
        "products" => product_rows
      }
    end

    # Rows arrive keyed by index -- tax_rates[social_charges][2][rate] --
    # rather than as a bare array, for the reason the rule builder gives: the
    # page adds rows, and an array would re-pair a date with the wrong rate the
    # moment a row in the middle went away. Insertion order is the form's
    # order; the overlay sorts by date when it merges, so nothing here has to.
    def rows_for(section)
      rows = params.dig(:tax_rates, section)
      return [] if rows.blank?

      rows.values
    end

    def dated_rows(section)
      rows_for(section).filter_map do |row|
        next if row[:effective_from].blank? && row[:rate].blank?

        { "effective_from" => row[:effective_from].to_s.strip,
          "rate" => fraction(row[:rate]) }
      end
    end

    # A schedule is a date and a list of bands, so this is the one place the
    # form nests twice. The whole schedule is posted back for every date, not
    # just the band that moved, because Tax::RateOverlay replaces a dated entry
    # rather than merging into it -- posting a partial schedule would delete
    # the bands left out of it.
    def bracket_rows
      rows_for(:income_tax_brackets).filter_map do |row|
        next if row[:effective_from].blank?

        bands = Array(row[:brackets]&.values).filter_map do |band|
          next if band[:upto].blank? && band[:rate].blank?

          { "upto" => amount(band[:upto]), "rate" => fraction(band[:rate]) }
        end

        next if bands.empty?

        { "effective_from" => row[:effective_from].to_s.strip, "brackets" => bands }
      end
    end

    # Keyed by product name rather than by index, because unlike the dated
    # rows these are a fixed set: the form cannot add a product, only correct
    # the two figures the overlay reads on one. A name the file does not carry
    # is dropped here rather than stored, since the rules look products up by
    # name and one that matches nothing would be a correction that silently
    # applies to nothing.
    def product_rows
      submitted_products = params.dig(:tax_rates, :products)
      return {} if submitted_products.blank?

      shipped_names = (shipped_data["products"] || {}).keys.to_set

      submitted_products.to_unsafe_h.each_with_object({}) do |(name, attrs), out|
        next unless shipped_names.include?(name.to_s)

        out[name.to_s] = {
          "maturity_years" => attrs["maturity_years"].presence,
          "ceiling" => amount(attrs["ceiling"])
        }
      end
    end

    # 18.6 in the box becomes 0.186 in the file.
    #
    # Unreadable input is passed through unchanged rather than dropped, so the
    # overlay can name it in an error the author can act on. Swallowing it here
    # would save a rate of nothing at all, which for a rate -- unlike for a
    # rule -- computes confidently and wrongly instead of refusing.
    def fraction(value)
      return nil if value.blank?

      (BigDecimal(value.to_s.tr(",", ".")) / 100).to_s("F")
    rescue ArgumentError, TypeError
      value.to_s
    end

    # Thresholds and ceilings are amounts, not rates, so they are not divided
    # by anything. Kept as text when unreadable, for the same reason.
    def amount(value)
      return nil if value.blank?

      BigDecimal(value.to_s.tr(",", ".").delete(" ")).to_s("F")
    rescue ArgumentError, TypeError
      value.to_s
    end

    def set_country
      @country = (Current.family&.country.presence || Tax::DEFAULT_COUNTRY).to_s.upcase
    end

    def require_supported_country
      return if Tax.supported?(Current.family&.country)

      redirect_to settings_profile_path
    end
end
