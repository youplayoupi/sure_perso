# frozen_string_literal: true

# One more additive table: what the household says about itself.
#
# Everything else this module stores is about an account (tax_profiles), about
# a product (tax_custom_rules) or about a country (tax_rate_corrections). The
# marginal rate is none of those. It is a fact about the people, it applies to
# every account they hold, and there was nowhere to put it -- so until now it
# was a URL parameter that defaulted to zero other income and one part, which
# is to say it was wrong for almost everybody and silently so.
#
# It is deliberately not folded into tax_rate_corrections, even though that
# table already holds a jsonb document and would have taken the value without
# a migration. That screen's "go back to the shipped figures" button deletes
# the document, and the shipped figures never included the household's own
# rate. Putting it there would mean correcting a social-charge rate and then
# undoing it wiped a number that had nothing to do with the country's file.
#
# Nullable on purpose. Null means "not declared", which the report says out
# loud on every figure that rests on the placeholder used in its place; see
# Tax::Assumptions. A default would have made an assumption look like an
# answer, which is the failure mode this whole module is arranged against.
class CreateTaxHouseholds < ActiveRecord::Migration[8.1]
  def change
    create_table :tax_households, id: :uuid do |t|
      # Cascade rather than `dependent: :destroy`, for the same reason as the
      # other three tables: this module does not edit app/models/family.rb, and
      # without one or the other, deleting a family would start raising a
      # foreign-key violation -- an additive migration breaking an existing
      # feature.
      t.references :family, null: false, type: :uuid, index: { unique: true },
                            foreign_key: { on_delete: :cascade }

      # Stored as the fraction, like every other rate in this module and in the
      # rate files: 0.3000, not 30. Four decimal places because bands are
      # published to a tenth of a percent and the extra digit costs nothing.
      t.decimal :marginal_rate, precision: 5, scale: 4

      t.timestamps
    end
  end
end
