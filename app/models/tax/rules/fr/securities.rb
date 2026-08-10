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
              reason: msg("fr_securities.no_cost_basis"),
              needs: msg("facts.acquisition_cost")
            )
          end

          warnings = []
          gain = subject.gain_against(base)
          pfu  = rates.flat_tax(on)

          loss = subject.loss_against(base)
          warnings << msg("fr_securities.latent_loss", loss: amount(loss)) if loss.positive?

          warnings << msg("fr_securities.declared_cost") if source == :declared

          # Whole percent here, unlike everywhere else: the sentence says
          # "roughly", and a figure given to a tenth reads as a threshold
          # somebody computed rather than as the rule of thumb it is.
          warnings << msg("fr_securities.flat_tax_assumed", rate: percent(pfu, 0))

          result(
            subject,
            taxable_base: gain,
            tax: cents(gain * pfu),
            basis: msg("fr_securities.basis", rate: percent(pfu), cost: amount(base)),
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
