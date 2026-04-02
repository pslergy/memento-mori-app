# Memento Mori — release R8 / ProGuard
# Цель: обфускация + удаление мёртвого кода (Java/Kotlin слой). Dart AOT отдельно.

# --- Flutter embedding & plugins (JNI / reflection) ---
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }

# --- Наш Kotlin (MethodChannel, Wi‑Fi Direct, GATT, фоновый сервис) ---
-keep class com.example.memento_mori_app.** { *; }

# --- Google Play Services / базовые зависимости ---
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# --- ML Kit / камера (mobile_scanner и т.п.) ---
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
-keep class com.google.android.gms.internal.mlkit_** { *; }
-dontwarn com.google.android.gms.internal.mlkit_**

# --- AndroidX / медиа (just_audio, foreground и др.) ---
-keep class androidx.media.** { *; }
-dontwarn androidx.media.**

# --- OkHttp / Okio (транзитивно у многих плагинов) ---
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**

# --- Kotlin (when / metadata) ---
-keepclassmembers class **$WhenMappings {
    <fields>;
}
-keepclassmembers class kotlin.Metadata {
    public <methods>;
}

# --- Сохраняем атрибуты для стеков в краш-репортах (можно убрать для ещё меньшей «читаемости») ---
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# --- Parcelable / Serializable (если плагины сериализуют) ---
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# --- Cronet (cronet_http) ---
-dontwarn org.chromium.net.**

# --- Play Core (deferred components) — классы есть только в Play-сборках; embedding ссылается опционально ---
-dontwarn com.google.android.play.core.**
