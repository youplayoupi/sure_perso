# frozen_string_literal: true

# Settings > Taxes: which rule this module applies to each of Sure's products.
#
# The products are not a list this module maintains. They are Sure's own
# `Accountable::TYPES` and their `SUBTYPES`, walked by Tax::Coverage, which is
# why a subtype added in a future Sure release turns up on this page by itself
# with a rule selector next to it. Nothing here has to be edited when that
# happens.
#
# One row of `tax_custom_rules` per product the family has overridden, and none
# at all for the products where the built-in rule is right -- so a family that
# has never opened this page has an empty table and behaves exactly as before.
class Settings::TaxesController < ApplicationController
  layout "settings"

  before_action :require_supported_country

  def show
    @country   = builder.country
    @registry  = builder.registry
    @coverage  = Tax::Coverage.new(@registry)
    @catalogue = Tax::Catalogue.entries
    @pinned    = pinned_rules

    # A second registry with no custom rules, so each row can say what would
    # happen if the family's own choice were removed. Without it the "use the
    # built-in" option would have to be labelled generically, and the one
    # question this page has to answer -- what am I overriding? -- would go
    # unanswered.
    @built_in = Tax::Registry.new(country: @country)

    @selected = rules.by_key.to_h { |r| [ [ r.accountable_type, r.subtype ], r.kind ] }

    # Products the family holds lead the page; the rest of Sure's world
    # catalogue goes behind a disclosure. A product with a rule the family set
    # by hand counts as held even if the account has since gone, so that a
    # stored row is never invisible on the page that manages it.
    @held, @unheld = @coverage.partition_by(
      helpers.tax_products_held(Current.family) + @selected.keys
    )

    # The same accounts the report covers, so a rule cannot be pinned to an
    # account the report will never look at.
    @pinnable = Current.family.accounts
                             .visible
                             .where.not(accountable_type: Tax::SubjectBuilder::EXCLUDED_TYPES)
                             .where.not(id: @pinned.map(&:account_id))
                             .order(:name)
  end

  # One product per request, because each row auto-submits its own select. The
  # alternative -- one big form for the whole page -- would make every change a
  # write to every row, and would turn a stale tab into a way to silently
  # revert a rule someone else set.
  def update
    accountable_type = params.dig(:tax_rule, :accountable_type).to_s
    subtype          = params.dig(:tax_rule, :subtype).presence
    kind             = params.dig(:tax_rule, :kind).to_s

    # The (type, subtype) pair is checked against what Sure actually defines,
    # not merely against the type list. `kind` is checked by the model against
    # Tax::Catalogue. Between them, a hand-crafted request can only ever write
    # a row that names a real product and a real rule.
    unless known_product?(accountable_type, subtype)
      return redirect_to settings_taxes_path, alert: t(".unknown_product")
    end

    kind.blank? ? clear(accountable_type, subtype) : assign(accountable_type, subtype, kind)
  end

  # Pinning a rule to one account.
  #
  # This is the answer to a product Sure has no subtype for -- PER being the
  # live example. There is nothing for a per-product rule to key on, so the
  # rule is attached to the account instead, and when Sure eventually ships the
  # subtype the built-in rule takes over and this row can be deleted with no
  # change in output.
  def create
    # Scoped to the family before the lookup, so an id belonging to someone
    # else is indistinguishable from an id that does not exist.
    account = Current.family.accounts.find_by(id: params.dig(:tax_rule, :account_id))

    return redirect_to settings_taxes_path, alert: t(".unknown_account") if account.nil?

    rule = Tax::CustomRule.find_or_initialize_by(
      family_id: Current.family.id, account_id: account.id
    )
    rule.kind = params.dig(:tax_rule, :kind).to_s

    if rule.save
      redirect_to settings_taxes_path, notice: t(".pinned")
    else
      redirect_to settings_taxes_path, alert: rule.errors.full_messages.to_sentence
    end
  end

  # Removing one. `rules` is already scoped to the family, so an id belonging
  # to someone else finds nothing and deletes nothing.
  def destroy
    rule = rules.pinned.find_by(id: params[:id])
    rule&.destroy

    redirect_to settings_taxes_path, notice: t(".unpinned")
  end

  private
    def clear(accountable_type, subtype)
      existing(accountable_type, subtype)&.destroy

      redirect_to settings_taxes_path, notice: t(".cleared")
    end

    def assign(accountable_type, subtype, kind)
      record = existing(accountable_type, subtype) ||
               rules.new(accountable_type: accountable_type, subtype: subtype)
      record.kind = kind

      if record.save
        redirect_to settings_taxes_path, notice: t(".saved")
      else
        redirect_to settings_taxes_path, alert: record.errors.full_messages.to_sentence
      end
    end

    def existing(accountable_type, subtype)
      rules.by_key.find_by(accountable_type: accountable_type, subtype: subtype)
    end

    # Scoped by family on every query rather than through a `has_many` on
    # Family. Adding the association would mean editing app/models/family.rb,
    # and this module is meant to come out by deleting files. The scoping is
    # the same either way; what changes is the footprint.
    def rules
      Tax::CustomRule.where(family_id: Current.family.id)
    end

    def pinned_rules
      rules.pinned.includes(:account).order(:created_at)
    end

    def known_product?(accountable_type, subtype)
      @coverage_index ||= Tax::Coverage.new(builder.registry)
                                       .entries
                                       .to_set { |e| [ e.accountable_type, e.subtype ] }

      @coverage_index.include?([ accountable_type, subtype ])
    end

    def builder
      @builder ||= Tax::SubjectBuilder.new(Current.family)
    end

    # Same test the nav entry uses. A household in a country this module has no
    # rules for gets no link here and no page behind it -- offering a rule
    # selector whose every option is French would be worse than offering
    # nothing.
    def require_supported_country
      return if Tax.supported?(Current.family&.country)

      redirect_to settings_profile_path
    end
end
