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
        # The term is `plus_value` rather than `gain_over_cost_basis`, which is
        # a change of spelling and not of arithmetic: this rule has always
        # preferred a declared figure over the holdings' own, and the formula
        # used to say only half of that. The half it left out was the half the
        # equivalence test then had to be told to skip. Now the formula says
        # what the rule does, and the test exercises declared and undeclared
        # accounts alike.
        #
        # Note which way round the preference runs here compared with the PEA.
        # For a CTO the cost basis *is* the base in law and a declared figure
        # is the household correcting it; for a PEA the versements are the base
        # and the cost basis is a stand-in. Same cascade, opposite meanings,
        # which is why each rule says its own sentence about which it got.
        formula terms: [
          { base: "plus_value", rate: "flat_tax" }
        ]

        def call(subject, on:, rates:, assumptions:)
          base, source = subject.plus_value_base

          if base.nil?
            return refuse(
              subject,
              reason: msg("fr_securities.no_cost_basis"),
              needs: msg("facts.acquisition_cost"),
              missing: [ :cost_basis ]
            )
          end

          warnings = []
          gain = subject.gain_against(base)
          pfu  = rates.flat_tax(on)

          loss = subject.loss_against(base)
          warnings << msg("fr_securities.latent_loss", loss: amount(loss)) if loss.positive?

          warnings << msg("fr_securities.declared_cost") if source == :paid_in

          # Whole percent here, unlike everywhere else: the sentence says
          # "roughly", and a figure given to a tenth reads as a threshold
          # somebody computed rather than as the rule of thumb it is.
          warnings << msg("fr_securities.flat_tax_assumed", rate: percent(pfu, 0))

          result(
            subject,
            taxable_base: gain,
            tax: cents(gain * pfu),
            basis: msg("fr_securities.basis", rate: percent(pfu), cost: amount(base)),
            basis_source: source,
            warnings: warnings
          )
        end
      end
    end
  end
end
