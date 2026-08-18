# frozen_string_literal: true

module Tax
  # A read-only description of what one country's rules actually do, assembled
  # from the engine itself rather than written by hand.
  #
  # The country page exists to answer "what does Sure do with my accounts here",
  # and the only trustworthy source for that is the same registry and rate table
  # the report runs on. Hand-written prose would drift the moment a subtype is
  # remapped or a rate file gains a section; this reads both back, so the page
  # cannot claim a wrapper is exempt while the registry taxes it.
  #
  # Pure PORO, no Rails: it takes a RateTable (already loaded, corrections and
  # all) and reads the registry's public class-level mapping. That keeps it
  # testable in the bare engine process and keeps the classification of a rule
  # in one place. All wording -- subtype labels, rate names, translated reasons
  # -- is left to the view edge, which knows the reader's language; this returns
  # identifiers and numbers.
  class CountryGuide
    # How a rule is presented on the page. Derived from the rule class, so a new
    # rule lands in the right bucket without this list being touched, except a
    # genuinely new *kind* of rule, which should be a deliberate addition here.
    def self.classify(rule)
      case rule
      when Rules::Exempt      then :exempt
      when Rules::CashDeposit then :cash
      when Rules::NotModelled then :not_modelled
      when Rules::Unknown     then :uncovered
      else :taxed
      end
    end

    Section = Struct.new(:name, :current_rate, :entries, keyword_init: true)
    Composite = Struct.new(:name, :parts, :current_rate, keyword_init: true)
    Product = Struct.new(:name, :label, :ceiling, :maturity_years, keyword_init: true)
    Group = Struct.new(:classification, :rule_id, :label, :reason, :pairs, keyword_init: true)

    attr_reader :country, :rate_table

    def initialize(country, rate_table:)
      @country = country.to_s.upcase
      @rate_table = rate_table
    end

    def currency
      rate_table.currency
    end

    # The dated rate sections, each with the value in force on `on` and its full
    # schedule (including entries not yet effective, which a household correcting
    # next year's rate needs to see).
    def rate_sections(on: Date.today)
      rate_table.dated_section_names.sort.map do |name|
        entries = rate_table.entries_for(name).map do |e|
          { effective_from: to_date(e["effective_from"]), rate: dec(e["rate"]), note: e["note"] }
        end.sort_by { |e| e[:effective_from] }

        Section.new(name: name, current_rate: current(name, on), entries: entries)
      end
    end

    # Rates the file states as the sum of other rates (France's PFU; the US
    # long-term-plus-NIIT figure), resolved on `on`.
    def composites(on: Date.today)
      rate_table.composites.map do |name, parts|
        Composite.new(name: name, parts: parts, current_rate: current(name, on))
      end
    end

    def products
      rate_table.product_names.map do |name|
        Product.new(
          name: name,
          label: rate_table.product_label(name),
          ceiling: rate_table.ceiling(name),
          maturity_years: rate_table.maturity_years(name)
        )
      end
    end

    # The `unmodelled:` list: things the country taxes that the module names but
    # does not compute. Raw hashes ({ "id", "label", "reason" }); the reasons
    # are in the country's own language, like the rest of the rate file.
    def unmodelled
      rate_table.unmodelled
    end

    # Every built-in rule for this country, grouped so each rule appears once
    # with the list of (accountable_type, subtype) pairs it covers, tagged with
    # how the page should present it. Ordered exempt/cash last so the taxed and
    # not-modelled wrappers -- the ones a reader is checking -- lead.
    def coverage_groups
      grouped = Registry.built_in(country).group_by { |(_pair, rule)| signature(rule) }

      groups = grouped.map do |_sig, entries|
        rule = entries.first.last
        Group.new(
          classification: self.class.classify(rule),
          rule_id: rule_id_of(rule),
          label: label_of(rule),
          reason: (rule.reason if rule.is_a?(Rules::NotModelled)),
          pairs: entries.map(&:first).sort_by { |(type, subtype)| [ type.to_s, subtype.to_s ] }
        )
      end

      groups.sort_by { |g| [ ORDER.fetch(g.classification, 99), g.label.to_s ] }
    end

    # A quick tally for the page header: how many wrappers land in each bucket.
    def counts
      coverage_groups.each_with_object(Hash.new(0)) do |group, out|
        out[group.classification] += group.pairs.size
      end
    end

    ORDER = { taxed: 0, not_modelled: 1, exempt: 2, cash: 3, uncovered: 4 }.freeze

    private
      # Two rules are the same row when they would tax an account the same way.
      # Class and rule_id cover the ordinary rules; the NotModelled reason is
      # folded in so "debt" and "NPS", both NotModelled, are two rows rather
      # than one lumped list with two reasons.
      def signature(rule)
        [ rule.class.name, rule_id_of(rule), (rule.reason.to_s if rule.is_a?(Rules::NotModelled)) ]
      end

      def rule_id_of(rule)
        rule.respond_to?(:rule_id) ? rule.rule_id : nil
      end

      def label_of(rule)
        rule.class.respond_to?(:label) ? rule.class.label : rule.class.name
      end

      def current(name, on)
        rate_table.rate(name, on)
      rescue RateError
        nil
      end

      def to_date(value)
        value.is_a?(Date) ? value : Date.parse(value.to_s)
      end

      def dec(value)
        return nil if value.nil?

        value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
      end
  end
end
