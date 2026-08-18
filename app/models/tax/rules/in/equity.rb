# frozen_string_literal: true

module Tax
  module Rules
    module In
      # Listed Indian equity and equity mutual funds (Section 112A) on
      # liquidation.
      #
      # This is the corner of Indian capital-gains tax where Sure's own data is
      # enough: a value and a cost basis on an equity holding give the gain,
      # and the long-term rate applies to it directly. Everything else India
      # taxes -- debt, small savings, NPS, insurance -- turns on facts Sure does
      # not hold and is mapped to NotModelled instead.
      #
      # Two stated assumptions:
      #
      #   * Long-term. The 12.5% rate is for units held over 12 months; short-
      #     term equity gains are taxed at 20% (Section 111A). Sure records no
      #     per-lot holding period, so the rule takes the long-term rate and
      #     says so.
      #
      #   * No exemption netting. The first ₹1.25 lakh of long-term equity gains
      #     each year is exempt, once, across all disposals -- not per account.
      #     The rule states that it ignores the exemption rather than applying
      #     it here and over-counting it across accounts.
      class Equity < Base
        rule_id "in_equity"
        label "Listed equity (long-term capital-gains rate on the gain)"

        formula terms: [
          { base: "plus_value", rate: "equity_ltcg" }
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
          rate = rates.rate("equity_ltcg", on)

          warnings = []
          loss = subject.loss_against(base)
          warnings << msg("securities_gain.latent_loss", loss: amount(loss)) if loss.positive?
          warnings << msg("in_equity.long_term_assumed", rate: percent(rate))
          warnings << msg("in_equity.exemption_ignored")

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
