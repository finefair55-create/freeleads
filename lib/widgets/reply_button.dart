import 'package:flutter/material.dart';

import '../models/lead.dart';
import 'link_opener.dart';

/// One way to answer a lead.
typedef _ReplyOption = ({
  String label,
  IconData icon,
  void Function(BuildContext context) open,
});

/// Call / Text / Email for the listing's own contact details, then its
/// original posting, whose site has its own reply tools.
List<_ReplyOption> _replyOptions(Lead lead) {
  final listing = safeWebUri(lead.sourceUrl);
  return [
    for (final action in contactActions(
      lead.contactInfo,
      subject: lead.title.trim().isEmpty ? null : 'Re: ${lead.displayTitle}',
    ))
      (
        label: action.label,
        icon: action.icon,
        open: (context) => openContact(context, action),
      ),
    if (listing != null)
      (
        label: 'Reply on listing',
        icon: Icons.open_in_new,
        open: (context) => openExternalLink(context, listing.toString()),
      ),
  ];
}

/// The lead's main action: "Reply". With one way to reply it goes straight
/// there; with several (call, text, email, the listing) it opens a menu.
/// Builds nothing for a lead with no way to reply (see [canReply]).
class ReplyButton extends StatelessWidget {
  const ReplyButton({super.key, required this.lead, this.style});

  final Lead lead;
  final ButtonStyle? style;

  static bool canReply(Lead lead) => _replyOptions(lead).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final options = _replyOptions(lead);
    if (options.isEmpty) {
      return const SizedBox.shrink();
    }
    Widget button(VoidCallback onPressed, IconData icon) => FilledButton.icon(
      style: style,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: const Text('Reply', maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    if (options case [final only]) {
      return Tooltip(
        message: only.label,
        child: button(() => only.open(context), only.icon),
      );
    }
    return MenuAnchor(
      menuChildren: [
        for (final option in options)
          MenuItemButton(
            leadingIcon: Icon(option.icon, size: 20),
            onPressed: () => option.open(context),
            child: Text(option.label),
          ),
      ],
      builder: (context, controller, _) => button(
        () => controller.isOpen ? controller.close() : controller.open(),
        Icons.reply,
      ),
    );
  }
}
