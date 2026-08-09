# frozen_string_literal: true

module Tax
  # Accounts, holdings and profiles in; plain Subjects out.
  #
  # This is the only class in the module that knows Rails exists. Everything
  # downstream of it is a pure function over value objects, which is what makes
  # the arithmetic testable without a database and diffable against the
  # reference implementation. Keeping the boundary at exactly one class is
  # deliberate: if a rule ever needs a new fact, the pressure lands here, on a
  # class whose whole job is to fetch facts, rather than leaking an ActiveRecord
  # call into a rule.
  #
  # Reads only. No `save`, no `update`, no `destroy`, nothing that touches an
  # account, a holding, an entry or a balance.
  class SubjectBuilder
    # Liabilities are not part of an after-tax picture of what you own, and
    # including them would produce a negative "gross" that means nothing. They
    # are excluded here rather than filtered in the view so that the totals and
    # the coverage table agree about what is in scope.
    EXCLUDED_TYPES = %w[Loan CreditCard OtherLiability].freeze

    # How far back a cached exchange rate may be and still be used. Balances are
    # read as they stand today, so the rate should be roughly today's too.
    RATE_LOOKBACK_DAYS = 30

    def initialize(family, accounts: nil)
      @family = family
      @accounts = accounts
    end

    def subjects
      accounts.map { |account| build(account) }
    end

    # Custom rules in the shape Registry wants. Rows naming a rule this version
    # no longer offers are dropped rather than raising -- see Catalogue.build.
    def custom_rules
      CustomRule.where(family_id: @family.id).select { |row| row.to_rule }
    end

    def registry
      Registry.new(country: country, custom_rules: custom_rules)
    end

    def country
      @family.country.presence || Tax::DEFAULT_COUNTRY
    end

    # The currency every figure on the report is expressed in -- and it is the
    # rate table's, not the family's display currency.
    #
    # That looks like the wrong choice for about ten seconds. Sure shows net
    # worth in the family currency, so matching it would be the consistent
    # thing to do. But the thresholds this module applies are denominated
    # amounts, not ratios: the French brackets are 11,600 / 29,579 / 84,577
    # euros, the PEA five-year clock is a euro allowance. Convert a portfolio
    # into dollars and then run euro brackets over it and every figure is
    # wrong, quietly and by a lot. The arithmetic has to happen in the currency
    # the law is written in.
    #
    # For a French household holding euros -- the case this was built for --
    # this is the identity and nothing is converted at all.
    def report_currency
      @report_currency ||= rate_table_currency || @family.currency
    end

    private
      def rate_table_currency
        Tax.rate_table(country).currency.presence
      rescue Tax::Error
        nil
      end
      def accounts
        @accounts ||= @family.accounts
                             .visible
                             .where.not(accountable_type: EXCLUDED_TYPES)
                             .includes(:holdings)
                             .order(:name)
      end

      def profiles
        @profiles ||= Profile.where(account_id: accounts.map(&:id)).index_by(&:account_id)
      end

      def build(account)
        profile = profiles[account.id]
        rate = conversion_rate_for(account)

        Subject.new(
          id: account.id,
          name: account.name,
          currency: report_currency,
          accountable_type: account.accountable_type,
          subtype: account.subtype,
          tax_treatment: treatment_for(account),

          # Declared facts override nothing Sure knows; they only fill gaps
          # Sure cannot fill. `product` is the one exception, and it exists
          # because Depository/savings covers a Livret A, an LDDS and an
          # ordinary taxable livret -- three different answers behind one
          # subtype.
          product: profile&.product.presence,
          opened_on: profile&.opened_on,

          # Declared in the account's own currency, because that is the
          # currency of the statement the figure was copied off, and converted
          # here along with everything else.
          paid_in: convert(profile&.paid_in, rate),
          paid_in_deducted: convert(profile&.paid_in_deducted, rate),

          value: convert(dec(account.balance), rate),
          cost_basis: convert(cost_basis_for(account), rate),
          declared: declared_facts(profile)
        )
      end

      # The account's currency expressed in the report's, or nil if that cannot
      # be established. nil propagates to a nil value, which Registry#apply
      # turns into an explicit refusal.
      #
      # Sure's own `ExchangeRate.rates_for` is deliberately not used here even
      # though it is right there and does almost this. It falls back to a rate
      # of 1 when none is on file, which is a defensible choice for a net worth
      # widget -- a roughly-right total beats a blank page -- and an indefensible
      # one for a tax figure, where "1 dollar is 1 euro" is not an approximation
      # but a fabrication. This module would rather show nothing.
      #
      # The lookup is also a plain read of what is already cached: no provider
      # call, no row written. Rendering a report is not an occasion to go out to
      # the network, and the no-writes promise is meant literally.
      def conversion_rate_for(account)
        return BigDecimal(1) if account.currency == report_currency

        rates_cache[account.currency]
      end

      def rates_cache
        @rates_cache ||= begin
          foreign = accounts.map(&:currency).uniq.reject { |c| c == report_currency }

          if foreign.empty?
            {}
          else
            window = (Date.current - RATE_LOOKBACK_DAYS)..Date.current

            # Ascending, so that assigning into the hash leaves the most recent
            # rate in place. A stale rate is bounded rather than unbounded: a
            # rate from three years ago is no more honest than no rate at all,
            # so outside the window this returns nothing and the account is
            # refused instead.
            ExchangeRate.where(from_currency: foreign, to_currency: report_currency)
                        .where(date: window)
                        .order(:date)
                        .each_with_object({}) { |r, map| map[r.from_currency] = dec(r.rate) }
          end
        end
      rescue StandardError
        {}
      end

      def convert(amount, rate)
        return nil if amount.nil? || rate.nil?

        amount * rate
      end

      # Sum of per-holding cost basis, or nil if any holding is missing one.
      #
      # Nil rather than a partial sum, and this is the important line in the
      # class. A partial sum is smaller than the truth, and a smaller cost
      # basis is a larger gain, so quietly summing what happens to be present
      # would overstate the tax while looking authoritative. Better to hand the
      # rule a nil and let it say why it cannot answer.
      def cost_basis_for(account)
        holdings = account.current_holdings.to_a
        return nil if holdings.empty?
        return nil if holdings.any? { |h| h.cost_basis.nil? }

        holdings.sum { |h| dec(h.cost_basis) }
      rescue StandardError
        # current_holdings runs a fairly involved query. A tax report is not
        # worth a 500, and the rules already handle a nil cost basis by saying
        # so out loud.
        nil
      end

      # Sure's own classification, via the TaxTreatable concern. Carried, not
      # acted on: see Tax::Treatment for why `:tax_exempt` is not allowed to
      # become "tax = 0".
      # `respond_to?` rather than a rescue: only some accountables include the
      # concern, and an accountable that raises from its own `tax_treatment` is
      # a bug worth seeing rather than swallowing.
      def treatment_for(account)
        accountable = account.accountable
        return nil unless accountable.respond_to?(:tax_treatment)

        accountable.tax_treatment
      end

      # What the user actually told us, so the report can distinguish a figure
      # that was declared from one that was defaulted.
      def declared_facts(profile)
        return [] if profile.nil?

        facts = []
        facts << :product if profile.product.present?
        facts << :opened_on if profile.opened_on.present?
        facts << :paid_in if profile.paid_in.present?
        facts << :paid_in_deducted if profile.paid_in_deducted.present?
        facts << :reviewed if profile.reviewed?
        facts
      end

      def dec(value)
        value.nil? ? nil : BigDecimal(value.to_s)
      end
  end
end
