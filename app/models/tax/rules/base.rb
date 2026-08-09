# frozen_string_literal: true

module Tax
  module Rules
    # A rule is a pure function: (Subject, date, RateTable, Assumptions) -> Result.
    #
    # No rule may read the database, and no rule may write anything. Everything
    # a rule needs is on the Subject. That constraint is what makes the whole
    # engine testable without Rails and what guarantees the module cannot
    # change any of Sure's own numbers.
    class Base
      class << self
        # Stable identifier used in the coverage table and in stored custom
        # rules. Set explicitly rather than derived from the class name so that
        # renaming a class cannot silently invalidate stored data.
        def rule_id(value = nil)
          @rule_id = value if value
          @rule_id
        end

        def label(value = nil)
          @label = value if value
          @label || rule_id
        end

        # The arithmetic this rule performs, as data, for the screen that
        # explains it. Declaring it is optional -- a rule too irregular to fit
        # the shape says so by leaving it out, and the page then admits it
        # cannot show the workings rather than showing a simplified version
        # that is not what ran.
        #
        # Where it is declared it is not documentation, because
        # test/models/tax/formula_equivalence_test.rb runs it through
        # Rules::Composed and demands the same tax to the cent as the method
        # below. A formula that falls out of step with its rule fails the
        # build.
        def formula(spec = nil)
          @formula = Formula.from(spec) if spec
          @formula
        end
      end

      # Instance-level for convenience at call sites that hold a rule object
      # rather than a class. Rules::Composed overrides it: its formula is the
      # one it was handed, not one declared on the class.
      def formula
        self.class.formula
      end

      def call(subject, on:, rates:, assumptions:)
        raise NotImplementedError, "#{self.class} must implement #call"
      end

      def rule_id
        self.class.rule_id
      end

      private
        # Round to cents.
        #
        # Half-to-even rather than half-up, purely so that this engine and the
        # Python reference implementation it was ported from can be diffed to
        # the cent. Ties are vanishingly rare in practice; when one occurs the
        # two implementations agreeing is worth more than the convention.
        def cents(value)
          return nil if value.nil?

          value.round(2, half: :even)
        end

        def zero
          BigDecimal(0)
        end

        def result(subject, **attrs)
          Result.new(
            account_id: subject.id,
            account_name: subject.name,
            accountable_type: subject.accountable_type,
            subtype: subject.subtype,
            product: subject.product,
            currency: subject.currency,
            gross: subject.value,
            **attrs
          )
        end

        # The standard refusal. Used whenever a rule knows which arithmetic it
        # would do but is missing an input it is not willing to guess.
        def refuse(subject, reason:, needs:, extra_warnings: [])
          warnings = [ reason ]
          warnings << "Declare #{needs} for this account to compute it."
          warnings.concat(Array(extra_warnings))

          result(
            subject,
            taxable_base: nil,
            tax: nil,
            basis: "cannot be computed",
            warnings: warnings,
            modelled: false
          )
        end

        # Cost basis is offered as context on a refusal and never as a
        # substitute. Sell and rebuy inside a wrapper and cost basis resets
        # upward while payments in do not, so a tax figure derived from it
        # understates the bill. Saying the number out loud while refusing to
        # use it is more useful than hiding it.
        def cost_basis_footnote(subject)
          return [] if subject.cost_basis.nil?

          gain = subject.gain_against(subject.cost_basis)
          [
            "For reference only: cost basis is #{subject.cost_basis.to_s('F')} " \
            "giving a gain of #{gain.to_s('F')}. Cost basis is not the same as " \
            "money paid in and is not used here."
          ]
        end
    end
  end
end
