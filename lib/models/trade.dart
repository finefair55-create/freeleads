import 'package:flutter/material.dart';

/// A common trade offered during onboarding and on the Profile tab. The
/// [query] is what gets searched and stored as `SearchProfile.profession`;
/// any other text the user types is used as-is.
class Trade {
  const Trade(this.label, this.query, this.icon);

  final String label;
  final String query;
  final IconData icon;

  static const common = [
    Trade('Plumbing', 'plumber', Icons.plumbing),
    Trade('HVAC', 'hvac', Icons.hvac),
    Trade('Electrical', 'electrician', Icons.electrical_services),
    Trade('Handyman', 'handyman', Icons.handyman),
    Trade('Cleaning', 'house cleaning', Icons.cleaning_services),
    Trade('Moving', 'movers', Icons.local_shipping),
    Trade('Painting', 'painter', Icons.format_paint),
    Trade('Landscaping', 'landscaping', Icons.grass),
    Trade('Roofing', 'roofer', Icons.roofing),
    Trade('Carpentry', 'carpenter', Icons.carpenter),
    Trade('Flooring', 'flooring', Icons.layers),
    Trade('Appliance repair', 'appliance repair', Icons.kitchen),
  ];

  /// The common trade whose query is [profession], if any.
  static Trade? match(String? profession) {
    final value = profession?.trim().toLowerCase();
    if (value == null || value.isEmpty) {
      return null;
    }
    for (final trade in common) {
      if (trade.query == value || trade.label.toLowerCase() == value) {
        return trade;
      }
    }
    return null;
  }

  /// Display name for a stored profession: the trade label when it is a
  /// common one, otherwise the text with its first letter capitalized.
  static String displayName(String profession) {
    final trade = match(profession);
    if (trade != null) {
      return trade.label;
    }
    final text = profession.trim();
    return text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';
  }
}
