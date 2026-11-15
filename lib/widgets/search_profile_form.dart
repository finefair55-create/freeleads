import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/search_profile.dart';
import '../services/lead_repository.dart';
import '../services/zip_geocoder.dart';
import 'profile_pickers.dart';

/// Trade, home ZIP and radius, saved as the user's [SearchProfile]. Stays in
/// sync if the profile is changed elsewhere while this form is mounted.
class SearchProfileForm extends StatefulWidget {
  const SearchProfileForm({
    super.key,
    this.submitLabel = 'Find leads',
    this.submitIcon = Icons.travel_explore,
    this.onSaved,
  });

  final String submitLabel;
  final IconData submitIcon;

  /// Called after a changed profile is saved ([changed] false when the
  /// values matched what was already saved).
  final void Function(bool changed)? onSaved;

  @override
  State<SearchProfileForm> createState() => _SearchProfileFormState();
}

class _SearchProfileFormState extends State<SearchProfileForm> {
  final _formKey = GlobalKey<FormState>();
  final _zip = TextEditingController();
  String _profession = '';
  String? _tradeError;
  int _radius = 25;
  ValueNotifier<SearchProfile?>? _profile;

  @override
  void initState() {
    super.initState();
    // For the "isn't on our map" hint.
    ZipGeocoder.instance.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    }, onError: (Object error) => debugPrint('ZIP table: $error'));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final profile = AppScope.of(context).repository.profile;
    if (!identical(profile, _profile)) {
      _profile?.removeListener(_onProfileChanged);
      _profile = profile..addListener(_onProfileChanged);
      _apply();
    }
  }

  @override
  void dispose() {
    _profile?.removeListener(_onProfileChanged);
    _zip.dispose();
    super.dispose();
  }

  void _onProfileChanged() => setState(_apply);

  void _apply() {
    final profile = _profile?.value;
    if (profile == null) {
      return;
    }
    _profession = profile.profession;
    _zip.text = profile.zipCode;
    _radius = SearchProfile.radiusOptions.contains(profile.radiusMiles)
        ? profile.radiusMiles
        : 25;
  }

  Future<void> _submit() async {
    final tradeError = _profession.trim().isEmpty
        ? 'Pick a trade or describe yours'
        : null;
    setState(() => _tradeError = tradeError);
    final zipOk = _formKey.currentState!.validate();
    if (tradeError != null || !zipOk) {
      return;
    }
    FocusScope.of(context).unfocus();
    final repository = AppScope.of(context).repository;
    final current = repository.profile.value;
    final next = (current ?? const SearchProfile(profession: '', zipCode: ''))
        .copyWith(
          profession: _profession.trim(),
          zipCode: _zip.text.trim(),
          radiusMiles: _radius,
        );
    final changed =
        current == null ||
        current.profession != next.profession ||
        current.zipCode != next.zipCode ||
        current.radiusMiles != next.radiusMiles;
    // Saving starts a search that can take a minute; report back right away
    // and let the refresh status show progress.
    final search = changed
        ? repository.updateProfile(next)
        : repository.refresh();
    widget.onSaved?.call(changed);
    await search;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Your trade', style: textTheme.labelLarge),
          const SizedBox(height: 8),
          TradePicker(
            value: _profession,
            errorText: _tradeError,
            onChanged: (value) => setState(() {
              _profession = value;
              _tradeError = null;
            }),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _zip,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            maxLength: 5,
            decoration: InputDecoration(
              labelText: 'Home ZIP',
              counterText: '',
              helperText: unknownZipNote(_zip.text),
              helperMaxLines: 2,
            ),
            onChanged: (_) => setState(() {}),
            onFieldSubmitted: (_) => _submit(),
            validator: validateHomeZip,
          ),
          const SizedBox(height: 16),
          Text('Search radius', style: textTheme.labelLarge),
          const SizedBox(height: 8),
          RadiusPicker(
            value: _radius,
            onChanged: (miles) => setState(() => _radius = miles),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: ValueListenableBuilder<RefreshStatus>(
              valueListenable: AppScope.of(context).repository.status,
              builder: (context, status, _) => FilledButton.icon(
                onPressed: status.isRunning ? null : _submit,
                icon: status.isRunning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(widget.submitIcon),
                label: Text(
                  status.isRunning ? 'Searching…' : widget.submitLabel,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
