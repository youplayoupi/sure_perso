# frozen_string_literal: true

module Tax
  # What a family actually changed, as opposed to what they submitted.
  #
  # The rates screen renders every figure in the shipped file and posts every
  # figure back, because a form that only showed the corrected ones would ask
  # people to correct a number they cannot see. What gets *stored* has to be
  # much smaller than that, and the reason is upgrades.
  #
  # The shipped file is versioned with the module. Next year's image carries
  # next year's brackets, a rate that changed in a Finance Act, a ceiling that
  # moved. A family who saved the whole table once would be pinned to the rates
  # as they stood the day they clicked save, and would go on filing against
  # them for as long as the row survived -- silently, because a stored rate and
  # a shipped rate look identical on screen. Storing only the difference means
  # a section nobody has touched keeps tracking the file, and a section someone
  # has corrected keeps their correction. That is the behaviour a self-hoster
  # already gets from editing the YAML, which is the thing this screen replaces.
  #
  # So: `diff` takes the shipped data and what came off the form, and returns
  # the smallest override document that turns one into the other. An entry that
  # matches what shipped is dropped, not stored as a no-op.
  #
  # There is a consequence worth stating plainly, because the screen has to say
  # it too: reverting a figure to its shipped value and deleting a correction
  # are the same operation here, and neither can remove an entry the file
  # ships. Tax::RateOverlay merges; it has no vocabulary for deletion. A
  # household that wants a shipped bracket gone has to set it to something,
  # not unset it.
  #
  # Pure Ruby, like the overlay it feeds, because deciding whether 0.186 and
  # "18.60" are the same number is exactly the sort of thing that should be
  # testable without booting Rails.
  module RateEdit
    class << self
      # The smallest override document that turns `shipped` into `submitted`.
      #
      # Both are plain data in rate-file shape. The result is suitable for
      # Tax::RateCorrection#overrides, which is to say Tax::RateOverlay will
      # validate it and lay it back over the same shipped data.
      def diff(shipped, submitted)
        shipped = stringify_deep(shipped || {})
        submitted = stringify_deep(submitted || {})

        document = {}

        RateOverlay::DATED_SECTIONS.each do |section|
          next unless submitted.key?(section)

          changed = changed_dated_entries(Array(shipped[section]), Array(submitted[section]))
          document[section] = changed if changed.any?
        end

        if submitted.key?("products")
          products = changed_products(shipped["products"] || {}, submitted["products"] || {})
          document["products"] = products if products.any?
        end

        document
      end

      # Whether two figures are the same number, whatever they are spelled as.
      #
      # Public because the rates screen has to mark a corrected box as
      # corrected, and it must reach the same verdict as `diff` does about
      # what counts as a change. Two implementations of "is this different?"
      # would eventually disagree, and the way it would show is a box the page
      # calls corrected that this class declined to store.
      def same_figure?(a, b) = same_number?(a, b)

      private
        # Matched on `effective_from`, the same key Tax::RateOverlay merges on.
        # An entry whose date the file does not have is new and always kept; an
        # entry whose date it does have is kept only if some value differs.
        def changed_dated_entries(shipped, submitted)
          by_date = shipped.each_with_object({}) { |e, out| out[date_key(e)] = e }

          submitted.reject do |entry|
            original = by_date[date_key(entry)]
            original && same_entry?(original, entry)
          end
        end

        # Compared on the keys the form can actually set, not on the whole
        # entry. The shipped file carries `note:` on several rows -- prose
        # explaining which Finance Act moved the number -- and the form neither
        # shows it nor posts it back. Comparing whole hashes would find every
        # annotated row different from itself and store the lot.
        def same_entry?(original, submitted)
          return false unless same_number?(original["rate"], submitted["rate"])

          same_brackets?(original["brackets"], submitted["brackets"])
        end

        def same_brackets?(original, submitted)
          return true if original.nil? && submitted.nil?
          return false if original.nil? || submitted.nil?
          return false unless original.length == submitted.length

          original.zip(submitted).all? do |a, b|
            same_number?(a["upto"], b["upto"]) && same_number?(a["rate"], b["rate"])
          end
        end

        def changed_products(shipped, submitted)
          submitted.each_with_object({}) do |(name, attrs), out|
            original = shipped[name] || {}

            changed = (attrs || {}).reject do |key, value|
              same_number?(original[key], value)
            end

            out[name] = changed if changed.any?
          end
        end

        # Value equality, not textual. 0.186 off the YAML parser is a Float,
        # "0.186" off the form is a String, and 18.60 typed into a percentage
        # box arrives as yet another spelling of the same rate. Treating any of
        # those as a correction would store a row that changes nothing and
        # freeze the section against future upgrades -- the exact failure this
        # module exists to avoid.
        def same_number?(a, b)
          return true if a.nil? && b.nil?
          return false if a.nil? || b.nil?

          left, right = decimal(a), decimal(b)
          return a.to_s.strip == b.to_s.strip if left.nil? || right.nil?

          left == right
        end

        def decimal(value)
          return value if value.is_a?(BigDecimal)

          BigDecimal(value.to_s.strip)
        rescue ArgumentError, TypeError
          nil
        end

        def date_key(entry)
          entry["effective_from"].to_s.strip
        end

        def stringify_deep(value)
          case value
          when Hash  then value.to_h.each_with_object({}) { |(k, v), out| out[k.to_s] = stringify_deep(v) }
          when Array then value.map { |v| stringify_deep(v) }
          else value
          end
        end
    end
  end
end
