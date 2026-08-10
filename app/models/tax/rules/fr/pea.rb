# frozen_string_literal: true

module Tax
  module Rules
    module Fr
      # PEA, PEA-PME and PEA Jeune, on full liquidation.
      #
      # Tax is levied on the *gain net* -- valeur liquidative minus versements
      # -- and not on the gain against the securities' cost basis. The two are
      # the same number only if nothing has ever been sold inside the plan.
      # Since Sure stores no versements anywhere, this rule refuses rather than
      # substituting the near-miss it does have.
      #
      # Past five years the plan is exempt from income tax and pays social
      # charges only. Before five years, any withdrawal closes the plan and the
      # whole gain takes the full PFU.
      class Pea < Base
        rule_id "fr_pea"
        label "PEA (gain net, 5-year clock)"

        # Five years is the statutory clock for all three PEA variants, and the
        # rate file agrees for each of them. The rule below still reads
        # `maturity_years` from the file per product rather than from here, so
        # that a self-hoster correcting the file is obeyed; this figure is what
        # the screen shows and what the equivalence test holds it to.
        formula terms: [
          { base: "gain_over_paid_in", rate: "social_charges", condition: "mature" },
          { base: "gain_over_paid_in", rate: "flat_tax",       condition: "immature" }
        ], maturity_years: 5

        TAUX_HISTORIQUES_WINDOW = Date.new(2013, 1, 1)..Date.new(2017, 12, 31)

        def call(subject, on:, rates:, assumptions:)
          if subject.paid_in.nil?
            return refuse(
              subject,
              reason: msg("fr_pea.no_paid_in"),
              needs: msg("facts.paid_in"),
              extra_warnings: cost_basis_footnote(subject)
            )
          end

          product   = subject.product || "pea"
          warnings  = []
          gain_net  = subject.gain_against(subject.paid_in)
          social    = rates.social_charges(on)
          pfu       = rates.flat_tax(on)
          maturity  = rates.maturity_years(product) || 5

          loss = subject.loss_against(subject.paid_in)
          if loss.positive?
            warnings << msg("fr_pea.loss", loss: amount(loss))
          end

          age = subject.age_years_at(on)
          if age.nil?
            mature = true
            warnings << msg("fr_pea.no_opening_date",
                            maturity: maturity,
                            mature_tax: amount(cents(gain_net * social)),
                            immature_tax: amount(cents(gain_net * pfu)))
          else
            mature = age >= maturity
            unless mature
              warnings << msg("fr_pea.immature",
                              age: age.round(1),
                              maturity: maturity)
            end
          end

          rate  = mature ? social : pfu
          basis = if mature
            msg("fr_pea.basis_mature", rate: percent(social))
          else
            msg("fr_pea.basis_immature", rate: percent(pfu), maturity: maturity)
          end

          # The ceiling is on money paid in, never on current value. A plan
          # worth more than the ceiling is the normal outcome of it working.
          ceiling = rates.ceiling(product)
          if ceiling && subject.paid_in > ceiling
            warnings << msg("fr_pea.exceeds_ceiling",
                            paid_in: amount(subject.paid_in),
                            ceiling: ceiling.to_i)
          end

          if subject.opened_on && TAUX_HISTORIQUES_WINDOW.cover?(subject.opened_on)
            warnings << msg("fr_pea.taux_historiques")
          end

          result(
            subject,
            taxable_base: gain_net,
            tax: cents(gain_net * rate),
            basis: basis,
            warnings: warnings
          )
        end
      end
    end
  end
end
