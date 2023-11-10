import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/core.dart';
import '../api/model/events.dart';
import '../api/model/initial_snapshot.dart';
import '../api/model/model.dart';
import '../api/route/events.dart';
import '../api/route/messages.dart';
import '../api/route/notifications.dart';
import '../log.dart';
import '../notifications.dart';
import 'autocomplete.dart';
import 'database.dart';
import 'message_list.dart';
import 'recent_dm_conversations.dart';
import 'unreads.dart';

export 'package:drift/drift.dart' show Value;
export 'database.dart' show Account, AccountsCompanion;

/// Store for all the user's data.
///
/// From UI code, use [GlobalStoreWidget.of] to get hold of an appropriate
/// instance of this class.
///
/// This object carries data that is independent of the account, like some
/// settings. It also includes a small amount of data for each account: enough
/// to authenticate as the active account, if there is one.
///
/// For other data associated with a particular account, a [GlobalStore]
/// provides a [PerAccountStore] for each account, which can be reached with
/// [GlobalStore.perAccount] or [GlobalStore.perAccountSync].
///
/// See also:
///  * [LiveGlobalStore], the implementation of this class that
///    we use outside of tests.
abstract class GlobalStore extends ChangeNotifier {
  GlobalStore({required Iterable<Account> accounts})
    : _accounts = Map.fromEntries(accounts.map((a) => MapEntry(a.id, a)));

  /// A cache of the [Accounts] table in the underlying data store.
  final Map<int, Account> _accounts;

  // TODO settings (those that are per-device rather than per-account)
  // TODO push token, and other data corresponding to GlobalSessionState

  final Map<int, PerAccountStore> _perAccountStores = {};
  final Map<int, Future<PerAccountStore>> _perAccountStoresLoading = {};

  /// The store's per-account data for the given account, if already loaded.
  ///
  /// When not null, this is the same [PerAccountStore] that would be returned
  /// by the asynchronous [perAccount].
  PerAccountStore? perAccountSync(int accountId) => _perAccountStores[accountId];

  /// The store's per-account data for the given account.
  ///
  /// If the data for this account is not already loaded, this will ensure a
  /// request is made to load it, and the returned future will complete when
  /// the data is ready.
  ///
  /// The [GlobalStore] will avoid making redundant requests for the same data,
  /// even if this method is called many times.  The futures returned from each
  /// call for the same account will all complete once the data is ready.
  ///
  /// Consider checking [perAccountSync] before calling this function, so that if
  /// the data is already available it can be used immediately (e.g., in the
  /// current frame.)
  ///
  /// See also:
  ///  * [PerAccountStoreWidget.of], for getting the relevant [PerAccountStore]
  ///    from UI code.
  Future<PerAccountStore> perAccount(int accountId) async {
    // First, see if we have the store already.
    PerAccountStore? store = _perAccountStores[accountId];
    if (store != null) {
      return store;
    }

    // Next, see if another call has already started loading one.
    Future<PerAccountStore>? future = _perAccountStoresLoading[accountId];
    if (future != null) {
      return future;
    }

    // It's up to us.  Start loading.
    final account = getAccount(accountId);
    assert(account != null, 'Account not found on global store');
    future = loadPerAccount(account!);
    _perAccountStoresLoading[accountId] = future;
    store = await future;
    _perAccountStores[accountId] = store;
    _perAccountStoresLoading.remove(accountId);
    return store;
  }

  /// Load per-account data for the given account, unconditionally.
  ///
  /// This method should be called only by the implementation of [perAccount].
  /// Other callers interested in per-account data should use [perAccount]
  /// and/or [perAccountSync].
  Future<PerAccountStore> loadPerAccount(Account account);

  // Just the Iterables, not the actual Map, to avoid clients mutating the map.
  // Mutations should go through the setters/mutators below.
  Iterable<Account> get accounts => _accounts.values;
  Iterable<int> get accountIds => _accounts.keys;
  Iterable<({ int accountId, Account account })> get accountEntries {
    return _accounts.entries.map((entry) {
      return (accountId: entry.key, account: entry.value);
    });
  }

  Account? getAccount(int id) => _accounts[id];

  /// Add an account to the store, returning its assigned account ID.
  Future<int> insertAccount(AccountsCompanion data) async {
    final account = await doInsertAccount(data);
    assert(!_accounts.containsKey(account.id));
    _accounts[account.id] = account;
    notifyListeners();
    return account.id;
  }

  /// Add an account to the underlying data store.
  Future<Account> doInsertAccount(AccountsCompanion data);

  // More mutators as needed:
  // Future<void> updateAccount...
}

/// Store for the user's data for a given Zulip account.
///
/// This should always have a consistent snapshot of the state on the server,
/// as provided by the Zulip event system.
///
/// An instance directly of this class will not attempt to poll an event queue
/// to keep the data up to date.  For that behavior, see the subclass
/// [LivePerAccountStore].
class PerAccountStore extends ChangeNotifier {
  /// Create a per-account data store that does not automatically stay up to date.
  ///
  /// For a [PerAccountStore] that polls an event queue to keep itself up to
  /// date, use [LivePerAccountStore.fromInitialSnapshot].
  PerAccountStore.fromInitialSnapshot({
    required this.account,
    required this.connection,
    required InitialSnapshot initialSnapshot,
  }) : zulipVersion = initialSnapshot.zulipVersion,
       maxFileUploadSizeMib = initialSnapshot.maxFileUploadSizeMib,
       realmDefaultExternalAccounts = initialSnapshot.realmDefaultExternalAccounts,
       customProfileFields = _sortCustomProfileFields(initialSnapshot.customProfileFields),
       userSettings = initialSnapshot.userSettings,
       unreads = Unreads(initial: initialSnapshot.unreadMsgs, selfUserId: account.userId),
       users = Map.fromEntries(
         initialSnapshot.realmUsers
         .followedBy(initialSnapshot.realmNonActiveUsers)
         .followedBy(initialSnapshot.crossRealmBots)
         .map((user) => MapEntry(user.userId, user))),
       streams = Map.fromEntries(initialSnapshot.streams.map(
         (stream) => MapEntry(stream.streamId, stream))),
       streamsByName = Map.fromEntries(initialSnapshot.streams.map(
         (stream) => MapEntry(stream.name, stream))),
       subscriptions = Map.fromEntries(initialSnapshot.subscriptions.map(
         (subscription) => MapEntry(subscription.streamId, subscription))),
       recentDmConversationsView = RecentDmConversationsView(
         initial: initialSnapshot.recentPrivateConversations, selfUserId: account.userId);

  final Account account;
  final ApiConnection connection; // TODO(#135): update zulipFeatureLevel with events

  // TODO(#135): Keep all this data updated by handling Zulip events from the server.

  // Data attached to the realm or the server.
  final String zulipVersion; // TODO get from account; update there on initial snapshot
  final int maxFileUploadSizeMib; // No event for this.
  final Map<String, RealmDefaultExternalAccount> realmDefaultExternalAccounts;
  List<CustomProfileField> customProfileFields;

  // Data attached to the self-account on the realm.
  final UserSettings? userSettings; // TODO(server-5)
  final Unreads unreads;

  // Users and data about them.
  final Map<int, User> users;

  // Streams, topics, and stuff about them.
  final Map<int, ZulipStream> streams;
  final Map<String, ZulipStream> streamsByName;
  final Map<int, Subscription> subscriptions;

  // TODO lots more data.  When adding, be sure to update handleEvent too.

  // TODO call [RecentDmConversationsView.dispose] in [dispose]
  final RecentDmConversationsView recentDmConversationsView;

  final Set<MessageListView> _messageListViews = {};

  void registerMessageList(MessageListView view) {
    final added = _messageListViews.add(view);
    assert(added);
  }

  void unregisterMessageList(MessageListView view) {
    final removed = _messageListViews.remove(view);
    assert(removed);
  }

  final AutocompleteViewManager autocompleteViewManager = AutocompleteViewManager();

  /// Called when the app is reassembled during debugging, e.g. for hot reload.
  ///
  /// This will redo from scratch any computations we can, such as parsing
  /// message contents.  It won't repeat network requests.
  void reassemble() {
    for (final view in _messageListViews) {
      view.reassemble();
    }
    autocompleteViewManager.reassemble();
  }

  void handleEvent(Event event) {
    if (event is HeartbeatEvent) {
      assert(debugLog("server event: heartbeat"));
    } else if (event is AlertWordsEvent) {
      assert(debugLog("server event: alert_words"));
      // We don't yet store this data, so there's nothing to update.
    } else if (event is UserSettingsUpdateEvent) {
      assert(debugLog("server event: user_settings/update ${event.property?.name ?? '[unrecognized]'}"));
      if (event.property == null) {
        // unrecognized setting; do nothing
        return;
      }
      switch (event.property!) {
        case UserSettingName.twentyFourHourTime:
          userSettings?.twentyFourHourTime        = event.value as bool;
        case UserSettingName.displayEmojiReactionUsers:
          userSettings?.displayEmojiReactionUsers = event.value as bool;
        case UserSettingName.emojiset:
          userSettings?.emojiset                  = event.value as Emojiset;
      }
      notifyListeners();
    } else if (event is CustomProfileFieldsEvent) {
      assert(debugLog("server event: custom_profile_fields"));
      customProfileFields = _sortCustomProfileFields(event.fields);
      notifyListeners();
    } else if (event is RealmUserAddEvent) {
      assert(debugLog("server event: realm_user/add"));
      users[event.person.userId] = event.person;
      autocompleteViewManager.handleRealmUserAddEvent(event);
      notifyListeners();
    } else if (event is RealmUserRemoveEvent) {
      assert(debugLog("server event: realm_user/remove"));
      users.remove(event.userId);
      autocompleteViewManager.handleRealmUserRemoveEvent(event);
      notifyListeners();
    } else if (event is RealmUserUpdateEvent) {
      assert(debugLog("server event: realm_user/update"));
      final user = users[event.userId];
      if (user == null) {
        return; // TODO log
      }
      if (event.fullName != null)       user.fullName                   = event.fullName!;
      if (event.avatarUrl != null)      user.avatarUrl                  = event.avatarUrl!;
      if (event.avatarVersion != null)  user.avatarVersion              = event.avatarVersion!;
      if (event.timezone != null)       user.timezone                   = event.timezone!;
      if (event.botOwnerId != null)     user.botOwnerId                 = event.botOwnerId!;
      if (event.role != null)           user.role                       = event.role!;
      if (event.isBillingAdmin != null) user.isBillingAdmin             = event.isBillingAdmin!;
      if (event.deliveryEmail != null)  user.deliveryEmailStaleDoNotUse = event.deliveryEmail!;
      if (event.newEmail != null)       user.email                      = event.newEmail!;
      if (event.customProfileField != null) {
        final profileData = (user.profileData ??= {});
        final update = event.customProfileField!;
        if (update.value != null) {
          profileData[update.id] = ProfileFieldUserData(value: update.value!, renderedValue: update.renderedValue);
        } else {
          profileData.remove(update.id);
        }
        if (profileData.isEmpty) {
          // null is equivalent to `{}` for efficiency; see [User._readProfileData].
          user.profileData = null;
        }
      }
      autocompleteViewManager.handleRealmUserUpdateEvent(event);
      notifyListeners();
    } else if (event is StreamCreateEvent) {
      assert(debugLog("server event: stream/create"));
      streams.addEntries(event.streams.map((stream) => MapEntry(stream.streamId, stream)));
      streamsByName.addEntries(event.streams.map((stream) => MapEntry(stream.name, stream)));
      // (Don't touch `subscriptions`. If the user is subscribed to the stream,
      // details will come in a later `subscription` event.)
      notifyListeners();
    } else if (event is StreamDeleteEvent) {
      assert(debugLog("server event: stream/delete"));
      for (final stream in event.streams) {
        streams.remove(stream.streamId);
        streamsByName.remove(stream.name);
        subscriptions.remove(stream.streamId);
      }
      notifyListeners();
    } else if (event is SubscriptionAddEvent) {
      assert(debugLog("server event: subscription/add"));
      for (final subscription in event.subscriptions) {
        subscriptions[subscription.streamId] = subscription;
      }
      notifyListeners();
    } else if (event is SubscriptionRemoveEvent) {
      assert(debugLog("server event: subscription/remove"));
      for (final streamId in event.streamIds) {
        subscriptions.remove(streamId);
      }
      notifyListeners();
    } else if (event is SubscriptionUpdateEvent) {
      assert(debugLog("server event: subscription/update"));
      final subscription = subscriptions[event.streamId];
      if (subscription == null) return; // TODO(log)
      switch (event.property) {
        case SubscriptionProperty.color:
          subscription.color                  = event.value as String;
        case SubscriptionProperty.isMuted:
          subscription.isMuted                = event.value as bool;
        case SubscriptionProperty.inHomeView:
          subscription.isMuted                = !(event.value as bool);
        case SubscriptionProperty.pinToTop:
          subscription.pinToTop               = event.value as bool;
        case SubscriptionProperty.desktopNotifications:
          subscription.desktopNotifications   = event.value as bool;
        case SubscriptionProperty.audibleNotifications:
          subscription.audibleNotifications   = event.value as bool;
        case SubscriptionProperty.pushNotifications:
          subscription.pushNotifications      = event.value as bool;
        case SubscriptionProperty.emailNotifications:
          subscription.emailNotifications     = event.value as bool;
        case SubscriptionProperty.wildcardMentionsNotify:
          subscription.wildcardMentionsNotify = event.value as bool;
        case SubscriptionProperty.unknown:
          // unrecognized property; do nothing
          return;
      }
      notifyListeners();
    } else if (event is SubscriptionPeerAddEvent) {
      assert(debugLog("server event: subscription/peer_add"));
      // TODO(#374): handle event
    } else if (event is SubscriptionPeerRemoveEvent) {
      assert(debugLog("server event: subscription/peer_remove"));
      // TODO(#374): handle event
    } else if (event is MessageEvent) {
      assert(debugLog("server event: message ${jsonEncode(event.message.toJson())}"));
      recentDmConversationsView.handleMessageEvent(event);
      for (final view in _messageListViews) {
        view.maybeAddMessage(event.message);
      }
      unreads.handleMessageEvent(event);
    } else if (event is UpdateMessageEvent) {
      assert(debugLog("server event: update_message ${event.messageId}"));
      for (final view in _messageListViews) {
        view.maybeUpdateMessage(event);
      }
      unreads.handleUpdateMessageEvent(event);
    } else if (event is DeleteMessageEvent) {
      assert(debugLog("server event: delete_message ${event.messageIds}"));
      // TODO handle in message lists
      unreads.handleDeleteMessageEvent(event);
    } else if (event is UpdateMessageFlagsEvent) {
      assert(debugLog("server event: update_message_flags/${event.op} ${event.flag.toJson()}"));
      for (final view in _messageListViews) {
        view.maybeUpdateMessageFlags(event);
      }
      unreads.handleUpdateMessageFlagsEvent(event);
    } else if (event is ReactionEvent) {
      assert(debugLog("server event: reaction/${event.op}"));
      for (final view in _messageListViews) {
        view.maybeUpdateMessageReactions(event);
      }
    } else if (event is UnexpectedEvent) {
      assert(debugLog("server event: ${jsonEncode(event.toJson())}")); // TODO log better
    } else {
      // TODO(dart-3): Use a sealed class / pattern-matching to exclude this.
      throw Exception("Event object of impossible type: ${event.toString()}");
    }
  }

  Future<void> sendMessage({required MessageDestination destination, required String content}) {
    // TODO implement outbox; see design at
    //   https://chat.zulip.org/#narrow/stream/243-mobile-team/topic/.23M3881.20Sending.20outbox.20messages.20is.20fraught.20with.20issues/near/1405739
    return _apiSendMessage(connection, destination: destination, content: content);
  }

  static List<CustomProfileField> _sortCustomProfileFields(List<CustomProfileField> initialCustomProfileFields) {
    // TODO(server): The realm-wide field objects have an `order` property,
    //   but the actual API appears to be that the fields should be shown in
    //   the order they appear in the array (`custom_profile_fields` in the
    //   API; our `realmFields` array here.)  See chat thread:
    //     https://chat.zulip.org/#narrow/stream/378-api-design/topic/custom.20profile.20fields/near/1382982
    //
    // We go on to put at the start of the list any fields that are marked for
    // displaying in the "profile summary".  (Possibly they should be at the
    // start of the list in the first place, but make sure just in case.)
    final displayFields = initialCustomProfileFields.where((e) => e.displayInProfileSummary == true);
    final nonDisplayFields = initialCustomProfileFields.where((e) => e.displayInProfileSummary != true);
    return displayFields.followedBy(nonDisplayFields).toList();
  }
}

const _apiSendMessage = sendMessage; // Bit ugly; for alternatives, see: https://chat.zulip.org/#narrow/stream/243-mobile-team/topic/flutter.3A.20PerAccountStore.20methods/near/1545809

/// A [GlobalStore] that uses a live server and live, persistent local database.
///
/// The underlying data store is an [AppDatabase] corresponding to a SQLite
/// database file in the app's persistent storage on the device.
///
/// The per-account stores will be instances of [LivePerAccountStore],
/// with data loaded through a live [ApiConnection].
class LiveGlobalStore extends GlobalStore {
  LiveGlobalStore._({
    required AppDatabase db,
    required super.accounts,
  }) : _db = db;

  // We keep the API simple and synchronous for the bulk of the app's code
  // by doing this loading up front before constructing a [GlobalStore].
  static Future<GlobalStore> load() async {
    final db = AppDatabase(NativeDatabase.createInBackground(await _dbFile()));
    final accounts = await db.select(db.accounts).get();
    return LiveGlobalStore._(db: db, accounts: accounts);
  }

  /// The file path to use for the app database.
  static Future<File> _dbFile() async {
    // What directory should we use?
    //   path_provider's getApplicationSupportDirectory:
    //     on Android, -> Flutter's PathUtils.getFilesDir -> https://developer.android.com/reference/android/content/Context#getFilesDir()
    //       -> empirically /data/data/com.zulip.flutter/files/
    //     on iOS, -> "Library/Application Support" via https://developer.apple.com/documentation/foundation/nssearchpathdirectory/nsapplicationsupportdirectory
    //     on Linux, -> "${XDG_DATA_HOME:-~/.local/share}/com.zulip.flutter/"
    //     All seem reasonable.
    //   path_provider's getApplicationDocumentsDirectory:
    //     on Android, -> Flutter's PathUtils.getDataDirectory -> https://developer.android.com/reference/android/content/Context#getDir(java.lang.String,%20int)
    //       with https://developer.android.com/reference/android/content/Context#MODE_PRIVATE
    //     on iOS, "Document directory" via https://developer.apple.com/documentation/foundation/nssearchpathdirectory/nsdocumentdirectory
    //     on Linux, -> `xdg-user-dir DOCUMENTS` -> e.g. ~/Documents
    //     That Linux answer is definitely not a fit.  Harder to tell about the rest.
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'zulip.db'));
  }

  final AppDatabase _db;

  @override
  Future<PerAccountStore> loadPerAccount(Account account) {
    return LivePerAccountStore.load(account);
  }

  @override
  Future<Account> doInsertAccount(AccountsCompanion data) async {
    final accountId = await _db.createAccount(data); // TODO(log): db errors
    // We can *basically* predict what the Account will contain
    // based on the AccountsCompanion and the account ID.  But
    // if we did that and then there was some subtle case where we
    // didn't match the database's behavior, that'd be a nasty bug.
    // This isn't a hot path, so just make the extra query.
    return await (_db.select(_db.accounts) // TODO perhaps put this logic in AppDatabase
      ..where((a) => a.id.equals(accountId))
    ).getSingle();
  }
}

/// A [PerAccountStore] which polls an event queue to stay up to date.
// TODO decouple "live"ness from polling and registerNotificationToken;
//   the latter are made up of testable internal logic, not external integration
class LivePerAccountStore extends PerAccountStore {
  LivePerAccountStore.fromInitialSnapshot({
    required super.account,
    required super.connection,
    required super.initialSnapshot,
  }) : queueId = initialSnapshot.queueId ?? (() {
         // The queueId is optional in the type, but should only be missing in the
         // case of unauthenticated access to a web-public realm.  We authenticated.
         throw Exception("bad initial snapshot: missing queueId");
       })(),
       lastEventId = initialSnapshot.lastEventId,
       super.fromInitialSnapshot();

  /// Load the user's data from the server, and start an event queue going.
  ///
  /// In the future this might load an old snapshot from local storage first.
  static Future<PerAccountStore> load(Account account) async {
    final connection = ApiConnection.live(
      realmUrl: account.realmUrl, zulipFeatureLevel: account.zulipFeatureLevel,
      email: account.email, apiKey: account.apiKey);

    final stopwatch = Stopwatch()..start();
    final initialSnapshot = await registerQueue(connection); // TODO retry
    final t = (stopwatch..stop()).elapsed;
    // TODO log the time better
    if (kDebugMode) print("initial fetch time: ${t.inMilliseconds}ms");

    final store = LivePerAccountStore.fromInitialSnapshot(
      account: account,
      connection: connection,
      initialSnapshot: initialSnapshot,
    );
    store.poll();
    // TODO do registerNotificationToken before registerQueue:
    //   https://github.com/zulip/zulip-flutter/pull/325#discussion_r1365982807
    store.registerNotificationToken();
    return store;
  }

  final String queueId;
  int lastEventId;

  void poll() async {
    while (true) {
      final result = await getEvents(connection,
        queueId: queueId, lastEventId: lastEventId);
      // TODO handle errors on get-events; retry with backoff
      // TODO abort long-poll and close ApiConnection on [dispose]
      final events = result.events;
      for (final event in events) {
        handleEvent(event);
      }
      if (events.isNotEmpty) {
        lastEventId = events.last.id;
      }
    }
  }

  /// Send this client's notification token to the server, now and if it changes.
  ///
  /// TODO The returned future isn't especially meaningful (it may or may not
  ///   mean we actually sent the token).  Make it just `void` once we fix the
  ///   one test that relies on the future.
  ///
  /// TODO(#321) handle iOS/APNs; currently only Android/FCM
  // TODO(#322) save acked token, to dedupe updating it on the server
  // TODO(#323) track the registerFcmToken/etc request, warn if not succeeding
  Future<void> registerNotificationToken() async {
    // TODO call removeListener on [dispose]
    NotificationService.instance.token.addListener(_registerNotificationToken);
    await _registerNotificationToken();
  }

  Future<void> _registerNotificationToken() async {
    final token = NotificationService.instance.token.value;
    if (token == null) return;
    await registerFcmToken(connection, token: token);
  }
}
