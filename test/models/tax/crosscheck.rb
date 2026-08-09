# frozen_string_literal: true

# Emit the Rails module's answer for a fixed set of inputs, as TSV.
#
# The twin of sure-tax-harness/crosscheck.py. Both print the same columns for
# the same inputs; `diff` between them is the acceptance test for the port.
#
# This exists because the unit suite next door was written *from* the Python
# output, so it can only prove the Ruby agrees with what I already believed the
# Python said. Regenerating both sides from source and diffing catches the
# other case -- where I transcribed a figure wrong into the test and then made
# the code match it.
#
#   ruby test/models/tax/crosscheck.rb > /tmp/rb.tsv
#   diff /tmp/py.tsv /tmp/rb.tsv
#
require_relative "engine_test_helper"

ON = Date.new(2026, 8, 8)
RATES = Tax::RateTable.load_file(TaxEngineTestHelper.rate_file)

def d(value) = BigDecimal(value.to_s)

# The Python harness keys rules on its own `Envelope` enum. The Rails module
# keys them on Sure's (accountable_type, subtype) and treats `product` as a
# declared override. Mapping one to the other here, explicitly, is what makes
# the two tables comparable at all -- and is itself worth reviewing, because a
# mistake here would hide a real difference behind a bogus one.
CASES = [
  # label,        type,          subtype,     product,     value,       paid_in,     deducted,    opened_on
  [ "pea_mature",   "Investment", "pea",       "pea",       "250000.00", "150000.00", nil,         Date.new(2010, 1, 1) ],
  [ "pea_immature", "Investment", "pea",       "pea",       "250000.00", "150000.00", nil,         Date.new(2024, 1, 1) ],
  [ "pea_no_date",  "Investment", "pea",       "pea",       "250000.00", "150000.00", nil,         nil ],
  [ "pea_loss",     "Investment", "pea",       "pea",       "90000.00",  "120000.00", nil,         Date.new(2010, 1, 1) ],
  [ "pea_2",        "Investment", "pea",       "pea",       "200000.00", "120000.00", nil,         Date.new(2012, 6, 1) ],
  [ "per_1",        "Investment", "per_x",     "per",       "80000.00",  "50000.00",  nil,         nil ],
  [ "per_2",        "Investment", "per_x",     "per",       "40000.00",  "25000.00",  nil,         nil ],
  [ "per_partial",  "Investment", "per_x",     "per",       "80000.00",  "50000.00",  "20000.00",  nil ],
  [ "livret_a",     "Depository", "savings",   "livret_a",  "20000.00",  nil,         nil,         nil ],
  [ "ldds",         "Depository", "savings",   "ldds",      "12000.00",  nil,         nil,         nil ]
].freeze

# CTO is taxed on cost basis, which in Sure comes from holdings, not from a
# declared figure -- so it is passed as cost_basis, with paid_in left nil.
CTO = [ "cto", "Investment", "brokerage", "cto", "100000.00", "80000.00" ].freeze

def subject_for(label, type, subtype, product, value, paid_in, deducted, opened_on)
  Tax::Subject.new(
    id: label, name: label, currency: "EUR",
    accountable_type: type, subtype: subtype, product: product,
    value: d(value),
    paid_in: paid_in && d(paid_in),
    paid_in_deducted: deducted && d(deducted),
    opened_on: opened_on
  )
end

def cto_subject
  label, type, subtype, product, value, cost = CTO
  Tax::Subject.new(
    id: label, name: label, currency: "EUR",
    accountable_type: type, subtype: subtype, product: product,
    value: d(value), cost_basis: d(cost)
  )
end

# PER has no Sure subtype, which is the whole reason custom rules exist. The
# Python harness reaches it through its `per` envelope; here it is a custom
# rule pinned to a made-up subtype, which is exactly how a user would do it
# today while waiting for Sure to ship one.
REGISTRY = Tax::Registry.new(
  country: "FR",
  custom_rules: [ TaxEngineTestHelper::FakeCustomRule.new(
    accountable_type: "Investment", subtype: "per_x",
    rule: Tax::Rules::Fr::CapitalAndGains.new
  ) ]
)

def emit(label, line)
  tax  = line.tax.nil? ? "nil" : format("%.2f", line.tax)
  base = line.taxable_base.nil? ? "nil" : format("%.2f", line.taxable_base)

  puts [
    label, format("%.2f", line.gross), base, tax,
    format("%.2f", line.bareme_income)
  ].join("\t")
end

flat   = Tax::Assumptions.new(tmi_mode: :flat, flat_rate: d("0.30"))
bareme = Tax::Assumptions.new(tmi_mode: :bareme, other_taxable_income: d(0), parts: d(1))

subjects = CASES.map { |c| subject_for(*c) } + [ cto_subject ]

{ "flat" => flat, "bareme" => bareme }.each do |mode, assumptions|
  subjects.each do |s|
    emit("#{mode}\t#{s.name}", REGISTRY.apply(s, on: ON, rates: RATES, assumptions: assumptions))
  end
end

stack = CASES.select { |c| %w[per_1 per_2].include?(c[0]) }.map { |c| subject_for(*c) }
REGISTRY.apply_all(stack, on: ON, rates: RATES, assumptions: bareme).each do |line|
  emit("stacked\t#{line.account_name}", line)
end

[ 2025, 2026 ].each do |year|
  on = Date.new(year, 6, 1)
  puts "rates\tsocial_#{year}\t#{format('%.4f', RATES.social_charges(on))}"
  puts "rates\tflat_#{year}\t#{format('%.4f', RATES.flat_tax(on))}"

  [ 11_000, 30_000, 50_000, 120_000 ].each do |amount|
    [ 1, 2 ].each do |parts|
      tax = RATES.income_tax(d(amount), on: on, parts: d(parts))
      puts "rates\tir_#{year}_#{amount}_p#{parts}\t#{format('%.2f', tax)}"
    end
  end
end
