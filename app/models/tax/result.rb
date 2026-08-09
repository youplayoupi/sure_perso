# frozen_string_literal: true

module Tax
  # One account, valued and taxed on one date.
  #
  # `tax` is deliberately nullable. nil means "no rule could compute this",
  # which is a different statement from zero and must survive all the way to
  # the view: nil is excluded from the total and marks the total incomplete,
  # zero is added to it. Anything that collapses the two is a bug.
  class Result
    attr_reader :account_id, :account_name, :accountable_type, :subtype, :product,
                :gross, :taxable_base, :tax, :basis, :currency
    attr_reader :warnings

    # Income this account pushes onto the progressive scale in the liquidation
    # year. A second account liquidated the same year stacks on top of it
    # rather than starting again from zero.
    attr_reader :bareme_income

    def initialize(
      account_id: nil, account_name:, accountable_type: nil, subtype: nil,
      product: nil, currency: nil,
      gross:, taxable_base: nil, tax: nil, basis: "", warnings: [],
      modelled: nil, bareme_income: BigDecimal(0)
    )
      @account_id = account_id
      @account_name = account_name
      @accountable_type = accountable_type
      @subtype = subtype
      @product = product
      @currency = currency
      @gross = gross
      @taxable_base = taxable_base
      @tax = tax
      @basis = basis
      @warnings = Array(warnings)
      @modelled = modelled.nil? ? !tax.nil? : modelled
      @bareme_income = bareme_income || BigDecimal(0)
    end

    # True when a rule produced a number we are willing to stand behind.
    def modelled?
      @modelled
    end

    # Gross minus tax, or nil when the tax is unknown. Callers must not
    # substitute gross here -- an unknown tax does not make the account
    # tax-free.
    def net
      return nil if tax.nil?

      gross - tax
    end

    def effective_rate
      return nil if tax.nil? || gross.nil? || gross.zero?

      tax / gross
    end

    def add_warning(message)
      @warnings << message
      self
    end

    def to_h
      {
        account_id: account_id, account_name: account_name,
        accountable_type: accountable_type, subtype: subtype, product: product,
        gross: gross, taxable_base: taxable_base, tax: tax, net: net,
        basis: basis, modelled: modelled?, warnings: warnings
      }
    end
  end
end
