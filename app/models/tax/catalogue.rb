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
        "fr_capital_and_gains" => [
          Rules::Fr::CapitalAndGains,
          "Deferred-tax pension wrapper taken as a lump sum: deducted " \
          "payments taxed as income, growth at the flat rate. Use this for a " \
          "PER until Sure ships a subtype for it."
        ],
        "exempt" => [
          Rules::Exempt,
          "Genuinely untaxed on liquidation. Reports zero, and means it."
        ]
      }.freeze
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

    # Returns nil rather than raising for an unknown kind. A row written by an
    # older version of this module naming a rule that has since been removed
    # should degrade to "no rule", which the engine already handles safely by
    # refusing to compute -- not blow up the whole report.
    def self.build(kind, params = {})
      klass = entries.dig(kind.to_s, 0)
      return nil if klass.nil?

      params.nil? || params.empty? ? klass.new : klass.new(**symbolize(params))
    end

    def self.symbolize(params)
      params.to_h.transform_keys(&:to_sym)
    end
    private_class_method :symbolize
  end
end
