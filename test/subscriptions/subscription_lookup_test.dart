import 'package:flutter_test/flutter_test.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/subscriptions/subscription_lookup.dart';

UserSubscription _user(String id, {bool inFeed = true}) => UserSubscription(
    id: id,
    screenName: 'screen_$id',
    name: 'Name $id',
    profileImageUrlHttps: null,
    verified: false,
    createdAt: DateTime(2020),
    inFeed: inFeed);

SearchSubscription _search(String term) => SearchSubscription(id: term, createdAt: DateTime(2020));

void main() {
  test('Should report a subscribed author as subscribed', () {
    expect(isSubscribed([_user('123')], '123'), isTrue,
        reason: 'an author with a subscription row must not be flagged');
  });

  test('Should ignore search subscriptions when matching ids', () {
    expect(isSubscribed([_search('123')], '123'), isFalse,
        reason: 'a search term must never be mistaken for a user id');
  });

  test('Should flag an author whose id matches no user subscription', () {
    expect(isSubscribed([_user('123'), _search('456')], '456'), isFalse,
        reason: 'only user subscriptions count, even when a search term collides with the author id');
  });

  test('Should report a subscription hidden from the main feed as subscribed', () {
    expect(isSubscribed([_user('123', inFeed: false)], '123'), isTrue,
        reason: 'inFeed only controls the feed, not the subscription itself');
  });

  test('Should not flag a null author id as subscribed', () {
    expect(isSubscribed([_user('123')], null), isFalse,
        reason: 'a missing author id has nothing to look up');
  });
}
