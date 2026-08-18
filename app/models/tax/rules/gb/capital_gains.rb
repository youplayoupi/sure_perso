# frozen_string_literal: true

module Tax
  module Rules
    module Gb
      # A taxable UK account (a General Investment Account and the like) on
      # liquidation.
      #
      # UK CGT has two rates -- 18% within the basic income-tax band, 24% above
      # it -- and which applies depends on where the gain lands once stacked on
      # income. The module does not run an income schedule, but the household's
      # declared marginal rate answers the question directly: a basic-rate
      # taxpayer is at 20% income tax, so anyone at or below 20% takes the basic
      # CGT rate and anyone above takes the higher one. No formula is declared
      # because the rate is chosen from a household assertion rather than fixed
      # on the valuation date, and the rules screen says so rather than showing
      # a rate that might not be the one that ran.
      #
      # The £3,000 annual exempt amount is not deducted: it applies once across
      # all disposals in the year, not per account, and every figure says it is
      # ignored rather than spreading it thinly and wrongly.
      class CapitalGains < Base
        rule_id "gb_capital_gains"
        label "Taxable account (UK CGT, band taken from your marginal rate)"

        BASIC_RATE_CEILING = BigDecimal("0.20")

        def call(subject, on:, rates:, assumptions:)
          base, source = subject.plus_value_base

          if base.nil?
            return refuse(
              subject,
              reason: msg("securities_gain.no_cost_basis"),
              needs: msg("facts.acquisition_cost"),
              missing: [ :cost_basis ]
            )
          end

          gain    = subject.gain_against(base)
          higher  = assumptions.marginal_rate > BASIC_RATE_CEILING
          rate    = rates.rate(higher ? "capital_gains_higher" : "capital_gains_basic", on)

          warnings = []
          loss = subject.loss_against(base)
          warnings << msg("securities_gain.latent_loss", loss: amount(loss)) if loss.positive?
          warnings << msg("gb_capital_gains.band_from_marginal", rate: percent(rate))
          warnings << assumptions.marginal_rate_caveat if assumptions.marginal_rate_caveat
          warnings << msg("gb_capital_gains.allowance_ignored")

          result(
            subject,
            taxable_base: gain,
            tax: cents(gain * rate),
            basis: msg("securities_gain.basis", rate: percent(rate), gain: amount(gain), cost: amount(base)),
            basis_source: source,
            warnings: warnings,
            household_rate_income: gain
          )
        end
      end
    end
  end
end
