// ignore: implementation_imports - convertTwitterDateTime is not exported by twitter_api.dart
import 'package:dart_twitter_api/src/utils/date_utils.dart';
import 'package:dart_twitter_api/twitter_api.dart';
import 'package:extended_image/extended_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_triple/flutter_triple.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/group/feed_refresh_controller.dart';
import 'package:quax/group/group_model.dart';
import 'package:quax/profile/profile.dart';
import 'package:quax/subscriptions/subscription_lookup.dart';
import 'package:quax/subscriptions/users_model.dart';
import 'package:multi_select_flutter/multi_select_flutter.dart';
import 'package:provider/provider.dart';

Widget _createUserAvatar(String? uri, double size) {
  if (uri == null) {
    return SizedBox(width: size, height: size);
  } else {
    return ExtendedImage.network(
      // TODO: This can error if the profile image has changed... use SWR-like
      uri.replaceAll('normal', '200x200'),
      width: size,
      height: size,
      loadStateChanged: (state) {
        switch (state.extendedImageLoadState) {
          case LoadState.failed:
            return const Icon(Icons.error_outline);
          default:
            return state.completedWidget;
        }
      },
    );
  }
}

/*
Widget _expandUserAvatar(String? uri, double size) {
  if (uri == null) {
    return SizedBox(width: size, height: size);
  } else {
    return ExtendedImage.network(
      // TODO: This can error if the profile image has changed... use SWR-like
      uri.replaceAll('normal', '400x400'),
      width: size,
      height: size,
      loadStateChanged: (state) {
        switch (state.extendedImageLoadState) {
          case LoadState.failed:
            return const Icon(Icons.error_outline);
          default:
            return state.completedWidget;
        }
      },
    );
  }
}
*/

class UserAvatar extends StatelessWidget {
  final String? uri;
  final double size;

  /// Overlaid on the bottom-right corner of the avatar, outside the clip so it is not rounded away.
  final Widget? badge;

  const UserAvatar({super.key, required this.uri, this.size = 48, this.badge});

  @override
  Widget build(BuildContext context) {
    var avatar = ClipRRect(
      borderRadius: BorderRadius.circular(size),
      child: _createUserAvatar(uri, size),
    );

    var badge = this.badge;
    if (badge == null) {
      return avatar;
    }

    return Stack(
      children: [avatar, Positioned(bottom: 0, right: 0, child: badge)],
    );
  }
}

class UserTile extends StatelessWidget {
  final Subscription user;

  const UserTile({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
      leading: UserAvatar(uri: user.profileImageUrlHttps),
      title: Row(
        children: [
          Flexible(child: Text(user.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (user.verified) const SizedBox(width: 6),
          if (user.verified) Icon(Icons.verified, size: 14, color: Theme.of(context).colorScheme.primary)
        ],
      ),
      subtitle: Text('@${user.screenName}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: FollowButton(user: user),
      onTap: () {
        Navigator.pushNamed(context, routeProfile, arguments: ProfileScreenArguments(user.id, user.screenName, null));
      },
    );
  }
}

class FollowButtonSelectGroupDialog extends StatefulWidget {
  final Subscription user;
  final bool followed;
  final List<String> groupsForUser;
  final String? skipFeedKey;

  const FollowButtonSelectGroupDialog(
      {super.key,
      required this.user,
      required this.followed,
      required this.groupsForUser,
      this.skipFeedKey});

  @override
  State<FollowButtonSelectGroupDialog> createState() => _FollowButtonSelectGroupDialogState();
}

class _FollowButtonSelectGroupDialogState extends State<FollowButtonSelectGroupDialog> {
  @override
  Widget build(BuildContext context) {
    var groupModel = context.read<GroupsModel>();
    var subscriptionsModel = context.read<SubscriptionsModel>();

    var color = Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black54;

    return MultiSelectDialog(
      title: Text(L10n.of(context).select),
      searchHint: L10n.of(context).search,
      confirmText: Text(L10n.of(context).ok),
      cancelText: Text(L10n.of(context).cancel),
      searchIcon: Icon(Icons.search, color: color),
      closeSearchIcon: Icon(Icons.close, color: color),
      itemsTextStyle: Theme.of(context).textTheme.bodyLarge,
      selectedColor: Theme.of(context).colorScheme.secondary,
      unselectedColor: color,
      selectedItemsTextStyle: Theme.of(context).textTheme.bodyLarge,
      items: groupModel.state.map((e) => MultiSelectItem(e.id, e.name)).toList(),
      initialValue: widget.groupsForUser,
      onConfirm: (List<String> memberships) async {
        // If we're not currently following the user, follow them first
        if (widget.followed == false) {
          await subscriptionsModel.toggleSubscribe(widget.user, widget.followed, skipFeedKey: widget.skipFeedKey);
        }

        // Then add them to all the selected groups
        await groupModel.saveUserGroupMembership(widget.user.id, memberships, skipFeedKey: widget.skipFeedKey);
      },
    );
  }
}

class FollowButton extends StatelessWidget {
  final Subscription user;
  final Color? color;

  /// Replaces the default icon button with an arbitrary tappable widget.
  final Widget? child;

  /// The feed shell left mounted when this change reloads the feeds. Set by the in-feed badge, so
  /// subscribing does not remount the feed the user is reading.
  final String? skipFeedKey;

  const FollowButton({super.key, required this.user, this.color, this.child, this.skipFeedKey});

  @override
  Widget build(BuildContext context) {
    var model = context.read<SubscriptionsModel>();

    return ScopedBuilder<SubscriptionsModel, List<Subscription>>(
      store: model,
      onState: (_, state) {
        var followed = state.any((element) => element.id == user.id);
        var inFeed = followed && state.any((element) => element.id == user.id && element.inFeed);

        // Why: a MenuAnchor menu has no modal barrier, so scrolling the feed dismisses it
        // instead of being swallowed by the menu.
        return MenuAnchor(
          menuChildren: _buildMenuItems(context, model, followed, inFeed),
          builder: (context, controller, _) => _buildAnchor(controller, followed, inFeed),
        );
      },
    );
  }

  List<Widget> _buildMenuItems(BuildContext context, SubscriptionsModel model, bool followed, bool inFeed) {
    return [
      MenuItemButton(
        onPressed: () => model.toggleSubscribe(user, followed, skipFeedKey: skipFeedKey),
        child: Text(followed ? L10n.of(context).unsubscribe : L10n.of(context).subscribe),
      ),
      MenuItemButton(
        onPressed: () => _openGroupSelection(context, followed),
        child: Text(L10n.of(context).add_to_group),
      ),
      if (followed)
        MenuItemButton(
          onPressed: () => model.toggleInFeed(user, inFeed),
          child: Text(inFeed ? L10n.of(context).hide_from_main_feed : L10n.of(context).show_in_main_feed),
        ),
    ];
  }

  Widget _buildAnchor(MenuController controller, bool followed, bool inFeed) {
    void toggleMenu() => controller.isOpen ? controller.close() : controller.open();

    var anchorChild = child;
    if (anchorChild != null) {
      return InkResponse(onTap: toggleMenu, child: anchorChild);
    }

    var icon = followed
        ? (inFeed ? Icon(Icons.person_remove, color: color) : Icon(Icons.visibility_off))
        : Icon(Icons.person_add, color: color);

    return IconButton(icon: icon, onPressed: toggleMenu);
  }

  Future<void> _openGroupSelection(BuildContext context, bool followed) async {
    var groups = await context.read<GroupsModel>().listGroupsForUser(user.id);
    if (context.mounted) {
      showDialog(
          context: context,
          builder: (_) => FollowButtonSelectGroupDialog(
              user: user, followed: followed, groupsForUser: groups, skipFeedKey: skipFeedKey));
    }
  }
}

/// A "+" corner badge shown on the avatar of an author the user is not subscribed to.
/// Tapping it opens the same menu as [FollowButton].
class SubscribeAvatarBadge extends StatelessWidget {
  static const _size = 20.0;
  static const _ringWidth = 2.0;
  static const _hitSize = 24.0;

  final User user;

  /// The colour the badge's ring is cut out of, so it reads as part of the card it sits on.
  final Color? cardColor;

  const SubscribeAvatarBadge({super.key, required this.user, this.cardColor});

  @override
  Widget build(BuildContext context) {
    return ScopedBuilder<SubscriptionsModel, List<Subscription>>(
      store: context.read<SubscriptionsModel>(),
      onState: (_, state) => isSubscribed(state, user.idStr)
          ? const SizedBox.shrink()
          : FollowButton(
              user: UserSubscription.fromUser(user),
              skipFeedKey: context.read<FeedRefreshController?>()?.feedKey,
              child: _buildBadge(context)),
    );
  }

  Widget _buildBadge(BuildContext context) {
    var theme = Theme.of(context);

    return Semantics(
      button: true,
      label: L10n.of(context).you_are_not_subscribed_to_this_author,
      child: SizedBox(
        width: _hitSize,
        height: _hitSize,
        child: Align(
          alignment: Alignment.bottomRight,
          child: Container(
            width: _size,
            height: _size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primary,
              border: Border.all(color: cardColor ?? theme.cardColor, width: _ringWidth),
            ),
            child: Icon(Icons.add, size: 12, color: theme.colorScheme.onPrimary),
          ),
        ),
      ),
    );
  }
}

class UserWithExtra extends User {
  Map<String, dynamic>? card;
  bool? possiblySensitive;

  UserWithExtra();

  factory UserWithExtra.fromArguments({
    String? idStr,
    String? name,
    String? screenName,
    String? location,
    Derived? derived,
    String? url,
    UserEntities? entities,
    String? description,
    bool? protected,
    bool? verified,
    Tweet? status,
    int? followersCount,
    int? friendsCount,
    int? listedCount,
    int? favoritesCount,
    int? statusesCount,
    DateTime? createdAt,
    String? profileBannerUrl,
    String? profileImageUrlHttps,
    bool? defaultProfile,
    bool? defaultProfileImage,
    List<String>? withheldInCountries,
    String? withheldScope,
    bool? possiblySensitive,
  }) {
    var userWithExtra = UserWithExtra()
      ..idStr = idStr
      ..name = name
      ..screenName = screenName
      ..location = location
      ..derived = derived
      ..url = url
      ..entities = entities
      ..description = description
      ..protected = protected
      ..verified = verified
      ..status = status
      ..followersCount = followersCount
      ..friendsCount = friendsCount
      ..listedCount = listedCount
      ..favoritesCount = favoritesCount
      ..statusesCount = statusesCount
      ..createdAt = createdAt
      ..profileBannerUrl = profileBannerUrl
      ..profileImageUrlHttps = profileImageUrlHttps
      ..defaultProfile = defaultProfile
      ..defaultProfileImage = defaultProfileImage
      ..withheldInCountries = withheldInCountries
      ..withheldScope = withheldScope
      ..possiblySensitive = possiblySensitive;

    return userWithExtra;
  }

  @override
  Map<String, dynamic> toJson() {
    var json = super.toJson();
    json['potentiallySensitive'] = possiblySensitive;

    return json;
  }

  factory UserWithExtra.fromNonLegacyJson(Map<String, dynamic> json) {
    var legacy = json['legacy'] as Map<String, dynamic>? ?? const {};
    return UserWithExtra.fromJson({...legacy, ..._flattenModernUser(json)});
  }

  static Map<String, dynamic> _flattenModernUser(Map<String, dynamic> json) {
    var avatar = _text(json['avatar']?['image_url']);
    var modern = <String, dynamic>{
      'id_str': json['rest_id'],
      'name': json['core']?['name'],
      'screen_name': json['core']?['screen_name'],
      'created_at': json['core']?['created_at'],
      'location': _text(json['location']?['location']),
      'url': _text(json['website']?['url']),
      'description': json['profile_bio']?['description'],
      'entities': json['profile_bio']?['entities'],
      'protected': json['privacy']?['protected'],
      'verified': json['verification']?['verified'],
      'verified_type': json['verification']?['verified_type'],
      'is_blue_verified': json['is_blue_verified'],
      'followers_count': json['relationship_counts']?['followers'],
      'friends_count': json['relationship_counts']?['following'],
      'favorites_count': json['action_counts']?['favorites_count'],
      'statuses_count': json['tweet_counts']?['tweets'],
      'profile_banner_url': _text(json['banner']?['image_url']),
      'profile_image_url_https': avatar,
      'possibly_sensitive': json['possibly_sensitive'],
      'default_profile_image': avatar?.contains('default_profile_images'),
    };
    modern.removeWhere((_, value) => value == null);
    return modern;
  }

  static String? _text(Object? value) {
    var text = value as String?;
    return (text == null || text.isEmpty) ? null : text;
  }

  static List<String> pinnedTweetIdsOf(Map<String, dynamic> json) {
    var ids = json['pinned_items']?['tweet_ids_str'] ?? json['legacy']?['pinned_tweet_ids_str'];
    return List<String>.from(ids as List<dynamic>? ?? const []);
  }

  factory UserWithExtra.fromJson(Map<String, dynamic> json) {
    var userWithExtra = UserWithExtra()
      ..idStr = json['id_str'] as String?
      ..name = json['name'] as String?
      ..screenName = json['screen_name'] as String?
      ..location = json['location'] as String?
      ..derived = json['derived'] == null ? null : Derived.fromJson(json['derived'] as Map<String, dynamic>)
      ..url = json['url'] as String?
      ..entities = json['entities'] == null ? null : UserEntities.fromJson(json['entities'] as Map<String, dynamic>)
      ..description = json['description'] as String?
      ..protected = json['protected'] as bool?
      ..verified = json['verified_type'] == "Business"
          ? true
          : json['ext_is_blue_verified'] ?? json['verified'] ?? json['is_blue_verified'] as bool?
      ..status = json['status'] == null ? null : Tweet.fromJson(json['status'] as Map<String, dynamic>)
      ..followersCount = json['followers_count'] as int?
      ..friendsCount = json['friends_count'] as int?
      ..listedCount = json['listed_count'] as int?
      ..favoritesCount = json['favorites_count'] as int?
      ..statusesCount = json['statuses_count'] as int?
      ..createdAt = convertTwitterDateTime(json['created_at'] as String?)
      ..profileBannerUrl = json['profile_banner_url'] as String?
      ..profileImageUrlHttps = json['profile_image_url_https'] as String?
      ..defaultProfile = json['default_profile'] as bool?
      ..defaultProfileImage = json['default_profile_image'] as bool?
      ..withheldInCountries = (json['withheld_in_countries'] as List<dynamic>?)?.map((e) => e as String).toList()
      ..withheldScope = json['withheld_scope'] as String?;

    userWithExtra.possiblySensitive = json['possibly_sensitive'] as bool?;

    return userWithExtra;
  }
}
