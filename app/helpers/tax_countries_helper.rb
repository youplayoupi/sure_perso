# frozen_string_literal: true

module TaxCountriesHelper
  # A primary-nav entry for the country reference. Unlike the report's own
  # nav item this is always shown, because its whole value to a household whose
  # country is not yet supported is telling them so and showing what is.
  def tax_countries_nav_item
    {
      name: t("tax_countries.index.title"),
      path: tax_countries_path,
      icon: "globe",
      icon_custom: false,
      active: page_active?(tax_countries_path)
    }
  end

  # "🇬🇧 United Kingdom", falling back to the raw code. Reuses the same country
  # table the profile/settings country picker uses, so the name and flag match
  # the rest of the app.
  def tax_country_name(code)
    LanguagesHelper::COUNTRY_MAPPING.fetch(code.to_s.upcase.to_sym, code.to_s.upcase)
  end

  # The human label for one (accountable_type, subtype) pair. A nil subtype is
  # the registry's wildcard -- "everything of this type" -- and is said as such.
  def tax_country_subtype_label(type, subtype)
    return t("tax_countries.all_of_type", type: tax_country_type_label(type)) if subtype.nil?

    klass = type.to_s.safe_constantize
    label = if klass && klass.const_defined?(:SUBTYPES)
      klass::SUBTYPES.dig(subtype.to_s, :long)
    end

    label || subtype.to_s.humanize
  end

  def tax_country_type_label(type)
    klass = type.to_s.safe_constantize
    klass.respond_to?(:singular_display_name) ? klass.singular_display_name : type.to_s
  end

  # Present a fraction as a percentage. Reuses the report's formatter so a rate
  # reads the same on both pages.
  def tax_country_rate(rate)
    return t("tax_countries.rate_unknown") if rate.nil?

    tax_percent(rate)
  end
end
