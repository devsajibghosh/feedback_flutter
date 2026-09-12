# Keep rules for the release build (§9). minifyEnabled/shrinkResources are
# on; most plugins ship their own consumer ProGuard rules bundled in their
# AAR, but these cover the parts that commonly break under R8 without a
# device to actually test the release build against.

# Flutter engine / embedding.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Referenced by Flutter's own deferred-components support even when unused.
-dontwarn com.google.android.play.core.**

# sqflite
-keep class com.tekartik.sqflite.** { *; }

# just_audio / ExoPlayer (media3)
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# record (audio capture)
-keep class com.llfbandit.record.** { *; }

# permission_handler
-keep class com.baseflow.permissionhandler.** { *; }

# connectivity_plus / wakelock_plus / package_info_plus
-keep class dev.fluttercommunity.plus.** { *; }
