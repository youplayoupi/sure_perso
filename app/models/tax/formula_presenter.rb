# frozen_string_literal: true

module Tax
  # A formula, rendered for a reader.
  #
  # This is the other half of the bargain Tax::Formula makes. Storing a rule's
  # arithmetic as data rather than as code is only worth the trouble if the
  # data gets shown, and shown in a form that settles the question the reader
  # actually has: not "which rule is attached to this account" but "what will
  # it do to my money, and at what rate, today".
  #
  # So the presenter resolves. A term says `social_charges`; the screen says
  # 17.2%, because that is the figure in force on the valuation date in the
  # rate table this family is actually using -- corrections and all. A term
  # says `condition: mature`; the screen says "once the plan is 5 years old",
  # with the 5 taken from the same place the rule will take it from when it
  # runs. The alternative is a page that prints the vocabulary back at the
  # reader, which tells them what the module's internals are called and nothing
  # about their tax.
  #
  # Two things it deliberately does not do.
  #
  # It does not translate. The engine writes English -- its refusals and its
  # `basis` sentences already do -- and translation happens at the view edge in
  # TaxReportsHelper, which is allowed to know what language it is rendering
  # in. Keeping this file plain Ruby means the rules page can be tested in the
  # same bare process as the arithmetic it describes.
  #
  # And it does not compute tax. Every number here is a rate or a threshold,
  # never a sum of money. If the reader wants to know what a rule does to a
  # particular account, that is the report, which runs the rule properly
  # against real facts. A presenter that guessed at amounts would be a second
  # implementation of the engine, and the two would diverge.
  class FormulaPresenter
    # One term, resolved. `sentence` is the whole line as prose; the parts are
    # exposed beside it so a table can lay them out in columns instead.
    Line = Struct.new(
      :base, :rate, :percent, :progressive, :condition, :window, :sentence,
      keyword_init: true
    ) do
      def progressive? = !!progressive

      # True when the rate is named in the rate file but could not be read on
      # this date -- the file has no entry that early, typically. The line
      # still renders, naming the rate without a number, because "social
      # charges, rate unknown for 2011" is honest and dropping the line
      # silently is not.
      def unresolved? = !progressive? && percent.nil?
    end

    attr_reader :formula, :rates, :on, :product

    # `rates` may be nil. The settings page renders formulas for countries
    # whose rate file this module does not ship, and a page that raised rather
    # than printing "social charges" without a percentage would be a worse
    # answer than the one it refused to give.
    def initialize(formula, rates: nil, on: Date.today, product: nil)
      @formula = formula || Formula.new
      @rates = rates
      @on = on
      @product = product
    end

    def empty? = formula.empty?

    def valid? = formula.valid?

    def errors = formula.errors

    def notes = formula.notes

    def stacks? = formula.stacks?

    def uses_clock? = formula.uses_clock?

    def uses_vintage? = formula.uses_vintage?

    # The clock the rule will actually use, which is not always the one the
    # formula declares.
    #
    # Rules::Composed#maturity_years_for prefers the rate file when the account
    # names a product, so that a self-hoster who corrects the statutory period
    # is obeyed. This has to resolve it the same way and from the same place,
    # or the page would print 5 while the engine ran 8 -- the exact failure the
    # formula abstraction exists to prevent, reintroduced one layer up.
    def maturity_years
      declared = formula.maturity_years
      return declared if rates.nil? || product.nil?

      rates.maturity_years(product) || declared
    end

    def lines
      @lines ||= formula.terms.map { |term| line_for(term) }
    end

    # One sentence for the whole rule, for a list row or a page heading.
    #
    # An empty formula gets a sentence of its own rather than an empty string,
    # because "nothing" is a real answer here and one a reader is entitled to
    # see stated. A livret and an account nobody has written a rule for both
    # produce no terms; only one of them means the tax is zero.
    def headline
      return "Nothing is taxed when this account is liquidated." if empty?

      "Tax is #{Vocabulary.to_sentence(lines.map(&:sentence))}."
    end

    # The facts an account has to carry before this rule will compute, in the
    # same words the refusal uses when one is missing.
    def needs
      formula.needs.map { |fact| Vocabulary.fact(fact) }
    end

    def needs_sentence
      return nil if needs.empty?

      "Needs #{Vocabulary.to_sentence(needs)}."
    end

    private
      def line_for(term)
        percent = percent_for(term)

        Line.new(
          base: Vocabulary.base(term.base),
          rate: rate_label(term, percent),
          percent: percent,
          progressive: term.progressive?,
          condition: condition_label(term),
          window: window_label(term),
          sentence: sentence_for(term, percent)
        )
      end

      # The resolved rate as a fraction, or nil when there is no single number
      # to give: the progressive scale, a rate table this page does not have,
      # or a date the table does not reach back to.
      def percent_for(term)
        return term.literal_rate if term.literal?
        return nil if term.progressive?
        return nil if rates.nil?

        case term.rate
        when "social_charges"            then rates.social_charges(on)
        when "flat_tax"                  then rates.flat_tax(on)
        when "flat_tax_income_component" then rates.flat_tax_income_component(on)
        end
      rescue Error
        nil
      end

      # "17.2% social charges", "30.0% (the flat tax)", "the progressive
      # income-tax scale".
      #
      # A literal rate is its own label -- naming it "a fixed rate" alongside
      # the number would be saying the same thing twice -- while a named rate
      # keeps its name beside the figure, because 17.2% means nothing on its
      # own and "social charges" is what the reader will look up.
      def rate_label(term, percent)
        return Vocabulary.rate(term.rate) if term.progressive?
        return percentage(percent) if term.literal?
        return Vocabulary.rate(term.rate) if percent.nil?

        "#{percentage(percent)} #{Vocabulary.rate(term.rate)}"
      end

      def condition_label(term)
        years = maturity_years
        clock = years ? "#{years} years old" : "mature"

        case term.condition
        when "mature"   then "once the account is #{clock}"
        when "immature" then "while the account is under #{years || 'the maturity period'} years old"
        end
      end

      def window_label(term)
        return nil unless term.vintage?

        from = Vocabulary.date(term.opened_from)
        till = Vocabulary.date(term.opened_until)

        if from && till then "for accounts opened between #{from} and #{till}"
        elsif from       then "for accounts opened on or after #{from}"
        elsif till       then "for accounts opened on or before #{till}"
        else                  "for accounts whose opening window cannot be read"
        end
      end

      # The clauses are ordered the way the sentence is read rather than the
      # way the term is stored: what is taxed, at what rate, and then the two
      # narrowings that say when the line applies at all.
      #
      # Three shapes, because a percentage and a name do not sit in a sentence
      # the same way. "31.4% flat tax on the gain" leads with the number, which
      # is what the reader came for; the scale and the unresolved rate have no
      # number to lead with, so they put the base first and the rate after it.
      def sentence_for(term, percent)
        base = Vocabulary.base(term.base)

        head =
          if term.progressive?
            "the #{Vocabulary.rate(term.rate)} on #{base}"
          elsif percent.nil?
            "#{base} at the #{Vocabulary.rate(term.rate)} rate"
          else
            "#{rate_label(term, percent)} on #{base}"
          end

        [ head, condition_label(term), window_label(term) ].compact.join(", ")
      end

      # One decimal place where one will do, so that 18.6% and 30.0% line up in
      # the same column instead of reading as a typo. A rate that needs more --
      # a literal somebody typed by hand -- is shown in full rather than
      # rounded, because a rate someone entered is a rate they meant, and a
      # page that quietly turned 7.25% into 7.3% would be lying about the
      # number it is about to use.
      #
      # Kept in BigDecimal throughout. `format("%.1f", ...)` would go through
      # Float, which is the one type this module does not let near a rate.
      def percentage(fraction)
        return nil if fraction.nil?

        value = fraction * 100
        tenth = value.round(1)

        "#{(value == tenth ? tenth : value.round(4)).to_s('F')}%"
      end
  end
end
