# Plan: "you don't follow this author" indicator

## Decisions (settled)

| Question | Choice |
|---|---|
| Visual | Corner badge on the avatar ("+" circle, bottom-right), Bluesky-style |
| Scope | Every tweet feed: main feed, group feeds and "For you" |
| Tap | Opens the existing subscribe / add-to-group popup |
| Existing "unrelated posts" dialog | Keep unchanged |
| Reaching the tile | A `showFollowStatus` field on the existing `TweetContextState`, not a flag threaded through the tile constructors |
| Quoted / birdwatch-quoted tweets | Badge shown there too |
| Pref default | On |

## Context from the codebase

- The signal already exists: `feedContainsUnrelatedTweets` (`lib/group/_feed.dart:163`) diffs author
  screen names against the chunk's subscriptions and raises a modal warning gated by
  `optionDisableWarningsForUnrelatedPostsInFeed`. This feature is the inline, per-post rendering of
  the same fact. The dialog stays as-is.
- "Following" has no X follow-graph behind it — nothing in `lib/client/` parses
  `relationship_perspectives`. It means a row in `tableSubscription`, i.e. `SubscriptionsModel.state`.
- App vocabulary is *subscribe* / *unsubscribe* (`FollowButton`, `lib/user.dart:147`), so user-facing
  strings say "not subscribed", not "not following".
- The main feed is not a separate screen: the Following tab is `SubscriptionGroupFeed` with group id
  `-1` (`lib/home/_feed.dart` → `lib/group/group_screen.dart:130`). Main feed and group feeds are the
  same widget, so those two share one opt-in site. The "For you" tab (`lib/home/_for_you.dart`)
  builds its own `TweetContextState` instead of going through `TweetContextScope`, so it is a second,
  separate opt-in site.
- `lib/tweet/tweet_context_scope.dart` already wraps both feed paths (`lib/group/_feed.dart:308` and
  the loading preview at `lib/group/group_screen.dart:105`) and already carries per-feed state
  (`TweetContextState`, `VideoContextState`). It is the plumbing this feature needs.

### Rules that fall out of that

- `inFeed == false` subscribers are still subscribed → no badge.
- `SearchSubscription` rows share the list but their `id` is a search term, not a user id → the
  lookup set must include `UserSubscription` only.
- Match on `idStr`, not `screenName`. The existing check uses screen names, which break on rename.
- The tile renders `retweetedStatusWithCard` when present (`lib/tweet/tweet.dart:456`), so the avatar
  already belongs to the original author. Retweets of non-subscribed authors are the main case and
  need no special handling.
- Hard suppress when `hideAuthorInformation` is true (`lib/tweet/tweet.dart:460`) — non-confirmation-
  bias mode exists to hide exactly this kind of cue.
- No badge when `tweet.user?.idStr` is null — there is nothing to subscribe to.

## Steps

1. **`lib/subscriptions/subscription_lookup.dart`** (new)
   Pure `SubscriptionLookup` built from `List<Subscription>`: a `Set<String>` of `UserSubscription`
   ids, plus `bool isSubscribed(String? userId)`. No store dependency, so it unit-tests directly.

2. ~~**`lib/subscriptions/users_model.dart`** — expose a cached lookup.~~ **Dropped.**
   The badge's own `ScopedBuilder` already hands it the current `state`, so it builds
   `SubscriptionLookup(state)` inline: nothing to keep in sync, and no ordering question between
   `execute`'s notification and the cache assignment. Revisit only if the per-badge `Set` build ever
   shows up in a profile.

3. **`lib/database/entities.dart`**
   `UserSubscription.fromUser` (line 166) null-asserts `idStr`, `screenName`, `name`, `verified` and
   `createdAt`; the last four are routinely absent on tweet-embedded users. Make it null-safe before
   any tap routes through it, and widen its parameter from `UserWithExtra` to `User` — `tweet.user` is
   typed `User`, and the factory only reads base-class fields. Its three existing callers (`lib/profile/profile.dart:555`,
   `lib/profile/_follows.dart:69`, `lib/search/search.dart:210`) pass full user objects, so relaxing
   the asserts does not change their behaviour.

4. **`lib/user.dart`**
   - `UserAvatar` gains an optional `badge`; `Stack` + `Positioned` must sit **outside** its
     `ClipRRect` or the badge is clipped away, and the `Stack` needs `clipBehavior: Clip.none` so the
     badge's hit area may spill past the avatar box.
   - New `SubscribeAvatarBadge`: owns its own
     `ScopedBuilder<SubscriptionsModel, List<Subscription>>` so a subscription change repaints only
     the badges, not whole tiles. It reuses `FollowButton` rather than restating the menu:
     `FollowButton` gains an optional `child` that replaces its icon, and `PopupMenuButton`'s own
     `InkWell` then swallows the tap, which otherwise reaches the `onTapProfile` gesture area the
     avatar sits in (`lib/tweet/tweet.dart`, `onTapProfile`). Visual spec below.

5. **`lib/tweet/tweet_context_scope.dart` + `lib/profile/profile.dart` (`TweetContextState`)**
   - `TweetContextState` gains `final bool showFollowStatus` as a named optional, default `false`, so
     the seven sites that construct it directly need no change.
   - `TweetContextScope` gains the same optional and forwards it.
   - `lib/group/_feed.dart:308` and `lib/group/group_screen.dart:105` pass `showFollowStatus: true`.
   - `lib/home/_for_you.dart:59` does not use `TweetContextScope`, so it passes `showFollowStatus: true`
     to the `TweetContextState` it constructs itself. Nothing else does.

6. **`lib/tweet/tweet.dart`**
   - Delete the redundant `ClipRRect` wrapping `UserAvatar` at line 677 — `UserAvatar` already clips.
   - In `build`, show the badge when `context.read<TweetContextState>().showFollowStatus` is true, the
     pref is on, and `!hideAuthorInformation`.
   - Read the pref in `build`, not through the `late final` fields copied in `initState`, or the badge
     will not react to the pref changing.
   - Quoted and birdwatch-quoted tiles read the same context and so inherit the badge, as decided.

7. **Pref**
   `optionShowNotFollowedIndicator` in `lib/constants.dart`, default `true` in `lib/main.dart`
   (~line 248, beside `optionNonConfirmationBiasMode`), `PrefSwitch` in `lib/settings/_posts.dart`.

8. **Strings**
   New ARB keys for the setting title/description and the badge's `Semantics` label, then
   `fvm dart run intl_utils:generate`. Use the `/translate` skill.

## UI design

Sizes, against the 48px avatar the tile draws (`avatarSize`, `lib/tweet/tweet.dart:830`):

| Part | Value |
|---|---|
| Badge outer diameter | 20 (a 16 circle plus a 2 ring on each side) |
| Icon | `Icons.add`, size 12 |
| Position | `bottom: 0, right: 0` of the avatar box — the badge overlaps the avatar's bottom-right corner and stays **inside** the 48 box |
| Hit area | 32×32 transparent, anchored on the badge |

Staying inside the avatar box is what keeps the layout untouched: the tile's body indent is
`railLeft + avatarSize` with no slack (`lib/tweet/tweet.dart:834`), so a badge that stuck out would
need every row measurement revisited.

Colors, all from the theme — no literals:

- Fill `theme.colorScheme.primary`, icon `theme.colorScheme.onPrimary`.
- A 2px ring in the tile's own card colour, so the badge reads as a cut-out rather than a sticker.
  `tweetCardColor(context)` (`lib/tweet/tweet.dart:877`) returns exactly that, including the
  true-black theme case. `lib/user.dart` must not import `lib/tweet/tweet.dart` for it — pass the
  colour in as a parameter from the tile, falling back to `theme.cardColor`.
- This inherits light/dark and the true-black theme for free; no per-theme branch to write.

Reference for the idiom: `GifBadge` (`lib/tweet/_video_controls.dart:879`) is the existing small-badge
widget in this codebase — a plain `Container` with a `BoxDecoration`, no custom painter. Follow it.

Two deliberate deviations, worth stating so they don't get 'fixed' later:

- The 32×32 hit area is below Material's 48×48 minimum. It cannot be 48 here without covering the
  whole avatar; the badge's `GestureDetector` sits above `onTapProfile` in the `Stack`, so the
  overlapping region opens the popup rather than the profile.
- No animation when the badge disappears on subscribe. The `ScopedBuilder` rebuild is enough; add a
  fade only if it looks abrupt in practice.

The thread connector line is drawn at the avatar's centre X and passes *behind* the avatar
(`lib/tweet/tweet.dart:839-841`), so a bottom-right badge does not touch it.

## Reading the pref

**Settled:** kept the non-listening `PrefService.of(context, listen: false)`, matching the rest of
`lib/tweet/tweet.dart`. An open feed therefore picks the toggle up on its next rebuild; a listening
read would rebuild every tile on any pref change.

## Test

One test file, `test/subscriptions/subscription_lookup_test.dart` (the suite is split by feature):
- should report a subscribed author as subscribed
- should ignore search subscriptions when building the id set
- should flag an author whose id matches no user subscription
- should report a subscription hidden from the main feed as subscribed
- should not flag a null author id as subscribed
