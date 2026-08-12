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

          # Declared facts fill gaps Sure cannot fill, and are preferred over
          # Sure's own answer only where Sure's answer is not the one the
          # question is asking for.
          #
          # `product` is the clearest case: Depository/savings covers a Livret
          # A, an LDDS and an ordinary taxable livret, three different answers
          # behind one subtype, so there is nothing to defer to.
          #
          # `opened_on` is the other way round. Sure does know this, and asking
          # a second time for a date already on the account was the module
          # duplicating a setting rather than adding one. The declared value
          # stays as an override -- see `anchored_opening_date` for the case it
          # exists to cover -- but it is now a correction rather than the only
          # source.
          product: profile&.product.presence,
          opened_on: profile&.opened_on || anchored_opening_date(account),

          # Not an opening date, and carried separately so that no rule can
          # mistake it for one. See `known_since`.
          known_since: profile&.opened_on ? nil : known_since(account),

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

      # What the securities currently held cost to acquire, or nil if that
      # cannot be established for every one of them.
      #
      # Nil rather than a partial sum, and this is the important line in the
      # class. A partial sum is smaller than the truth, and a smaller cost
      # basis is a larger gain, so quietly summing what happens to be present
      # would overstate the tax while looking authoritative. Better to hand the
      # rule a nil and let it say why it cannot answer.
      #
      # `holdings.cost_basis` is not this number and reading it directly was a
      # bug that survived a long time because the result looked plausible.
      # Sure stores an *average cost per share* in that column --
      # Holding::ForwardCalculator#cost_basis_for divides total cost by total
      # quantity before writing it -- so summing it across a portfolio adds
      # prices together and calls the result a cost. A holding of one share and
      # a holding of a thousand contributed equally. Hence `* qty`.
      #
      # Reading through `avg_cost` rather than the column is the second half of
      # the same fix. The column is nullable and frequently null; `avg_cost`
      # returns it when it is trustworthy and otherwise derives the figure from
      # the trades on file. The old guard refused whenever the column was null,
      # which meant refusing accounts whose entire purchase history Sure holds
      # and can total on demand. `cost_basis_known?` is the stricter predicate
      # and is deliberately not used here for exactly that reason: it asks
      # whether the stored column is good, and the question here is whether the
      # cost is knowable at all.
      #
      # This costs one query per holding when the column is null, since that is
      # where `avg_cost` falls back to SQL over the trades. Tens of holdings on
      # a page nobody loads in a loop is a note rather than a defect; batching
      # it belongs in the same change as measuring it.
      def cost_basis_for(account)
        holdings = account.current_holdings.to_a
        return nil if holdings.empty?

        totals = holdings.map { |holding| position_cost(holding) }
        return nil if totals.any?(&:nil?)

        totals.sum
      rescue StandardError
        # current_holdings runs a fairly involved query. A tax report is not
        # worth a 500, and the rules already handle a nil cost basis by saying
        # so out loud.
        nil
      end

      # One holding's total acquisition cost, in the holding's own currency.
      #
      # Currency is left alone here on purpose: `build` converts the summed
      # figure through the same rate as every other amount on the account, and
      # a second conversion path would be a second place for a rate to go
      # stale. Which does mean a single account holding securities denominated
      # in two currencies is added up before conversion. Sure holds one
      # currency per account, so that case does not arise today; if it ever
      # does, this is where it breaks and it should break loudly.
      def position_cost(holding)
        average = holding.avg_cost
        return nil if average.nil? || holding.qty.nil?

        dec(average.amount) * dec(holding.qty)
      end

      # Sure's opening date, but only when it is one.
      #
      # `Account#opening_anchor_date` always returns something. When an opening
      # anchor has been set it returns that date; when none has, it falls back
      # to the earliest entry on file, and failing that to today -- both
      # perfectly reasonable for drawing a balance chart from the left edge,
      # and both actively dangerous here. A PEA opened in 2015 whose Sure
      # history starts in 2024 would come back as two years old, which flips it
      # from past its five-year clock and exempt to inside it and taxed at the
      # full PFU.
      #
      # `has_opening_anchor?` was the first guard and it is not enough. It
      # answers "is there an anchor row", not "does that row's date mean
      # anything", and Sure writes an anchor for every manually created
      # account: `Time.zone.today - 2.years` by default, rewritten to the entry
      # date once a real opening balance is given. So an account entered today
      # with the balance it has today carries an anchor dated today, and the
      # first guard believed it. Every wrapper in this household came back zero
      # years old, and only a refusal further upstream kept that off the page.
      #
      # The balance is what tells them apart. An anchor whose balance is zero
      # is consistent with "the account began here". An anchor whose balance is
      # not zero is proof of the opposite: money was already in it, so the
      # account existed before that date and the date is a lower bound on how
      # long it has been held. That case is not an opening date at all, and is
      # returned by `known_since` instead.
      #
      # One asymmetry worth naming, because it is a decision and not an
      # oversight. Sure's two-year default with a zero balance is not a
      # statement by anybody, and this believes it. That is harmless today --
      # no deposit rule has a clock, and every wrapper that does have one
      # carries a balance -- and it would stop being harmless the day a rule
      # with a clock applies to an account somebody created and left empty.
      def anchored_opening_date(account)
        return nil unless believable_anchor?(account)
        return nil unless dec(account.opening_anchor_balance)&.zero?

        account.opening_anchor_date
      rescue StandardError
        # Same posture as `cost_basis_for`: this reaches into Sure's balance
        # machinery, and a tax report is not worth a 500 when the rules already
        # handle a missing date by saying so.
        nil
      end

      # A date the account demonstrably predates. Never an opening date.
      #
      # The other half of the split above: an anchor carrying money proves the
      # account is at least this old, which is worth something even though it
      # is not the fact the rules would prefer. A PEA whose anchor is six years
      # back with a balance on it has certainly run its five-year clock, and
      # saying so beats asking for a date in order to conclude what is already
      # known. Where the bound is not enough to settle the question, the rules
      # fall back to what they did before and say the date is unknown.
      def known_since(account)
        return nil unless believable_anchor?(account)
        return nil if dec(account.opening_anchor_balance)&.zero?

        account.opening_anchor_date
      rescue StandardError
        nil
      end

      def believable_anchor?(account)
        return false unless account.respond_to?(:has_opening_anchor?)

        account.has_opening_anchor?
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
