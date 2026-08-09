# frozen_string_literal: true

module Tax
  # Gross against net, year by year.
  #
  # The interesting thing on the chart is not the growth line, which is just
  # compounding. It is the gap between the two lines and where that gap changes
  # shape -- a plan crossing its five-year mark drops from the full flat tax to
  # social charges only, and the net line steps up while the gross line carries
  # straight on.
  #
  # Modelling choices, all questionable, all stated on the report:
  #   * one expected return for every account
  #   * payments in held constant, so no future contributions
  #   * everything liquidated in the projected year, in a single tax year
  #   * today's rules apply forever, except where the rate table says otherwise
  class Projection
    def initialize(registry:, rates:, assumptions:)
      @registry = registry
      @rates = rates
      @assumptions = assumptions
    end

    def run(subjects, from:)
      (0..@assumptions.horizon_years).map do |year|
        on = shift_years(from, year)
        cohort = subjects.map { |s| grow(s, year) }

        Snapshot.new(
          on: on,
          year_offset: year,
          results: @registry.apply_all(cohort, on: on, rates: @rates, assumptions: @assumptions)
        )
      end
    end

    # Value compounds; payments in do not. That asymmetry is the entire reason
    # the taxable gap widens over a long horizon, and it is also the reason the
    # far end of the chart should not be taken too seriously -- in real life
    # you keep paying in.
    def grow(subject, years)
      return subject if years.zero?

      factor = (BigDecimal(1) + @assumptions.expected_return) ** years

      subject.with(
        value: (subject.value * factor).round(2, half: :even),
        cost_basis: subject.cost_basis
      )
    end

    def self.deflate(amount, years:, inflation:)
      return amount if inflation.nil? || inflation.zero? || years.zero?

      (amount / ((BigDecimal(1) + inflation) ** years)).round(2, half: :even)
    end

    private
      def shift_years(date, years)
        date >> (12 * years)
      end
  end
end
