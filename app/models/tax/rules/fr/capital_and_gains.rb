# frozen_string_literal: true

module Tax
  module Rules
    module Fr
      # A retirement wrapper taken as a lump sum, where the money splits into
      # two streams taxed under different regimes and never mixed:
      #
      #   payments in that were deducted on the way in  -> household rate,
      #                                                    no social charges
      #   payments in that were not deducted            -> not taxed again
      #   growth (value minus payments in)              -> flat tax (PFU)
      #
      # This is the shape of a French PER taken en capital, and it is the
      # reason the formula vocabulary has more than one term. Sure has no PER
      # subtype today: an ordinary taxable brokerage account and a PER are the
      # same (Investment, brokerage) pair as far as Sure is concerned, so no
      # rule keyed on the subtype could tell them apart, and nothing registers
      # this one by default. It is reached by pinning it to the account on the
      # Taxes screen, and it will be picked up automatically for any subtype a
      # future Sure release adds and an operator maps to it.
      #
      # CapitalAndGainsAtHouseholdRate is the same rule with the growth taxed
      # at the household rate instead. Both are shipped because both are real: the PFU is what applies unless you
      # ask otherwise, and asking otherwise is worth doing at a low marginal
      # rate. Choosing between them is a decision about the household's own
      # circumstances, so the module offers both and picks neither.
      class CapitalAndGains < Base
        rule_id "fr_capital_and_gains"
        label "Lump sum: your rate on the capital, flat tax on the growth"

        # The deducted payments go to the household's own marginal rate; the
        # growth takes the flat tax. Payments that were never deducted appear
        # in neither term, which is the arithmetic saying they come back
        # untaxed rather than a gap where a term should be.
        formula terms: [
          { base: "paid_in_deducted",  rate: "household_rate" },
          { base: "gain_over_paid_in", rate: "flat_tax" }
        ], notes: [ Message.new("fr_capital_and_gains.whole_wrapper_lump_sum") ]

        def call(subject, on:, rates:, assumptions:)
          if subject.paid_in.nil?
            return refuse(
              subject,
              reason: msg("fr_capital_and_gains.no_paid_in"),
              needs: msg("facts.paid_in"),
              extra_warnings: cost_basis_footnote(subject)
            )
          end

          warnings = []
          paid_in = subject.paid_in
          deducted = subject.paid_in_deducted

          if deducted.nil?
            deducted = paid_in
            warnings << msg("fr_capital_and_gains.no_deducted")
          elsif deducted > paid_in
            warnings << msg("fr_capital_and_gains.deducted_exceeds_total",
                            deducted: amount(deducted),
                            paid_in: amount(paid_in))
            deducted = paid_in
          end

          gains        = subject.gain_against(paid_in)
          non_deducted = paid_in - deducted
          household    = assumptions.marginal_rate
          growth_rate  = gains_rate(rates: rates, on: on, assumptions: assumptions)

          capital_tax = deducted * household
          gains_tax   = gains * growth_rate

          # The lump-sum caveat, stated with the number it applies to rather
          # than in the abstract. A single rate on the whole capital is exact
          # while the withdrawal stays inside one band and understates the bill
          # once it climbs out of it, and the amount is the only thing that
          # tells the reader which of those they are looking at.
          warnings << msg("fr_capital_and_gains.lump_sum_caveat",
                          rate: percent(household),
                          amount: amount(deducted))

          warnings << assumptions.marginal_rate_caveat if assumptions.marginal_rate_caveat

          if non_deducted.positive?
            warnings << msg("fr_capital_and_gains.non_deducted_untaxed",
                            amount: amount(non_deducted))
          end

          warnings << msg("fr_capital_and_gains.whole_wrapper_lump_sum")

          warnings.concat(regime_notes)

          total = capital_tax + gains_tax

          result(
            subject,
            taxable_base: deducted + gains,
            tax: cents(total),
            basis: msg("fr_capital_and_gains.basis",
                       rate: percent(household),
                       amount: amount(deducted),
                       capital_tax: amount(cents(capital_tax)),
                       gains_rate: gains_basis(growth_rate),
                       gains: amount(gains),
                       gains_tax: amount(cents(gains_tax))),
            warnings: warnings,
            household_rate_income: household_rate_income(deducted, gains)
          )
        end

        private
          # What the growth is taxed at. The one thing the two rules disagree
          # about, kept as a method rather than a constant so that everything
          # else -- the deduction split, the caps, the caveats -- is shared
          # code and cannot drift between them.
          def gains_rate(rates:, on:, assumptions:)
            rates.flat_tax(on)
          end

          def gains_basis(rate)
            "flat tax #{percent(rate)}"
          end

          # Only the deducted stream rests on the household's own figure here.
          def household_rate_income(deducted, _gains)
            deducted
          end

          # Anything the *choice between the two rules* obliges the reader to
          # know, as opposed to anything about this account. Empty here: taking
          # the flat tax on the growth is what happens if the household does
          # nothing, and a warning on the default would be a warning on almost
          # every PER in the report, which is how readers learn to skip them.
          def regime_notes
            []
          end
      end
    end
  end
end
