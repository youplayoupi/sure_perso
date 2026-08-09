# frozen_string_literal: true

module Tax
  module Rules
    module Fr
      # A retirement wrapper taken as a lump sum, where the money splits into
      # two streams taxed under different regimes and never mixed:
      #
      #   payments in that were deducted on the way in  -> progressive scale,
      #                                                    no social charges
      #   payments in that were not deducted            -> not taxed again
      #   growth (value minus payments in)              -> flat tax
      #
      # This is the shape of a French PER. Sure has no PER subtype today, so
      # nothing registers this rule by default -- it is reachable as a custom
      # rule, and it will be picked up automatically for any subtype whose name
      # a future Sure release adds and which an operator maps to it.
      #
      # The deducted stream is what makes stacking matter: two wrappers
      # liquidated in the same year are added together and run through the
      # brackets once, not taxed twice from zero.
      class CapitalAndGains < Base
        rule_id "fr_capital_and_gains"
        label "Lump sum: scale on the capital, flat tax on the growth"

        def call(subject, on:, rates:, assumptions:)
          if subject.paid_in.nil?
            return refuse(
              subject,
              reason: "This wrapper splits into payments in and growth, taxed under " \
                      "different regimes. Sure does not store the amount paid in.",
              needs: "the total paid in",
              extra_warnings: cost_basis_footnote(subject)
            )
          end

          warnings = []
          paid_in = subject.paid_in
          deducted = subject.paid_in_deducted

          if deducted.nil?
            deducted = paid_in
            warnings << "The deducted portion is not declared, so all payments in are " \
                        "assumed to have been deducted. That is the higher-tax " \
                        "assumption. Declare it if some payments were made without " \
                        "taking the deduction."
          elsif deducted > paid_in
            warnings << "The declared deducted portion (#{deducted.to_s('F')}) exceeds " \
                        "the total paid in (#{paid_in.to_s('F')}). Capped at the total; " \
                        "one of the two figures is wrong."
            deducted = paid_in
          end

          gains        = subject.gain_against(paid_in)
          non_deducted = paid_in - deducted
          pfu          = rates.flat_tax(on)

          capital_tax = assumptions.income_tax_on(deducted, rates: rates, on: on)
          gains_tax   = gains * pfu

          if assumptions.flat?
            warnings << format(
              "The capital is taxed at a flat %d%%. A lump sum of %s would in reality " \
              "push through brackets; switch to the progressive scale for the figure " \
              "that actually applies.", (assumptions.flat_rate * 100).to_i, deducted.to_s("F")
            )
          end

          if non_deducted.positive?
            warnings << "#{non_deducted.to_s('F')} of non-deducted payments in comes " \
                        "back untaxed."
          end

          warnings << "Assumes the whole wrapper is taken as a lump sum in a single tax " \
                      "year. Spreading withdrawals lowers the bill and is not modelled."

          total = capital_tax + gains_tax

          result(
            subject,
            taxable_base: deducted + gains,
            tax: cents(total),
            basis: format(
              "progressive scale on %s of deducted payments in (%s) plus flat tax %.1f%% " \
              "on %s of growth (%s)",
              deducted.to_s("F"), cents(capital_tax).to_s("F"),
              pfu * 100, gains.to_s("F"), cents(gains_tax).to_s("F")
            ),
            warnings: warnings,
            # Only the deducted stream lands on the progressive scale, so only
            # it stacks onto anything liquidated later the same year.
            bareme_income: assumptions.bareme? ? deducted : zero
          )
        end
      end
    end
  end
end
