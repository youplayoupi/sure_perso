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
        return refuse_invalid(subject) unless formula.valid?

        missing = missing_facts(subject)
        return refuse_missing(subject, missing) if missing.any?

        warnings = []
        deducted = resolve_deducted(subject, warnings)
        mature   = resolve_maturity(subject, on: on, rates: rates, assumptions: assumptions,
                                    deducted: deducted, warnings: warnings)

        run = evaluate(subject, mature: mature, on: on, rates: rates,
                       assumptions: assumptions, deducted: deducted)

        warnings.concat(formula.notes)

        result(
          subject,
          taxable_base: run[:base],
          tax: cents(run[:tax]),
          basis: run[:basis],
          warnings: warnings,
          bareme_income: run[:bareme]
        )
      end

      private
        # A term needs a fact; the account either has it or the rule declines.
        # `paid_in_deducted` is the one exception and it is not an exception to
        # this: it needs `paid_in`, and the deducted portion on top of that is
        # allowed to be absent because there is a defensible reading of absence
        # -- assume it was all deducted, which taxes the account more, not less.
        def missing_facts(subject)
          formula.needs.reject { |fact| subject.public_send(fact) }
        end

        def refuse_missing(subject, missing)
          words = missing.map { |f| FACT_NAMES.fetch(f, f.to_s) }

          refuse(
            subject,
            reason: "This rule taxes #{plain_english_bases}, which needs " \
                    "#{to_sentence(words)}. That is not recorded for this account.",
            needs: to_sentence(words),
            extra_warnings: missing.include?(:paid_in) ? cost_basis_footnote(subject) : []
          )
        end

        # A formula that does not add up is reported as a refusal rather than
        # raised. The row is already stored by the time anyone finds out, and
        # taking down the whole report because one account has a bad rule would
        # hide every figure that is fine.
        def refuse_invalid(subject)
          result(
            subject,
            taxable_base: nil,
            tax: nil,
            basis: "cannot be computed",
            modelled: false,
            warnings: [
              "The custom rule set for this account does not describe a valid " \
              "calculation: #{to_sentence(formula.errors)}. Nothing is assumed in " \
              "its place -- fix the rule and this account will compute.",
              *cost_basis_footnote(subject)
            ]
          )
        end

        FACT_NAMES = {
          paid_in: "the total paid in",
          cost_basis: "the cost basis of what is held",
          opened_on: "the date the account was opened"
        }.freeze

        # The deducted portion, with absence read the expensive way.
        def resolve_deducted(subject, warnings)
          return nil unless formula.terms.any? { |t| t.base.start_with?("paid_in") }

          paid_in = subject.paid_in
          declared = subject.paid_in_deducted

          if declared.nil?
            return paid_in unless uses_deduction_split?

            warnings << "The deducted portion of the payments in is not declared, so all " \
                        "of them are assumed to have been deducted. That is the " \
                        "higher-tax assumption."
            paid_in
          elsif declared > paid_in
            warnings << "The declared deducted portion (#{declared.to_s('F')}) is more than " \
                        "the total paid in (#{paid_in.to_s('F')}). Capped at the total; one " \
                        "of the two figures is wrong."
            paid_in
          else
            declared
          end
        end

        def uses_deduction_split?
          formula.terms.any? { |t| t.base == "paid_in_deducted" || t.base == "paid_in_not_deducted" }
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
            as_mature = evaluate(subject, mature: true, on: on, rates: rates,
                                 assumptions: assumptions, deducted: deducted)
            as_young  = evaluate(subject, mature: false, on: on, rates: rates,
                                 assumptions: assumptions, deducted: deducted)

            warnings << "No opening date is declared, so the #{years}-year clock cannot be " \
                        "checked. Treated as mature, which gives " \
                        "#{cents(as_mature[:tax]).to_s('F')}; if it is not, the tax would be " \
                        "#{cents(as_young[:tax]).to_s('F')}."
            return true
          end

          mature = age >= years
          unless mature
            warnings << "This wrapper is #{age.round(1)} years old, under the #{years} it " \
                        "needs, so the terms that depend on the clock are taxed at the " \
                        "pre-maturity rate."
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
          base_total   = zero
          tax_total    = zero
          bareme_total = zero
          sentences    = []

          formula.terms.each do |term|
            next unless fires?(term, mature, subject)

            amount = amount_for(term, subject, deducted)
            next if amount.nil?

            if term.progressive?
              due = assumptions.income_tax_on(amount, rates: rates, on: on)
              bareme_total += amount if assumptions.bareme?
              sentences << format("progressive scale on %s (%s)", amount.to_s("F"), cents(due).to_s("F"))
            else
              rate = rate_for(term, rates, on)
              due = amount * rate
              sentences << format("%.1f%% on %s (%s)", rate * 100, amount.to_s("F"), cents(due).to_s("F"))
            end

            base_total += amount
            tax_total  += due
          end

          {
            base: base_total,
            tax: tax_total,
            bareme: bareme_total,
            basis: sentences.empty? ? "not taxed on liquidation" : sentences.join(" plus ")
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
          end
        end

        def rate_for(term, rates, on)
          case term.rate
          when "literal"                   then term.literal_rate
          when "social_charges"            then rates.social_charges(on)
          when "flat_tax"                  then rates.flat_tax(on)
          when "flat_tax_income_component" then rates.flat_tax_income_component(on)
          end
        end

        def plain_english_bases
          to_sentence(formula.terms.map { |t| BASE_WORDS.fetch(t.base, t.base) }.uniq)
        end

        BASE_WORDS = {
          "full_value" => "the whole balance",
          "gain_over_paid_in" => "the gain over what was paid in",
          "gain_over_cost_basis" => "the gain over cost basis",
          "paid_in" => "the payments in",
          "paid_in_deducted" => "the deducted payments in",
          "paid_in_not_deducted" => "the payments in that were not deducted"
        }.freeze

        # ActiveSupport's to_sentence would do, and is exactly the kind of
        # thing this engine may not reach for: it has to load into a bare Ruby
        # process. Three lines here is the price of that.
        def to_sentence(items)
          list = Array(items).map(&:to_s)
          return "" if list.empty?
          return list.first if list.one?

          "#{list[0..-2].join(', ')} and #{list.last}"
        end
    end
  end
end
