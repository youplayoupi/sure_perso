# frozen_string_literal: true

module Tax
  module Rules
    module Us
      # A taxable US account (brokerage, UGMA/UTMA) on liquidation.
      #
      # Long-term capital gains are computed on the acquisition price of the
      # securities -- exactly a cost basis -- so this is one of the wrappers
      # where Sure's own data is enough and nothing has to be declared.
      #
      # Two things this rule assumes and states rather than hides:
      #
      #   * Long-term treatment. The federal long-term rate (0/15/20) applies
      #     to assets held over a year; short-term gains are ordinary income.
      #     Sure records no per-lot holding period, so the rule takes the
      #     long-term rate and says so. Assuming long-term is the lower-tax
      #     reading, which is the wrong direction to lean silently -- hence the
      #     warning, not a quiet default.
      #
      #   * The middle bracket. 15% is assumed; a household in the 0% or 20%
      #     band corrects `long_term_gains` on the rates screen and every
      #     figure resting on it moves.
      class Securities < Base
        rule_id "us_securities"
        label "Taxable account (long-term capital-gains rate on the gain)"

        formula terms: [
          { base: "plus_value", rate: "long_term_gains" }
        ]

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

          gain = subject.gain_against(base)
          rate = rates.rate("long_term_gains", on)

          warnings = []
          loss = subject.loss_against(base)
          warnings << msg("securities_gain.latent_loss", loss: amount(loss)) if loss.positive?
          warnings << msg("us_long_term.rate_assumed", rate: percent(rate, 0))
          warnings << msg("us_long_term.bracket")
          warnings << msg("us_niit.note")

          result(
            subject,
            taxable_base: gain,
            tax: cents(gain * rate),
            basis: msg("securities_gain.basis", rate: percent(rate), gain: amount(gain), cost: amount(base)),
            basis_source: source,
            warnings: warnings
          )
        end
      end
    end
  end
end
