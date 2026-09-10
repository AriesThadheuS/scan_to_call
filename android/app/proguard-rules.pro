# Flutter Engine & Plugins
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-dontwarn com.google.android.play.**

# Google ML Kit Text Recognition
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

# SQLite & Sqflite Plugin
-keep class com.tekartik.sqflite.** { *; }
-dontwarn com.tekartik.sqflite.**

# Camera & Image Picker & Url Launcher
-keep class io.flutter.plugins.camera.** { *; }
-keep class io.flutter.plugins.imagepicker.** { *; }
-keep class io.flutter.plugins.urllauncher.** { *; }

