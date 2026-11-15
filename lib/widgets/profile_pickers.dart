import 'package:flutter/material.dart';

import '../models/search_profile.dart';
import '../models/trade.dart';
import '../services/zip_geocoder.dart';

/// Chips for the common trades plus "Other" with a free-text field.
/// [value] is the stored profession (a trade's query or custom text).
class TradePicker extends StatefulWidget {
  const TradePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.errorText,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? errorText;

  static const maxLength = 60;

  @override
  State<TradePicker> createState() => _TradePickerState();
}

class _TradePickerState extends State<TradePicker> {
  final _custom = TextEditingController();
  bool _other = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(TradePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _sync();
    }
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  void _sync() {
    final value = widget.value.trim();
    // Typing "plumber" into Other shouldn't yank the field away.
    if (_other && value == _custom.text.trim()) {
      return;
    }
    if (Trade.match(value) == null && value.isNotEmpty) {
      _other = true;
      _custom.text = value;
    } else {
      _other = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _other ? null : Trade.match(widget.value);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final trade in Trade.common)
              ChoiceChip(
                avatar: Icon(trade.icon, size: 18),
                label: Text(trade.label),
                selected: selected == trade,
                showCheckmark: false,
                onSelected: (_) {
                  setState(() => _other = false);
                  widget.onChanged(trade.query);
                },
              ),
            ChoiceChip(
              avatar: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Other'),
              selected: _other,
              showCheckmark: false,
              onSelected: (_) {
                setState(() => _other = true);
                widget.onChanged(_custom.text.trim());
              },
            ),
          ],
        ),
        if (_other) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _custom,
            autofocus: widget.value.isEmpty,
            maxLength: TradePicker.maxLength,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Your trade',
              hintText: 'e.g. pool cleaning, piano tuning',
              errorText: widget.errorText,
              counterText: '',
            ),
            onChanged: (text) => widget.onChanged(text.trim()),
          ),
        ] else if (widget.errorText != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.errorText!,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.error),
          ),
        ],
      ],
    );
  }
}

/// One chip per [SearchProfile.radiusOptions].
class RadiusPicker extends StatelessWidget {
  const RadiusPicker({super.key, required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final miles in SearchProfile.radiusOptions)
          ChoiceChip(
            label: Text('$miles mi'),
            selected: value == miles,
            showCheckmark: false,
            onSelected: (_) => onChanged(miles),
          ),
      ],
    );
  }
}

String? validateHomeZip(String? value) =>
    RegExp(r'^\d{5}$').hasMatch(value?.trim() ?? '')
    ? null
    : 'Enter a 5-digit ZIP';

/// A heads-up when a well-formed [zip] isn't in the bundled Census table
/// (often a typo). Not an error: PO-box and business ZIPs aren't in the
/// table but still search fine. Null until the table has loaded.
String? unknownZipNote(String zip, {ZipGeocoder? geocoder}) {
  final table = geocoder ?? ZipGeocoder.instance;
  if (validateHomeZip(zip) != null ||
      !table.isLoaded ||
      table.lookup(zip) != null) {
    return null;
  }
  return "Double-check this ZIP: it isn't on our map, but searching still "
      'works.';
}
