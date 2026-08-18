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

    # The facts whose absence caused this refusal, as symbols.
    #
    # The warnings already say this in a sentence, and a sentence is the right
    # thing for a reader. It is the wrong thing for the report, which has to
    # decide whether to offer a link to the form -- and a view that answered
    # that question by matching on the text of a warning would be one
    # translation away from breaking. So the same fact travels twice: once as
    # prose for the person, once as a symbol for the code.
    #
    # Not every entry is something a person can supply. `:cost_basis` is
    # derived from Sure's own holdings and no form collects it, so a caller
    # offering an action intersects this with what it can actually ask for,
    # rather than reading a non-empty list as "there is a box to fill in".
    attr_reader :missing_facts

    # Which figure the gain was actually measured against: `:paid_in` for a
    # declared total paid in, `:cost_basis` for what the holdings cost, nil
    # where the question does not arise.
    #
    # Set by each rule from the figure it actually reached for, rather than
    # centrally by asking the Subject what it would have preferred. The two
    # would agree today -- every rule goes through the same cascade -- and
    # would still be the wrong place to decide it, because the cascade means
    # opposite things on either side of it. For a PEA the versements are the
    # base and the cost basis is the stand-in; for a CTO the cost basis is the
    # base in law and a declared figure is the household correcting it. A rule
    # that skipped its own answer and read the Subject's would be right by
    # coincidence, and a fifth rule with its own order of preference would be
    # captioned by a cascade it never ran.
    #
    # Carried as a symbol rather than as a sentence for the same reason
    # `missing_facts` is: the page picks the words, in the reader's language.
    attr_reader :basis_source

    # How much of this account's taxable base was taxed at the household's own
    # declared marginal rate, as opposed to at a rate the country publishes.
    #
    # It used to exist so that two wrappers liquidated in the same year could
    # be stacked and run through the income-tax scale once. That is gone: a
    # single marginal rate distributes over a sum, so stacking changed nothing
    # and pretending otherwise was machinery with no effect. What is left is
    # disclosure. The report totals this to say how much of the bill rests on
    # a number the household typed rather than on one Sure looked up, which is
    # the difference the rest of the module exists to keep visible.
    attr_reader :household_rate_income

    # Whether the household has opened this account's form and saved it.
    #
    # The engine does nothing with it. It is carried for the same reason
    # `account_name` and `subtype` are carried -- the page needs it and the
    # Subject already has it, so passing it through costs one line and saves
    # the view a second trip to the database. What the page does with it is
    # quieten a warning about a box somebody looked at and chose to leave
    # empty; see TaxReportsHelper#tax_warnings. Deciding that here would be the
    # engine deciding how loudly to say something, which is not its business.
    attr_reader :reviewed

    def initialize(
      account_id: nil, account_name:, accountable_type: nil, subtype: nil,
      product: nil, currency: nil,
      gross:, taxable_base: nil, tax: nil, basis: "", basis_source: nil,
      warnings: [],
      missing_facts: [], modelled: nil, household_rate_income: BigDecimal(0),
      reviewed: false
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
      @basis_source = basis_source
      @warnings = Array(warnings)
      @missing_facts = Array(missing_facts).map(&:to_sym)
      @modelled = modelled.nil? ? !tax.nil? : modelled
      @household_rate_income = household_rate_income || BigDecimal(0)
      @reviewed = !!reviewed
    end

    # True when a rule produced a number we are willing to stand behind.
    def modelled?
      @modelled
    end

    def reviewed?
      @reviewed
    end

    # The warnings sorted by what each of them asks of the reader.
    #
    # One array in, three named piles out, so that a caller asks a question
    # instead of scanning. This is the engine's own reading of its own
    # sentences -- see Tax::Messages::SEVERITY -- and it is deliberately not
    # the page's: the report demotes some gaps once the household has been
    # asked and declined to answer, and that judgement belongs at the view
    # edge rather than in a value object that has never heard of a form.
    #
    # A plain String can appear among the warnings -- Rules::Composed carries
    # the notes a household typed into their own custom rule -- and has no key
    # to look a severity up by. Those are notes: the household wrote them, so
    # they are already as loud as their author wanted.
    def warnings_by_severity
      warnings.group_by do |warning|
        warning.respond_to?(:severity) ? warning.severity : :note
      end
    end

    # Something is missing or contradictory and the figure would change if it
    # were put right. The figure still stands, which is what separates this
    # from `blocked?`.
    def gaps?
      warnings_by_severity.fetch(:gap, []).any?
    end

    # Nothing was computed, and the warnings say why. Distinct from
    # `!modelled?` only in principle -- a blocker is what makes a result
    # unmodelled -- but a caller that wants to print the reasons should ask
    # for the reasons.
    def blocked?
      warnings_by_severity.fetch(:blocker, []).any?
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
        basis: basis, modelled: modelled?, warnings: warnings,
        missing_facts: missing_facts
      }
    end
  end
end
