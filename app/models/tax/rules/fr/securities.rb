# frozen_string_literal: true

module Tax
  module Rules
    module Fr
      # Ordinary securities account (compte-titres ordinaire), on liquidation.
      #
      # This is the one wrapper where Sure's own data is sufficient. French
      # capital gains on a CTO are computed on the acquisition price of the
      # securities, which is exactly what a cost basis is -- so unlike the PEA,
      # nothing has to be declared and nothing has to be refused.
      class Securities < Base
        rule_id "fr_securities"
        label "Securities account (flat tax on the capital gain)"

        # One term, and no clock: a CTO has no holding period that changes the
        # rate.
        #
        # The formula names cost basis because that is the base in law.
        # #acquisition_cost below prefers a declared figure where one exists,
        # which is a rule about where the number comes from rather than about
        # what is taxed, so it is not a term. The equivalence test exercises
        # this rule on accounts with nothing declared, and says so.
        formula terms: [
          { base: "gain_over_cost_basis", rate: "flat_tax" }
        ]

        def call(subject, on:, rates:, assumptions:)
          base, source = acquisition_cost(subject)

          if base.nil?
            return refuse(
              subject,
              reason: "The capital gain is the current value minus the acquisition " \
                      "cost of the securities, and no cost basis is recorded on the " \
                      "holdings in this account.",
              needs: "the acquisition cost"
            )
          end

          warnings = []
          gain = subject.gain_against(base)
          pfu  = rates.flat_tax(on)

          loss = subject.loss_against(base)
          if loss.positive?
            warnings << "Latent loss of #{loss.to_s('F')}. Realised losses offset gains " \
                        "for ten years, which is not modelled."
          end

          if source == :declared
            warnings << "Using the declared figure as the acquisition cost. For a " \
                        "securities account the correct base is what the holdings cost, " \
                        "not the cash paid into the account -- check the declared value " \
                        "is the former."
          end

          warnings << format(
            "The flat tax is assumed. Electing the progressive scale instead can beat " \
            "it below roughly a %d%% effective rate and is not modelled.", (pfu * 100).to_i
          )

          result(
            subject,
            taxable_base: gain,
            tax: cents(gain * pfu),
            basis: format("flat tax %.1f%% on the capital gain (cost %s)", pfu * 100, base.to_s("F")),
            warnings: warnings
          )
        end

        private
          # A declared figure wins over a computed one -- the user knows things
          # the importer does not -- but the report always says which was used.
          def acquisition_cost(subject)
            return [ subject.paid_in, :declared ] unless subject.paid_in.nil?
            return [ subject.cost_basis, :holdings ] unless subject.cost_basis.nil?

            [ nil, nil ]
          end
      end
    end
  end
end
