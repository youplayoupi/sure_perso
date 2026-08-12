# frozen_string_literal: true

module Tax
  # The facts about an account that Sure has nowhere to store.
  #
  # Every column is nullable on purpose. A half-filled profile is useful --
  # declaring an opening date without declaring payments in still improves the
  # report, and the rule will refuse the parts it cannot compute rather than
  # refuse the account. Nothing here is required to use Sure, and an account
  # with no profile at all behaves exactly as it did before this module
  # existed.
  #
  # `paid_in` is the field worth being careful about, so it is worth saying
  # once more where it will be read: it is the total ever paid into the
  # wrapper, not the cost basis of what is currently held. Reinvest a dividend
  # and cost basis rises while payments in do not. Sell and rebuy and cost
  # basis resets while payments in do not. The two numbers drift apart in one
  # direction only, so using cost basis in place of payments in always
  # understates the tax -- which is why the rules refuse rather than substitute.
  class Profile < ApplicationRecord
    self.table_name = "tax_profiles"

    belongs_to :account

    # The facts a person can actually type, in the order the form asks for
    # them, and the reason the form does not simply render every column.
    #
    # A rule states what it wants through `Tax::Formula#needs` and
    # `#optional_needs`, in the engine's vocabulary -- which includes facts no
    # form collects, `:cost_basis` above all, because that one is derived from
    # Sure's own holdings. Intersecting against this list is how a caller turns
    # "what the arithmetic wants" into "what there is a box for", and it is why
    # a missing cost basis produces an explanation on the report rather than a
    # link to a form with nothing on it.
    #
    # `notes` is absent deliberately: it is free text about the account rather
    # than an input to any rule, so it is always offered and never asked for.
    DECLARABLE = %i[product paid_in paid_in_deducted opened_on].freeze

    validates :account_id, uniqueness: true
    validates :paid_in, :paid_in_deducted,
              numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
    validate :product_is_known
    validate :opening_date_is_not_in_the_future

    scope :reviewed, -> { where.not(reviewed_at: nil) }

    def reviewed? = reviewed_at.present?

    # Deliberately not a validation. Someone mid-way through filling the form
    # should be able to save what they have, and a paid-in figure larger than
    # the deducted part is a thing to point out on the report rather than a
    # thing to block a save over. The rule caps it and warns.
    def deduction_exceeds_payments?
      paid_in.present? && paid_in_deducted.present? && paid_in_deducted > paid_in
    end

    def blank_declaration?
      product.blank? && opened_on.nil? && paid_in.nil? && paid_in_deducted.nil?
    end

    private
      # The product list comes from the rate file, so adding a product is a
      # YAML edit. Validating against it stops a typo ("livretA") from silently
      # falling through to the unknown rule weeks later.
      #
      # The messages are symbols rather than sentences. This is a record, not
      # the engine -- it already depends on Rails, so it can use the ordinary
      # activerecord.errors mechanism instead of the Tax::Message scheme the
      # engine needs. Both end up in config/locales; only the route differs,
      # and the route is decided by whether the file can load I18n at all.
      def product_is_known
        return if product.blank?

        country = account&.family&.country.presence || Tax::DEFAULT_COUNTRY

        # No rate file for this country means the field cannot mean anything.
        # Rejecting it is friendlier than accepting a value that will silently
        # never be read -- the earlier version of this validation skipped
        # quietly here, which made "livretA" look like it had been saved fine.
        unless Tax.supported?(country)
          errors.add(:product, :unsupported_country, country: country)
          return
        end

        rates = Tax.rate_table(country)
        return if rates.product?(product)

        # The list is in the message because the field is a free-text select
        # backed by a YAML file: "not a product this module knows about" on its
        # own leaves the reader with no way to find out what is.
        errors.add(:product, :unknown_product, products: rates.product_names.join(", "))
      end

      def opening_date_is_not_in_the_future
        return if opened_on.nil? || opened_on <= Date.current

        errors.add(:opened_on, :in_the_future)
      end
  end
end
