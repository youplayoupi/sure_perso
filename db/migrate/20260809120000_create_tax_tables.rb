# frozen_string_literal: true

# Two additive tables. Nothing existing is altered, and every column here holds
# a fact Sure has nowhere else to put.
#
# `tax_profiles` is the per-account declaration sheet. The three columns that
# matter are `paid_in`, `paid_in_deducted` and `opened_on`:
#
#   paid_in     Cumulative payments into the wrapper. This is NOT cost basis
#               and NOT the sum of buy trades -- a PEA is taxed on
#               valeur liquidative minus versements, and reinvested dividends
#               raise cost basis without being a versement. Sure cannot derive
#               it. Nullable, and null means unknown, never zero: zero paid-in
#               would declare the entire balance a taxable gain.
#
#   opened_on   Sure has `Account#start_date`, but it is `first entry date - 1
#               day`, which for a CSV-imported account is the day before the
#               import ran. It cannot anchor a five-year clock.
#
#   product     A declared override for cases where Sure's subtype is not
#               specific enough to pick a rule. `Depository/savings` covers a
#               Livret A, an LDDS and an ordinary taxable livret, which are
#               three different tax answers behind one subtype.
#
# `tax_custom_rules` lets a family cover a product this module has no built-in
# rule for -- the live example being PER, which has no Sure subtype at all.
# It stores a `kind` naming a rule class plus a params hash. It deliberately
# cannot store code, and the `kind` is looked up in an allow-list rather than
# constantized, so a row in this table can select a rule but can never define
# one.
class CreateTaxTables < ActiveRecord::Migration[8.1]
  def change
    # `on_delete: :cascade` on every reference below, rather than
    # `dependent: :destroy` on Account and Family.
    #
    # The two are not equivalent here. `dependent: :destroy` would mean editing
    # app/models/account.rb and app/models/family.rb, and this module is meant
    # to be removable without leaving marks on Sure's own models. More
    # importantly, without one or the other, deleting an account would start
    # raising a foreign-key violation -- so an additive migration would have
    # broken an existing feature. Pushing the cleanup into the schema keeps the
    # blast radius inside this migration.
    create_table :tax_profiles, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, index: { unique: true },
                             foreign_key: { on_delete: :cascade }

      t.string  :product
      t.date    :opened_on
      t.decimal :paid_in,          precision: 19, scale: 4
      t.decimal :paid_in_deducted, precision: 19, scale: 4

      # Set when the user has looked at the account and confirmed the figures
      # above are right. An unreviewed profile still computes, but the report
      # says so -- the difference between "declared" and "not yet checked" is
      # worth keeping.
      t.datetime :reviewed_at
      t.text     :notes

      t.timestamps
    end

    create_table :tax_custom_rules, id: :uuid do |t|
      t.references :family, null: false, type: :uuid,
                            foreign_key: { on_delete: :cascade }

      # Exactly one of (account_id) or (accountable_type [, subtype]) is set.
      # An account-pinned rule beats a type-and-subtype rule, which beats a
      # built-in. Enforced in the model, not here, so the error message can
      # explain itself.
      t.references :account, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :accountable_type
      t.string :subtype

      t.string :kind, null: false
      t.jsonb  :params, null: false, default: {}
      t.text   :note

      t.timestamps
    end

    add_index :tax_custom_rules, [ :family_id, :accountable_type, :subtype ],
              name: "index_tax_custom_rules_on_family_and_key"
    add_index :tax_custom_rules, [ :family_id, :account_id ],
              name: "index_tax_custom_rules_on_family_and_account"
  end
end
