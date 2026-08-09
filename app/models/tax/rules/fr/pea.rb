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
              reason: "PEA tax is levied on the gain net, which is the current value " \
                      "minus the total paid in. Sure does not store the amount paid in.",
              needs: "the total paid in (versements)",
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
            warnings << "Value is #{loss.to_s('F')} below the amount paid in. A loss is " \
                        "not taxed. A realised loss on closing the plan may be " \
                        "offsettable, which is not modelled."
          end

          age = subject.age_years_at(on)
          if age.nil?
            mature = true
            warnings << "The opening date is not declared, so the #{maturity}-year clock " \
                        "cannot be checked. Assuming the plan is mature. If it is not, " \
                        "the tax would be #{cents(gain_net * pfu).to_s('F')} instead of " \
                        "#{cents(gain_net * social).to_s('F')}."
          else
            mature = age >= maturity
            unless mature
              warnings << "The plan is #{age.round(1)} years old, under #{maturity}. Any " \
                          "withdrawal closes it and the whole gain takes the full rate."
            end
          end

          rate  = mature ? social : pfu
          basis = if mature
            format("social charges %.1f%% on the gain net (plan mature, income tax exempt)", social * 100)
          else
            format("flat tax %.1f%% on the gain net (plan under %d years)", pfu * 100, maturity)
          end

          # The ceiling is on money paid in, never on current value. A plan
          # worth more than the ceiling is the normal outcome of it working.
          ceiling = rates.ceiling(product)
          if ceiling && subject.paid_in > ceiling
            warnings << "Payments in of #{subject.paid_in.to_s('F')} exceed the " \
                        "#{ceiling.to_i} ceiling for this plan."
          end

          if subject.opened_on && TAUX_HISTORIQUES_WINDOW.cover?(subject.opened_on)
            warnings << "Opened between 2013 and 2017, so part of the gain may qualify " \
                        "for the social-charge rates in force when it accrued. Not " \
                        "modelled, so the tax here may be overstated."
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
