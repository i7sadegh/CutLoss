package com.tharunbirla.librecuts

import android.media.MediaMetadataRetriever
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.widget.EditText
import android.widget.TextView
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.tharunbirla.librecuts.viewmodels.VideoEditingViewModel
import java.io.File
import java.util.Locale

/**
 * CutStudio - Export settings dialog (v2).
 *
 * Every control change is pushed live into the ViewModel, then the REAL export
 * command is rebuilt through VideoEditingViewModel.buildConsolidatedFFmpegCommand()
 * (the exact same code path the final export uses) and displayed in the preview
 * box, together with an estimated output file size.
 *
 * Save   -> keeps the current state and triggers the export flow.
 * Cancel -> restores the snapshot taken when the dialog was opened.
 */
class ExportSettingsDialog(
    private val activity: VideoEditingActivity,
    private val viewModel: VideoEditingViewModel,
    private val sourceFile: File?,
    private val durationMs: Long,
    private val fontPath: String?,
    private val onApplyAndExport: () -> Unit
) {
    // ---- snapshot of pre-dialog state (restored on Cancel) ----
    private var snapRes = 1080
    private var snapFps = 30
    private var snapBitrate = "8M"
    private var snapAudioOnly = false
    private var snapAdvanced = VideoEditingViewModel.AdvancedExport()

    // ---- current dialog state ----
    private var selRes = 1080            // 0 = same as input
    private var selFps = 30              // 0 = same as input
    private var bitrateSameAsInput = true
    private var manualBitrateKbps = 8000
    private var selFormat = "same"       // same|mp4|mkv|mov|webm|avi
    private var selCodec = ""            // "" = same as input (app default chain)
    private var selPreset = "medium"     // ultrafast..veryslow
    private var selAudioFormat = "same"  // same|aac|mp3|opus|flac|wav
    private var selAudioCodec = "aac"    // aac|libmp3lame|libopus|pcm_s16le|flac
    private var selAudioBitrate = ""     // "" = same as input
    private var customW = 0
    private var customH = 0
    private var suppressBoxClear = false

    // ---- probed source info ----
    private var srcW = 0
    private var srcH = 0
    private var srcKbps = 0

    // ---- views ----
    private lateinit var tvEstimatedSize: TextView
    private lateinit var tvCommand: TextView
    private lateinit var etWidth: EditText
    private lateinit var etHeight: EditText
    private lateinit var etBitrate: EditText
    private lateinit var chipBitrateSame: Chip
    private lateinit var cgResolution: ChipGroup
    private lateinit var cgAudioCodec: ChipGroup

    fun show() {
        probeSource()

        snapRes = viewModel.exportResolution.value
        snapFps = viewModel.exportFps.value
        snapBitrate = viewModel.exportBitrate.value
        snapAudioOnly = viewModel.exportAudioOnly.value
        snapAdvanced = viewModel.advancedExport.value.copy()

        selRes = snapRes
        selFps = snapFps
        selCodec = snapAdvanced.videoCodec
        selPreset = snapAdvanced.preset.ifEmpty { "medium" }
        selAudioCodec = snapAdvanced.audioCodec.ifEmpty { "aac" }
        selAudioBitrate = snapAdvanced.audioBitrate
        selFormat = when (snapAdvanced.videoFormat) {
            "mkv" -> "mkv"; "mov" -> "mov"; "webm" -> "webm"; "avi" -> "avi"; else -> "same"
        }
        selAudioFormat = when (snapAdvanced.audioOnlyFormat) {
            "mp3" -> "mp3"; "opus" -> "opus"; "flac" -> "flac"; "wav" -> "wav"; else -> "same"
        }
        customW = snapAdvanced.customWidth
        customH = snapAdvanced.customHeight
        parseBitrate(snapBitrate)

        val dialogView = activity.layoutInflater.inflate(R.layout.dialog_export_settings, null)
        val dialog = MaterialAlertDialogBuilder(activity).setView(dialogView).create()

        bindViews(dialogView)

        dialog.setOnCancelListener { restoreSnapshot() }
        dialogView.findViewById<View>(R.id.btnCancelExport).setOnClickListener { dialog.cancel() }
        dialogView.findViewById<View>(R.id.btnSaveExport).setOnClickListener {
            dialog.dismiss()
            onApplyAndExport()
        }

        refresh()
        dialog.show()
    }

    // ---------------------------------------------------------------- helpers

    private fun parseBitrate(cur: String) {
        val kbps: Int? = when {
            cur.endsWith("M", true) -> cur.dropLast(1).toDoubleOrNull()?.let { (it * 1000).toInt() }
            cur.endsWith("k", true) -> cur.dropLast(1).toIntOrNull()
            cur.toIntOrNull() != null -> cur.toIntOrNull()
            else -> null
        }
        if (kbps != null && kbps in 100..500000) {
            bitrateSameAsInput = false
            manualBitrateKbps = kbps
        } else {
            bitrateSameAsInput = true
        }
    }

    private fun restoreSnapshot() {
        viewModel.setExportSettings(snapRes, snapFps, snapAudioOnly, snapBitrate)
        viewModel.setAdvancedExport(snapAdvanced)
    }

    private fun probeSource() {
        val f = sourceFile ?: return
        if (!f.exists()) return
        try {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(f.absolutePath)
                var w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                var h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                if (rot == 90 || rot == 270) { val t = w; w = h; h = t }
                srcW = w
                srcH = h
            } finally { r.release() }
        } catch (_: Exception) { }
        val durSec = durationMs / 1000.0
        if (durSec > 0 && f.length() > 0) {
            srcKbps = (f.length() * 8.0 / 1000.0 / durSec).toInt()
        }
    }

    private fun sourceVideoKbps(): Int {
        val total = if (srcKbps > 0) srcKbps else 8000
        return (total - 128).coerceAtLeast(300)
    }

    private fun effectiveVideoKbps(): Int {
        if (!bitrateSameAsInput) {
            val typed = etBitrate.text.toString().toIntOrNull()
            if (typed != null && typed in 100..500000) return typed
        }
        return sourceVideoKbps()
    }

    private fun currentBitrateString(): String = "${effectiveVideoKbps()}k"

    private fun effectiveVideoFormat(): String {
        if (selFormat != "same") return selFormat
        val ext = sourceFile?.extension?.lowercase(Locale.US) ?: ""
        return if (ext in listOf("mp4", "mkv", "mov", "webm", "avi")) ext else "mp4"
    }

    private fun effectiveAudioOnlyFormat(): String {
        if (selAudioFormat != "same") {
            return when (selAudioFormat) {
                "aac" -> "m4a"; "mp3" -> "mp3"; "opus" -> "opus"
                "flac" -> "flac"; "wav" -> "wav"; else -> "m4a"
            }
        }
        val ext = sourceFile?.extension?.lowercase(Locale.US) ?: ""
        return if (ext in listOf("m4a", "mp3", "opus", "flac", "wav")) ext else "m4a"
    }

    private fun estimateSizeText(): String {
        val durSec = durationMs / 1000.0
        if (durSec <= 0.0) return "..."
        val videoKbps = effectiveVideoKbps()
        val audioKbps = when {
            selAudioCodec == "pcm_s16le" -> 1411
            selAudioCodec == "flac" -> 900
            selAudioBitrate.isNotEmpty() -> selAudioBitrate.dropLast(1).toIntOrNull() ?: 128
            else -> 128
        }
        val bytes = (videoKbps + audioKbps) * 1000.0 / 8.0 * durSec
        val body = when {
            bytes < 1024.0 * 1024 -> String.format(Locale.US, "%.0f KB", bytes / 1024.0)
            bytes < 1024.0 * 1024 * 1024 -> String.format(Locale.US, "%.1f MB", bytes / (1024.0 * 1024))
            else -> String.format(Locale.US, "%.2f GB", bytes / (1024.0 * 1024 * 1024))
        }
        return "~$body"
    }

    // ------------------------------------------------------------ live refresh

    private fun refresh() {
        if (!::tvCommand.isInitialized) return
        viewModel.setExportSettings(selRes, selFps, snapAudioOnly, currentBitrateString())
        viewModel.setAdvancedExport(
            VideoEditingViewModel.AdvancedExport(
                videoFormat = effectiveVideoFormat(),
                videoCodec = selCodec,
                preset = selPreset,
                audioCodec = selAudioCodec,
                audioBitrate = selAudioBitrate,
                audioOnlyFormat = effectiveAudioOnlyFormat(),
                customWidth = customW,
                customHeight = customH
            )
        )
        val ext = viewModel.getOutputExtension(false)
        val previewPath = File(activity.cacheDir, "temp_video_preview$ext").absolutePath
        val srcPath = sourceFile?.absolutePath
        val cmd = if (srcPath != null)
            viewModel.buildConsolidatedFFmpegCommand(srcPath, previewPath, fontPath, activity)
        else null
        tvCommand.text = when {
            cmd == null -> "(preview unavailable)"
            cmd.contains("(CONCAT_LIST:") ->
                cmd.substring(0, cmd.indexOf("(CONCAT_LIST:")).trim() +
                    "  ...(+concat list appended at export time)"
            else -> cmd
        }
        tvEstimatedSize.text = estimateSizeText()
    }

    // -------------------------------------------------------------- view setup

    private fun <T> wireChipRow(
        group: ChipGroup,
        valueById: Map<Int, T>,
        initial: T?,
        selectionRequired: Boolean,
        onPick: (T?) -> Unit
    ) {
        group.setSelectionRequired(selectionRequired)
        val startChip = valueById.entries.firstOrNull { it.value == initial }?.key
            ?: valueById.entries.firstOrNull()?.key
        if (startChip != null) group.check(startChip)
        group.setOnCheckedStateChangeListener { _, ids ->
            val id = ids.firstOrNull()
            onPick(if (id == null) null else valueById[id])
            refresh()
        }
    }

    private fun bindViews(v: View) {
        tvEstimatedSize = v.findViewById(R.id.tvEstimatedSize)
        tvCommand = v.findViewById(R.id.tvCommand)
        etWidth = v.findViewById(R.id.etWidth)
        etHeight = v.findViewById(R.id.etHeight)
        etBitrate = v.findViewById(R.id.etBitrate)
        chipBitrateSame = v.findViewById(R.id.chipBitrateSame)
        cgResolution = v.findViewById(R.id.cgResolution)
        cgAudioCodec = v.findViewById(R.id.cgAudioCodec)

        etWidth.hint = if (srcW > 0) srcW.toString() else "1920"
        etHeight.hint = if (srcH > 0) srcH.toString() else "1080"

        // ---- Resolution chips (custom W x H boxes override the row) ----
        wireChipRow(cgResolution, mapOf(
            R.id.chipResSame to 0, R.id.chipRes360 to 360, R.id.chipRes480 to 480,
            R.id.chipRes720 to 720, R.id.chipRes1080 to 1080,
            R.id.chipRes1440 to 1440, R.id.chipRes2160 to 2160), selRes, false
        ) { picked ->
            if (picked != null) {
                selRes = picked
                if (!suppressBoxClear) clearWxH()
            }
        }

        // ---- custom W x H boxes ----
        val wxhWatcher = object : TextWatcher {
            override fun beforeTextChanged(p0: CharSequence?, p1: Int, p2: Int, p3: Int) {}
            override fun onTextChanged(p0: CharSequence?, p1: Int, p2: Int, p3: Int) {}
            override fun afterTextChanged(e: Editable?) { onWxHChanged() }
        }
        etWidth.addTextChangedListener(wxhWatcher)
        etHeight.addTextChangedListener(wxhWatcher)
        if (customW > 0 && customH > 0) {
            etWidth.setText(customW.toString())
            etHeight.setText(customH.toString())
        }

        // ---- Video format ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgVideoFormat), mapOf(
            R.id.chipFmtSame to "same", R.id.chipFmtMp4 to "mp4", R.id.chipFmtMkv to "mkv",
            R.id.chipFmtMov to "mov", R.id.chipFmtWebm to "webm", R.id.chipFmtAvi to "avi"),
            selFormat, true
        ) { picked -> selFormat = picked ?: "same" }

        // ---- Video codec ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgVideoCodec), mapOf(
            R.id.chipCodecSame to "", R.id.chipCodecX264 to "libx264",
            R.id.chipCodecH265 to "hevc_mediacodec", R.id.chipCodecX265 to "libx265",
            R.id.chipCodecVp9 to "libvpx-vp9", R.id.chipCodecAv1 to "libaom-av1"),
            selCodec, true
        ) { picked -> selCodec = picked ?: "" }

        // ---- Video FPS ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgFps), mapOf(
            R.id.chipFpsSame to 0, R.id.chipFps24 to 24, R.id.chipFps25 to 25,
            R.id.chipFps30 to 30, R.id.chipFps60 to 60), selFps, true
        ) { picked -> selFps = picked ?: 0 }

        // ---- Audio format (also drives -c:a; last-touched wins vs codec row) ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgAudioFormat), mapOf(
            R.id.chipAFSame to "same", R.id.chipAFAac to "aac", R.id.chipAFMp3 to "mp3",
            R.id.chipAFOpus to "opus", R.id.chipAFFlac to "flac", R.id.chipAFWav to "wav"),
            selAudioFormat, true
        ) { picked ->
            selAudioFormat = picked ?: "same"
            val codec = when (selAudioFormat) {
                "aac" -> "aac"; "mp3" -> "libmp3lame"; "opus" -> "libopus"
                "flac" -> "flac"; "wav" -> "pcm_s16le"; else -> null
            }
            if (codec != null) {
                selAudioCodec = codec
                val chip = when (codec) {
                    "aac" -> R.id.chipACAac; "libmp3lame" -> R.id.chipACMp3
                    "libopus" -> R.id.chipACOpus; else -> 0
                }
                if (chip != 0) cgAudioCodec.check(chip) else cgAudioCodec.clearCheck()
            }
        }

        // ---- Audio codec ----
        wireChipRow(cgAudioCodec, mapOf(
            R.id.chipACAac to "aac", R.id.chipACMp3 to "libmp3lame",
            R.id.chipACOpus to "libopus", R.id.chipACPcm to "pcm_s16le"),
            selAudioCodec, true
        ) { picked -> if (picked != null) selAudioCodec = picked }

        // ---- Audio bitrate ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgAudioBitrate), mapOf(
            R.id.chipABSame to "", R.id.chipAB128 to "128k", R.id.chipAB192 to "192k",
            R.id.chipAB256 to "256k", R.id.chipAB320 to "320k"),
            selAudioBitrate, true
        ) { picked -> selAudioBitrate = picked ?: "" }

        // ---- Preset ----
        wireChipRow(v.findViewById<ChipGroup>(R.id.cgPreset), mapOf(
            R.id.chipPresetUltrafast to "ultrafast", R.id.chipPresetSuperfast to "superfast",
            R.id.chipPresetVeryfast to "veryfast", R.id.chipPresetFaster to "faster",
            R.id.chipPresetFast to "fast", R.id.chipPresetMedium to "medium",
            R.id.chipPresetSlow to "slow", R.id.chipPresetSlower to "slower",
            R.id.chipPresetVeryslow to "veryslow"),
            selPreset, true
        ) { picked -> selPreset = picked ?: "medium" }

        // ---- Video bitrate: textbox + "Same as input" chip ----
        chipBitrateSame.isChecked = bitrateSameAsInput
        chipBitrateSame.setOnCheckedChangeListener { _, checked ->
            bitrateSameAsInput = checked
            applyBitrateBoxState()
            refresh()
        }
        etBitrate.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(p0: CharSequence?, p1: Int, p2: Int, p3: Int) {}
            override fun onTextChanged(p0: CharSequence?, p1: Int, p2: Int, p3: Int) {}
            override fun afterTextChanged(e: Editable?) { refresh() }
        })
        applyBitrateBoxState()
        if (!bitrateSameAsInput) etBitrate.setText(manualBitrateKbps.toString())
    }

    private fun applyBitrateBoxState() {
        if (bitrateSameAsInput) {
            etBitrate.isEnabled = false
            etBitrate.alpha = 0.45f
            etBitrate.setText(sourceVideoKbps().toString())
        } else {
            etBitrate.isEnabled = true
            etBitrate.alpha = 1f
        }
    }

    private fun clearWxH() {
        customW = 0
        customH = 0
        etWidth.setText("")
        etHeight.setText("")
    }

    private fun onWxHChanged() {
        val w = etWidth.text.toString().toIntOrNull()
        val h = etHeight.text.toString().toIntOrNull()
        if (w != null && h != null && w >= 16 && h >= 16 && w <= 8192 && h <= 8192) {
            customW = w
            customH = h
            if (cgResolution.checkedChipId != View.NO_ID) cgResolution.clearCheck()
        } else {
            customW = 0
            customH = 0
            if (cgResolution.checkedChipId == View.NO_ID) {
                suppressBoxClear = true
                cgResolution.check(R.id.chipResSame)
                suppressBoxClear = false
            }
        }
        refresh()
    }
}
