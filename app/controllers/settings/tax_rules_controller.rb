# frozen_string_literal: true

# Settings > Taxes > Rules: what every rule does, and a builder for writing one.
#
# Two audiences, one page, and that is deliberate. Someone who has just picked
# "PEA (gain net, 5-year clock)" from the selector on the page next door wants
# to know what they picked; someone whose product this module has no rule for
# wants to write one. Splitting those into separate screens would mean the
# second group never sees the worked examples that are the best documentation
# the first group has -- and would let the shipped rules and the hand-written
# ones be described in different vocabularies, which is exactly the drift
# Tax::Formula exists to prevent.
#
# So the shipped rules render read-only from their declared formulas, through
# the same presenter that renders a family's own, and both say things like
# "18.6% social charges on the gain over what was paid in, once the account is
# 5 years old". A reader can compare them because they are the same sentence
# shape, and the equivalence test in test/models/tax/formula_test.rb is what
# makes the shipped ones true.
class Settings::TaxRulesController < ApplicationController
  layout "settings"

  before_action :require_supported_country
  before_action :set_rule, only: %i[edit update destroy]
  before_action :set_targets, only: %i[new create edit update]

  def index
    @built_ins = Tax::Catalogue.entries.reject { |kind, _| Tax::Catalogue.composed?(kind) }
    @mine = rules.where(kind: Tax::Catalogue::COMPOSED).order(:created_at)
  end

  def new
    @rule = rules.new(kind: Tax::Catalogue::COMPOSED, params: starting_params)
    apply_target(@rule, params[:target])
  end

  def create
    @rule = rules.new(kind: Tax::Catalogue::COMPOSED)

    if save(@rule)
      redirect_to settings_taxes_rules_path, notice: t(".created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if save(@rule)
      redirect_to settings_taxes_rules_path, notice: t(".updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @rule.destroy

    redirect_to settings_taxes_rules_path, notice: t(".deleted")
  end

  private
    # Both writes go through here, so a create and an update can never disagree
    # about how a form becomes a formula.
    def save(rule)
      rule.params = formula_params
      apply_target(rule, rule_params[:target])
      rule.save
    end

    # Scoped by family on every query rather than through a `has_many` on
    # Family, for the reason Settings::TaxesController gives: this module is
    # meant to come out by deleting files.
    def rules
      Tax::CustomRule.where(family_id: Current.family.id)
    end

    def set_rule
      @rule = rules.where(kind: Tax::Catalogue::COMPOSED).find_by(id: params[:id])

      # Absolute rather than lazy: this runs in a before_action, where the lazy
      # form would resolve against whichever action was asked for and need the
      # same sentence written out three times.
      return if @rule

      redirect_to settings_taxes_rules_path, alert: t("settings.tax_rules.not_found")
    end

    # What a rule can be pointed at: the family's own accounts, and Sure's
    # products.
    #
    # The account list is scoped exactly as Tax::SubjectBuilder scopes the
    # report, so a rule cannot be attached to an account the report will never
    # look at. Offering one would produce a rule that appears to be in force
    # and changes no figure anywhere.
    def set_targets
      @accounts = Current.family.accounts
                         .visible
                         .where.not(accountable_type: Tax::SubjectBuilder::EXCLUDED_TYPES)
                         .order(:name)

      # Split the same way Settings::TaxesController splits its page, and for
      # the same reason: Sure's subtype list is a world catalogue, eighty-odd
      # wrappers across a dozen countries. Offering it flat would file the PEA
      # between Kisan Vikas Patra and Riester-Rente, and the one product this
      # family is writing a rule for would be the hardest to find in the list.
      #
      # The rest is offered rather than dropped, because writing a rule for a
      # product before opening one is legitimate -- it decides what happens the
      # first time you do.
      @held_products, @other_products =
        Tax::Coverage.new(Tax::SubjectBuilder.new(Current.family).registry)
                     .partition_by(helpers.tax_products_held(Current.family))
    end

    TERM_FIELDS = %i[base rate literal_rate condition opened_from opened_until].freeze

    def rule_params
      @rule_params ||= params.fetch(:tax_rule, {})
                             .permit(:name, :maturity_years, :notes, :target)
    end

    # Term rows arrive keyed by index -- `tax_rule[terms][3][base]` -- rather
    # than as a bare array, because the builder adds and removes rows and an
    # array would silently re-pair a base with the wrong rate the moment a row
    # in the middle went away.
    #
    # Insertion order is the form's order, which is the order the rule is read
    # in. The keys themselves are not sortable and are not sorted: the Stimulus
    # controller stamps new rows with a timestamp, so sorting would file every
    # added row after every original one regardless of where it was put.
    def term_rows
      rows = params.dig(:tax_rule, :terms)
      return [] if rows.blank?

      rows.values.map { |row| row.permit(*TERM_FIELDS) }
    end

    # The form's shape, turned into the formula the engine stores.
    #
    # Nothing here validates. Tax::Formula does that, Tax::CustomRule surfaces
    # it as a form error, and Rules::Composed refuses at run time if a bad row
    # gets in anyway. A controller that also validated would be a fourth
    # opinion about what a valid rule is, and the fourth opinion is the one
    # that ends up wrong.
    def formula_params
      {
        "terms" => term_rows.filter_map { |t| term_from(t) },
        "maturity_years" => rule_params[:maturity_years].presence,
        "notes" => Array(rule_params[:notes].to_s.split("\n")).map(&:strip).reject(&:empty?),
        "name" => rule_params[:name].to_s.strip.presence
      }.compact
    end

    # A blank base is an empty row -- the form always renders one, and the
    # Stimulus controller adds more -- so it is dropped rather than reported.
    # Every other blank is kept and left for the validator to complain about,
    # because a row someone half-filled is a row they meant to fill.
    def term_from(term)
      return nil if term[:base].blank?

      {
        "base" => term[:base],
        "rate" => term[:rate],
        "literal_rate" => literal_rate_for(term),
        "condition" => term[:condition].presence || "always",
        "opened_from" => term[:opened_from].presence,
        "opened_until" => term[:opened_until].presence
      }.compact
    end

    # The form asks for a percentage because that is what a rate is called
    # everywhere outside this codebase; the engine stores a fraction because
    # that is what it multiplies by. 7.5 in the box becomes 0.075 in the row.
    #
    # Only for a literal. Sending a percentage on a named rate would be a
    # contradiction the formula rejects, and it is left to do so rather than
    # silently dropped, so the author finds out they filled in a box that does
    # not apply.
    def literal_rate_for(term)
      return nil if term[:literal_rate].blank?

      (BigDecimal(term[:literal_rate].to_s.tr(",", ".")) / 100).to_s("F")
    rescue ArgumentError, TypeError
      # Unreadable input is passed through unchanged so the formula can name it
      # in an error the author can act on. Swallowing it here would save the
      # rule with no rate at all.
      term[:literal_rate].to_s
    end

    # Where the rule applies, as one field.
    #
    # The model already insists a rule targets exactly one thing -- an account
    # or a product, never both -- so the form offers one grouped select rather
    # than two fields and a radio that can contradict each other. The encoded
    # value is decoded against the family's own accounts and Sure's own
    # product list, so a hand-crafted request can still only name something
    # real.
    def apply_target(rule, target)
      kind, value = target.to_s.split(":", 2)

      case kind
      when "account"
        rule.account_id = Current.family.accounts.where(id: value).pick(:id)
        rule.accountable_type = nil
        rule.subtype = nil
      when "product"
        accountable_type, subtype = value.to_s.split("|", 2)
        return unless known_product?(accountable_type, subtype.presence)

        rule.account_id = nil
        rule.accountable_type = accountable_type
        rule.subtype = subtype.presence
      end
    end

    # A rule with no terms is valid -- it is how "genuinely untaxed" is written
    # -- but it is not a useful thing to hand someone who clicked "write a
    # rule". One empty row is the invitation.
    def starting_params
      { "terms" => [ { "base" => "", "rate" => "" } ] }
    end

    def known_product?(accountable_type, subtype)
      return false if accountable_type.blank?

      @coverage_index ||= Tax::Coverage
                          .new(Tax::SubjectBuilder.new(Current.family).registry)
                          .entries
                          .to_set { |e| [ e.accountable_type, e.subtype ] }

      @coverage_index.include?([ accountable_type, subtype ])
    end

    def require_supported_country
      return if Tax.supported?(Current.family&.country)

      redirect_to settings_profile_path
    end
end
