# frozen_string_literal: true

module Tax
  # Everything the user asserts rather than something Sure observed.
  #
  # All of it is rendered on the report. An assumption that is not visible is
  # indistinguishable from a fact, and that is exactly the failure mode this
  # module exists to avoid.
  class Assumptions
    # The rate used when the household has not said what theirs is.
    #
    # It is a plausible middle band, and that is the problem with it: a figure
    # computed from it looks exactly like a figure computed from a declared
    # rate. Nothing here hides that. `marginal_rate_declared?` is false while
    # this is in use, every result touched by it carries a warning, and the
    # report labels its own total as provisional. The alternative -- refusing
    # to compute until someone fills in a form -- would leave a household with
    # a blank page and no idea which number it was waiting for.
    PLACEHOLDER_MARGINAL_RATE = BigDecimal("0.30")

    attr_reader :expected_return, :horizon_years, :inflation, :real_terms,
                :liquidate_all

    # `marginal_rate` is the household's own top rate of income tax: the rate
    # the next euro of taxable income would be taxed at.
    #
    # It replaces the income-tax scale this module used to carry. Running the
    # brackets required the household's other income and its number of parts,
    # neither of which Sure knows, so both were asked for on a form and both
    # were routinely left at zero and one -- which produces a bill for a large
    # withdrawal that is wrong by a wide margin and confidently presented. One
    # number the household can actually look up on last year's assessment is
    # less machinery and more accurate in practice.
    #
    # It is also the piece that makes a second country possible. Brackets, a
    # quotient familial and a five-band schedule are French statute; "the rate
    # your marginal income is taxed at" is a question with an answer almost
    # everywhere.
    def initialize(
      marginal_rate: nil,
      expected_return: BigDecimal("0.05"),
      horizon_years: 20,
      inflation: BigDecimal("0.02"),
      real_terms: false,
      liquidate_all: true
    )
      @declared_marginal_rate = usable_rate(marginal_rate)
      @expected_return = expected_return
      @horizon_years = horizon_years
      @inflation = inflation
      @real_terms = real_terms
      @liquidate_all = liquidate_all
    end

    # Always a number, so no caller has to branch before multiplying. Whether
    # that number came from the household is a separate question, asked
    # separately, and every screen that prints a figure resting on it asks.
    def marginal_rate
      @declared_marginal_rate || PLACEHOLDER_MARGINAL_RATE
    end

    def marginal_rate_declared?
      !@declared_marginal_rate.nil?
    end

    # The sentence a rule appends to any result computed off an undeclared
    # rate. Kept here rather than written out at each of the three call sites
    # so the three cannot drift into saying subtly different things about the
    # same placeholder.
    def marginal_rate_caveat
      return nil if marginal_rate_declared?

      # Pre-formatted, percent sign included. No message template may contain a
      # literal `%`: Ruby's String#% reads `%%` as an escaped one and I18n
      # leaves it alone, so the same template would render a different rate in
      # English than in French. See Tax::Messages.
      Message.new("assumptions.marginal_rate_caveat",
                  rate: format("%d%%", (PLACEHOLDER_MARGINAL_RATE * 100).to_i))
    end

    # Income tax on an amount taxed at the household's own rate.
    #
    # A single multiplication, which is exact when the amount stays inside one
    # band and understates it when the amount is large enough to climb into the
    # next. Rules that tax a lump sum this way say so; see
    # Rules::Fr::CapitalAndGains.
    def income_tax_on(amount)
      return BigDecimal(0) if amount.nil? || amount <= 0

      amount * marginal_rate
    end

    def with(**overrides)
      self.class.new(
        marginal_rate: overrides.fetch(:marginal_rate, @declared_marginal_rate),
        expected_return: overrides.fetch(:expected_return, expected_return),
        horizon_years: overrides.fetch(:horizon_years, horizon_years),
        inflation: overrides.fetch(:inflation, inflation),
        real_terms: overrides.fetch(:real_terms, real_terms),
        liquidate_all: overrides.fetch(:liquidate_all, liquidate_all)
      )
    end

    private
      # A rate outside 0..1 is discarded rather than clamped or raised on.
      #
      # Clamping 30 to 1 would tax the whole withdrawal away and call it an
      # answer; raising would take down a report over a number typed into a
      # settings form months ago. Discarding falls back to the placeholder,
      # which is the one outcome that announces itself on every line it
      # touches. The form rejects this input on the way in, so reaching here
      # means a row written by something else.
      def usable_rate(value)
        return nil if value.nil?

        decimal = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s, exception: false)
        return nil if decimal.nil?
        return nil if decimal.negative? || decimal > 1

        decimal
      end
  end
end
