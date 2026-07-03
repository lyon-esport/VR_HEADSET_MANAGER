# NanoHTTPD - keep all public API
-keep class fi.iki.elonen.** { *; }
# Gson - keep model classes
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }
