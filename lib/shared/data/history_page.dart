import 'package:cloud_firestore/cloud_firestore.dart';

/// Stable ID cursors avoid dropping older rows when a bounded list fills up.
class HistoryPage<T> {
  const HistoryPage(this.items, this.next, {this.unavailable = const {}});
  final List<T> items;
  final String? next;

  /// IDs remain accounted for even when historical metadata cannot be parsed.
  final Map<String, String> unavailable;
}

abstract interface class HistoryPager<T> {
  Future<HistoryPage<T>> historyPage({
    String? after,
    Map<String, String> scope = const {},
  });
}

Future<HistoryPage<T>> readHistoryPage<T>(
  Query<Map<String, dynamic>> query,
  T Function(String, Map<String, dynamic>) parse, {
  String? after,
}) async {
  var page = query.orderBy(FieldPath.documentId).limit(20);
  if (after != null) page = page.startAfter([after]);
  final snapshot = await page.get(const GetOptions(source: Source.server));
  return HistoryPage(
    snapshot.docs.map((doc) => parse(doc.id, doc.data())).toList(),
    snapshot.size == 20 ? snapshot.docs.last.id : null,
  );
}
