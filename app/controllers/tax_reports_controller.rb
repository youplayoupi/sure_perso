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

    @rows = rows_by_state

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

    # The family's rates, not the shipped ones.
    #
    # A household that has corrected a rate has said, in as many words, that
    # the figure in the file is wrong for them. Computing the report from the
    # shipped table anyway would leave the correction visible on the settings
    # page and absent from every number it was made to fix -- which is worse
    # than not offering corrections at all, because it looks like it worked.
    def rates
      @rates ||= Tax.rate_table_for(Current.family, @country)
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
    #
    # The marginal rate is the one assumption that is not a URL parameter, and
    # deliberately so. It used to be three of them -- a mode, a flat rate, the
    # household's other income and its number of parts -- which defaulted to
    # zero other income and one part, so unless somebody hand-edited the query
    # string every large withdrawal was taxed as though it were the household's
    # only income for the year. That is a wrong answer arrived at confidently,
    # which is the one output this module exists to refuse. It is now a stored
    # fact the household states once, under Taxes, and nil until they do --
    # see Tax::Assumptions#marginal_rate_caveat for what the report says in the
    # meantime.
    #
    # The projection knobs stay in the URL because they are a question being
    # asked ("what if I hold for thirty years?"), not a fact being declared,
    # and a question should be shareable and shouldn't outlive the tab.
    def assumptions_from_params
      Tax::Assumptions.new(
        marginal_rate: Tax::Household.marginal_rate_for(Current.family),
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

    # The table's rows, sorted into the three blocks the reader cares about and
    # ordered by size inside each.
    #
    # `Snapshot#results` is ordered by account, which is the right order for a
    # thing that has to be stable and reproducible and the wrong one for a
    # person reading it: an account needing a fact sits between two that are
    # fine, so finding what to act on means reading every row. Grouping puts
    # the work first; sorting by gross inside each block puts the money first,
    # because a 200 € Livret and a 200 000 € PEA in the same state are not
    # equally worth the reader's next five minutes.
    #
    # Computed here rather than in the template because ERB that groups and
    # sorts is ERB that has to be read to know what the page shows. The state
    # itself comes from the helper -- see TaxReportsHelper#tax_row_state -- so
    # that the block a row lands in and the colour it wears are the same
    # decision made once. Each row carries its own already-sorted warnings, too:
    # the template needed them anyway, and computing them here means the
    # demotion pass runs once per row instead of three times.
    #
    # Every state is a key even when empty, so the template iterates a constant
    # order instead of whatever `group_by` happened to see first, and an empty
    # block is a thing the page can choose to say nothing about rather than a
    # missing key it has to guard.
    def rows_by_state
      rows = @snapshot.results.map do |result|
        warnings = helpers.tax_warnings(result)
        [ helpers.tax_row_state(result, warnings), result, warnings ]
      end

      grouped = rows.group_by(&:first)

      TaxReportsHelper::STATES.index_with do |state|
        Array(grouped[state])
          .sort_by { |(_, result, _)| -(result.gross || 0) }
          .map { |(_, result, warnings)| [ result, warnings ] }
      end
    end

    # Disagreements between Sure's own classification of an account and what
    # this module did with it. Usually empty; when it is not, it means one of
    # the two is wrong and the user is better placed than we are to say which.
    #
    # Paired on the account id rather than by position. `apply_all` sorts its
    # input before taxing it -- so that the report does not depend on the order
    # rows came back from the database -- which means results do not come back
    # in the order the subjects went in. Zipping the two compared one account's
    # classification against another account's tax and filed the resulting note
    # under a third account's name. It stayed invisible because this list is
    # empty for most portfolios: the pairing is only wrong where it has
    # something to say.
    def audit_notes
      results = @snapshot.results.index_by(&:account_id)

      @subjects.flat_map do |subject|
        Tax::Treatment.audit(subject, results[subject.id]).map { |note| [ subject.name, note ] }
      end
    end

    def decimal(value, fallback)
      BigDecimal(value.presence || fallback)
    rescue ArgumentError, TypeError
      BigDecimal(fallback)
    end
end
