import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../models/lead.dart';
import '../models/search_profile.dart';
import '../platform/firebase_support.dart';

/// A Google account signed in to Firebase, shown on the Post a Lead screen.
class PosterAccount {
  const PosterAccount({required this.uid, this.email, this.name});

  final String uid;
  final String? email;
  final String? name;

  /// "Jane Doe" or "jane@example.com".
  String get label => name ?? email ?? 'Google account';
}

/// Thrown by [FirestoreService.postLead] when no Google account is signed in.
class SignInRequiredException implements Exception {
  const SignInRequiredException();

  @override
  String toString() => 'Sign in with Google to post a lead.';
}

/// Direct customer (user-posted) leads in Cloud Firestore.
///
/// Never touches Firebase unless an app is initialized on a supported
/// platform. When unavailable, [isAvailable] is false, [watchCommunityLeads]
/// emits an empty list and [postLead] throws, and the repository keeps
/// posted orders on-device instead.
///
/// Documents live in `leads/{id}` with the fields from [Lead.toCloudJson]
/// plus `createdAt` (server timestamp) and `zipPrefix`. See
/// `firestore.rules` and `firestore.indexes.json` at the project root.
class FirestoreService {
  FirestoreService._(this._firestore, this._auth);

  factory FirestoreService({FirebaseFirestore? firestore, FirebaseAuth? auth}) {
    if (firestore != null) {
      return FirestoreService._(firestore, auth);
    }
    if (_canUseFirebase()) {
      try {
        return FirestoreService._(
          FirebaseFirestore.instance,
          FirebaseAuth.instance,
        );
      } catch (error, stackTrace) {
        debugPrint('Firestore unavailable, community leads disabled: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
    return FirestoreService._(null, null);
  }

  /// A service with no backend, for tests and unsupported platforms.
  factory FirestoreService.unavailable() => FirestoreService._(null, null);

  static const collection = 'leads';
  static const usersCollection = 'users';
  static const _feedLimit = 100;

  final FirebaseFirestore? _firestore;
  final FirebaseAuth? _auth;

  bool get isAvailable => _firestore != null;

  String? get currentUserId => _auth?.currentUser?.uid;

  /// The signed-in Google account, or null while anonymous / signed out.
  PosterAccount? get account => _accountOf(_auth?.currentUser);

  /// [account] now and whenever the user signs in or out.
  Stream<PosterAccount?> watchAccount() {
    final auth = _auth;
    if (auth == null) {
      return Stream<PosterAccount?>.value(null);
    }
    return auth.userChanges().map(_accountOf);
  }

  static PosterAccount? _accountOf(User? user) {
    if (user == null || user.isAnonymous) {
      return null;
    }
    String? blankToNull(String? value) =>
        value == null || value.trim().isEmpty ? null : value.trim();
    return PosterAccount(
      uid: user.uid,
      email: blankToNull(user.email),
      name: blankToNull(user.displayName),
    );
  }

  /// One-tap Google sign-in through Firebase Auth (needs the Google provider
  /// enabled in the Firebase console). The anonymous account used to read
  /// the feed is upgraded in place, so its uid, and the user's earlier
  /// posts, carry over. Returns null if the user closed the account picker.
  Future<PosterAccount?> signInWithGoogle() async {
    final auth = _auth;
    if (auth == null) {
      throw StateError('Firebase is not available on this device.');
    }
    final provider = GoogleAuthProvider()
      ..setCustomParameters({'prompt': 'select_account'});
    try {
      final current = auth.currentUser;
      UserCredential credential;
      if (current != null && current.isAnonymous) {
        try {
          credential = kIsWeb
              ? await current.linkWithPopup(provider)
              : await current.linkWithProvider(provider);
        } on FirebaseAuthException catch (error) {
          // That Google account already has its own Firebase user (e.g.
          // from another device): switch to it instead.
          if (error.code != 'credential-already-in-use' &&
              error.code != 'email-already-in-use') {
            rethrow;
          }
          final existing = error.credential;
          credential = existing != null
              ? await auth.signInWithCredential(existing)
              : await _signInWith(auth, provider);
        }
      } else {
        credential = await _signInWith(auth, provider);
      }
      return _accountOf(credential.user);
    } on FirebaseAuthException catch (error) {
      if (const {
        'canceled',
        'cancelled',
        'web-context-canceled',
        'popup-closed-by-user',
        'cancelled-popup-request',
      }.contains(error.code)) {
        return null;
      }
      debugPrint('Google sign-in failed: ${error.code} ${error.message}');
      rethrow;
    }
  }

  static Future<UserCredential> _signInWith(
    FirebaseAuth auth,
    GoogleAuthProvider provider,
  ) => kIsWeb
      ? auth.signInWithPopup(provider)
      : auth.signInWithProvider(provider);

  /// Signs out of Google, then back in anonymously so the feed keeps
  /// loading.
  Future<void> signOut() async {
    final auth = _auth;
    if (auth == null) {
      return;
    }
    await auth.signOut();
    await ensureSignedIn();
  }

  static bool _canUseFirebase() {
    if (!isFirebasePlatformSupported) {
      return false;
    }
    try {
      return Firebase.apps.isNotEmpty;
    } catch (error) {
      debugPrint('Firebase.apps check failed: $error');
      return false;
    }
  }

  /// Signs in anonymously (unless already signed in) so security rules can
  /// require `request.auth` to read the feed. Posting additionally needs
  /// [signInWithGoogle]. Requires the Anonymous provider to be enabled in
  /// the Firebase console.
  ///
  /// Concurrent callers (the feed, onboarding's restore, a post) share one
  /// sign-in. Separate calls would each create an anonymous account, and
  /// writes stamped with one uid would then be denied under the other.
  Future<String?> ensureSignedIn() {
    final auth = _auth;
    if (auth == null) {
      return Future.value();
    }
    final current = auth.currentUser;
    if (current != null) {
      return Future.value(current.uid);
    }
    return _signingIn ??= _signIn(auth).whenComplete(() => _signingIn = null);
  }

  Future<String?>? _signingIn;

  Future<String?> _signIn(FirebaseAuth auth) async {
    try {
      final credential = await auth.signInAnonymously();
      return credential.user?.uid;
    } on FirebaseAuthException catch (error) {
      debugPrint('Anonymous sign-in failed: ${error.code} ${error.message}');
      return null;
    }
  }

  /// Newest community leads, scoped to [zipPrefix] (first 3 ZIP digits)
  /// when given. Errors are logged and surface as an empty list so the
  /// scraped feed keeps working.
  Stream<List<Lead>> watchCommunityLeads({String? zipPrefix}) {
    final firestore = _firestore;
    if (firestore == null) {
      return Stream<List<Lead>>.value(const []);
    }

    // Re-subscribes with backoff after errors (e.g. permission-denied
    // because anonymous sign-in failed while offline) instead of leaving
    // the community feed empty until the next restart.
    late final StreamController<List<Lead>> controller;
    StreamSubscription<List<Lead>>? subscription;
    Timer? retry;
    var attempt = 0;
    var cancelled = false;

    Future<void> subscribe() async {
      await ensureSignedIn();
      if (cancelled) {
        return;
      }
      Query<Map<String, dynamic>> query = firestore.collection(collection);
      if (zipPrefix != null && zipPrefix.isNotEmpty) {
        query = query.where('zipPrefix', isEqualTo: zipPrefix);
      }
      query = query.orderBy('createdAt', descending: true).limit(_feedLimit);
      subscription = query
          .snapshots()
          .map((snapshot) => [for (final doc in snapshot.docs) ?_readLead(doc)])
          .listen(
            (leads) {
              attempt = 0;
              controller.add(leads);
            },
            onError: (Object error, StackTrace stack) {
              debugPrint('Community lead stream error: $error');
              if (error is FirebaseException &&
                  error.code == 'failed-precondition') {
                debugPrint(
                  'Deploy firestore.indexes.json (zipPrefix + createdAt).',
                );
              }
              subscription?.cancel();
              if (cancelled) {
                return;
              }
              final delay = Duration(seconds: 5 << attempt.clamp(0, 4));
              attempt++;
              retry = Timer(delay, subscribe);
            },
          );
    }

    controller = StreamController<List<Lead>>(
      onListen: subscribe,
      onCancel: () {
        cancelled = true;
        retry?.cancel();
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// A community lead from [doc], or null when the doc is malformed. One
  /// bad doc must not error the stream: it would be read again on every
  /// re-subscribe and keep the whole community feed empty.
  static Lead? _readLead(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    try {
      // Orders are written by strangers; never trust the text.
      final lead = Lead.fromJson(doc.data(), id: doc.id).sanitized();
      // A just-posted lead's server timestamp is still pending.
      return lead.createdAt == null
          ? lead.copyWith(createdAt: DateTime.now())
          : lead;
    } catch (error) {
      debugPrint('Skipping malformed community lead ${doc.id}: $error');
      return null;
    }
  }

  /// Writes [lead] and returns it with its new id, plus whether the server
  /// confirmed the write within [ackTimeout]. Unconfirmed writes stay in
  /// Firestore's offline queue and upload when the device reconnects.
  Future<({Lead lead, bool confirmed})> postLead(
    Lead lead, {
    Duration ackTimeout = const Duration(seconds: 5),
  }) async {
    final firestore = _firestore;
    if (firestore == null) {
      throw StateError('Firestore is not available on this device.');
    }
    // The rules only accept posts from Google accounts, so an anonymous
    // write would be rejected later, after the user was told it was posted.
    final uid = account?.uid;
    if (uid == null) {
      throw const SignInRequiredException();
    }
    final doc = firestore.collection(collection).doc();
    final stored = lead.copyWith(
      id: doc.id,
      authorId: uid,
      source: LeadSource.internal,
      createdAt: DateTime.now(),
    );
    // Offline, Firestore queues the write locally and this future only
    // completes once the server acknowledges it; don't block the UI on that.
    final confirmed = await doc
        .set({
          ...stored.toCloudJson(),
          'zipPrefix': stored.zipCode.length >= 3
              ? stored.zipCode.substring(0, 3)
              : '',
          'createdAt': FieldValue.serverTimestamp(),
        })
        .then((_) => true)
        .timeout(
          ackTimeout,
          onTimeout: () {
            debugPrint('Lead ${doc.id} queued until online.');
            return false;
          },
        );
    return (lead: stored, confirmed: confirmed);
  }

  /// Deletes a lead the current user posted.
  ///
  /// Offline, the delete is queued and this returns after [ackTimeout]
  /// rather than waiting for the server.
  Future<void> deleteLead(
    String id, {
    Duration ackTimeout = const Duration(seconds: 5),
  }) async {
    await _firestore
        ?.collection(collection)
        .doc(id)
        .delete()
        .timeout(
          ackTimeout,
          onTimeout: () => debugPrint('Delete of $id queued until online.'),
        );
  }

  /// Backs up the user's search preferences to `users/{uid}` (readable
  /// only by that user). Best effort: offline, the write is queued.
  Future<void> saveProfile(
    SearchProfile profile, {
    Duration ackTimeout = const Duration(seconds: 5),
  }) async {
    final firestore = _firestore;
    if (firestore == null) {
      return;
    }
    try {
      final uid = await ensureSignedIn();
      if (uid == null) {
        return;
      }
      await firestore
          .collection(usersCollection)
          .doc(uid)
          .set({
            'profession': profile.profession,
            'zipCode': profile.zipCode,
            'radiusMiles': profile.radiusMiles,
            'updatedAt': FieldValue.serverTimestamp(),
          })
          .timeout(
            ackTimeout,
            onTimeout: () => debugPrint('Profile backup queued until online.'),
          );
    } catch (error) {
      debugPrint('Profile backup failed: $error');
    }
  }

  /// The preferences saved by [saveProfile] for the signed-in user, if any.
  Future<SearchProfile?> loadProfile({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final firestore = _firestore;
    if (firestore == null) {
      return null;
    }
    try {
      final uid = await ensureSignedIn().timeout(timeout);
      if (uid == null) {
        return null;
      }
      final snapshot = await firestore
          .collection(usersCollection)
          .doc(uid)
          .get()
          .timeout(timeout);
      final data = snapshot.data();
      if (data == null) {
        return null;
      }
      final profile = SearchProfile.fromJson(data);
      return profile.isValid ? profile : null;
    } catch (error) {
      debugPrint('Profile restore skipped: $error');
      return null;
    }
  }
}
