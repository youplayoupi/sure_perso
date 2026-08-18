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
  # It does not translate. Every phrase it produces is a Tax::Message -- a key
  # and its values -- exactly like the engine's refusals and `basis` sentences,
  # and translation happens at the view edge in TaxReportsHelper, which is
  # allowed to know what language it is rendering in. Keeping this file plain
  # Ruby means the rules page can be tested in the same bare process as the
  # arithmetic it describes.
  #
  # That is also why the clauses are assembled from keys rather than by
  # interpolation. "31.4% flat tax on the gain" puts the rate in front of the
  # base; a language that puts it after has to be able to say so, and a
  # `"#{rate} on #{base}"` here would have decided for it.
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
      :base, :rate, :percent, :household_rate, :condition, :window, :sentence,
      keyword_init: true
    ) do
      # The one rate this page cannot put a number on even in principle: it is
      # not in the country's file, it is what the household said about itself,
      # and the rules page describes a rule rather than a household.
      def household_rate? = !!household_rate

      # True when the rate is named in the rate file but could not be read on
      # this date -- the file has no entry that early, typically. The line
      # still renders, naming the rate without a number, because "social
      # charges, rate unknown for 2011" is honest and dropping the line
      # silently is not.
      def unresolved? = !household_rate? && percent.nil?

      # The two narrowings as one phrase, for the "when" column. Assembled here
      # rather than joined in the template: how two clauses run together is a
      # question about language, and a template is not where it gets answered.
      def when_clause
        parts = [ condition, window ].compact
        return nil if parts.empty?

        Message::List.new(parts, connector: nil)
      end
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

    def uses_household_rate? = formula.uses_household_rate?

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
      return Message.new("formula.nothing_taxed") if empty?

      Message.new("formula.headline", terms: Message::List.new(lines.map(&:sentence)))
    end

    # The facts an account has to carry before this rule will compute, in the
    # same words -- the same keys, now -- that the refusal uses when one is
    # missing.
    def needs
      formula.needs.map { |fact| Message.new("facts.#{fact}") }
    end

    def needs_sentence
      return nil if needs.empty?

      Message.new("formula.needs", facts: Message::List.new(needs))
    end

    private
      def line_for(term)
        percent = percent_for(term)

        Line.new(
          base: Vocabulary.base(term.base),
          rate: rate_label(term, percent),
          percent: percent,
          household_rate: term.household_rate?,
          condition: condition_label(term),
          window: window_label(term),
          sentence: sentence_for(term, percent)
        )
      end

      # The resolved rate as a fraction, or nil when there is no single number
      # to give: the household's own rate, a rate table this page does not
      # have, a rate this country's file does not carry, or a date the table
      # does not reach back to.
      #
      # Asked of the table by name rather than switched on here. The switch
      # this replaced listed France's three rates, which meant a second
      # country's file could declare a rate, have it accepted by the validator
      # and computed by the engine, and still render on this page as a bare
      # name with no figure -- the one screen whose job is to put figures on
      # names.
      def percent_for(term)
        return term.literal_rate if term.literal?
        return nil if term.household_rate?
        return nil if rates.nil?
        return nil unless rates.rate?(term.rate)

        rates.rate(term.rate, on)
      rescue Error
        nil
      end

      # "17.2% social charges", "30.0% (the flat tax)", "your marginal rate".
      #
      # A literal rate is its own label -- naming it "a fixed rate" alongside
      # the number would be saying the same thing twice -- while a named rate
      # keeps its name beside the figure, because 17.2% means nothing on its
      # own and "social charges" is what the reader will look up.
      def rate_label(term, percent)
        return Message.new("rates.#{term.rate}") if term.household_rate?
        return percentage(percent) if term.literal?
        return Message.new("rates.#{term.rate}") if percent.nil?

        # Two pieces with a space between them in English, and not necessarily
        # in that order elsewhere, so the order is in the template rather than
        # in this concatenation.
        Message.new("formula.rate_with_percent",
                    percent: percentage(percent), rate: Message.new("rates.#{term.rate}"))
      end

      def condition_label(term)
        years = maturity_years

        case term.condition
        when "mature"
          Message.new("formula.condition_mature", clock: clock_label(years))
        when "immature"
          if years
            Message.new("formula.condition_immature", years: years)
          else
            Message.new("formula.condition_immature_unknown_clock")
          end
        end
      end

      # "5 years old", or "mature" when the rule declares no period and none is
      # in the rate file. The second is not a fallback string standing in for a
      # number -- it is the only thing that can truthfully be said.
      def clock_label(years)
        return Message.new("formula.clock_unknown") if years.nil?

        Message.new("formula.clock_years", years: years)
      end

      # Dates go in raw. Tax::Messages writes them out in English and the view
      # edge hands the same Date to I18n.l, so a French reader gets "1 janvier
      # 2013" without this file knowing there was a question.
      def window_label(term)
        return nil unless term.vintage?

        from = term.opened_from
        till = term.opened_until

        if from && till then Message.new("formula.window_between", from: from, until: till)
        elsif from       then Message.new("formula.window_from", from: from)
        elsif till       then Message.new("formula.window_until", until: till)
        else                  Message.new("formula.window_unreadable")
        end
      end

      # The clauses are ordered the way the sentence is read rather than the
      # way the term is stored: what is taxed, at what rate, and then the two
      # narrowings that say when the line applies at all.
      #
      # Three shapes, because a percentage and a name do not sit in a sentence
      # the same way. "31.4% flat tax on the gain" leads with the number, which
      # is what the reader came for; the household rate and the unresolved rate
      # have no number to lead with, so they put the base first and the rate
      # after it.
      def sentence_for(term, percent)
        base = Message.new("bases.#{term.base}")

        head =
          if term.household_rate?
            Message.new("formula.head_named_rate",
                        rate: Message.new("rates.#{term.rate}"), base: base)
          elsif percent.nil?
            Message.new("formula.head_unresolved_rate",
                        base: base, rate: Message.new("rates.#{term.rate}"))
          else
            Message.new("formula.head_with_percent",
                        rate: rate_label(term, percent), base: base)
          end

        # No conjunction: each clause narrows the one before it rather than
        # adding to it. See Tax::Message::List.
        Message::List.new(
          [ head, condition_label(term), window_label(term) ].compact,
          connector: nil
        )
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
