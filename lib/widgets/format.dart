/// "just now", "12m ago", "5h ago", "3d ago", or a short date.
String timeAgo(DateTime? time, {DateTime? now}) {
  if (time == null) {
    return '';
  }
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inMinutes < 1) {
    return 'just now';
  }
  if (diff.inHours < 1) {
    return '${diff.inMinutes}m ago';
  }
  if (diff.inDays < 1) {
    return '${diff.inHours}h ago';
  }
  if (diff.inDays < 14) {
    return '${diff.inDays}d ago';
  }
  final local = time.toLocal();
  return '${local.month}/${local.day}/${local.year}';
}

/// Whole dollars with thousands separators: "$85", "$1,250".
String formatDollars(double amount) {
  final digits = amount.round().toString();
  final grouped = digits.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+$)'),
    (_) => ',',
  );
  return '\$$grouped';
}
