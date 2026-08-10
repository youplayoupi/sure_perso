# frozen_string_literal: true

module Tax
  # A family's corrections laid over the shipped rate file.
  #
  # The rate file is data, and the README has always said that a self-hoster
  # who needs to correct a number edits it and restarts. That is fine for the
  # person who deployed the container and useless for everyone else in the
  # household, so the same corrections can now be stored per family. This is
  # the merge, and it is deliberately here rather than in the ActiveRecord
  # model: it is arithmetic about which number applies on which date, it wants
  # the same kind of testing as the rules, and it must not need Rails to run.
  #
  # Three shapes, three merges, no others:
  #
  #   effective-dated rate lists
  #       Which sections these are is read off the shipped file rather than
  #       listed here: any top-level key holding a list of entries that each
  #       carry an `effective_from` and a `rate`. That is what lets a second
  #       country ship a file with sections France has never heard of and get
  #       a working corrections screen with no change to this module.
  #
  #       Matched on `effective_from`. An override with a date the file already
  #       has replaces that entry; an override with a new date is added to the
  #       schedule. The result is re-sorted by date.
  #
  #   products
  #       Merged one product at a time, one key at a time, so correcting a PEA
  #       ceiling does not silently drop its maturity or delete Livret A.
  #
  #   country, currency
  #       Not overridable. They identify which file this is; changing them
  #       would make the override document mean something different from the
  #       thing it was written against.
  #
  # Replacing rather than appending matters because RateTable#effective picks
  # the entry with the greatest `effective_from` and breaks ties by taking the
  # first it finds. Two entries on 2026-01-01 would resolve to whichever the
  # merge happened to put first -- a coin toss deciding a tax rate. Matching on
  # the date removes the tie instead of picking a winner for it.
  module RateOverlay
    # Top-level keys of a rate file that are not effective-dated rate lists.
    # Named so that `dated_sections` can recognise a rate section by shape and
    # still not mistake one of these for one.
    NON_RATE_KEYS = %w[country currency products composites unmodelled].freeze

    PRODUCTS = "products"

    class << self
      # The effective-dated rate sections of a rate file, by name.
      #
      # Recognised by shape, not by a list kept in Ruby. A section is a list of
      # entries, each dated and each carrying a rate. Everything a country file
      # holds that is not that -- its identity, its products, its composites,
      # its list of things nobody has modelled -- is excluded by shape anyway;
      # NON_RATE_KEYS is belt and braces for a future key that happens to look
      # like one.
      #
      # Both the corrections screen and Tax::RateEdit ask this rather than
      # keeping their own idea of what the file contains, because two lists
      # would drift and the way it would show is a section that is editable on
      # screen and silently discarded on save.
      def dated_sections(data)
        (data || {}).each_with_object([]) do |(key, value), out|
          name = key.to_s
          next if NON_RATE_KEYS.include?(name)
          next unless value.is_a?(Array) && !value.empty?
          next unless value.all? { |e| e.respond_to?(:to_h) && !e.is_a?(Array) && dated_rate?(e) }

          out << name
        end.sort
      end

      # Returns a new hash. Neither argument is mutated, because `base` is the
      # parsed YAML that Tax.rate_table memoises for the whole process, and a
      # merge that wrote into it would leak one family's corrections into every
      # other family's report.
      def apply(base, overrides)
        result = deep_dup(base || {})
        return result if overrides.nil? || overrides.empty?

        normalise(overrides).each do |section, value|
          result[section] =
            if section == "products"
              merge_products(result[section] || {}, value)
            else
              merge_dated(result[section] || [], value)
            end
        end

        result
      end

      # Everything wrong with an override document, in one pass, as sentences.
      # Empty means it can be saved. Same contract as Formula#errors and for
      # the same reason: a form should be able to show every problem at once
      # rather than make the author find them one save at a time.
      # `known_sections` is the section list of the file these corrections are
      # written against, and passing it is what turns a typo into an error. An
      # unknown key is far more likely to be "social_charge" than a section
      # this module has not heard of, and left unreported it would sit in the
      # database looking applied while changing nothing. Callers that have the
      # shipped file -- which is all of them in the app -- should pass it.
      # Omitted, the shape of each section is still checked; only the names
      # are taken on trust.
      def errors(overrides, known_sections: nil)
        return [] if overrides.nil? || overrides.empty?

        unless overrides.respond_to?(:to_h)
          return [ "Rate corrections must be a set of sections, not #{overrides.class}." ]
        end

        permitted = known_sections.nil? ? nil : (Array(known_sections).map(&:to_s) + [ PRODUCTS ])

        normalise(overrides).flat_map do |section, value|
          if permitted && !permitted.include?(section)
            [ "'#{section}' is not a section of the rate file (#{permitted.sort.join(', ')})." ]
          elsif section == PRODUCTS
            product_errors(value)
          else
            dated_errors(section, value)
          end
        end
      end

      def valid?(overrides, known_sections: nil)
        errors(overrides, known_sections: known_sections).empty?
      end

      # Which sections a family has actually corrected, for the "this figure is
      # not the shipped one" flag on the report. A section present but equal to
      # what shipped still counts as edited -- someone typed it, and the report
      # should say the number came from them.
      def edited_sections(overrides)
        return [] if overrides.nil? || overrides.empty?

        normalise(overrides).reject { |_, v| v.nil? || v.empty? }.keys
      end

      private
        def dated_rate?(entry)
          row = stringify(entry)
          row.key?("effective_from") && row.key?("rate")
        end

        # jsonb round-trips with string keys, but a hash built in a controller
        # or a test arrives with symbols. Normalising once here means every
        # method below can assume strings, and the two paths cannot drift.
        def normalise(hash)
          hash.to_h.each_with_object({}) do |(key, value), out|
            out[key.to_s] = value
          end
        end

        def merge_dated(shipped, entries)
          return deep_dup(shipped) if entries.nil?

          by_date = {}
          Array(shipped).each { |e| by_date[date_key(e)] = deep_dup(e) }
          Array(entries).each { |e| by_date[date_key(e)] = stringify(e) }

          by_date.values.sort_by { |e| date_key(e).to_s }
        end

        def merge_products(shipped, products)
          merged = deep_dup(shipped)
          normalise(products).each do |name, attrs|
            next if attrs.nil?

            merged[name] = (merged[name] || {}).merge(stringify(attrs))
          end
          merged
        end

        def date_key(entry)
          value = stringify(entry)["effective_from"]
          value.is_a?(Date) ? value.to_s : value.to_s
        end

        # Date.parse is generous -- "2026" and "1 Jan" both succeed and both
        # mean something the author did not type. The rate file writes plain
        # ISO dates and so does the form, so anything else is a mistake worth
        # naming rather than a shorthand worth guessing at.
        def parseable_date?(value)
          return true if value.is_a?(Date)

          text = value.to_s.strip
          return false unless /\A\d{4}-\d{2}-\d{2}\z/.match?(text)

          Date.parse(text)
          true
        rescue ArgumentError, TypeError
          false
        end

        def dated_errors(section, entries)
          unless entries.is_a?(Array)
            return [ "'#{section}' must be a list of dated entries." ]
          end

          entries.flat_map.with_index do |entry, index|
            where = "#{section} entry #{index + 1}"
            row = stringify(entry)
            problems = []

            if row["effective_from"].to_s.strip.empty?
              problems << "#{where} has no date it takes effect from."
            elsif !parseable_date?(row["effective_from"])
              problems << "#{where}: '#{row['effective_from']}' is not a date."
            end

            problems + entry_value_errors(section, where, row)
          end
        end

        # Every dated section is one rate per date. It used to be two shapes,
        # the second being the income-tax scale with its list of bands; that
        # went when the scale did, and with it the only reason this method had
        # to know one section name from another.
        def entry_value_errors(_section, where, row)
          rate_errors(where, row["rate"])
        end

        def rate_errors(where, rate)
          return [ "#{where} has no rate." ] if rate.nil? || rate.to_s.strip.empty?

          decimal = begin
            BigDecimal(rate.to_s)
          rescue ArgumentError
            return [ "#{where}: '#{rate}' is not a number." ]
          end

          return [] if decimal >= 0 && decimal <= 1

          # The mistake this exists for is typing 18.6 where 0.186 was meant,
          # which would otherwise produce a tax bill eighteen times the account
          # balance and no complaint from anything downstream.
          [ "#{where}: #{rate} is not between 0 and 1. Rates are decimals, so 18.6% is 0.186." ]
        end

        def product_errors(products)
          return [ "'products' must be a set of products." ] unless products.respond_to?(:to_h)

          normalise(products).flat_map do |name, attrs|
            next [ "products/#{name} must be a set of values." ] unless attrs.respond_to?(:to_h)

            stringify(attrs).flat_map do |key, value|
              next [] if value.nil?

              case key
              when "maturity_years" then years_errors(name, value)
              when "ceiling" then ceiling_errors(name, value)
              else [ "products/#{name}: '#{key}' is not a value this module reads." ]
              end
            end
          end
        end

        def years_errors(name, value)
          years = Integer(value.to_s, exception: false)
          return [ "products/#{name}: maturity must be a whole number of years." ] if years.nil?
          return [] if years >= 0 && years <= 100

          [ "products/#{name}: a maturity of #{years} years is not plausible." ]
        end

        def ceiling_errors(name, value)
          amount = BigDecimal(value.to_s, exception: false)
          return [ "products/#{name}: the ceiling must be an amount." ] if amount.nil?
          return [] if amount >= 0

          [ "products/#{name}: the ceiling cannot be negative." ]
        end

        def stringify(value)
          return value unless value.respond_to?(:to_h) && !value.is_a?(Array)

          value.to_h.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
        end

        def deep_dup(value)
          case value
          when Hash  then value.each_with_object({}) { |(k, v), out| out[k.to_s] = deep_dup(v) }
          when Array then value.map { |v| deep_dup(v) }
          else value
          end
        end
    end
  end
end
