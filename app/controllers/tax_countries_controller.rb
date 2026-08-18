# frozen_string_literal: true

# The "Tax countries" reference: how the after-tax module treats accounts in
# each country it supports.
#
# Read-only and computed entirely from the engine (Tax::CountryGuide reads the
# registry and rate table), so the page cannot fall out of step with what the
# report actually does. Deliberately available to every family, including those
# whose own country is not yet supported: the general mechanism and the list of
# what *is* covered is exactly what an unsupported household needs to see.
class TaxCountriesController < ApplicationController
  def index
    @countries = Tax.supported_countries
    @family_country = Current.family&.country.to_s.upcase
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("tax_countries.index.title"), nil ] ]
  end

  def show
    @country = params[:id].to_s.upcase

    unless Tax.supported?(@country)
      redirect_to tax_countries_path, alert: t("tax_countries.show.unsupported", country: @country)
      return
    end

    @guide = Tax::CountryGuide.new(@country, rate_table: Tax.rate_table(@country))
    @on = Date.current
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("tax_countries.index.title"), tax_countries_path ],
      [ helpers.tax_country_name(@country), nil ]
    ]
  end
end
