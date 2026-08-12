# frozen_string_literal: true

module Tax
  module Rules
    module Fr
      # The same wrapper with the growth taxed at the household rate too.
      #
      # In French terms this is the option for the bareme on the plus-value
      # instead of the PFU: it is elected, not automatic, and it is worth
      # electing exactly when the household's marginal rate is below the flat
      # tax. Sure cannot tell whether the election was made -- it is a box on a
      # tax return, not a fact about an account -- so this is a separate rule
      # to be chosen rather than a branch that guesses.
      #
      # Note what is not modelled: electing the bareme is all-or-nothing across
      # a household's investment income for the year, so choosing this for one
      # account and the flat tax for another is a combination the tax office
      # would not accept. The report will happily compute it. That is a
      # limitation of taxing accounts one at a time, and it is stated in the
      # warning rather than enforced, because enforcing it would mean the
      # module deciding which of two legal elections a household made.
      class CapitalAndGainsAtHouseholdRate < CapitalAndGains
        rule_id "fr_capital_and_gains_household"
        label "Lump sum: your rate on both the capital and the growth"

        formula terms: [
          { base: "plus_value_base_deducted", rate: "household_rate" },
          { base: "plus_value",               rate: "household_rate" }
          # The same two keys the rule raises as warnings when it runs. The note
          # on the rules screen and the warning on the report are one claim, and
          # keying them separately would hand a translator the same sentence
          # twice and get back two French sentences that disagree.
        ], notes: [
          Message.new("fr_capital_and_gains.whole_wrapper_lump_sum"),
          Message.new("fr_capital_and_gains.mixed_election_not_modelled")
        ]

        private
          def gains_rate(rates:, on:, assumptions:)
            assumptions.marginal_rate
          end

          def gains_basis(rate)
            "#{percent(rate)} household rate"
          end

          def household_rate_income(deducted, gains)
            deducted + gains
          end

          # Said on the report and not only in the rule library, because the
          # library is where somebody reads about the rule once and the report
          # is where they read the number every time. The mixture this warns
          # about is not visible from inside a single account -- it is a
          # property of the set of rules a household has chosen -- so it is
          # stated on each account that could be part of one.
          def regime_notes
            [
              msg("fr_capital_and_gains.mixed_election_not_modelled")
            ]
          end
      end
    end
  end
end
