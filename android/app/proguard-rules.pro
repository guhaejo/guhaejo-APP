# Flutter engine/embedding classes are kept via each plugin's own consumer-rules.
# These extra rules are a safety net for reflection-based / JSON-adjacent code paths.

-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Supabase / gotrue / postgrest talk over plain HTTP+JSON with no code generation,
# but keep enum values just in case any model relies on name()/valueOf().
-keepclassmembers enum * { *; }

-dontwarn io.flutter.embedding.**
