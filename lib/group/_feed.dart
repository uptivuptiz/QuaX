import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:quax/client/client.dart';
import 'package:quax/constants.dart';
import 'package:quax/database/entities.dart';
import 'package:quax/database/repository.dart';
import 'package:quax/generated/l10n.dart';
import 'package:quax/group/feed_cache.dart';
import 'package:quax/group/feed_session_cache.dart';
import 'package:quax/group/group_screen.dart';
import 'package:quax/tweet/conversation.dart';
import 'package:quax/tweet/paginated_tweet_list.dart';
import 'package:quax/tweet/tweet_context_scope.dart';
import 'package:quax/utils/iterables.dart';
import 'package:pref/pref.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:quax/utils/urls.dart';

class SubscriptionGroupFeed extends StatefulWidget {
  final SubscriptionGroupGet group;
  final List<SubscriptionGroupFeedChunk> chunks;
  final bool includeReplies;
  final bool includeRetweets;
  // When non-null, the PagingController and scroll offset are stored in the
  // app-scoped FeedSessionCache under this key, so pop+push of the same route
  // restores tweets and scroll position. When null, state is local to this
  // State and disposed normally — used by home-tab usages, which are kept
  // alive by AutomaticKeepAliveClientMixin in the shell.
  final String? cacheKey;
  // Cached tweets to show immediately while the first page loads, seeded by the
  // caller (e.g. the All/Following feed reuses the preview it already read while
  // its subscriptions were loading). Refined to this feed's own chunks once read.
  final List<TweetChain>? initialPreview;

  const SubscriptionGroupFeed(
      {super.key,
      required this.group,
      required this.chunks,
      required this.includeReplies,
      required this.includeRetweets,
      this.cacheKey,
      this.initialPreview});

  @override
  State<SubscriptionGroupFeed> createState() => _SubscriptionGroupFeedState();
}

class _SubscriptionGroupFeedState extends State<SubscriptionGroupFeed> {
  late final TweetFeedController _feedController;
  FeedSessionCache? _cache;
  ScrollController? _innerScrollController;
  bool _scrollRestoreScheduled = false;
  // Batched initial-load state.
  bool _isDoingInitialLoad = false;
  bool _initialLoadCancelled = false;
  List<TweetChain>? _batchedChains;
  final ScrollController _scrollController = ScrollController();

  bool get _usesCache => widget.cacheKey != null;

  @override
  void initState() {
    super.initState();
    if (_usesCache) {
      _cache = context.read<FeedSessionCache>();
      _feedController = _cache!.getOrCreateController(widget.cacheKey!);
    } else {
      _feedController = TweetFeedController();
    }
    // Batched initial load: feeds chunks in small batches with a delay so
    // results appear incrementally instead of firing all 63+ API calls at once.
    if (!_usesCache && !_feedController.hasItems && widget.chunks.isNotEmpty) {
      _loadInitialBatches();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_usesCache) return;
    // Inside NestedScrollView's body, PrimaryScrollController is the inner
    // controller PagedListView attaches to, and the one we need for jumpTo().
    _innerScrollController = PrimaryScrollController.maybeOf(context);
    _maybeRestoreScrollOffset();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (_usesCache && notification is ScrollEndNotification) {
      final metrics = notification.metrics;
      if (metrics.hasPixels) {
        _cache!.saveOffset(widget.cacheKey!, metrics.pixels);
      }
    }
    return false;
  }

  void _maybeRestoreScrollOffset() {
    if (_scrollRestoreScheduled) return;
    _scrollRestoreScheduled = true;
    final saved = _cache!.readOffset(widget.cacheKey!);
    if (saved == null || saved <= 0) return;
    _scheduleRestore(saved);
  }

  // The cached items render and lay out across the first few frames, so the
  // ScrollPosition may not be attached yet on the very first post-frame.
  // Keep scheduling post-frame callbacks until the scrollable reports stable
  // dimensions, then jump. Terminates via `mounted` when the widget unmounts.
  void _scheduleRestore(double offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = _innerScrollController;
      if (c == null || !c.hasClients || !c.position.haveDimensions) {
        _scheduleRestore(offset);
        return;
      }
      c.jumpTo(offset.clamp(0.0, c.position.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    _initialLoadCancelled = true;
    _isDoingInitialLoad = false;
    _scrollController.dispose();
    if (!_usesCache) {
      _feedController.dispose();
    }
    // When cached, the FeedSessionCache owns the controller's lifecycle across
    // pop/push; PaginatedTweetList has already detached its own listener.
    super.dispose();
  }

  @override
  void didUpdateWidget(SubscriptionGroupFeed oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.includeReplies != widget.includeReplies ||
        oldWidget.includeRetweets != widget.includeRetweets ||
        !_chunksMatch(oldWidget.chunks, widget.chunks)) {
      _feedController.controller.refresh();
    }
  }

  bool _chunksMatch(List<SubscriptionGroupFeedChunk> a, List<SubscriptionGroupFeedChunk> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].hash != b[i].hash) return false;
    }
    return true;
  }

  Future<String> createCursor(Database repository) async {
    return (await repository.insert(tableFeedGroupCursor, {}, nullColumnHack: 'id')).toString();
  }

  bool feedContainsUnrelatedTweets(TweetStatus tweets, List<Subscription> users) {
    final screenNames = users.map((e) => e.screenName).toSet();
    return tweets.chains.any(
        (chain) => chain.tweets.any((tweet) => tweet.user != null && !screenNames.contains(tweet.user!.screenName)));
  }

  Future<void> showUnrelatedPostsInFeedWarning() async {
    await showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text("⚠️ ${L10n.of(context).feed_issue_detected}"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(L10n.of(context).feed_contains_unrelated_tweets),
                SizedBox(height: Theme.of(context).textTheme.bodyMedium!.fontSize! * 2),
                PrefCheckbox(
                  title: Text(
                    L10n.of(context).never_show_again,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  pref: optionDisableWarningsForUnrelatedPostsInFeed,
                )
              ],
            ),
            actions: [
              TextButton(
                child: Text(L10n.of(context).more_info),
                onPressed: () async {
                  await openUri(context, "https://github.com/Teskann/QuaX/issues/26");
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
              ),
              TextButton(
                child: Text(L10n.of(context).close),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        });
  }

  /// Loads all chunks in batches of 3 with a 5-second delay between batches.
  /// After each batch the results are shown immediately via setState, so the
  /// user sees posts appearing as they load. Once every chunk has been fetched
  /// the paging controller is seeded with all results so "load older" works.
  Future<void> _loadInitialBatches() async {
    _isDoingInitialLoad = true;

    var repository = await Repository.writable();
    var cursorId = await createCursor(repository);
    var allChains = <TweetChain>[];
    bool shouldShowUnrelatedPostsInFeedWarning = false;

    const batchSize = 3;
    const delay = Duration(seconds: 5);

    for (var i = 0; i < widget.chunks.length; i += batchSize) {
      if (_initialLoadCancelled) return;

      var batchEnd = (i + batchSize < widget.chunks.length)
          ? i + batchSize
          : widget.chunks.length;
      var batchFutures = <Future<(List<TweetChain>, bool)>>[];

      for (var j = i; j < batchEnd; j++) {
        batchFutures
            .add(_processChunk(widget.chunks[j], null, repository, cursorId));
      }

      try {
        var batchResult = await Future.wait(batchFutures);
        for (var (chains, hasUnrelated) in batchResult) {
          allChains.addAll(chains);
          shouldShowUnrelatedPostsInFeedWarning |= hasUnrelated;
        }
      } catch (e) {
        debugPrint('Initial batch $i failed: $e');
      }

      if (_initialLoadCancelled) return;

      setState(() => _batchedChains = List.of(allChains));

      // Wait before the next batch (skip after the last one).
      if (i + batchSize < widget.chunks.length) {
        await Future.delayed(delay);
      }
    }

    if (_initialLoadCancelled) return;
    if (!mounted) return;

    // Unrelated-posts warning (only once, after all batches).
    if (shouldShowUnrelatedPostsInFeedWarning &&
        !PrefService.of(context)
            .get(optionDisableWarningsForUnrelatedPostsInFeed)) {
      await showUnrelatedPostsInFeedWarning();
      if (_initialLoadCancelled) return;
    }

    // Seed the paging controller so normal pagination can continue from here.
    _feedController.seed(allChains, cursorId.toString());

    _isDoingInitialLoad = false;
    if (mounted) setState(() {});
  }

  String _buildSearchQuery(List<Subscription> users) {
    var query = '';

    var remainingLength = 512 - query.length;

    for (var user in users) {
      var queryToAdd = '';
      if (user is UserSubscription) {
        queryToAdd = 'from:${user.screenName}';
      } else if (user is SearchSubscription) {
        queryToAdd = '"${user.id}"';
      }

      // If we can add this user to the query and still be less than ~512 characters, do so
      if (query.length + queryToAdd.length < remainingLength) {
        if (query != '' && query.isNotEmpty) {
          query += ' OR ';
        }

        query += queryToAdd;
      } else {
        // Otherwise, add the search future and start a new one
        assert(false, 'should never reach here');
        query = queryToAdd;
      }
    }

    if (!widget.includeReplies) {
      query += ' -filter:replies ';
    }

    if (!widget.includeRetweets) {
      query += ' -filter:retweets ';
    } else {
      query += ' include:nativeretweets ';
    }

    return query;
  }

  /// Search for our next "page" of tweets.
  ///
  /// Here, each page is actually a set of mappings, where the ID of each set is the hash of all the user IDs in that
  /// set. We store this along with the top and bottom pagination cursors, which we use to perform pagination for all
  /// sets at the same time, allowing us to create a feed made up of individual search queries.
  Future<TweetPageResult> _listTweets(String? cursorKey) async {
    var repository = await Repository.writable();
    var nextCursor = await createCursor(repository);

    const batchSize = 3;
    var allChains = <TweetChain>[];
    bool shouldShowUnrelatedPostsInFeedWarning = false;

    for (var i = 0; i < widget.chunks.length; i += batchSize) {
      var batchEnd = (i + batchSize < widget.chunks.length) ? i + batchSize : widget.chunks.length;
      var batchFutures = <Future<(List<TweetChain>, bool)>>[];

      for (var j = i; j < batchEnd; j++) {
        batchFutures.add(_processChunk(widget.chunks[j], cursorKey, repository, nextCursor));
      }

      try {
        var batchResult = await Future.wait(batchFutures);
        for (var (chains, hasUnrelated) in batchResult) {
          allChains.addAll(chains);
          shouldShowUnrelatedPostsInFeedWarning |= hasUnrelated;
        }
      } catch (e) {
        debugPrint('Batch $i failed: $e');
      }
    }

    var threads = sortChainsNewestFirst(allChains);

    if (!mounted) {
      return (chains: <TweetChain>[], nextCursor: null);
    }

    if (shouldShowUnrelatedPostsInFeedWarning &&
        !PrefService.of(context).get(optionDisableWarningsForUnrelatedPostsInFeed)) {
      await showUnrelatedPostsInFeedWarning();
    }

    return (chains: threads, nextCursor: nextCursor);
  }

  Future<(List<TweetChain> chains, bool hasUnrelated)> _processChunk(
    SubscriptionGroupFeedChunk chunk,
    String? cursorKey,
    Database repository,
    String nextCursor,
  ) async {
    var tweets = <TweetChain>[];
    var hash = chunk.hash;

    String? searchCursor;

    if (cursorKey == null) {
      var storedChunks = await repository.query(tableFeedGroupChunk,
          where: 'hash = ?', whereArgs: [hash], orderBy: 'created_at DESC');

      tweets.addAll(chainsFromStoredChunks(storedChunks));

      var latestChunk = storedChunks.firstOrNull;
      if (latestChunk != null) {
        searchCursor = latestChunk['cursor_top'] as String;
      }
    } else {
      var storedChunks = await repository.query(tableFeedGroupChunk,
          where: 'cursor_id = ? AND hash = ?', whereArgs: [int.parse(cursorKey), hash]);
      if (storedChunks.isNotEmpty) {
        searchCursor = storedChunks.first['cursor_bottom'] as String;
      }
    }

    var query = _buildSearchQuery(chunk.users);
    var result = await Twitter.searchTweets(query, widget.includeReplies, cursor: searchCursor);

    bool hasUnrelated = feedContainsUnrelatedTweets(result, chunk.users);

    if (result.chains.isNotEmpty) {
      tweets.addAll(result.chains);
      await repository.insert(tableFeedGroupChunk, {
        'cursor_id': int.parse(nextCursor),
        'hash': hash,
        'cursor_top': result.cursorTop,
        'cursor_bottom': result.cursorBottom,
        'response': jsonEncode(result.chains.map((e) => e.toJson()).toList()),
      });
    }

    return (tweets, hasUnrelated);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chunks.isEmpty) {
      return Scaffold(
        body: Center(
          child: Text(L10n.of(context).this_group_contains_no_subscriptions),
        ),
      );
    }

    // During the batched initial load show a plain interactive list so the user
    // can scroll and tap posts while the remaining batches arrive. Once the
    // paging controller has been seeded we switch to the normal paginated list.
    if (_isDoingInitialLoad && !_feedController.hasItems) {
      return Scaffold(
        body: TweetContextScope(
          child: _batchedChains != null
              ? ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(top: 4),
                  itemCount: _batchedChains!.length,
                  itemBuilder: (context, index) {
                    var chain = _batchedChains![index];
                    return TweetConversation(
                      id: chain.id,
                      tweets: chain.tweets,
                      username: null,
                      isPinned: chain.isPinned,
                    );
                  },
                )
              : const Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Scaffold(
      body: TweetContextScope(
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: PaginatedTweetList(
            feed: _feedController,
            loadPage: _listTweets,
            scrollController: _scrollController,
            username: null,
            firstPagePreview: null,
            onRefresh: () async {
              var repository = await Repository.writable();
              await repository.delete(tableFeedGroupChunk);
            },
            firstPageErrorPrefix: L10n.of(context).unable_to_load_the_tweets_for_the_feed,
            newPageErrorPrefix: L10n.of(context).unable_to_load_the_next_page_of_tweets,
            emptyMessage: L10n.of(context).could_not_find_any_tweets_from_the_last_7_days,
          ),
        ),
      ),
    );
  }
}
