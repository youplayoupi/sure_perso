# frozen_string_literal: true

module Tax
  module Rules
    module Fr
      # PEA, PEA-PME and PEA Jeune, on full liquidation.
      #
      # Tax is levied on the *gain net* -- valeur liquidative minus versements
      # -- and not on the gain against the securities' cost basis. The two are
      # the same number only if nothing has ever been sold inside the plan.
      # Sure stores no versements anywhere, so where they have not been
      # declared this rule measures against what the holdings cost and says so.
      # That figure is a floor: selling and rebuying inside the plan resets it
      # upward while the versements do not, so the gain it yields is understated
      # and the tax with it. It is used anyway, because a plan showing no figure
      # at all gives the reader nothing to notice is wrong, and because this is
      # the commonest wrapper in France -- a report that is permanently blank on
      # it is not being careful.
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
          { base: "plus_value", rate: "social_charges", condition: "mature" },
          { base: "plus_value", rate: "flat_tax",       condition: "immature" }
        ], maturity_years: 5

        TAUX_HISTORIQUES_WINDOW = Date.new(2013, 1, 1)..Date.new(2017, 12, 31)

        def call(subject, on:, rates:, assumptions:)
          base, source = subject.plus_value_base

          # Still a refusal, and the same one as before -- just narrowed to the
          # case where nothing at all is known about what went in. A plan with
          # holdings has a cost basis; a plan holding only cash, or one Sure has
          # no trades for, has neither figure and there is nothing to measure.
          if base.nil?
            return refuse(
              subject,
              reason: msg("fr_pea.no_paid_in"),
              needs: msg("facts.paid_in"),
              missing: [ :paid_in ]
            )
          end

          product   = subject.product || "pea"
          warnings  = []
          gain_net  = subject.gain_against(base)
          social    = rates.social_charges(on)
          pfu       = rates.flat_tax(on)
          maturity  = rates.maturity_years(product) || 5

          if source == :cost_basis
            warnings << msg("fr_pea.computed_from_cost_basis",
                            cost_basis: amount(base))
          end

          loss = subject.loss_against(base)
          if loss.positive?
            warnings << msg("fr_pea.loss", loss: amount(loss))
          end

          # Three ways to answer "has the five-year clock run", in descending
          # order of how much is actually known.
          #
          # A declared or anchored opening date settles it outright. Failing
          # that, a lower bound can still settle it in one direction: an
          # account Sure has held money in since before the clock length is
          # mature as a matter of fact, and saying so beats asking for a date
          # in order to conclude something already proved. The bound can never
          # settle it the other way -- "at least two years old" says nothing
          # about whether it is six -- so a bound short of maturity falls
          # through to the same assumption as no date at all.
          #
          # That assumption is deliberately the optimistic one, and it is the
          # one place this rule guesses. Refusing instead would leave the
          # commonest French wrapper permanently blank; guessing the *pessi*
          # mistic way would print a tax roughly double the likely one. So it
          # assumes maturity, prints both figures, and asks.
          age   = subject.age_years_at(on)
          floor = subject.minimum_age_years_at(on)

          if age
            mature = age >= maturity
            unless mature
              warnings << msg("fr_pea.immature",
                              age: age.round(1),
                              maturity: maturity)
            end
          elsif floor && floor >= maturity
            mature = true
            warnings << msg("fr_pea.mature_by_lower_bound",
                            since: subject.known_since,
                            maturity: maturity)
          else
            mature = true

            # Same assumption, two sentences, and which one shows turns on
            # whether the reader has a date on the account that this rule has
            # just declined to use. "The opening date is not declared" reads to
            # that reader as the module having failed to look, and the first
            # thing they do is check -- correctly -- that Sure has a date.
            # Naming the date and saying why it is only a floor is the
            # difference between a report that looks broken and one that says
            # what it needs.
            clock = {
              maturity: maturity,
              mature_tax: amount(cents(gain_net * social)),
              immature_tax: amount(cents(gain_net * pfu))
            }

            warnings << if subject.known_since
              msg("fr_pea.opening_date_floor_only",
                  **clock, since: subject.known_since)
            else
              msg("fr_pea.no_opening_date", **clock)
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
          #
          # Checked against the declared versements only, never against the
          # cost basis standing in for them above. The two happen to be
          # comparable numbers and mean entirely different things: a plan whose
          # holdings cost more than the ceiling has almost certainly not
          # breached it, having reinvested inside the plan rather than paid more
          # in, and a warning that a household has broken a statutory limit is
          # not a thing to raise on a proxy.
          ceiling = rates.ceiling(product)
          if ceiling && subject.paid_in && subject.paid_in > ceiling
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
            basis_source: source,
            warnings: warnings
          )
        end
      end
    end
  end
end
