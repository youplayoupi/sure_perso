# frozen_string_literal: true

# The one page this module adds.
#
# Read-only in the strict sense: `show` issues selects and nothing else. There
# is no create, no update, no destroy, and no background job. Declaring the
# facts the report needs happens on the account itself, through
# Tax::ProfilesController.
class TaxReportsController < ApplicationController
  def show
    @country = builder.country

    unless Tax.supported?(@country)
      @unsupported = true
      return
    end

    @assumptions = assumptions_from_params
    @currency    = builder.report_currency
    @registry    = builder.registry
    @subjects    = builder.subjects
    @snapshot    = Tax::Snapshot.new(
      on: valuation_date,
      results: @registry.apply_all(
        @subjects, on: valuation_date, rates: rates, assumptions: @assumptions
      )
    )

    @coverage = Tax::Coverage.new(@registry)

    # The card lists what this household holds; the rest of Sure's world
    # catalogue is counted rather than enumerated. See the coverage section of
    # the view for why, and the settings page for the full list.
    @coverage_held, @coverage_unheld =
      @coverage.partition_by(helpers.tax_products_held(Current.family))

    @audit    = audit_notes
    @projection = projection if @assumptions.horizon_years.positive?

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("tax_reports.show.title"), nil ] ]
  end

  private
    def builder
      @builder ||= Tax::SubjectBuilder.new(Current.family)
    end

    def rates
      @rates ||= Tax.rate_table(@country)
    end

    def valuation_date
      @valuation_date ||= begin
        parsed = params[:on].present? ? Date.parse(params[:on]) : Date.current
        # A future valuation date is a legitimate thing to ask for -- "what if
        # I liquidate in 2030" -- but a past one silently changes which rate
        # table applies, so both are allowed and the date is printed on the
        # report rather than hidden.
        parsed
      rescue Date::Error
        Date.current
      end
    end

    # Everything the user asserts rather than observes. All of it is rendered
    # on the page, because a net figure without its assumptions is a number
    # without a meaning.
    def assumptions_from_params
      Tax::Assumptions.new(
        tmi_mode: params[:tmi_mode] == "flat" ? :flat : :bareme,
        flat_rate: decimal(params[:flat_rate], "0.30"),
        other_taxable_income: decimal(params[:other_income], "0"),
        parts: decimal(params[:parts], "1"),
        expected_return: decimal(params[:expected_return], "0.05"),
        inflation: decimal(params[:inflation], "0.02"),
        horizon_years: params.fetch(:horizon, 20).to_i.clamp(0, 50)
      )
    end

    def projection
      Tax::Projection.new(
        registry: @registry, rates: rates, assumptions: @assumptions
      ).run(@subjects, from: valuation_date)
    end

    # Disagreements between Sure's own classification of an account and what
    # this module did with it. Usually empty; when it is not, it means one of
    # the two is wrong and the user is better placed than we are to say which.
    def audit_notes
      @subjects.zip(@snapshot.results).flat_map do |subject, result|
        Tax::Treatment.audit(subject, result).map { |note| [ subject.name, note ] }
      end
    end

    def decimal(value, fallback)
      BigDecimal(value.presence || fallback)
    rescue ArgumentError, TypeError
      BigDecimal(fallback)
    end
end
