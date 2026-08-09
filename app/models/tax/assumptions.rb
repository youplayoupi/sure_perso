# frozen_string_literal: true

module Tax
  # Everything the user asserts rather than something Sure observed.
  #
  # All of it is rendered on the report. An assumption that is not visible is
  # indistinguishable from a fact, and that is exactly the failure mode this
  # module exists to avoid.
  class Assumptions
    TMI_MODES = %i[flat bareme].freeze

    attr_reader :tmi_mode, :flat_rate, :other_taxable_income, :parts,
                :expected_return, :horizon_years, :inflation, :real_terms,
                :liquidate_all

    def initialize(
      tmi_mode: :bareme,
      flat_rate: BigDecimal("0.30"),
      other_taxable_income: BigDecimal(0),
      parts: BigDecimal(1),
      expected_return: BigDecimal("0.05"),
      horizon_years: 20,
      inflation: BigDecimal("0.02"),
      real_terms: false,
      liquidate_all: true
    )
      @tmi_mode = tmi_mode.to_sym
      raise ArgumentError, "unknown tmi_mode #{tmi_mode}" unless TMI_MODES.include?(@tmi_mode)

      @flat_rate = flat_rate
      @other_taxable_income = other_taxable_income
      @parts = parts.zero? ? BigDecimal(1) : parts
      @expected_return = expected_return
      @horizon_years = horizon_years
      @inflation = inflation
      @real_terms = real_terms
      @liquidate_all = liquidate_all
    end

    def bareme?
      tmi_mode == :bareme
    end

    def flat?
      tmi_mode == :flat
    end

    # Income tax on an amount that lands on the progressive scale.
    #
    # In :flat mode this is a single rate applied to the whole amount, which is
    # fast and wrong near a bracket edge. In :bareme mode the amount is stacked
    # on top of other income and the difference in total tax is taken, which is
    # what actually happens when you withdraw a lump sum.
    def income_tax_on(amount, rates:, on:)
      return BigDecimal(0) if amount.nil? || amount <= 0
      return amount * flat_rate if flat?

      rates.marginal_income_tax(
        amount, other_income: other_taxable_income, on: on, parts: parts
      )
    end

    def with(**overrides)
      self.class.new(
        tmi_mode: overrides.fetch(:tmi_mode, tmi_mode),
        flat_rate: overrides.fetch(:flat_rate, flat_rate),
        other_taxable_income: overrides.fetch(:other_taxable_income, other_taxable_income),
        parts: overrides.fetch(:parts, parts),
        expected_return: overrides.fetch(:expected_return, expected_return),
        horizon_years: overrides.fetch(:horizon_years, horizon_years),
        inflation: overrides.fetch(:inflation, inflation),
        real_terms: overrides.fetch(:real_terms, real_terms),
        liquidate_all: overrides.fetch(:liquidate_all, liquidate_all)
      )
    end
  end
end
