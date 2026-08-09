# frozen_string_literal: true

module Tax
  # The plain-English name for every term the formula vocabulary knows.
  #
  # It is a separate file, and not a private constant inside the rule that
  # first needed it, because two callers have to agree on the wording and the
  # cost of them disagreeing is a reader's confidence. When Rules::Composed
  # declines an account it says "this rule taxes the gain over what was paid
  # in, which needs the total paid in"; the rules page then has to describe
  # that same rule in the same breath. Two hashes drifting apart would have the
  # explanation and the refusal naming the same quantity differently, and the
  # reader with no way to tell whether that is two names for one thing or two
  # different things.
  #
  # Plain Ruby, like everything else the engine loads: no I18n, no
  # ActiveSupport. Translation happens at the view edge, in
  # TaxReportsHelper, which already knows it is rendering a page and is allowed
  # to know what language it is rendering in.
  module Vocabulary
    # What a term taxes. Keys are Formula::BASES.
    BASES = {
      "full_value" => "the whole balance",
      "gain_over_paid_in" => "the gain over what was paid in",
      "gain_over_cost_basis" => "the gain over cost basis",
      "paid_in" => "the payments in",
      "paid_in_deducted" => "the deducted payments in",
      "paid_in_not_deducted" => "the payments in that were not deducted"
    }.freeze

    # Facts an account has to carry for a term to be computable. Keys are the
    # symbols in Formula::BASES[..][:needs].
    FACTS = {
      paid_in: "the total paid in",
      cost_basis: "the cost basis of what is held",
      opened_on: "the date the account was opened"
    }.freeze

    # What a term multiplies its base by. Keys are Formula::RATES.
    #
    # These name the rate rather than state it, because the number depends on
    # the valuation date and, for `progressive`, on the rest of the household's
    # year. FormulaPresenter resolves the ones that can be resolved and puts
    # the percentage in front of the name.
    #
    # Bare noun phrases, with no article. The percentage goes in front of them
    # far more often than not -- "18.6% social charges" -- and "31.4% the flat
    # tax" is the kind of sentence that makes a reader stop and reread. The
    # handful of places that need an article add their own.
    RATES = {
      "social_charges" => "social charges",
      "flat_tax" => "flat tax",
      "flat_tax_income_component" => "income-tax part of the flat tax",
      "progressive" => "progressive income-tax scale",
      "literal" => "fixed rate"
    }.freeze

    def self.base(name)
      BASES.fetch(name.to_s, name.to_s)
    end

    def self.fact(name)
      FACTS.fetch(name.to_sym, name.to_s)
    end

    def self.rate(name)
      RATES.fetch(name.to_s, name.to_s)
    end

    # ActiveSupport's to_sentence would do, and is exactly the kind of thing
    # this engine may not reach for: it has to load into a bare Ruby process.
    # Four lines here is the price of that.
    def self.to_sentence(items)
      list = Array(items).map(&:to_s).reject(&:empty?)
      return "" if list.empty?
      return list.first if list.one?

      "#{list[0..-2].join(', ')} and #{list.last}"
    end

    # "8 August 2026". Written out rather than left as an ISO string because
    # these appear mid-sentence, where 2013-01-01 reads as a serial number.
    def self.date(value)
      return nil if value.nil?

      value.strftime("%-d %B %Y")
    end
  end
end
