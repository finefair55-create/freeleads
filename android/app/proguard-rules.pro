# R8 rules for release builds. Firebase, url_launcher and the Flutter
# embedding ship their own consumer rules; only gaps go here.

# Flutter's deferred-components code references Play Core, which this app
# doesn't bundle. Without this, R8 fails on the missing classes.
-dontwarn com.google.android.play.core.**
