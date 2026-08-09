# frozen_string_literal: true

module Tax
  # An account as the rules see it: a plain value object with no ActiveRecord
  # underneath. Rules take a Subject and return a Result, which makes every
  # rule a pure function and lets the whole engine be exercised without a
  # database. `Tax::SubjectBuilder` is the only place that knows about models.
  #
  # On the vocabulary:
  #
  #   subtype    Sure's own string, e.g. "pea", "brokerage", "savings". The
  #              registry is keyed on it so a subtype added upstream is picked
  #              up automatically.
  #
  #   product    what the rule needs to know, e.g. "livret_a". Usually derived
  #              from the subtype, but sometimes it cannot be: Sure files a
  #              Livret A and an ordinary taxable livret under the same
  #              `Depository/savings`. When they differ, the product is
  #              declared per account.
  #
  #   paid_in    cumulative money paid into the wrapper (FR: versements).
  #              Deliberately NOT called "contributions", because Sure already
  #              uses that word for the cash value of buy trades, which is a
  #              different and much larger number.
  #
  #   cost_basis what was paid for the securities currently held. It is not
  #              paid_in and must never be silently substituted for it: sell
  #              and rebuy inside a wrapper and cost basis resets upward while
  #              paid_in does not, so tax derived from it understates the bill.
  class Subject
    attr_reader :id, :name, :currency, :accountable_type, :subtype, :product,
                :value, :cost_basis, :paid_in, :paid_in_deducted, :opened_on,
                :declared, :tax_treatment

    def initialize(
      name:, value:, accountable_type: nil, subtype: nil, product: nil,
      id: nil, currency: nil, cost_basis: nil, tax_treatment: nil,
      paid_in: nil, paid_in_deducted: nil, opened_on: nil, declared: []
    )
      @id = id
      @name = name
      @currency = currency
      @accountable_type = accountable_type
      @subtype = subtype
      @product = product
      # Sure's own classification, via TaxTreatable. Carried so that a rule
      # which cannot compute anything can still report what Sure believes,
      # rather than saying nothing at all.
      @tax_treatment = tax_treatment
      @value = value
      @cost_basis = cost_basis
      @paid_in = paid_in
      @paid_in_deducted = paid_in_deducted
      @opened_on = opened_on
      @declared = Array(declared)
    end

    # The registry key. Both halves are Sure's, never ours.
    def key
      [ accountable_type, subtype ]
    end

    def declared?(fact)
      declared.include?(fact.to_sym)
    end

    # Age in years on the valuation date, or nil if the opening date is not
    # known. nil must not be read as "new" or as "old" -- rules have to decide
    # explicitly and say which way they leaned.
    def age_years_at(on)
      return nil if opened_on.nil?

      ((on - opened_on).to_f / 365.2425)
    end

    # Gain against a stated base, floored at zero. Losses are not negative tax.
    def gain_against(base)
      return nil if base.nil? || value.nil?

      diff = value - base
      diff.negative? ? BigDecimal(0) : diff
    end

    def loss_against(base)
      return nil if base.nil? || value.nil?

      diff = base - value
      diff.negative? ? BigDecimal(0) : diff
    end

    def with(**overrides)
      self.class.new(
        id: id, name: name, currency: currency,
        accountable_type: accountable_type, subtype: subtype, product: product,
        value: value, cost_basis: cost_basis, tax_treatment: tax_treatment,
        paid_in: paid_in, paid_in_deducted: paid_in_deducted,
        opened_on: opened_on, declared: declared
      ).tap do |copy|
        overrides.each { |k, v| copy.instance_variable_set("@#{k}", v) }
      end
    end
  end
end
