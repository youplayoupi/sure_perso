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
      when "US" then us_rules
      when "GB" then gb_rules
      when "IN" then in_rules
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
          reason: Message.new("not_modelled.assurance_vie")
        ),

        [ "Depository", "checking" ]     => deposit,
        [ "Depository", "savings" ]      => deposit,
        [ "Depository", "cd" ]           => deposit,
        [ "Depository", "money_market" ] => deposit,

        [ "Crypto", TYPE_WILDCARD ] => Rules::NotModelled.new(
          reason: Message.new("not_modelled.crypto")
        ),
        [ "Property", TYPE_WILDCARD ] => Rules::NotModelled.new(
          reason: Message.new("not_modelled.property")
        )
      }
    end

    # United States. Taxable accounts take the long-term capital-gains rate on
    # the gain; pre-tax retirement wrappers are taxed as income on the whole
    # balance; Roth/HSA/529 are genuinely exempt on qualified use.
    def self.us_rules
      securities = Rules::Us::Securities.new
      deferred   = Rules::Us::Deferred.new
      deposit    = Rules::CashDeposit.new

      {
        [ "Investment", "brokerage" ]   => securities,
        [ "Investment", "ugma" ]        => securities,
        [ "Investment", "utma" ]        => securities,
        [ "Investment", "mutual_fund" ] => securities,
        [ "Investment", "trust" ]       => securities,
        [ "Investment", "angel" ]       => securities,

        [ "Investment", "401k" ]       => deferred,
        [ "Investment", "403b" ]       => deferred,
        [ "Investment", "457b" ]       => deferred,
        [ "Investment", "tsp" ]        => deferred,
        [ "Investment", "ira" ]        => deferred,
        [ "Investment", "sep_ira" ]    => deferred,
        [ "Investment", "simple_ira" ] => deferred,

        [ "Investment", "roth_401k" ] => Rules::Exempt.new,
        [ "Investment", "roth_ira" ]  => Rules::Exempt.new,
        [ "Investment", "529_plan" ]  => Rules::Exempt.new,
        [ "Investment", "hsa" ]       => Rules::Exempt.new,

        [ "Depository", "checking" ]     => deposit,
        [ "Depository", "savings" ]      => deposit,
        [ "Depository", "cd" ]           => deposit,
        [ "Depository", "money_market" ] => deposit,
        [ "Depository", "hsa" ]          => Rules::Exempt.new,

        [ "Crypto", TYPE_WILDCARD ] => securities
      }
    end

    # United Kingdom. Taxable accounts take CGT at the band implied by the
    # household's marginal rate; ISAs are exempt; pensions are a lump sum taxed
    # as income on three-quarters of the balance.
    def self.gb_rules
      cgt     = Rules::Gb::CapitalGains.new
      pension = Rules::Gb::Pension.new
      deposit = Rules::CashDeposit.new

      {
        [ "Investment", "brokerage" ]   => cgt,
        [ "Investment", "mutual_fund" ] => cgt,
        [ "Investment", "trust" ]       => cgt,
        [ "Investment", "angel" ]       => cgt,

        [ "Investment", "isa" ]  => Rules::Exempt.new,
        [ "Investment", "lisa" ] => Rules::Exempt.new,

        [ "Investment", "sipp" ]                 => pension,
        [ "Investment", "workplace_pension_uk" ] => pension,

        [ "Depository", "checking" ]     => deposit,
        [ "Depository", "savings" ]      => deposit,
        [ "Depository", "cd" ]           => deposit,
        [ "Depository", "money_market" ] => deposit,

        [ "Crypto", TYPE_WILDCARD ] => cgt
      }
    end

    # India. Listed-equity wrappers take the long-term equity rate on the gain;
    # PPF and equivalents are exempt; debt, small savings, NPS and insurance
    # turn on facts Sure does not hold and are named rather than valued.
    def self.in_rules
      equity  = Rules::In::Equity.new
      deposit = Rules::CashDeposit.new

      debt = Rules::NotModelled.new(
        reason: "Indian debt funds, fixed deposits and small-savings schemes are taxed " \
                "at slab rates on interest that accrues as it arises, over holding-period " \
                "bands Sure does not record. Named rather than valued."
      )
      retirement = Rules::NotModelled.new(
        reason: "NPS, APY and life insurance are taxed on the split between lump sum and " \
                "annuity and on deduction history, none of which Sure holds."
      )

      {
        [ "Investment", "indian_stocks" ] => equity,
        [ "Investment", "indian_equity" ] => equity,
        [ "Investment", "indian_etf" ]    => equity,
        [ "Investment", "gold_etf" ]      => equity,
        [ "Investment", "gold_mf" ]       => equity,
        [ "Investment", "mutual_fund" ]   => equity,

        [ "Investment", "ppf" ]           => Rules::Exempt.new,
        [ "Investment", "ssy" ]           => Rules::Exempt.new,
        [ "Investment", "tax_free_bond" ] => Rules::Exempt.new,

        [ "Investment", "nps" ]            => retirement,
        [ "Investment", "apy" ]            => retirement,
        [ "Investment", "life_insurance" ] => retirement,

        [ "Investment", "fd" ]             => debt,
        [ "Investment", "rd" ]             => debt,
        [ "Investment", "nsc" ]            => debt,
        [ "Investment", "scss" ]           => debt,
        [ "Investment", "corporate_bond" ] => debt,
        [ "Investment", "g_sec" ]          => debt,

        [ "Depository", "checking" ]     => deposit,
        [ "Depository", "savings" ]      => deposit,
        [ "Depository", "cd" ]           => deposit,
        [ "Depository", "money_market" ] => deposit
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
      return unvalued(subject) if subject.value.nil?

      resolve(subject).call(subject, on: on, rates: rates, assumptions: assumptions)
    end

    # Tax a whole portfolio in one pass.
    #
    # This used to carry income from one account to the next, adding the
    # wrappers that landed on the progressive scale together and running them
    # through the brackets once rather than taxing each from zero. With the
    # scale replaced by a single household marginal rate that is no longer a
    # correction of any kind: one rate multiplied over a sum is the same number
    # as the sum of the same rate over each part. The loop was kept for a while
    # anyway and it was worse than useless -- it produced a warning about
    # brackets nobody was crossing.
    #
    # What stays is the ordering. Accounts are sorted before they are taxed so
    # the report never depends on the order rows came back from the database,
    # which is what makes two runs of the same portfolio comparable.
    def apply_all(subjects, on:, rates:, assumptions:)
      sort(subjects).map { |subject| apply(subject, on: on, rates: rates, assumptions: assumptions) }
    end

    private
      # A subject whose value could not be established in the report's currency.
      #
      # Every rule assumes it has been handed a number to work from, so rather
      # than letting each one discover the nil separately -- and probably
      # differently -- the dispatch point refuses once, here. In practice this
      # fires when an account is held in a currency with no exchange rate on
      # file: see Tax::SubjectBuilder, which declines to invent one.
      def unvalued(subject)
        Result.new(
          account_id: subject.id,
          account_name: subject.name,
          accountable_type: subject.accountable_type,
          subtype: subject.subtype,
          product: subject.product,
          currency: subject.currency,
          gross: nil,
          taxable_base: nil,
          tax: nil,
          basis: Message.new("base.cannot_be_computed"),
          modelled: false,
          warnings: [
            Message.new("registry.no_value", currency: subject.currency)
          ]
        )
      end

      def sort(subjects)
        subjects.sort_by { |s| [ s.accountable_type.to_s, s.subtype.to_s, s.name.to_s, s.id.to_s ] }
      end
  end
end
