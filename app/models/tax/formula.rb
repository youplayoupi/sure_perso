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
  # test/models/tax/formula_test.rb asserts that running the
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
    #
    # `optional:` is the other half of that sentence, and it exists for the
    # form rather than for the arithmetic. A fact listed there has a defensible
    # reading when absent -- so the rule computes without it -- but supplying it
    # changes the answer. The distinction is what lets the profile form ask a
    # PER for its deducted portion and ask a Livret A for nothing at all,
    # instead of asking every account for everything and leaving the reader to
    # work out which boxes were meant for them.
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
      "paid_in_deducted" => { needs: [ :paid_in ], optional: [ :paid_in_deducted ] },

      # Payments that were made without taking the deduction, which come back
      # untaxed. Present so that a formula can state that explicitly rather
      # than by omission.
      "paid_in_not_deducted" => { needs: [ :paid_in ], optional: [ :paid_in_deducted ] },

      # The gain, measured against the payments in where they were declared
      # and against what the holdings cost where they were not. See
      # Tax::Subject#plus_value_base for which is which and why the second is
      # a floor rather than an answer.
      #
      # `needs: []` looks like a claim that this base can always be computed,
      # and it is not one: it needs *one of* two facts, which is a shape this
      # table cannot express and Rules::Composed#missing_facts checks for
      # separately. What the empty list buys is the thing the whole of this
      # part is for -- a wrapper with neither fact declared still refuses,
      # while a wrapper with only the cost basis gets a number instead of a
      # blank row.
      #
      # `paid_in` is optional in the strict sense the comment above gives it:
      # the rule reaches an answer without it, and supplying it changes that
      # answer. That is exactly the entry that puts a "refine this" link on a
      # row whose figure already stands.
      "plus_value" => { needs: [], optional: [ :paid_in ] },

      # The part of that same base that was deducted from taxable income on
      # the way in. Stands to `plus_value` as `paid_in_deducted` stands to
      # `gain_over_paid_in`, and pairs with it: a wrapper taxed on both is
      # taxed on its whole value between the two terms, which is what makes
      # the cost basis an acceptable stand-in here at all. Substituting it
      # into the gain term alone would move money out of the household's rate
      # and into the flat tax, which is a discount this module has no business
      # granting.
      "plus_value_base_deducted" => { needs: [], optional: [ :paid_in, :paid_in_deducted ] }
    }.freeze

    # The two rates that do not come from a country's rate file.
    #
    # Everything else a term may name is a section of that file --
    # `social_charges`, `flat_tax` -- looked up at the valuation date, so a
    # formula written today keeps giving the right answer for a 2025 valuation
    # after the 2026 rates land. Those names are not listed here on purpose:
    # they belong to the country, and hard-coding France's set is exactly what
    # would stop a second country's file from working. `known_rates:` below is
    # how a caller that has the table checks a name against it.
    #
    # The household's own marginal rate of income tax, set under Taxes. Routed
    # through Assumptions rather than RateTable because it is an assertion by
    # the household, not a figure the country publishes -- and it is the one
    # rate the report has to keep flagging as such.
    HOUSEHOLD_RATE = "household_rate"

    # A rate stored on the term itself. The escape hatch for a rate this
    # module does not track.
    LITERAL = "literal"

    BUILT_IN_RATES = [ HOUSEHOLD_RATE, LITERAL ].freeze

    # `progressive` was what `household_rate` used to be called, back when it
    # meant "run the income-tax scale" rather than "apply the rate you told us".
    # Rules stored under the old name are read as the new one rather than
    # refused: the arithmetic they asked for is the arithmetic they now get,
    # and refusing a household's saved PER rule on upgrade to make a point
    # about vocabulary would be the module failing at its actual job. The new
    # spelling is what gets written back on the next save.
    RATE_ALIASES = { "progressive" => HOUSEHOLD_RATE }.freeze

    # A name that could be a section of some country's rate file. Used only
    # when no table is at hand to check against; see `errors`.
    RATE_NAME = /\A[a-z][a-z0-9_]*\z/

    CONDITIONS = %w[always mature immature].freeze

    # One line of the calculation.
    #
    # A term can be narrowed two ways, and they are different in kind:
    #
    #   `condition`                the maturity clock. Relative: how old is
    #                              this wrapper on the valuation date. The PEA
    #                              five-year mark is this.
    #
    #   `opened_from`/`opened_until`   the vintage. Absolute: when was the
    #                              wrapper opened, regardless of its age now.
    #                              French tax is full of these -- a PEA opened
    #                              between 2013 and 2017 keeps the social-charge
    #                              rates in force as each year's gain arose, and
    #                              an assurance-vie signed before 27 September
    #                              2017 is taxed on terms withdrawn for contracts
    #                              signed after it.
    #
    # Both may narrow the same term. Neither implies the other: a plan opened
    # in 2014 is old enough to be mature and is also of a particular vintage,
    # and those two facts select different terms.
    #
    # A term with a vintage window needs the opening date the way a term over
    # the gain needs the payments in, so it says so through the same `needs`
    # channel and the rule refuses the account when it is missing. There is no
    # defensible guess: assuming a wrapper falls inside the window taxes it one
    # way, assuming outside taxes it another, and nothing about a null date
    # favours either.
    class Term
      attr_reader :base, :rate, :literal_rate, :condition, :opened_from, :opened_until

      def initialize(base:, rate:, literal_rate: nil, condition: "always",
                     opened_from: nil, opened_until: nil)
        @base = base.to_s
        @rate = RATE_ALIASES.fetch(rate.to_s, rate.to_s)
        @condition = condition.to_s

        # The raw values are kept beside the parsed ones so that unreadable
        # input survives a round trip through storage. Dropping it would make
        # the formula look valid the second time it was loaded, which is how a
        # rejected edit quietly becomes an accepted one.
        #
        # Parsed leniently, too, and for a stronger reason than tidiness. This
        # constructor runs over stored data -- on the report, for every account
        # -- and `BigDecimal("abc")` raises. A row with junk in it has to
        # degrade to a refusal the way every other bad input here does, because
        # the alternative is one corrupt rule taking down a page of figures
        # that are all fine.
        @literal_rate_raw = presence(literal_rate)
        @literal_rate = to_rate(@literal_rate_raw)

        @opened_from_raw = presence(opened_from)
        @opened_until_raw = presence(opened_until)
        @opened_from = to_date(@opened_from_raw)
        @opened_until = to_date(@opened_until_raw)
        freeze
      end

      def self.from(hash)
        h = hash.transform_keys(&:to_s)
        new(
          base: h["base"],
          rate: h["rate"],
          literal_rate: h["literal_rate"],
          condition: h["condition"] || "always",
          opened_from: h["opened_from"],
          opened_until: h["opened_until"]
        )
      end

      # Keyed on the raw value rather than on `literal?`, so that a rate typed
      # into the wrong box comes back on reload and the error naming it comes
      # back with it. Emitting only what the term turned out to need would let
      # a rejected edit validate cleanly the second time it was loaded.
      def to_h
        { "base" => base, "rate" => rate, "condition" => condition }.tap do |h|
          h["literal_rate"] = literal_rate&.to_s("F") || @literal_rate_raw.to_s if @literal_rate_raw
          h["opened_from"] = @opened_from_raw.to_s if @opened_from_raw
          h["opened_until"] = @opened_until_raw.to_s if @opened_until_raw
        end
      end

      def literal? = rate == LITERAL

      # Taxed at the rate the household declared, rather than at one the
      # country publishes. The only kind of term that cannot be printed as a
      # percentage without saying whose percentage it is.
      def household_rate? = rate == HOUSEHOLD_RATE

      # A rate this term expects to find in the country's rate file.
      def named_rate? = !literal? && !household_rate?

      def conditional? = condition != "always"

      # Bounded on either side. Half-open is the common case: "opened before
      # 2018" is a window with no start.
      def vintage? = !@opened_from_raw.nil? || !@opened_until_raw.nil?

      # Inclusive at both ends, because a statutory window is written as dates
      # people can be on. "From 2013-01-01 to 2017-12-31" has to include both.
      #
      # An unreadable bound makes the whole formula invalid, so a rule never
      # reaches this with one. If some future caller does, a window nobody can
      # read matches nothing rather than everything -- refusing to fire is the
      # direction that cannot quietly under-tax.
      def covers_opening?(opened_on)
        return true unless vintage?
        return false if opened_on.nil?
        return false unless bounds_readable?
        return false if opened_from && opened_on < opened_from
        return false if opened_until && opened_on > opened_until

        true
      end

      def needs
        facts = BASES.fetch(base, { needs: [] })[:needs]
        vintage? ? (facts + [ :opened_on ]).uniq : facts
      end

      # Facts this term can do without and would rather have. Never overlaps
      # `needs`: a fact is either refused for or assumed about, not both.
      def optional_needs
        BASES.fetch(base, {}).fetch(:optional, [])
      end

      # Collected rather than raised on, so that a form can show every problem
      # at once and a row written by a future version of this module degrades
      # to a refusal instead of an exception.
      def errors(known_rates: nil)
        problems = []
        problems << "unknown base #{base.inspect}" unless BASES.key?(base)
        problems.concat(rate_name_errors(known_rates))
        problems << "unknown condition #{condition.inspect}" unless CONDITIONS.include?(condition)
        problems << "a literal rate needs a percentage" if literal? && @literal_rate_raw.nil?
        problems << "a percentage belongs only on a literal rate" if !literal? && !@literal_rate_raw.nil?

        if @literal_rate_raw && literal_rate.nil?
          problems << "#{@literal_rate_raw.to_s.strip.inspect} is not a number"
        end

        if literal? && literal_rate && (literal_rate.negative? || literal_rate > 1)
          problems << "a rate of #{literal_rate.to_s('F')} is not between 0 and 1"
        end

        problems.concat(vintage_errors)
        problems
      end

      private
        # Checked against the country's own rate names when the caller has
        # them, and only for shape when it does not.
        #
        # The distinction matters because getting it wrong is silent in one
        # direction: a term naming "social_charge" would save cleanly, then
        # refuse the account months later on a report nobody was watching.
        # Every caller inside the app has a rate table -- the rule builder, the
        # settings controller, Rules::Composed -- so in practice the strict
        # branch is the one that runs, and the loose one exists so that a
        # formula can still be parsed and displayed with no country in hand.
        def rate_name_errors(known_rates)
          return [] if BUILT_IN_RATES.include?(rate)

          if known_rates.nil?
            return [] if RATE_NAME.match?(rate)

            return [ "unknown rate #{rate.inspect}" ]
          end

          return [] if Array(known_rates).map(&:to_s).include?(rate)

          [ "unknown rate #{rate.inspect}" ]
        end

        def bounds_readable?
          (@opened_from_raw.nil? || !opened_from.nil?) &&
            (@opened_until_raw.nil? || !opened_until.nil?)
        end

        def vintage_errors
          problems = []
          problems << "'opened from' is not a date" if @opened_from_raw && opened_from.nil?
          problems << "'opened until' is not a date" if @opened_until_raw && opened_until.nil?

          if opened_from && opened_until && opened_from > opened_until
            problems << "the opening window ends (#{opened_until}) before it starts " \
                        "(#{opened_from}), so no account could ever fall inside it"
          end

          problems
        end

        def presence(value)
          value.nil? || value.to_s.strip.empty? ? nil : value
        end

        # Returns nil rather than raising, so an unreadable rate is one more
        # line in `errors` beside the unreadable dates instead of an exception
        # thrown from inside a loop over every account on the report.
        def to_rate(value)
          return nil if value.nil?
          return value if value.is_a?(BigDecimal)

          BigDecimal(value.to_s.strip)
        rescue ArgumentError, TypeError
          nil
        end

        # Returns nil rather than raising, so an unreadable date is one more
        # line in `errors` beside the others instead of a 500 on a form someone
        # was halfway through. `vintage_errors` tells the two nils apart by
        # looking at the raw value.
        #
        # Date.parse is not used on its own because it is generous: "2026" and
        # "1 Jan" both succeed and neither is what the author typed. The rate
        # file writes plain ISO dates and so does the form.
        def to_date(value)
          return nil if value.nil?
          return value if value.is_a?(Date)

          text = value.to_s.strip
          return nil unless /\A\d{4}-\d{2}-\d{2}\z/.match?(text)

          Date.parse(text)
        rescue ArgumentError, TypeError
          nil
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

    # Whether any term is narrowed to a range of opening dates. Distinct from
    # `uses_clock?`: one asks how old the wrapper is, the other asks when it
    # was opened, and a rule can use either, both or neither.
    def uses_vintage? = terms.any?(&:vintage?)

    # Whether any term rests on the rate the household declared, and therefore
    # on the one figure in the calculation that Sure did not get from a
    # published source.
    def uses_household_rate? = terms.any?(&:household_rate?)

    # Every account fact this formula cannot do without, across all its terms.
    def needs
      terms.flat_map(&:needs).uniq
    end

    # Facts that change the answer without being required to reach one.
    #
    # `opened_on` is here rather than in `needs` whenever a term is on the
    # maturity clock, and the asymmetry with a vintage window is deliberate.
    # A window has no defensible default -- inside and outside are two
    # different taxes and a null date favours neither -- so a term with one
    # refuses. A clock does: Rules::Fr::Pea assumes a plan with no opening date
    # is mature, says so in a warning, and prints both figures. The opening
    # date is then worth asking for and not worth blocking on, which is exactly
    # what this list means.
    def optional_needs
      facts = terms.flat_map(&:optional_needs)
      facts << :opened_on if uses_clock?
      (facts - needs).uniq
    end

    def errors(known_rates: nil)
      problems = terms.each_with_index.flat_map do |term, index|
        term.errors(known_rates: known_rates).map { |e| "term #{index + 1}: #{e}" }
      end

      if uses_clock? && maturity_years.nil?
        problems << "a term depends on the maturity clock but no maturity period is set"
      end

      if maturity_years && !maturity_years.positive?
        problems << "the maturity period must be a positive number of years"
      end

      problems
    end

    def valid?(known_rates: nil) = errors(known_rates: known_rates).empty?
  end
end
