# frozen_string_literal: true

module Tax
  # What a rule does, as data rather than as code.
  #
  # A formula is an ordered list of terms, each of which multiplies some base
  # drawn from the account by some rate drawn from the rate table, optionally
  # only when the wrapper has passed its maturity date. The tax is the sum.
  #
  # It exists for two reasons that turned out to be the same reason.
  #
  # The first is display. A rule written in Ruby can only be read by opening
  # the file, which means the screen that says "PEA (gain net, 5-year clock)"
  # is asking to be taken on trust. A formula can be rendered: the base, the
  # rate actually in force on the valuation date, and the condition, in the
  # reader's own language.
  #
  # The second is authoring. A family whose product this module has no rule for
  # can assemble one from the same terms, stored as data in
  # `tax_custom_rules.params` and executed by Rules::Composed. Note what is
  # absent: there is no expression to parse and nothing to evaluate. A term
  # chooses from two closed lists, so a stored formula is either valid or
  # rejected at write time, and the worst a corrupted row can produce is a
  # wrong number arrived at by arithmetic this file can perform.
  #
  # The two uses check each other. Every built-in declares its formula, and
  # test/models/tax/formula_equivalence_test.rb asserts that running the
  # declared formula gives the same tax, to the cent, as the hand-written rule
  # across a matrix of accounts. Change Rules::Fr::Pea's arithmetic without
  # changing its formula and that test fails -- which is what stops the
  # explanation on screen from drifting away from the number beside it.
  class Formula
    # Where the money a term taxes comes from.
    #
    # Each entry names the facts it cannot do without. A term whose facts are
    # missing does not guess and does not fall back to a near-miss; the rule
    # refuses the whole account, which is the same thing the hand-written rules
    # do and for the same reason.
    BASES = {
      # The entire balance. Rare, and deliberately so -- most wrappers tax a
      # gain -- but it is what a withdrawal from a fully deducted pension pot
      # looks like.
      "full_value" => { needs: [] },

      # Value minus everything ever paid in. This is the French gain net, and
      # it is the base almost every wrapper actually uses.
      "gain_over_paid_in" => { needs: [ :paid_in ] },

      # Value minus what the securities currently held cost. Not the same
      # number as the one above, and not interchangeable with it: sell and
      # rebuy inside a wrapper and cost basis resets upward while payments in
      # do not. Right for an ordinary securities account, wrong for a PEA.
      "gain_over_cost_basis" => { needs: [ :cost_basis ] },

      # The payments themselves rather than the growth on them.
      "paid_in" => { needs: [ :paid_in ] },

      # The portion of those payments that was deducted from taxable income on
      # the way in, and therefore becomes taxable on the way out. Undeclared
      # means "assume all of it", which is the higher-tax reading; see
      # Rules::Composed#deducted.
      "paid_in_deducted" => { needs: [ :paid_in ] },

      # Payments that were made without taking the deduction, which come back
      # untaxed. Present so that a formula can state that explicitly rather
      # than by omission.
      "paid_in_not_deducted" => { needs: [ :paid_in ] }
    }.freeze

    # What a term multiplies its base by.
    #
    # The named rates are looked up in the rate table at the valuation date, so
    # a formula written today keeps giving the right answer for a 2025
    # valuation after the 2026 rates land. A literal is stored on the term
    # itself and is the escape hatch for a rate this module does not track.
    RATES = %w[
      social_charges
      flat_tax
      flat_tax_income_component
      progressive
      literal
    ].freeze

    # `progressive` is not a rate at all -- it is the income-tax scale, where
    # the amount due depends on what else the household is liquidating that
    # year. It is the only kind that cannot be printed as a percentage, the
    # only one that stacks across accounts, and the only one routed through
    # Assumptions rather than RateTable.
    PROGRESSIVE = "progressive"

    CONDITIONS = %w[always mature immature].freeze

    # One line of the calculation.
    class Term
      attr_reader :base, :rate, :literal_rate, :condition

      def initialize(base:, rate:, literal_rate: nil, condition: "always")
        @base = base.to_s
        @rate = rate.to_s
        @literal_rate = literal_rate.nil? ? nil : BigDecimal(literal_rate.to_s)
        @condition = condition.to_s
        freeze
      end

      def self.from(hash)
        h = hash.transform_keys(&:to_s)
        new(
          base: h["base"],
          rate: h["rate"],
          literal_rate: h["literal_rate"],
          condition: h["condition"] || "always"
        )
      end

      def to_h
        { "base" => base, "rate" => rate, "condition" => condition }.tap do |h|
          h["literal_rate"] = literal_rate.to_s("F") if literal?
        end
      end

      def literal? = rate == "literal"

      def progressive? = rate == PROGRESSIVE

      def conditional? = condition != "always"

      def needs = BASES.fetch(base, { needs: [] })[:needs]

      # Collected rather than raised on, so that a form can show every problem
      # at once and a row written by a future version of this module degrades
      # to a refusal instead of an exception.
      def errors
        problems = []
        problems << "unknown base #{base.inspect}" unless BASES.key?(base)
        problems << "unknown rate #{rate.inspect}" unless RATES.include?(rate)
        problems << "unknown condition #{condition.inspect}" unless CONDITIONS.include?(condition)
        problems << "a literal rate needs a percentage" if literal? && literal_rate.nil?
        problems << "a percentage belongs only on a literal rate" if !literal? && !literal_rate.nil?

        if literal? && literal_rate && (literal_rate.negative? || literal_rate > 1)
          problems << "a rate of #{literal_rate.to_s('F')} is not between 0 and 1"
        end

        problems
      end
    end

    attr_reader :terms, :maturity_years, :notes

    # `maturity_years` is only meaningful when some term is conditional on it.
    # Kept on the formula rather than on the term because a wrapper has one
    # clock, and two terms disagreeing about when it strikes would be a bug
    # with no sensible reading.
    def initialize(terms: [], maturity_years: nil, notes: [])
      @terms = Array(terms).map { |t| t.is_a?(Term) ? t : Term.from(t) }.freeze
      @maturity_years = maturity_years&.to_i
      @notes = Array(notes).map(&:to_s).freeze
      freeze
    end

    def self.from(hash)
      return new if hash.nil?

      h = hash.transform_keys(&:to_s)
      new(
        terms: Array(h["terms"]),
        maturity_years: h["maturity_years"],
        notes: Array(h["notes"])
      )
    end

    def to_h
      { "terms" => terms.map(&:to_h) }.tap do |h|
        h["maturity_years"] = maturity_years if maturity_years
        h["notes"] = notes if notes.any?
      end
    end

    # A formula with no terms is not an error -- it is how "this is genuinely
    # untaxed" is written, and Rules::Exempt and Rules::Fr::Deposit are both
    # exactly that.
    def empty? = terms.empty?

    def uses_clock? = terms.any?(&:conditional?)

    def stacks? = terms.any?(&:progressive?)

    # Every account fact this formula cannot do without, across all its terms.
    def needs
      terms.flat_map(&:needs).uniq
    end

    def errors
      problems = terms.each_with_index.flat_map do |term, index|
        term.errors.map { |e| "term #{index + 1}: #{e}" }
      end

      if uses_clock? && maturity_years.nil?
        problems << "a term depends on the maturity clock but no maturity period is set"
      end

      if maturity_years && !maturity_years.positive?
        problems << "the maturity period must be a positive number of years"
      end

      problems
    end

    def valid? = errors.empty?
  end
end
