package com.tharunbirla.librecuts.services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.provider.MediaStore
import android.util.Log
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.tharunbirla.librecuts.MainActivity
import com.tharunbirla.librecuts.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.io.File

class ExportService : Service() {

    private val TAG = "ExportService"
    private val CHANNEL_ID = "ExportChannel"
    private val NOTIFICATION_ID = 1001

    private val serviceJob = Job()
    private val serviceScope = CoroutineScope(Dispatchers.IO + serviceJob)
    private lateinit var ffmpegEngine: FFmpegRenderEngine

    companion object {
        const val ACTION_EXPORT_PROGRESS = "com.i7sadegh.cutloss.ACTION_EXPORT_PROGRESS"
        const val ACTION_EXPORT_SUCCESS = "com.i7sadegh.cutloss.ACTION_EXPORT_SUCCESS"
        const val ACTION_EXPORT_FAILURE = "com.i7sadegh.cutloss.ACTION_EXPORT_FAILURE"

        const val EXTRA_PROGRESS = "extra_progress"
        const val EXTRA_SAVED_URI = "extra_saved_uri"
        const val EXTRA_ERROR = "extra_error"

        const val EXTRA_COMMAND = "extra_command"
        const val EXTRA_TEMP_OUTPUT_PATH = "extra_temp_output_path"
        const val EXTRA_CONCAT_FILE_PATH = "extra_concat_file_path"
        const val EXTRA_TOTAL_DURATION_SECS = "extra_total_duration_secs"
        const val EXTRA_IS_AUDIO_ONLY = "extra_is_audio_only"
        const val EXTRA_SMART_PLAN_PATH = "extra_smart_plan_path"
    }

    /** Phase 10 plan.json parse result (commands + explicit output list). */
    private data class ParsedPlan(val commands: List<Pair<String, Double>>, val outputs: List<String>)

    /** runSmartExport result: render status plus the output files it produced. */
    data class SmartExportOutcome(
        val result: FFmpegRenderEngine.RenderResult,
        val outputFiles: List<File>
    )

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        ffmpegEngine = FFmpegRenderEngine(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        val smartPlanPath = intent.getStringExtra(EXTRA_SMART_PLAN_PATH)
        val command = intent.getStringExtra(EXTRA_COMMAND)
        if (command == null && smartPlanPath == null) {
            return START_NOT_STICKY
        }
        val tempOutputPath = intent.getStringExtra(EXTRA_TEMP_OUTPUT_PATH) ?: return START_NOT_STICKY
        val concatFilePath = intent.getStringExtra(EXTRA_CONCAT_FILE_PATH)
        val durationSecs = intent.getDoubleExtra(EXTRA_TOTAL_DURATION_SECS, 0.0)

        startForeground(NOTIFICATION_ID, buildNotification(0, "Exporting..."))

        serviceScope.launch {
            try {
                val smartOutcome: SmartExportOutcome? =
                    if (smartPlanPath != null) runSmartExport(smartPlanPath) else null
                val result: FFmpegRenderEngine.RenderResult = when {
                    smartOutcome != null -> smartOutcome.result
                    command != null -> ffmpegEngine.exportFinal(
                        ffmpegCommand = command,
                        totalDurationSecs = durationSecs,
                        onProgress = { progress ->
                            updateNotification(progress, "Exporting...")
                            broadcastProgress(progress)
                        }
                    )
                    else -> FFmpegRenderEngine.RenderResult.Failure("No export command provided")
                }

                val tempFile = File(tempOutputPath)
                val concatFile = concatFilePath?.let { File(it) }

                when (result) {
                    is FFmpegRenderEngine.RenderResult.Success -> {
                        // Phase 10: smart separate-files mode produces one output
                        // file per timeline clip - each becomes its own gallery entry.
                        val smartFiles = smartOutcome?.outputFiles ?: emptyList()
                        val filesToSave = if (smartFiles.isNotEmpty()) smartFiles else listOf(tempFile)
                        if (filesToSave.size > 1) {
                            val saved = mutableListOf<Uri>()
                            for (f in filesToSave) {
                                val uri = saveVideoToGallery(f)
                                if (uri != null) saved.add(uri)
                            }
                            if (saved.isNotEmpty()) {
                                showCompletionNotification(
                                    "Export Complete",
                                    "${saved.size} of ${filesToSave.size} files saved to gallery",
                                    saved.first()
                                )
                                broadcastSuccess(saved.first().toString())
                                Log.d(TAG, "Separate export successful: ${saved.size} files")
                            } else {
                                showCompletionNotification("Export Failed", "Failed to save videos to gallery", null)
                                broadcastFailure("Failed to save videos to gallery")
                            }
                        } else {
                            val savedUri = saveVideoToGallery(filesToSave[0])
                            if (savedUri != null) {
                                showCompletionNotification("Export Complete", "Video saved to gallery", savedUri)
                                broadcastSuccess(savedUri.toString())
                                Log.d(TAG, "Export successful: $savedUri")
                            } else {
                                showCompletionNotification("Export Failed", "Failed to save video to gallery", null)
                                broadcastFailure("Failed to save video to gallery")
                            }
                        }
                    }
                    is FFmpegRenderEngine.RenderResult.Failure -> {
                        showCompletionNotification("Export Failed", "Error during rendering", null)
                        broadcastFailure(result.error)
                        Log.e(TAG, "Export failed: ${result.error}")
                    }
                    is FFmpegRenderEngine.RenderResult.Cancelled -> {
                        showCompletionNotification("Export Cancelled", "The export was cancelled", null)
                        broadcastFailure("Export cancelled")
                    }
                }

                // Cleanup temp files
                if (tempFile.exists()) tempFile.delete()
                if (concatFile?.exists() == true) concatFile.delete()
                smartPlanPath?.let { sp ->
                    val smartWorkDir = File(sp).parentFile
                    if (smartWorkDir != null && smartWorkDir.exists()) {
                        smartWorkDir.listFiles()?.forEach { it.delete() }
                        smartWorkDir.delete()
                    }
                }

            } catch (e: Exception) {
                Log.e(TAG, "Export exception", e)
                showCompletionNotification("Export Failed", e.message ?: "Unknown error", null)
                broadcastFailure(e.message ?: "Unknown error")
            } finally {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }

        return START_NOT_STICKY
    }

    /**
     * Smart export mode (phase 9/10): runs the plan produced by
     * SmartExportPlanner command-by-command with aggregated progress. In
     * merged mode the last command is the concat step that writes the final
     * output file; in separate mode (phase 10) every segment file IS an
     * output. plan.json is read in object form ({"separate":...,
     * "outputs":[...], "commands":[...]}) with the phase 9 plain-array form
     * still accepted.
     */
    private suspend fun runSmartExport(planPath: String): SmartExportOutcome {
        val planFile = File(planPath)
        if (!planFile.exists()) {
            return SmartExportOutcome(
                FFmpegRenderEngine.RenderResult.Failure("Smart export plan not found"),
                emptyList()
            )
        }
        val parsed: ParsedPlan = try {
            parseSmartPlan(planFile)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse smart export plan: ${e.message}", e)
            return SmartExportOutcome(
                FFmpegRenderEngine.RenderResult.Failure("Invalid smart export plan"),
                emptyList()
            )
        }
        val commands = parsed.commands
        if (commands.isEmpty()) {
            return SmartExportOutcome(
                FFmpegRenderEngine.RenderResult.Failure("Empty smart export plan"),
                emptyList()
            )
        }

        val totalWeight = commands.sumOf { it.second }.coerceAtLeast(0.001)
        var completedWeight = 0.0
        var lastResult: FFmpegRenderEngine.RenderResult =
            FFmpegRenderEngine.RenderResult.Failure("No commands executed")

        for (pair in commands) {
            val cmd = pair.first
            val weight = pair.second
            val base = completedWeight
            val result = ffmpegEngine.exportFinal(
                ffmpegCommand = cmd,
                totalDurationSecs = if (weight > 0.01) weight else null,
                onProgress = { pct ->
                    val overall = (((base + pct / 100.0 * weight) / totalWeight) * 100)
                        .toInt().coerceIn(0, 99)
                    updateNotification(overall, "Exporting...")
                    broadcastProgress(overall)
                }
            )
            if (result !is FFmpegRenderEngine.RenderResult.Success) {
                // Phase 10.1: wrap the render failure so the return type
                // matches SmartExportOutcome; outputFiles is only read on
                // success, so an empty list is correct here.
                return SmartExportOutcome(result, emptyList())
            }
            completedWeight += weight
            lastResult = result
        }

        broadcastProgress(100)
        updateNotification(100, "Exporting...")
        return SmartExportOutcome(lastResult, parsed.outputs.map { File(it) })
    }

    /**
     * Parse a phase 10 plan.json (object form) or a phase 9 plan (plain
     * array of {cmd, weight} objects; outputs stay empty -> the caller falls
     * back to the temp output path).
     */
    private fun parseSmartPlan(planFile: File): ParsedPlan {
        val raw = planFile.readText().trim()
        if (raw.startsWith("[")) {
            val arr = org.json.JSONArray(raw)
            val list = mutableListOf<Pair<String, Double>>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                list.add(Pair(o.getString("cmd"), o.optDouble("weight", 1.0)))
            }
            return ParsedPlan(list, emptyList())
        }
        val obj = org.json.JSONObject(raw)
        val arr = obj.getJSONArray("commands")
        val list = mutableListOf<Pair<String, Double>>()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            list.add(Pair(o.getString("cmd"), o.optDouble("weight", 1.0)))
        }
        val outArr = obj.optJSONArray("outputs")
        val outs = mutableListOf<String>()
        if (outArr != null) {
            for (i in 0 until outArr.length()) outs.add(outArr.getString(i))
        }
        return ParsedPlan(list, outs)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Video Export",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(progress: Int, title: String): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(if (progress > 0) "$progress%" else "Starting...")
            .setSmallIcon(R.drawable.ic_save_24)
            .setProgress(100, progress, progress == 0)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(progress: Int, title: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(progress, title))
    }

    private fun showCompletionNotification(title: String, message: String, videoUri: Uri?) {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            if (videoUri != null) {
                setDataAndType(videoUri, if (message.contains("Audio", true)) "audio/*" else "video/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } else {
                setClass(this@ExportService, MainActivity::class.java)
            }
        }

        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(R.drawable.ic_check_24)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID + 1, notification)
    }

    private fun broadcastProgress(progress: Int) {
        val intent = Intent(ACTION_EXPORT_PROGRESS).apply {
            putExtra(EXTRA_PROGRESS, progress)
        }
        LocalBroadcastManager.getInstance(this).sendBroadcast(intent)
    }

    private fun broadcastSuccess(savedUri: String) {
        val intent = Intent(ACTION_EXPORT_SUCCESS).apply {
            putExtra(EXTRA_SAVED_URI, savedUri)
        }
        LocalBroadcastManager.getInstance(this).sendBroadcast(intent)
    }

    private fun broadcastFailure(error: String) {
        val intent = Intent(ACTION_EXPORT_FAILURE).apply {
            putExtra(EXTRA_ERROR, error)
        }
        LocalBroadcastManager.getInstance(this).sendBroadcast(intent)
    }

    private fun saveVideoToGallery(videoFile: File): Uri? {
        // Phase 13: the smart plan can export MP4/MKV/MOV/WebM (and the
        // audio-only formats) - derive the gallery mime type, extension and
        // name prefix from the ACTUAL output file instead of assuming MP4.
        val ext = "." + videoFile.extension.lowercase()
        val isAudio: Boolean
        val mimeType: String
        val prefix: String
        when (ext) {
            ".mp3" -> { isAudio = true; mimeType = "audio/mpeg"; prefix = "Cutloss_Audio_" }
            ".m4a" -> { isAudio = true; mimeType = "audio/mp4"; prefix = "Cutloss_Audio_" }
            ".opus" -> { isAudio = true; mimeType = "audio/opus"; prefix = "Cutloss_Audio_" }
            ".flac" -> { isAudio = true; mimeType = "audio/flac"; prefix = "Cutloss_Audio_" }
            ".wav" -> { isAudio = true; mimeType = "audio/x-wav"; prefix = "Cutloss_Audio_" }
            ".mkv" -> { isAudio = false; mimeType = "video/x-matroska"; prefix = "Cutloss_" }
            ".mov" -> { isAudio = false; mimeType = "video/quicktime"; prefix = "Cutloss_" }
            ".webm" -> { isAudio = false; mimeType = "video/webm"; prefix = "Cutloss_" }
            ".avi" -> { isAudio = false; mimeType = "video/x-msvideo"; prefix = "Cutloss_" }
            else -> { isAudio = false; mimeType = "video/mp4"; prefix = "Cutloss_" }
        }

        val sharedPreferences = getSharedPreferences("librecuts_prefs", Context.MODE_PRIVATE)
        val prefKey = if (isAudio) "export_audio_directory_uri" else "export_directory_uri"
        val customUriString = sharedPreferences.getString(prefKey, null)
        
        if (customUriString != null) {
            try {
                val treeUri = Uri.parse(customUriString)
                val parentUri = android.provider.DocumentsContract.buildDocumentUriUsingTree(
                    treeUri,
                    android.provider.DocumentsContract.getTreeDocumentId(treeUri)
                )
                val newFileUri = android.provider.DocumentsContract.createDocument(
                    contentResolver,
                    parentUri,
                    mimeType,
                    "${prefix}${System.currentTimeMillis()}$ext"
                )
                if (newFileUri != null) {
                    contentResolver.openOutputStream(newFileUri)?.use { output ->
                        videoFile.inputStream().use { input -> input.copyTo(output) }
                    }
                    return newFileUri
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error saving to custom directory: ${e.message}, falling back to default", e)
            }
        }

        return try {
            val contentValues = android.content.ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, "${prefix}${System.currentTimeMillis()}$ext")
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                if (isAudio) {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/Cutloss")
                } else {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Cutloss")
                }
            }
            val collectionUri = if (isAudio) MediaStore.Audio.Media.EXTERNAL_CONTENT_URI else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            val uri = contentResolver.insert(collectionUri, contentValues)
            uri?.let {
                contentResolver.openOutputStream(it)?.use { output ->
                    videoFile.inputStream().use { input -> input.copyTo(output) }
                }
                it
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error saving to default gallery: ${e.message}", e)
            null
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        serviceJob.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
