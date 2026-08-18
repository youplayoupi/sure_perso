# frozen_string_literal: true

# One more additive table: a family's corrections to the shipped rate file.
#
# The module has always said that rates are data and that a self-hoster who
# needs to correct one edits `config/tax/fr.yml` and restarts. That works for
# whoever deployed the container and for nobody else in the household, and it
# does not survive an upgrade -- the next image ships its own copy of the file.
# This table is the same edit, stored where it belongs.
#
# It holds a jsonb document rather than a row per rate, and that is a
# deliberate trade. The alternative -- a table of (section, key, effective
# date, value) -- would need to model an income-tax bracket set, which is a
# list of pairs with an open-ended top, and it would spread one logical
# correction across many rows that could be half-saved. The document is
# validated as a whole by Tax::RateOverlay before it is written, so the
# looseness of jsonb buys flexibility without buying ambiguity.
#
# What it cannot hold is worth stating: no rule, no code, no class name.
# Tax::RateOverlay merges only sections it recognises and rejects the rest, so
# the worst a corrupted row can do is name a rate that this module then refuses
# to save. Rates are data here exactly as they are data in the YAML.
#
# A separate migration from CreateTaxTables because that one has already been
# run on live instances. Folding these columns into it would leave those
# databases silently missing the table.
class CreateTaxRateCorrections < ActiveRecord::Migration[8.1]
  def change
    create_table :tax_rate_corrections, id: :uuid do |t|
      # Cascade rather than `dependent: :destroy`, for the same reason as the
      # other two tables: this module does not edit app/models/family.rb, and
      # without one or the other, deleting a family would start raising a
      # foreign-key violation -- an additive migration breaking an existing
      # feature.
      t.references :family, null: false, type: :uuid,
                            foreign_key: { on_delete: :cascade }

      # One document per family per country, so a household with accounts in
      # two countries corrects each independently. The unique index is what
      # makes "the corrections" a single well-defined thing rather than a pile
      # of rows whose merge order would decide a tax rate.
      t.string :country, null: false
      t.jsonb  :overrides, null: false, default: {}

      t.timestamps
    end

    add_index :tax_rate_corrections, [ :family_id, :country ], unique: true
  end
end
