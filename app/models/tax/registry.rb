# frozen_string_literal: true

module Tax
  # Maps Sure's own (accountable_type, subtype) pairs onto tax rules.
  #
  # Keying on Sure's classification rather than on a private enum is the whole
  # design. It means a subtype added in a future Sure release is picked up by
  # this module automatically -- either matching a rule, or appearing in
  # Tax::Coverage as an explicit gap. It can never be silently misfiled into a
  # rule written for something else.
  #
  # Resolution order, most specific first:
  #
  #   1. a custom rule pinned to this one account
  #   2. a custom rule for this (type, subtype)
  #   3. a built-in rule for this (type, subtype)
  #   4. a custom or built-in rule for this type, any subtype
  #   5. Tax::Rules::Unknown, which reports gross and refuses to name a tax
  #
  # Step 5 is why an unrecognised product cannot quietly become zero.
  class Registry
    TYPE_WILDCARD = nil

    attr_reader :country

    # Built-in rules, defined as a method rather than a constant so that
    # Zeitwerk resolves the rule classes lazily on first use.
    def self.built_in(country)
      case country.to_s.upcase
      when "FR" then french_rules
      else {}
      end
    end

    def self.french_rules
      securities = Rules::Fr::Securities.new
      deposit    = Rules::Fr::Deposit.new

      {
        [ "Investment", "pea" ]           => Rules::Fr::Pea.new,
        [ "Investment", "pea_pme" ]       => Rules::Fr::Pea.new,
        [ "Investment", "brokerage" ]     => securities,
        [ "Investment", "assurance_vie" ] => Rules::NotModelled.new(
          reason: "Assurance vie taxation depends on the age of the contract, the split " \
                  "between capital and gains, an annual allowance and which of two " \
                  "regimes the payments fall under. Sure stores none of that."
        ),

        [ "Depository", "checking" ]     => deposit,
        [ "Depository", "savings" ]      => deposit,
        [ "Depository", "cd" ]           => deposit,
        [ "Depository", "money_market" ] => deposit,

        [ "Crypto", TYPE_WILDCARD ] => Rules::NotModelled.new(
          reason: "French crypto gains are computed on a portfolio-wide formula that " \
                  "prorates total acquisition cost across the whole holding, not " \
                  "per-asset. That is a different calculation from securities and is " \
                  "not implemented."
        ),
        [ "Property", TYPE_WILDCARD ] => Rules::NotModelled.new(
          reason: "Property gains depend on whether it is your main home, and otherwise " \
                  "on allowances that taper with how long you have owned it. Not modelled."
        )
      }
    end

    # `custom_rules` is a list of objects responding to
    # #accountable_type, #subtype, #account_id and #to_rule.
    def initialize(country: Tax::DEFAULT_COUNTRY, custom_rules: [])
      @country = country.to_s.upcase
      @built_in = self.class.built_in(@country)
      @by_key = {}
      @by_account = {}

      Array(custom_rules).each do |custom|
        if custom.account_id
          @by_account[custom.account_id] = custom.to_rule
        else
          @by_key[[ custom.accountable_type, custom.subtype ]] = custom.to_rule
        end
      end

      @fallback = Rules::Unknown.new
    end

    def resolve(subject)
      @by_account[subject.id] ||
        @by_key[subject.key] ||
        @built_in[subject.key] ||
        @by_key[[ subject.accountable_type, TYPE_WILDCARD ]] ||
        @built_in[[ subject.accountable_type, TYPE_WILDCARD ]] ||
        @fallback
    end

    def covered?(accountable_type, subtype)
      key = [ accountable_type, subtype ]
      @by_key.key?(key) || @built_in.key?(key) ||
        @by_key.key?([ accountable_type, TYPE_WILDCARD ]) ||
        @built_in.key?([ accountable_type, TYPE_WILDCARD ])
    end

    def rule_for(accountable_type, subtype)
      key = [ accountable_type, subtype ]
      @by_key[key] || @built_in[key] ||
        @by_key[[ accountable_type, TYPE_WILDCARD ]] ||
        @built_in[[ accountable_type, TYPE_WILDCARD ]]
    end

    def custom?(accountable_type, subtype)
      @by_key.key?([ accountable_type, subtype ])
    end

    def apply(subject, on:, rates:, assumptions:)
      resolve(subject).call(subject, on: on, rates: rates, assumptions: assumptions)
    end

    # Tax a whole portfolio in one pass, carrying progressive-scale income
    # across accounts.
    #
    # Applying each rule in isolation understates the bill whenever two
    # wrappers land on the progressive scale in the same year: they are added
    # together and run through the brackets once, not taxed twice from zero.
    # Accounts are sorted first so the result never depends on the order rows
    # came back from the database.
    def apply_all(subjects, on:, rates:, assumptions:)
      stacked = BigDecimal(0)

      sort(subjects).map do |subject|
        local = if stacked.positive?
          assumptions.with(other_taxable_income: assumptions.other_taxable_income + stacked)
        else
          assumptions
        end

        line = apply(subject, on: on, rates: rates, assumptions: local)

        if stacked.positive? && line.bareme_income.positive?
          line.add_warning(
            "Stacked on #{stacked.to_s('F')} of income from wrappers liquidated earlier " \
            "in the same year, which is what pushes it into higher brackets."
          )
        end

        stacked += line.bareme_income
        line
      end
    end

    private
      def sort(subjects)
        subjects.sort_by { |s| [ s.accountable_type.to_s, s.subtype.to_s, s.name.to_s, s.id.to_s ] }
      end
  end
end
