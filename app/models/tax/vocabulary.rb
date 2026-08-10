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
      opened_on: "the date the account was opened",
      # Not one of Formula::BASES[..][:needs] -- the securities rule names this
      # one directly when it refuses. It lives here anyway so that every phrase
      # a refusal can end with is in one list, and none of them reaches a page
      # through `fact`'s underscores-out fallback.
      acquisition_cost: "the acquisition cost"
    }.freeze

    # What a term multiplies its base by.
    #
    # These name the rate rather than state it, because the number depends on
    # the valuation date and, for the household rate, on what the household
    # said about itself. FormulaPresenter resolves the ones that can be
    # resolved and puts the percentage in front of the name.
    #
    # Unlike BASES this is a *fallback*, not the vocabulary. The vocabulary of
    # rates is whatever the country's file declares, which is why `rate` below
    # returns the name unchanged for anything not listed: a `be.yml` naming a
    # rate this hash has never heard of has to render as that name rather than
    # be silently dropped or raise. What is listed here are the French ones,
    # because "flat_tax_income_component" is a file key and "income-tax part of
    # the flat tax" is a sentence, and only the second belongs on a page.
    #
    # Bare noun phrases, with no article. The percentage goes in front of them
    # far more often than not -- "18.6% social charges" -- and "31.4% the flat
    # tax" is the kind of sentence that makes a reader stop and reread. The
    # handful of places that need an article add their own.
    RATES = {
      "social_charges" => "social charges",
      "flat_tax" => "flat tax",
      "flat_tax_income_component" => "income-tax part of the flat tax",
      "household_rate" => "your marginal rate",
      "literal" => "fixed rate"
    }.freeze

    # Sure's own tax_treatment enum, said mid-sentence.
    #
    # Sure already translates these under `accounts.tax_treatments`, in title
    # case, for a badge. These are the same four words in the case a sentence
    # wants them -- "classifies this account as tax deferred", not "as
    # Tax-Deferred" -- plus the fifth case the badge never has to render,
    # because a badge for an unclassified account is simply absent while a
    # sentence about one still has to name it.
    TREATMENTS = {
      "taxable" => "taxable",
      "tax_deferred" => "tax deferred",
      "tax_exempt" => "tax exempt",
      "tax_advantaged" => "tax advantaged",
      "unclassified" => "unclassified"
    }.freeze

    # The words that join a list into a phrase. Two of them, and they are not
    # interchangeable: a list of missing facts is joined with "and", the lines
    # of a calculation with "plus". A language may well want a different word
    # for each, or the same word for both, and this is where it says so.
    CONNECTORS = {
      "and" => "and",
      "plus" => "plus"
    }.freeze

    def self.base(name)
      BASES.fetch(name.to_s, name.to_s)
    end

    def self.connector(name)
      CONNECTORS.fetch(name.to_s, name.to_s)
    end

    # Underscores out for a treatment Sure adds in a later release, on the same
    # reasoning as `rate` below: a new enum value should read as words rather
    # than vanish or raise.
    def self.treatment(name)
      TREATMENTS.fetch(name.to_s) { name.to_s.tr("_", " ") }
    end

    def self.fact(name)
      FACTS.fetch(name.to_sym, name.to_s)
    end

    # Underscores out for anything unlisted, so a rate a second country's file
    # introduces reads as "regional surcharge" rather than as an identifier.
    # Not `humanize` -- that is ActiveSupport, and this file has to load into a
    # bare Ruby process.
    def self.rate(name)
      RATES.fetch(name.to_s) { name.to_s.tr("_", " ") }
    end

    # ActiveSupport's to_sentence would do, and is exactly the kind of thing
    # this engine may not reach for: it has to load into a bare Ruby process.
    # Five lines here is the price of that.
    #
    # `word` is the already-resolved connector, not its key, because the view
    # edge resolves it through I18n instead and both then call this with a word
    # in the reader's language.
    def self.to_sentence(items, word: CONNECTORS.fetch("and"))
      list = Array(items).map(&:to_s).reject(&:empty?)
      return "" if list.empty?
      return list.first if list.one?
      return list.join(", ") if word.nil?

      "#{list[0..-2].join(', ')} #{word} #{list.last}"
    end

    # "8 August 2026". Written out rather than left as an ISO string because
    # these appear mid-sentence, where 2013-01-01 reads as a serial number.
    def self.date(value)
      return nil if value.nil?

      value.strftime("%-d %B %Y")
    end
  end
end
