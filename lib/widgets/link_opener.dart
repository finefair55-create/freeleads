import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

typedef UrlOpener = Future<bool> Function(Uri uri);

/// Opens links in the user's browser (not an in-app web view), so the
/// listing site gets its usual cookies and reply tools. Swappable in tests.
@visibleForTesting
UrlOpener urlOpener = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// [raw] as a web URL, or null unless it is absolute http(s) with a host.
/// Scraped and community data is untrusted, so anything else (javascript:,
/// intent:, file:, relative or garbled text) is refused.
Uri? safeWebUri(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !(uri.isScheme('https') || uri.isScheme('http')) ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

/// Opens [raw] in the browser. Never throws: a bad link or a device with no
/// browser shows a message offering to copy the link instead.
Future<void> openExternalLink(BuildContext context, String? raw) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final uri = safeWebUri(raw);
  var opened = false;
  if (uri != null) {
    try {
      opened = await urlOpener(uri);
    } on PlatformException catch (error) {
      debugPrint('Could not open $uri: $error');
    } on ArgumentError catch (error) {
      debugPrint('Could not open $uri: $error');
    }
  }
  if (opened || messenger == null) {
    return;
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        uri == null
            ? "This link doesn't look valid, so it wasn't opened."
            : "Couldn't open a browser for this link.",
      ),
      action: raw == null || raw.trim().isEmpty
          ? null
          : SnackBarAction(
              label: 'Copy link',
              onPressed: () => Clipboard.setData(ClipboardData(text: raw)),
            ),
    ),
  );
}

/// A way to reach a lead's poster, built from the contact text.
class ContactAction {
  const ContactAction(this.label, this.icon, this.uri, this.value);

  final String label;
  final IconData icon;
  final Uri uri;

  /// The phone number or address the action uses, for copying.
  final String value;
}

final _phonePattern = RegExp(
  r'(?<!\d)(?:\+?1[\s.-]?)?\(?([2-9]\d{2})\)?[\s.-]?(\d{3})[\s.-]?(\d{4})\b',
);
final _emailPattern = RegExp(r'[\w.+-]+@[\w-]+(?:\.[\w-]+)+');

/// Call, text and email actions for the first US phone number and email
/// address in [contact]. URIs are rebuilt from the digits or address
/// alone, so no other text from the listing reaches the dialer or mail app.
List<ContactAction> contactActions(String? contact, {String? subject}) {
  if (contact == null || contact.trim().isEmpty) {
    return const [];
  }
  final actions = <ContactAction>[];
  final phone = _phonePattern.firstMatch(contact);
  if (phone != null) {
    final digits = '+1${phone[1]}${phone[2]}${phone[3]}';
    final display = '(${phone[1]}) ${phone[2]}-${phone[3]}';
    actions
      ..add(
        ContactAction(
          'Call',
          Icons.call,
          Uri(scheme: 'tel', path: digits),
          display,
        ),
      )
      ..add(
        ContactAction(
          'Text',
          Icons.sms_outlined,
          Uri(scheme: 'sms', path: digits),
          display,
        ),
      );
  }
  final email = _emailPattern.firstMatch(contact)?.group(0);
  if (email != null) {
    actions.add(
      ContactAction(
        'Email',
        Icons.mail_outline,
        Uri(
          scheme: 'mailto',
          path: email,
          // Spaces as %20: mail apps show a `+` from queryParameters as-is.
          query: subject == null || subject.isEmpty
              ? null
              : 'subject=${Uri.encodeComponent(subject)}',
        ),
        email,
      ),
    );
  }
  return actions;
}

/// Opens a [ContactAction]. Never throws: without a phone or mail app it
/// offers to copy the number or address.
Future<void> openContact(BuildContext context, ContactAction action) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  var opened = false;
  try {
    opened = await urlOpener(action.uri);
  } on PlatformException catch (error) {
    debugPrint('Could not open ${action.uri.scheme}: $error');
  } on ArgumentError catch (error) {
    debugPrint('Could not open ${action.uri.scheme}: $error');
  }
  if (opened || messenger == null) {
    return;
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text("Couldn't open an app to ${action.label.toLowerCase()}."),
      action: SnackBarAction(
        label: 'Copy',
        onPressed: () => Clipboard.setData(ClipboardData(text: action.value)),
      ),
    ),
  );
}
