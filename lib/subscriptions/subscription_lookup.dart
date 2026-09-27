import 'package:quax/database/entities.dart';

/// Answers "is this author subscribed to?" over a snapshot of `SubscriptionsModel.state`.
///
/// Search subscriptions are excluded: their id is a search term, not a user id.
/// Subscriptions hidden from the main feed still count as subscribed.
bool isSubscribed(List<Subscription> subscriptions, String? userId) =>
    userId != null && subscriptions.any((e) => e is UserSubscription && e.id == userId);
