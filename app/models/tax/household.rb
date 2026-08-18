# frozen_string_literal: true

module Tax
  # What the household says about itself, as opposed to about its accounts.
  #
  # One row per family, holding the marginal rate of income tax that the
  # rules apply to anything taxed as income: the deducted payments coming out
  # of a PER, the growth on one when the progressive scale has been elected.
  #
  # There is exactly one number here today and that is not an accident of an
  # unfinished feature. The module used to run France's five-band scale, which
  # needed the household's other taxable income and its number of parts, and
  # both of those were asked for on the report as URL parameters that defaulted
  # to zero and one. Nobody changed them, so every large withdrawal was taxed
  # as though it were the household's only income -- a wrong answer arrived at
  # confidently, which is the one output this module is built to refuse. One
  # rate the household can read off last year's assessment is less machinery
  # and better arithmetic in practice.
  class Household < ApplicationRecord
    self.table_name = "tax_households"

    belongs_to :family

    validates :family_id, uniqueness: true

    # Stored as a fraction, so the range is the range. The form converts from
    # percent on the way in and back on the way out; see
    # Settings::TaxHouseholdsController.
    validates :marginal_rate,
              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
              allow_nil: true

    def self.for(family)
      find_or_initialize_by(family: family)
    end

    # The rate to hand Tax::Assumptions, or nil when the household has not
    # said. nil is the whole point: it is what makes the report label its own
    # total provisional instead of presenting a placeholder as an answer.
    def self.marginal_rate_for(family)
      return nil if family.nil?

      find_by(family_id: family.id)&.marginal_rate
    end

    def declared? = marginal_rate.present?
  end
end
