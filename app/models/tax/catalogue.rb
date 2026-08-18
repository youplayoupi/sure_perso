# frozen_string_literal: true

module Tax
  # The allow-list of rule classes a stored custom rule may select.
  #
  # This exists so that `tax_custom_rules.kind` can be turned into a rule
  # object without `constantize`. A user-writable string that gets
  # constantized is a way to reach arbitrary classes; a user-writable string
  # looked up in a frozen hash is a choice from a menu. The menu is short and
  # it is here.
  #
  # A rule offered here must be safe to point at *any* account, because that
  # is what the UI allows. None of them read the database and none of them
  # write anything -- see Rules::Base.
  module Catalogue
    # rule_id => [class, one-line description shown next to the choice]
    def self.entries
      @entries ||= {
        "fr_pea" => [
          Rules::Fr::Pea,
          "PEA-style wrapper: gains taxed only on withdrawal, social charges " \
          "only once the plan passes its five-year mark."
        ],
        "fr_securities" => [
          Rules::Fr::Securities,
          "Ordinary securities account: latent gain taxed at the flat rate."
        ],
        "fr_deposit" => [
          Rules::Fr::Deposit,
          "Cash deposit or livret: withdrawing the balance is not itself a " \
          "taxable event."
        ],
        # The two PER shapes. They are the same wrapper and differ only in what
        # the growth is taxed at, which is the one part of a French PER
        # withdrawal the household elects rather than inherits. Both are
        # offered because Sure cannot see which election was made -- that is a
        # box on a tax return, not a fact about an account -- and guessing
        # would be picking a number on the household's behalf.
        "fr_capital_and_gains" => [
          Rules::Fr::CapitalAndGains,
          "PER taken as a lump sum, the default way: the deducted payments " \
          "taxed at your marginal rate, the growth at the flat tax. Use this " \
          "until Sure ships a PER subtype."
        ],
        "fr_capital_and_gains_household" => [
          Rules::Fr::CapitalAndGainsAtHouseholdRate,
          "The same PER lump sum with the progressive scale elected over the " \
          "flat tax, so the growth is taxed at your marginal rate too. Worth " \
          "electing when your rate is below the flat tax."
        ],
        "exempt" => [
          Rules::Exempt,
          "Genuinely untaxed on liquidation. Reports zero, and means it."
        ],
        "cash_deposit" => [
          Rules::CashDeposit,
          "Cash deposit: withdrawing the balance is not a taxable event; " \
          "interest is taxed as it arises, outside this report."
        ],
        "us_securities" => [
          Rules::Us::Securities,
          "US taxable account: latent gain taxed at the long-term capital-gains " \
          "rate (0/15/20 by income; the middle band is assumed)."
        ],
        "us_deferred" => [
          Rules::Us::Deferred,
          "US pre-tax retirement account (Traditional 401(k)/IRA): the whole " \
          "balance taxed as income at your marginal rate on withdrawal."
        ],
        # gb_capital_gains and gb_pension are deliberately NOT offered here.
        # Both choose their rate from a household assertion rather than from a
        # fixed rate on the valuation date, so neither can declare a formula the
        # rules screen could render -- and a pinnable rule that cannot explain
        # itself is exactly what Tax::Formula exists to prevent. They still run
        # as built-in rules mapped onto UK subtypes in Tax::Registry; they are
        # simply not on the "write your own" menu.
        "in_equity" => [
          Rules::In::Equity,
          "Indian listed equity: latent long-term gain taxed at 12.5% (the " \
          "₹1.25 lakh annual exemption is applied once, not per account)."
        ],
        COMPOSED => [
          Rules::Composed,
          "Write your own: choose what is taxed -- the whole balance, the gain, " \
          "the payments in -- and at what rate, with an optional maturity clock."
        ]
      }.freeze
    end

    # The one rule here that is configured rather than merely chosen. The
    # settings screen has to branch on it to show a builder instead of a
    # description, and it should do that without a bare string in a view.
    COMPOSED = "composed"

    def self.composed?(kind)
      kind.to_s == COMPOSED
    end

    def self.kinds
      entries.keys
    end

    def self.include?(kind)
      entries.key?(kind.to_s)
    end

    def self.description(kind)
      entries.dig(kind.to_s, 1)
    end

    # The class itself, for callers that want to ask it something -- its
    # declared formula, in practice -- rather than instantiate it. Returns nil
    # for an unknown kind, like everything else here.
    def self.rule_class(kind)
      entries.dig(kind.to_s, 0)
    end

    # Returns nil rather than raising for an unknown kind. A row written by an
    # older version of this module naming a rule that has since been removed
    # should degrade to "no rule", which the engine already handles safely by
    # refusing to compute -- not blow up the whole report.
    def self.build(kind, params = {})
      klass = entries.dig(kind.to_s, 0)
      return nil if klass.nil?

      accepted = accepted_params(klass, params)
      accepted.empty? ? klass.new : klass.new(**accepted)
    end

    def self.symbolize(params)
      params.to_h.transform_keys(&:to_sym)
    end
    private_class_method :symbolize

    # Keys the constructor does not name are dropped rather than splatted in,
    # because `new(**unexpected)` is an ArgumentError and this runs inside a
    # loop over every account in the report. A params hash written by a newer
    # version of the module, or by hand, should cost the reader one rule -- and
    # ideally not even that, since the rule still gets built from the keys it
    # does understand. Losing the whole page over a stray key would be a worse
    # answer than any of the rules could give.
    def self.accepted_params(klass, params)
      return {} if params.nil? || params.empty?

      names = klass.instance_method(:initialize).parameters.filter_map do |type, name|
        name if %i[key keyreq].include?(type)
      end
      symbolize(params).slice(*names)
    end
    private_class_method :accepted_params
  end
end
