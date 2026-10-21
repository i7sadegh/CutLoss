# ==========================================================================
#  CutStudio release ProGuard / R8 rules
#  Introduced with the phase-0 cleanup (minifyEnabled true).
#
#  IMPORTANT -- why these rules exist:
#   1. ProjectSerializer (utils/ProjectSerializer.kt) serializes the edit
#      graph to .lcprj project files using Gson REFLECTION and stores the
#      runtime class simple name ("type"/"operationType": "Trim",
#      "AddText", ...). If R8 renames any class or field in the models
#      package, every previously saved project file becomes unreadable.
#   2. ffmpeg-kit talks to native code through JNI. JNI resolves native
#      methods by class/method NAME, so renaming breaks the whole render
#      engine at runtime.
#   3. Gson resolves generic field types (List<EditOperation>, etc.) via
#      the Signature attribute -- it must be preserved.
# ==========================================================================

# ---- Keep stack traces readable in crash logs (name is still obfuscated,
#      but file/line numbers survive for error diagnostics) ----
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# ---- Required by Gson reflection (generic type resolution) ----
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*,AnnotationDefault

# ---- .lcprj project models: keep verbatim (class names + field names) ----
#  Covers EditOperation (sealed, all subclasses), EditRecipe, VideoProject,
#  SubtitleCue and anything else added to the models package later.
-keep class com.tharunbirla.librecuts.models.** { *; }

#  Serializable machinery for the same package (EditOperation : Serializable)
-keepclassmembers class com.tharunbirla.librecuts.models.** implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# ---- ffmpeg-kit (com.antonkarpenko repack): JNI bindings must keep names ----
-keep class com.antonkarpenko.ffmpegkit.** { *; }

# ---- Gson TypeToken (anonymous subclasses capture generic types) ----
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken

# ---- Enums: Gson serializes by constant name; R8 must not rename them ----
-keepclassmembers enum com.tharunbirla.librecuts.** {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# ---- Lottie animations load by file name from assets (no rules needed),
#      ExoPlayer / Material / aboutlibraries ship their own consumer rules ----
