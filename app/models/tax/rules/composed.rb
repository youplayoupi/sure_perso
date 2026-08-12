# frozen_string_literal: true

module Tax
  module Rules
    # Runs a Formula.
    #
    # This is the rule behind every calculation a family assembles for itself.
    # It is also, through the equivalence test, the executable proof that the
    # formulas shown on screen for the built-in rules are the arithmetic those
    # rules actually perform.
    #
    # It is a rule like any other: it reads nothing, writes nothing, and takes
    # every fact it uses off the Subject. The formula it runs arrives as plain
    # data that was validated before it was stored, so nothing here is
    # evaluated, parsed or constantized. Given a term this file does not
    # recognise -- a row written by a newer version, say -- it refuses the
    # account rather than skipping the term, because a tax figure short one
    # term looks exactly like a correct one.
    class Composed < Base
      rule_id "composed"
      label "Custom rule"

      # Bases that measure against Tax::Subject#plus_value_base rather than
      # against the declared payments in, and therefore accept the cost basis
      # as a stand-in. Named once because three methods below have to agree
      # about the set, and a base added to two of them would be a term that
      # computes with a figure nobody split or splits a figure nobody
      # computed.
      PLUS_VALUE_BASES = %w[plus_value plus_value_base_deducted].freeze

      # Bases that need the deducted portion resolved before they can be
      # evaluated.
      DEDUCTION_SPLIT_BASES = %w[
        paid_in_deducted paid_in_not_deducted plus_value_base_deducted
      ].freeze

      attr_reader :formula, :name

      # `name` is the family's own label for the rule. It is carried rather
      # than used here, so that the settings page can show "Mon PER" instead of
      # "Custom rule" without the engine having to know anything about how it
      # is displayed.
      def initialize(terms: [], maturity_years: nil, notes: [], name: nil)
        @formula = Formula.new(terms: terms, maturity_years: maturity_years, notes: notes)
        @name = name.to_s.strip.empty? ? nil : name.to_s.strip
      end

      def call(subject, on:, rates:, assumptions:)
        # Validated against this country's own rate names, not against a list
        # kept in Ruby. A term naming a rate France has and Germany does not
        # is a valid formula in one file and an invalid one in the other, and
        # the only thing that can tell them apart is the table in hand.
        return refuse_invalid(subject, rates) unless formula.valid?(known_rates: rates.rate_names)

        missing = missing_facts(subject)
        return refuse_missing(subject, missing) if missing.any?

        warnings = []
        deducted = resolve_deducted(subject, warnings)
        mature   = resolve_maturity(subject, on: on, rates: rates, assumptions: assumptions,
                                    deducted: deducted, warnings: warnings)

        run = evaluate(subject, mature: mature, on: on, rates: rates,
                       assumptions: assumptions, deducted: deducted)

        warnings.concat(formula.notes)

        # Said once for the whole rule rather than once per term, and only when
        # a term actually rests on the declared rate. A rule that is all flat
        # tax is unaffected by whether the household has set its rate, and
        # warning about it anyway would train the reader to skip warnings.
        if formula.uses_household_rate? && assumptions.marginal_rate_caveat
          warnings << assumptions.marginal_rate_caveat
        end

        # Only a rule that went through the cascade has provenance to report.
        # A formula written entirely in `paid_in` terms asked for the declared
        # figure by name and was given it or refused; captioning that "measured
        # against the payments you declared" would be telling the reader
        # something the rule's own name already said, in the same tone the page
        # uses for a substitution they might want to correct.
        source = subject.plus_value_base.last if uses_plus_value?

        result(
          subject,
          taxable_base: run[:base],
          tax: cents(run[:tax]),
          basis: run[:basis],
          basis_source: source,
          warnings: warnings,
          household_rate_income: run[:household_rate_income]
        )
      end

      private
        # A term needs a fact; the account either has it or the rule declines.
        # `paid_in_deducted` is the one exception and it is not an exception to
        # this: it needs `paid_in`, and the deducted portion on top of that is
        # allowed to be absent because there is a defensible reading of absence
        # -- assume it was all deducted, which taxes the account more, not less.
        def missing_facts(subject)
          facts = formula.needs.reject { |fact| subject.public_send(fact) }

          # The one base whose requirement this table cannot state: it needs
          # the payments in *or* the cost basis, and Formula::BASES has no way
          # to say "or". Without this the account would sail through the check
          # above, reach #amount_for with nothing to measure against, have its
          # only term skipped as nil, and come out of #evaluate reading "not
          # taxed on liquidation" -- a refusal wearing the words of an
          # exemption, which is the worst sentence this module could print.
          if uses_plus_value? && subject.plus_value_base.first.nil?
            facts += [ :paid_in ]
          end

          facts.uniq
        end

        def uses_plus_value?
          formula.terms.any? { |t| PLUS_VALUE_BASES.include?(t.base) }
        end

        def refuse_missing(subject, missing)
          words = missing.map { |f| msg("facts.#{f}") }

          refuse(
            subject,
            reason: msg("composed.missing_facts",
                        bases: plain_english_bases,
                        facts: words),
            needs: words,
            missing: missing,
            extra_warnings: missing.include?(:paid_in) ? cost_basis_footnote(subject) : []
          )
        end

        # A formula that does not add up is reported as a refusal rather than
        # raised. The row is already stored by the time anyone finds out, and
        # taking down the whole report because one account has a bad rule would
        # hide every figure that is fine.
        def refuse_invalid(subject, rates)
          problems = formula.errors(known_rates: rates.rate_names)

          result(
            subject,
            taxable_base: nil,
            tax: nil,
            basis: msg("base.cannot_be_computed"),
            modelled: false,
            warnings: [
              msg("composed.invalid_formula", problems: problems),
              *cost_basis_footnote(subject)
            ]
          )
        end

        # The deducted portion, with absence read the expensive way.
        def resolve_deducted(subject, warnings)
          return nil unless uses_plus_value? || formula.terms.any? { |t| t.base.start_with?("paid_in") }

          paid_in = capital(subject)
          declared = subject.paid_in_deducted

          if declared.nil?
            return paid_in unless uses_deduction_split?

            warnings << msg("composed.no_deducted_portion")
            paid_in
          elsif declared > paid_in
            warnings << msg("composed.deducted_exceeds_total",
                            declared: amount(declared),
                            paid_in: amount(paid_in))
            paid_in
          else
            declared
          end
        end

        # What a deduction splits.
        #
        # A `paid_in_*` term splits the versements and nothing else, because a
        # rule that names them has said it wants that exact figure. A
        # `plus_value_base_deducted` term splits whatever the gain was measured
        # against, which is the versements where they exist and the cost basis
        # where they do not -- and it has to be the same figure the gain used,
        # or the two terms stop summing to the value and the account is taxed
        # on more or less than it holds.
        def capital(subject)
          return subject.plus_value_base.first if uses_plus_value?

          subject.paid_in
        end

        def uses_deduction_split?
          formula.terms.any? { |t| DEDUCTION_SPLIT_BASES.include?(t.base) }
        end

        # Whether the wrapper has passed its clock, and what to say when nobody
        # knows.
        #
        # An undeclared opening date is treated as mature -- but only after
        # working out what the bill would be either way and putting both
        # numbers in front of the reader. Assuming silently in either direction
        # would be picking a number on the household's behalf; assuming out
        # loud, with the alternative stated, is the most this rule can honestly
        # do with the facts it has.
        def resolve_maturity(subject, on:, rates:, assumptions:, deducted:, warnings:)
          return true unless formula.uses_clock?

          years = maturity_years_for(subject, rates)
          age = subject.age_years_at(on)

          if age.nil?
            # A lower bound can prove the clock has run, and where it does
            # there is nothing left to assume and nothing to ask for. Same
            # treatment as Rules::Fr::Pea, deliberately: a custom rule with a
            # clock should behave like the built-in one with a clock, or the
            # rules screen is offering something subtly different from what it
            # appears to be offering.
            floor = subject.minimum_age_years_at(on)
            if floor && floor >= years
              warnings << msg("composed.known_since",
                              since: subject.known_since,
                              years: years)
              return true
            end

            as_mature = evaluate(subject, mature: true, on: on, rates: rates,
                                 assumptions: assumptions, deducted: deducted)
            as_young  = evaluate(subject, mature: false, on: on, rates: rates,
                                 assumptions: assumptions, deducted: deducted)

            # See Rules::Fr::Pea for why there are two sentences here rather
            # than one. A floor Sure supplied and this rule could not use has
            # to be named, or the reader goes looking for the date they already
            # entered and concludes the module cannot see it.
            clock = {
              years: years,
              mature_tax: amount(cents(as_mature[:tax])),
              young_tax: amount(cents(as_young[:tax]))
            }

            warnings << if subject.known_since
              msg("composed.opening_date_floor_only",
                  **clock, since: subject.known_since)
            else
              msg("composed.no_opening_date", **clock)
            end
            return true
          end

          mature = age >= years
          unless mature
            warnings << msg("composed.immature",
                            age: age.round(1),
                            years: years)
          end

          mature
        end

        # The rate file wins over the formula, exactly as it does in
        # Rules::Fr::Pea, and for the same reason: a self-hoster who corrects
        # the statutory clock for a product should be obeyed by every rule that
        # reads it, not only by the hand-written ones.
        #
        # The declared figure is the fallback and is what the settings screen
        # prints. The two agree in the shipped file; they are allowed to
        # disagree, and when they do the file is the one that ran. Sourcing the
        # number from the same place in both is what stops the equivalence test
        # from passing on the shipped rates and lying about an edited table.
        def maturity_years_for(subject, rates)
          declared = formula.maturity_years
          return declared if subject.product.nil?

          rates.maturity_years(subject.product) || declared
        end

        def evaluate(subject, mature:, on:, rates:, assumptions:, deducted:)
          base_total      = zero
          tax_total       = zero
          household_total = zero
          sentences       = []

          formula.terms.each do |term|
            next unless fires?(term, mature, subject)

            taxed = amount_for(term, subject, deducted)
            next if taxed.nil?

            rate = rate_for(term, rates, on, assumptions)
            due  = taxed * rate

            # The household rate gets its own key rather than a bare
            # percentage. The reader has to be able to tell which line of the
            # calculation is theirs to correct, and "30.0% on 40000" beside
            # "12.8% on 5000" gives them no way to.
            sentences << if term.household_rate?
              household_total += taxed
              msg("composed.term_household_rate",
                  rate: percent(rate), amount: amount(taxed), tax: amount(cents(due)))
            else
              msg("composed.term",
                  rate: percent(rate), amount: amount(taxed), tax: amount(cents(due)))
            end

            base_total += taxed
            tax_total  += due
          end

          {
            base: base_total,
            tax: tax_total,
            household_rate_income: household_total,
            basis: if sentences.empty?
                     msg("composed.not_taxed_on_liquidation")
                   else
                     # "plus", not "and": these are addends, and a reader adding them
                     # up has to be able to see that they add.
                     msg("composed.basis", terms: Message::List.new(sentences, connector: "plus"))
                   end
          }
        end

        # Two independent gates, and a term has to pass both.
        #
        # The clock asks how old the wrapper is now; the vintage asks when it
        # was opened. A PEA opened in 2014 is mature *and* of the 2013-2017
        # vintage, and a rule may well want to say something that is true only
        # of both at once.
        #
        # `covers_opening?` is given the declared date, which is guaranteed
        # present here: a term with a window declares :opened_on in its `needs`,
        # so the rule has already refused the account if it is missing.
        def fires?(term, mature, subject)
          return false unless term.covers_opening?(subject.opened_on)

          case term.condition
          when "mature"   then mature
          when "immature" then !mature
          else true
          end
        end

        def amount_for(term, subject, deducted)
          case term.base
          when "full_value"            then subject.value
          when "gain_over_paid_in"     then subject.gain_against(subject.paid_in)
          when "gain_over_cost_basis"  then subject.gain_against(subject.cost_basis)
          when "paid_in"               then subject.paid_in
          when "paid_in_deducted"      then deducted
          when "paid_in_not_deducted"  then subject.paid_in - deducted
          when "plus_value"            then subject.plus_value
          when "plus_value_base_deducted" then deducted
          end
        end

        # One lookup, three sources, and no list of French rate names.
        #
        # `call` has already refused the account if a term names a rate this
        # country's file does not define, so by the time anything reaches here
        # the name resolves. That check is what lets this be a plain lookup
        # rather than a case statement that would need an opinion about a rate
        # it does not recognise -- and it is what stops an unrecognised rate
        # from quietly becoming zero.
        def rate_for(term, rates, on, assumptions)
          return term.literal_rate if term.literal?
          return assumptions.marginal_rate if term.household_rate?

          rates.rate(term.rate, on)
        end

        def plain_english_bases
          to_sentence(formula.terms.map { |t| Vocabulary.base(t.base) }.uniq)
        end

        def to_sentence(items)
          Vocabulary.to_sentence(items)
        end
    end
  end
end
