# frozen_string_literal: true

module Tax
  # Every product Sure knows about, and whether this module has a rule for it.
  #
  # This is the answer to "what happens when Sure adds a new account subtype".
  # Nothing breaks and nothing is silently mistaxed -- the new subtype simply
  # appears here as uncovered, with Sure's own classification beside it and a
  # suggestion for which rule would fit. The gap is visible in the UI on the
  # day the upgrade lands, without anyone editing this module.
  class Coverage
    Entry = Struct.new(
      :accountable_type, :subtype, :label, :tax_treatment,
      :covered, :rule_id, :rule_label, :suggested_rule_id, :custom,
      keyword_init: true
    ) do
      def covered? = covered
      def custom? = custom
    end

    # Types the report will never look at are left out rather than listed as
    # uncovered. Liabilities are out of scope by construction -- this module
    # answers "what would you keep", not "what are you worth" -- so a row
    # offering a tax rule for a credit card offers a rule that can never fire,
    # and counting it as a gap inflates the "N of M covered" figure with
    # products that were never in the running.
    #
    # Derived from SubjectBuilder's own exclusion list rather than restated, so
    # the coverage table and the accounts actually taxed cannot disagree about
    # what is in scope.
    def self.default_types
      Accountable::TYPES - Tax::SubjectBuilder::EXCLUDED_TYPES
    end

    def initialize(registry, types: nil)
      @registry = registry
      @types = types || self.class.default_types
    end

    def entries
      @entries ||= @types.flat_map { |type_name| entries_for(type_name) }
    end

    def covered
      entries.select(&:covered?)
    end

    def uncovered
      entries.reject(&:covered?)
    end

    def uncovered_count
      uncovered.size
    end

    def by_type
      entries.group_by(&:accountable_type)
    end

    # Split the catalogue into the products the family actually holds and the
    # rest.
    #
    # Sure's SUBTYPES is a world catalogue -- 401(k), Riester-Rente, Kisan
    # Vikas Patra and eighty more. A French household is not helped by being
    # asked to choose a French tax rule for a Thrift Savings Plan, and a
    # coverage figure of "19 of 86" describes Sure's breadth rather than
    # anything about this portfolio.
    #
    # Nothing is hidden: the remainder is still enumerated, and a subtype added
    # in a future Sure release still appears. It appears in the half of the
    # page that is about products nobody here owns, which is where it belongs
    # until somebody owns one.
    #
    # `keys` is a set of [accountable_type, subtype] pairs, built from the
    # family's own accounts by the caller. Coverage does not query anything --
    # that is what makes it testable against a bare registry.
    def partition_by(keys)
      entries.partition { |e| keys.include?([ e.accountable_type, e.subtype ]) }
    end

    private
      def entries_for(type_name)
        klass = resolve(type_name)
        return [] if klass.nil?

        subtypes = klass.const_defined?(:SUBTYPES) ? klass::SUBTYPES : {}

        # A class with no SUBTYPES still deserves a row: it can hold value and
        # therefore can be taxed.
        return [ entry(type_name, nil, type_name, nil) ] if subtypes.empty?

        subtypes.map do |subtype, meta|
          entry(type_name, subtype, meta[:long] || meta[:short] || subtype, treatment_for(klass, subtype, meta))
        end
      end

      def entry(type_name, subtype, label, treatment)
        rule = @registry.rule_for(type_name, subtype)

        Entry.new(
          accountable_type: type_name,
          subtype: subtype,
          label: label,
          tax_treatment: treatment,
          covered: !rule.nil?,
          rule_id: rule&.rule_id,
          rule_label: rule ? rule.class.label : nil,
          suggested_rule_id: rule ? nil : Treatment.suggested_rule_id(treatment),
          custom: @registry.custom?(type_name, subtype)
        )
      end

      # Read Sure's classification without instantiating anything. Mirrors what
      # `Investment#tax_treatment` and `Depository#tax_treatment` do.
      def treatment_for(klass, subtype, meta)
        return meta[:tax_treatment] if meta[:tax_treatment]

        if klass.const_defined?(:TAX_ADVANTAGED_SUBTYPES) &&
           klass::TAX_ADVANTAGED_SUBTYPES.include?(subtype)
          return :tax_advantaged
        end

        klass == Investment ? :taxable : nil
      end

      def resolve(type_name)
        Accountable.from_type(type_name)
      rescue NameError
        nil
      end
  end
end
