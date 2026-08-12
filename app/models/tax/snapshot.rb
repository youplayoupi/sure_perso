# frozen_string_literal: true

module Tax
  # A whole portfolio, valued and taxed on one date.
  #
  # The totals are careful in one specific way: accounts whose tax could not be
  # computed still contribute their gross, but contribute no tax. That makes
  # `net` an upper bound rather than an answer whenever `complete?` is false,
  # and both facts have to travel together to the view. Showing the net without
  # showing that it is incomplete would be the single most misleading thing
  # this module could do.
  class Snapshot
    attr_reader :on, :year_offset, :results

    def initialize(on:, results:, year_offset: 0)
      @on = on
      @results = results
      @year_offset = year_offset
    end

    def gross
      sum { |r| r.gross }
    end

    def tax
      sum { |r| r.tax }
    end

    # Upper bound when incomplete. See the class comment.
    def net
      gross - tax
    end

    def modelled_gross
      sum { |r| r.modelled? ? r.gross : nil }
    end

    def unmodelled_gross
      sum { |r| r.modelled? ? nil : r.gross }
    end

    def complete?
      results.all?(&:modelled?)
    end

    # The accounts there is no figure for, in the order the results came in.
    #
    # This replaces a count. "3 accounts could not be computed" tells a reader
    # that something is wrong and leaves them to work out which, which on a page
    # of nine rows means reading all nine to find the three -- and the banner
    # exists precisely so they do not have to. A list of names is longer and
    # answers the question the sentence raises.
    def incomplete
      results.reject(&:modelled?)
    end

    def effective_rate
      total = gross
      return BigDecimal(0) if total.nil? || total.zero?

      tax / total
    end

    # The effective rate over only the part we could actually compute, which is
    # the honest headline when some accounts are unknown.
    def modelled_effective_rate
      base = modelled_gross
      return BigDecimal(0) if base.nil? || base.zero?

      tax / base
    end

    private
      def sum
        results.reduce(BigDecimal(0)) do |acc, result|
          value = yield(result)
          value.nil? ? acc : acc + value
        end
      end
  end
end
