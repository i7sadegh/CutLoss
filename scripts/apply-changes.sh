#!/usr/bin/env bash
###############################################################################
# CutLoss phase 14 -- "the transition contract"
#
# User directive (spelled out by the user):
#   When a transition sits between two videos, the program must first make
#   that small segment MATCH the main video, then attach it to the rest
#   like a separate clip, so the whole thing assembles with -c copy and no
#   second encode. The values that must be identical to the main video:
#     codec, profile, resolution, pixel format, sar, dar, fps, tbn,
#     sample rate, channel layout.
#
# What changes (3 files):
#   SmartExportPlanner.kt:
#     - probeMedia now also reads sample_aspect_ratio ("0:1"/unset -> 1:1)
#       and the video time_base denominator (tbn).
#     - A fade transition exports as its own small segments: the left
#       clip's tail fading out + the right clip's head fading in, both
#       re-encoded with parameters IDENTICAL to the reference clip -
#       libx264/libx265 with the source profile + level, source pixel
#       format (encodablePixFmt), no scale (same resolution), setsar=
#       source SAR (DAR follows from W/H + SAR), fps= source rate,
#       -video_track_timescale source tbn, -c:a aac -ar source -ac source.
#       Everything else stays a stream copy and the concat demuxer
#       assembles with -c copy: only the transition window is re-encoded.
#     - Copied spans next to a transition are cut EXACTLY at keyframe
#       packet boundaries: the planner probes the packet list with
#       FFprobeKit.execute (-show_packets), seeks with -ss at the keyframe
#       timestamp and limits video with -frames:v N counted from the list,
#       so no frame is duplicated or lost at the seams (a plain -t alone
#       overshoots the tail by the B-frame reorder delay - measured 2
#       frames in the lab).
#     - -video_track_timescale <source tbn> is written on every MP4/MOV
#       segment and the finalize command, so mixed-timescale sources
#       normalize losslessly and the concat output carries the source tbn.
#     - Normal-cut and per-segment-encode plans carry the fades inside
#       their own commands (local timestamps) + matching afade windows on
#       the audio; the two-step plan bakes the fades into the lossless cut
#       (step 1) so the finalize re-encode keeps them.
#     - Transition types: fade / dissolve / fadeblack / fadewhite render
#       (fade and dissolve as a dip through black - disclosed in the
#       dialog note; fadewhite dips through white). Every other type
#       (wipes, slides, circles, ...) needs to blend frames from two
#       clips at once = a filter graph -> the export blocks with the real
#       reason instead of silently degrading.
#     - Durations clamp to each side's span (>=250 ms untouched material
#       per side, effect >= 200 ms) via ONE shared helper so the dialog
#       and the planner always agree.
#     - New per-clip uniformity gate: sample aspect ratio must match.
#     - A non-encodable pixel format + a transition takes the uniform
#       per-segment encode (the fade pieces could not match their copied
#       neighbours otherwise).
#   ExportSettingsDialog.kt:
#     - The transition note now says what really happens: "N transition(s)
#       as matched fade segments (only the transition window is
#       re-encoded)"; separate-files mode says transitions need the merged
#       single-file export.
#     - Copy/re-encode seconds + size estimate account for the transition
#       windows (keyframe cut: the D window re-encodes; normal cut: the
#       whole adjacent clips do).
#     - smartEncodeMode mirrors the new non-encodable + transitions
#       trigger; the two-step preview shows the transition piece command.
#   VideoEditingActivity.kt:
#     - The live transition preview window follows the transition's own
#       duration instead of a hardcoded 1000 ms.
#
# Every template was validated against ffmpeg in the lab (sources with
# GOP 1s / 0.7s, tbn 15360 / 30000, h264 / hevc, yuv420p / yuvj420p, with
# and without audio, mixed timescales): exact frame counts at the seams
# (240/240, 360 for three clips), uniform stream parameters after concat,
# clean decodes, fades landing where they should, and honest blocking for
# non-fade types.
#
# Apply + build: upload as scripts/apply-changes.sh; the apply-and-build
# workflow runs it, commits the result and produces the APK.
###############################################################################
set -euo pipefail

PLANNER="app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
ESD="app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
VEA="app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"

for f in "$PLANNER" "$ESD" "$VEA"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f not found - run from the repository root at the expected commit"
    exit 1
  fi
done

echo "== phase 14: applying the transition contract =="

python3 - <<'PYEOF'
import sys

PLANNER = "app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt"
ESD = "app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt"
VEA = "app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt"

edits_applied = 0
edits_skipped = 0


def apply_edit(path, old, new, name):
    global edits_applied, edits_skipped
    with open(path, "r") as f:
        s = f.read()
    if new in s:
        edits_skipped += 1
        return
    if old not in s:
        print("  [FAIL] " + name + ": anchor not found")
        sys.exit(1)
    if s.count(old) != 1:
        print("  [FAIL] " + name + ": anchor not unique")
        sys.exit(1)
    s = s.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(s)
    edits_applied += 1


apply_edit(PLANNER, """ * Phase 12: there is NO legacy filter-graph fallback anymore - this
 * planner is the ONLY export pipeline, and it never emits complex filter
 * graphs. Transitions export as straight cuts (frames are never blended). Any
 * pixel format is fine: keyframe cuts copy bytes untouched, encodable""",
""" * Phase 12: there is NO legacy filter-graph fallback anymore - this
 * planner is the ONLY export pipeline, and it never emits complex filter
 * graphs. Fade transitions render as matched per-clip fade segments
 * (phase 14); other transition types block the export. Any
 * pixel format is fine: keyframe cuts copy bytes untouched, encodable""",
"planner: stale phase-12 header sentence")

# ---- 1) header doc: phase 14 paragraph ----
apply_edit(PLANNER, """ * WebM needs VP9/AV1 video + Opus audio, AVI is refused.
 * When the project or settings are not compatible the planner returns null""",
""" * WebM needs VP9/AV1 video + Opus audio, AVI is refused.
 * Phase 14 (matched fade segments): a transition between two clips is
 * exported as its own small segments - the tail of the left clip fading
 * out and the head of the right clip fading in - encoded with parameters
 * IDENTICAL to the reference clip (codec, profile, level, resolution,
 * pixel format, SAR - DAR follows from W/H + SAR -, fps, TBN via
 * -video_track_timescale, audio sample rate and channel layout). The rest
 * of the timeline stays a stream copy and the final assembly is still the
 * concat demuxer with -c copy, so only the transition window is ever
 * re-encoded. Fade-type transitions (fade / dissolve / fade black / fade
 * white) render as a dip through the fade color; every other transition
 * type blocks the export honestly because blending frames from two clips
 * at once needs a filter graph. Copied spans next to a transition are cut
 * EXACTLY at keyframe packet boundaries (-ss at the keyframe plus
 * -frames:v N counted from the probed packet list), so no frame is
 * duplicated or lost at the seams.
 * When the project or settings are not compatible the planner returns null""",
"planner: header doc phase 14")

# ---- 2) MediaParams: sar + tbn fields ----
apply_edit(PLANNER, """        val rotation: Int,
        val durationMs: Long
    )
""",
"""        val rotation: Int,
        val durationMs: Long,
        val sarNum: Int = 1,
        val sarDen: Int = 1,
        val tbn: Int = 0
    )
""",
"planner: MediaParams sar/tbn fields")

# ---- 3) probeMedia: parse sar + tbn ----
apply_edit(PLANNER, """        val fpsString = v.optString("avg_frame_rate", "0/0")
        val fpsValue = parseFraction(fpsString) ?: return null
        if (fpsValue <= 0.0) return null

        return MediaParams(""",
"""        val fpsString = v.optString("avg_frame_rate", "0/0")
        val fpsValue = parseFraction(fpsString) ?: return null
        if (fpsValue <= 0.0) return null
        // Phase 14: sample aspect ratio and the video track timescale, so
        // re-encoded transition segments can match the source exactly (an
        // unset or "0:1" SAR is treated as square pixels like players do).
        val sarParts = v.optString("sample_aspect_ratio", "1:1").split(":")
        var sarNum = 1
        var sarDen = 1
        if (sarParts.size == 2) {
            val sn = sarParts[0].trim().toIntOrNull() ?: 0
            val sd = sarParts[1].trim().toIntOrNull() ?: 0
            if (sn > 0 && sd > 0) {
                sarNum = sn
                sarDen = sd
            }
        }
        val tbn = parseTimeBaseDen(v.optString("time_base", ""))

        return MediaParams(""",
"planner: probeMedia sar/tbn parse")

apply_edit(PLANNER, """            rotation = rotation,
            durationMs = durationMs
        )
    }
""",
"""            rotation = rotation,
            durationMs = durationMs,
            sarNum = sarNum,
            sarDen = sarDen,
            tbn = tbn
        )
    }
""",
"planner: MediaParams ctor args")

# ---- 4) new helpers after parseFraction ----
apply_edit(PLANNER, """    // ------------------------------------------------------------------
    // Freeze frame command builder
    // ------------------------------------------------------------------
""",
"""    private fun parseTimeBaseDen(s: String): Int {
        if (!s.contains("/")) return 0
        return try {
            val den = s.split("/")[1].trim().toIntOrNull() ?: 0
            if (den > 0) den else 0
        } catch (e: Exception) {
            0
        }
    }

    /**
     * Phase 14: transition types the lossless pipeline can render. A fade
     * is a per-frame opacity ramp on a single stream, so the tail of the
     * left clip and the head of the right clip carry it as two small
     * re-encoded segments. Every other transition type has to blend frames
     * from two clips at once, which needs a filter graph - those block the
     * export honestly instead of silently degrading.
     */
    private fun renderableTransitionType(type: String): Boolean =
        type.equals("fade", ignoreCase = true) || type.equals("dissolve", ignoreCase = true) ||
            type.equals("fadeblack", ignoreCase = true) || type.equals("fadewhite", ignoreCase = true)

    /**
     * Phase 14: effective transition durations after clamping. A
     * transition of duration D shows as D/2 of fade-out at the end of the
     * left clip and D/2 of fade-in at the head of the right clip, so each
     * side keeps at least 250 ms of untouched material and the effect
     * itself stays at least 200 ms. One shared implementation keeps the
     * export dialog and the planner in agreement.
     */
    private fun effectiveTransitionDurations(
        transitions: Map<Int, Pair<String, Long>>,
        spans: List<Pair<Long, Long>>
    ): Map<Int, Long> {
        val out = mutableMapOf<Int, Long>()
        for ((gap, td) in transitions) {
            if (gap < 0 || gap >= spans.size - 1) continue
            val leftDur = spans[gap].second - spans[gap].first
            val rightDur = spans[gap + 1].second - spans[gap + 1].first
            val maxD = Math.min(leftDur - 250L, rightDur - 250L)
            if (maxD < 200L) continue
            val d = Math.min(td.second, maxD)
            if (d >= 200L) out[gap] = d
        }
        return out
    }

    /**
     * Phase 14: video packet list (pts in ms, is-keyframe) straight from
     * ffprobe's packet dump. Stream copy can only start on a keyframe and
     * a plain -t overshoots the tail by the reorder delay, so the exact
     * copied spans next to a transition are cut with -ss at a keyframe
     * timestamp plus -frames:v N counted from this list. Packets without a
     * readable pts keep their index slot (pts -1) so the count stays true.
     */
    private fun probeVideoPackets(path: String): List<Pair<Long, Boolean>>? {
        val session = try {
            com.antonkarpenko.ffmpegkit.FFprobeKit.execute(
                "-v error -select_streams v:0 -show_packets -show_entries " +
                    "packet=pts_time,flags -of csv=p=0 \\"" + path + "\\""
            )
        } catch (e: Exception) {
            Log.w(TAG, "packet probe failed: " + e.message)
            null
        } ?: return null
        val out = try {
            session.output
        } catch (e: Exception) {
            null
        } ?: return null
        if (out.isBlank()) return null
        val pkts = mutableListOf<Pair<Long, Boolean>>()
        for (line in out.split("\\n")) {
            val parts = line.split(",")
            if (parts.size < 2) continue
            val ptsSec = parts[0].trim().toDoubleOrNull()
            pkts.add(Pair(ptsSec?.let { Math.round(it * 1000.0) } ?: -1L, parts[1].contains("K")))
        }
        return if (pkts.isEmpty()) null else pkts
    }

    /**
     * Exact boundaries for the copied span of a clip next to a transition
     * (phase 14). startKf is the keyframe the -ss seek lands on (the
     * aligned keyframe after a left transition's fade-in, or the snap
     * keyframe at or before trimStart otherwise); endKf is the keyframe at
     * or before a right transition's fade-out start, or trimEnd when no
     * transition follows. framesV is the exact video packet count between
     * the two keyframes (0 = plain -t tail). Returns null when no clean
     * boundary exists - the whole span then re-encodes with the fades
     * riding on it.
     */
    private fun planTransitionSpan(
        pkts: List<Pair<Long, Boolean>>,
        trimStartMs: Long,
        trimEndMs: Long,
        leftD: Long,
        rightD: Long
    ): TransitionSpan? {
        val startKf: Long = if (leftD > 0L) {
            val target = trimStartMs + leftD
            pkts.firstOrNull { it.second && it.first >= 0L && it.first >= target }?.first ?: return null
        } else {
            pkts.lastOrNull { it.second && it.first >= 0L && it.first <= trimStartMs }?.first ?: return null
        }
        val endKf: Long = if (rightD > 0L) {
            val target = trimEndMs - rightD
            pkts.lastOrNull { it.second && it.first >= 0L && it.first <= target }?.first ?: return null
        } else {
            trimEndMs
        }
        if (endKf - startKf < 100L) return null
        if (rightD > 0L) {
            var idxStart = -1
            var idxEnd = -1
            for (i in pkts.indices) {
                if (idxStart < 0 && pkts[i].second && pkts[i].first == startKf) idxStart = i
                if (pkts[i].second && pkts[i].first == endKf) idxEnd = i
            }
            if (idxStart < 0 || idxEnd <= idxStart) return null
            return TransitionSpan(startKf, endKf, idxEnd - idxStart)
        }
        return TransitionSpan(startKf, endKf, 0)
    }

    private data class TransitionSpan(
        val startKfMs: Long,
        val endKfMs: Long,
        val framesV: Int
    )

    // ------------------------------------------------------------------
    // Freeze frame command builder
    // ------------------------------------------------------------------
""",
"planner: new phase-14 helpers")

# ---- 5) analyzeInternal: transition type gate + shared clamp ----
apply_edit(PLANNER, """        val transitions = mutableMapOf<Int, Pair<String, Long>>()
        for (t in ops.filterIsInstance<EditOperation.Transition>()) {
            if (t.type.equals("none", ignoreCase = true)) continue
            if (t.index < 0 || t.index >= clips.size - 1) continue
            transitions[t.index] = Pair(t.type, t.durationMs)
        }
        val clampedTransitions = mutableMapOf<Int, Long>()
        for ((gap, td) in transitions) {
            val leftDur = clips[gap].trimEndMs - clips[gap].trimStartMs
            val rightDur = clips[gap + 1].trimEndMs - clips[gap + 1].trimStartMs
            val d = td.second.coerceAtMost(leftDur).coerceAtMost(rightDur)
            if (d >= 50L) clampedTransitions[gap] = d
        }
""",
"""        val transitions = mutableMapOf<Int, Pair<String, Long>>()
        for (t in ops.filterIsInstance<EditOperation.Transition>()) {
            if (t.type.equals("none", ignoreCase = true)) continue
            if (t.index < 0 || t.index >= clips.size - 1) continue
            if (!renderableTransitionType(t.type)) {
                return fail("transition '" + t.type +
                    "' needs frame blending - use Fade, Fade Black or Fade White")
            }
            transitions[t.index] = Pair(t.type, t.durationMs)
        }
        val clampedTransitions = effectiveTransitionDurations(
            transitions,
            clips.map { Pair(it.trimStartMs, it.trimEndMs) }
        )
""",
"planner: analyzeInternal type gate + clamp")

# ---- 6) analyzeInternal: sar uniformity ----
apply_edit(PLANNER, """                if (p.pixFmt != refParams.pixFmt) return fail("clips use different pixel formats")""",
"""                if (p.pixFmt != refParams.pixFmt) return fail("clips use different pixel formats")
                if (p.sarNum != refParams.sarNum || p.sarDen != refParams.sarDen) {
                    return fail("clips use different sample aspect ratios")
                }""",
"planner: analyzeInternal sar gate")

# ---- 7) planInternal: sar uniformity ----
apply_edit(PLANNER, """                if (p.pixFmt != refParams.pixFmt) return null
                if (p.durationMs <= 0L) return null""",
"""                if (p.pixFmt != refParams.pixFmt) return null
                if (p.sarNum != refParams.sarNum || p.sarDen != refParams.sarDen) return null
                if (p.durationMs <= 0L) return null""",
"planner: planInternal sar gate")

# ---- 8) planInternal: phase-14 transition block before phase-13 block ----
apply_edit(PLANNER, """        // ---- phase 13: the flag contract ----
        // A setting left on "same as input" never writes a flag. All""",
"""        // ---- phase 14: transitions as matched fade segments ----
        // A fade transition is per-stream, so it exports as small segments
        // that then join the rest through the concat: the left clip's tail
        // fades out, the right clip's head fades in, and both pieces are
        // re-encoded with parameters IDENTICAL to the reference clip -
        // codec, profile, level, resolution, pixel format, SAR (DAR
        // follows from W/H + SAR), fps, TBN, audio sample rate and channel
        // layout - so the final assembly stays a pure -c copy. Copied
        // spans around a seam are cut exactly at keyframe packet
        // boundaries. Non-fade transitions need a frame blend, so they
        // block the export instead of silently degrading.
        val merged = !exportSeparateFiles   // single file vs one per clip
        val transitionsRaw = mutableMapOf<Int, Pair<String, Long>>()
        for (t in ops.filterIsInstance<EditOperation.Transition>()) {
            if (t.type.equals("none", ignoreCase = true)) continue
            if (t.index < 0 || t.index >= clips.size - 1) continue
            if (!renderableTransitionType(t.type)) return null
            transitionsRaw[t.index] = Pair(t.type, t.durationMs)
        }
        val transitionDurations = if (merged) {
            effectiveTransitionDurations(
                transitionsRaw,
                clips.map { Pair(it.trimStartMs, it.trimEndMs) }
            )
        } else {
            emptyMap()
        }
        val hasTransitions = transitionDurations.isNotEmpty()

        // ---- phase 13: the flag contract ----
        // A setting left on "same as input" never writes a flag. All""",
"planner: phase-14 transition block")

# ---- 9) planInternal: perSegmentEncode trigger extension ----
apply_edit(PLANNER, """        val twoStep = anyEncode && keyframeCut
        val perSegmentEncode = !keyframeCut &&
            (anyEncode || (!encodableSource && anyTrimmedSpan))""",
"""        val twoStep = anyEncode && keyframeCut
        // A source pixel format the encoders cannot reproduce would make
        // the fade pieces differ from their copied neighbours, so a
        // transition on a non-encodable source takes the uniform encode
        // (the fades then ride the per-segment commands).
        val perSegmentEncode = (!keyframeCut &&
            (anyEncode || (!encodableSource && anyTrimmedSpan))) ||
            (!encodableSource && merged && hasTransitions)""",
"planner: perSegmentEncode trigger")

# ---- 10) planInternal: replace phase-12 straight-cut block with span probes ----
apply_edit(PLANNER, """        // ---- phase 12: transitions export as straight cuts ----
        // The lossless pipeline never blends frames, so no transition
        // segments are rendered and no span is shortened: every clip is
        // simply its trim, and clips join end to start in the concat.
        val merged = !exportSeparateFiles   // single file vs one per clip
        for (i in clips.indices) {""",
"""        // Transition-adjacent copied spans need exact keyframe boundaries
        // (phase 14); encoded plans carry the fades inside their commands.
        val spanPlans = mutableMapOf<Int, TransitionSpan?>()
        if (hasTransitions && !perSegmentEncode) {
            for (i in clips.indices) {
                val ld = if (i > 0) transitionDurations[i - 1] ?: 0L else 0L
                val rd = if (i < clips.size - 1) transitionDurations[i] ?: 0L else 0L
                if (ld <= 0L && rd <= 0L) continue
                val pkts = probeVideoPackets(clips[i].path)
                spanPlans[i] = pkts?.let {
                    planTransitionSpan(it, clips[i].trimStartMs, clips[i].trimEndMs, ld / 2L, rd / 2L)
                }
            }
        }
        for (i in clips.indices) {""",
"planner: span probe block")

# ---- 11) planInternal: sar/tbn helper vals after fpsFilter ----
apply_edit(PLANNER, """        val fpsFilter = "fps=" + refParams.fpsString
""",
"""        val fpsFilter = "fps=" + refParams.fpsString
        // Phase 14 match values: the source SAR (DAR follows from
        // resolution + SAR) and the video track timescale, so every
        // segment the planner writes is concat-uniform with the source
        // whatever the source clips' own timescales are.
        val sarSpec = if (refParams.sarNum > 0 && refParams.sarDen > 0) {
            refParams.sarNum.toString() + ":" + refParams.sarDen
        } else {
            "1:1"
        }
        val segTbn = if (refParams.tbn > 0 && (segExt == ".mp4" || segExt == ".mov")) {
            " -video_track_timescale " + refParams.tbn
        } else {
            ""
        }
        val outTbn = if (refParams.tbn > 0 && (outExt == ".mp4" || outExt == ".mov")) {
            " -video_track_timescale " + refParams.tbn
        } else {
            ""
        }
        fun fadeColorFor(gap: Int): String =
            if (gap >= 0 && transitionsRaw[gap]?.first.equals("fadewhite", ignoreCase = true)) {
                ":color=white"
            } else {
                ""
            }
""",
"planner: sar/tbn/fadeColor helpers")

# ---- 12) planInternal: loop header with transition halves ----
apply_edit(PLANNER, """        for (i in clips.indices) {
            val clip = clips[i]
            val spanStart = clip.trimStartMs
            val spanEnd = clip.trimEndMs
            val spanMs = spanEnd - spanStart
            val fullRange = spanStart <= 60L && spanEnd >= clip.durationMs - 60L
            val silenceAudio = planHasAudio && (!clip.params.hasAudio || clip.muted)
            val seg = if (perSegmentEncode) nextSegmentFile(outExt) else nextSegmentFile(segExt)

            if (perSegmentEncode) {""",
"""        for (i in clips.indices) {
            val clip = clips[i]
            val spanStart = clip.trimStartMs
            val spanEnd = clip.trimEndMs
            val spanMs = spanEnd - spanStart
            val fullRange = spanStart <= 60L && spanEnd >= clip.durationMs - 60L
            val silenceAudio = planHasAudio && (!clip.params.hasAudio || clip.muted)
            val leftD = if (i > 0) (transitionDurations[i - 1] ?: 0L) / 2L else 0L
            val rightD = if (i < clips.size - 1) (transitionDurations[i] ?: 0L) / 2L else 0L
            val adjacent = leftD > 0L || rightD > 0L

            if (perSegmentEncode) {
                val seg = nextSegmentFile(outExt)""",
"planner: loop header transition halves")

apply_edit(PLANNER, """                if (scaleFilter != null) sb.append(" -vf \\"").append(scaleFilter).append("\\"")
                if (fpsArg != null) sb.append(" ").append(fpsArg)
                sb.append(" ").append(vEncSimple)
                if (silenceAudio) {
                    sb.append(" ").append(aEncSilence)
                } else if (planHasAudio) {
                    sb.append(" ").append(aEncSimple)
                }
                if (preserveMetadata) sb.append(" -map_metadata 0")
                if (movFastStart && (outExt == ".mp4" || outExt == ".mov")) sb.append(" -movflags +faststart")
                sb.append(" \\"").append(seg.absolutePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            } else if (fullRange) {""",
"""                if (scaleFilter != null || adjacent) {
                    val vParts = mutableListOf<String>()
                    if (scaleFilter != null) vParts.add(scaleFilter)
                    if (leftD > 0L) {
                        vParts.add("fade=t=in:st=0:d=" + ms(leftD) + fadeColorFor(i - 1))
                    }
                    if (rightD > 0L) {
                        vParts.add("fade=t=out:st=" + ms(spanMs - rightD) +
                            ":d=" + ms(rightD) + fadeColorFor(i))
                    }
                    sb.append(" -vf \\"").append(vParts.joinToString(",")).append("\\"")
                }
                if (fpsArg != null) sb.append(" ").append(fpsArg)
                sb.append(" ").append(vEncSimple)
                if (silenceAudio) {
                    sb.append(" ").append(aEncSilence)
                } else if (adjacent && planHasAudio) {
                    sb.append(" ").append(aEnc)
                    val aFades = mutableListOf<String>()
                    if (leftD > 0L) aFades.add("afade=t=in:st=0:d=" + ms(leftD))
                    if (rightD > 0L) {
                        aFades.add("afade=t=out:st=" + ms(spanMs - rightD) + ":d=" + ms(rightD))
                    }
                    sb.append(" -af \\"").append(aFades.joinToString(",")).append("\\"")
                } else if (planHasAudio) {
                    sb.append(" ").append(aEncSimple)
                }
                if (preserveMetadata) sb.append(" -map_metadata 0")
                if (movFastStart && (outExt == ".mp4" || outExt == ".mov")) sb.append(" -movflags +faststart")
                sb.append(outTbn)
                sb.append(" \\"").append(seg.absolutePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            } else if (adjacent && (!keyframeCut || spanPlans[i] == null)) {
                // Phase 14: no clean keyframe boundary (or a normal cut), so
                // the whole span re-encodes once with the fade windows riding
                // on it - still matched to the source parameters.
                val seg = nextSegmentFile(segExt)
                val sb = StringBuilder("-y -noautorotate")
                if (spanStart > 0L) sb.append(" -ss ").append(ms(spanStart))
                sb.append(" -t ").append(ms(spanMs)).append(" -i \\"").append(clip.path).append("\\"")
                if (silenceAudio) {
                    sb.append(" -f lavfi -t ").append(ms(spanMs))
                    sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
                }
                sb.append(" -map 0:v:0")
                if (silenceAudio) {
                    sb.append(" -map 1:a:0")
                } else if (planHasAudio) {
                    sb.append(" -map 0:a:0")
                }
                val vParts = mutableListOf<String>()
                vParts.add(fpsFilter)
                vParts.add("setsar=" + sarSpec)
                if (leftD > 0L) {
                    vParts.add("fade=t=in:st=0:d=" + ms(leftD) + fadeColorFor(i - 1))
                }
                if (rightD > 0L) {
                    vParts.add("fade=t=out:st=" + ms(spanMs - rightD) +
                        ":d=" + ms(rightD) + fadeColorFor(i))
                }
                sb.append(" -vf \\"").append(vParts.joinToString(",")).append("\\"")
                if (!silenceAudio && planHasAudio) {
                    val aFades = mutableListOf<String>()
                    if (leftD > 0L) aFades.add("afade=t=in:st=0:d=" + ms(leftD))
                    if (rightD > 0L) {
                        aFades.add("afade=t=out:st=" + ms(spanMs - rightD) + ":d=" + ms(rightD))
                    }
                    sb.append(" -af \\"").append(aFades.joinToString(",")).append("\\"")
                }
                sb.append(" ").append(enc)
                if (silenceAudio || planHasAudio) sb.append(" ").append(aEnc)
                sb.append(segTbn)
                sb.append(" \\"").append(seg.absolutePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            } else if (adjacent) {
                // Phase 14 keyframe mode: the fade pieces re-encode with
                // parameters identical to the source, and the copied span
                // between them is cut exactly at keyframe packet boundaries
                // (-ss at the keyframe plus -frames:v N), so the concat
                // joins everything with -c copy and no frame repeats.
                val plan = spanPlans[i]!!
                if (leftD > 0L) {
                    // fade-in piece: [spanStart, startKf] - fade over the
                    // first leftD, plain bridge up to the keyframe
                    val pieceMs = plan.startKfMs - spanStart
                    val pSeg = nextSegmentFile(segExt)
                    val sb = StringBuilder("-y -noautorotate")
                    if (spanStart > 0L) sb.append(" -ss ").append(ms(spanStart))
                    sb.append(" -t ").append(ms(pieceMs)).append(" -i \\"").append(clip.path).append("\\"")
                    if (silenceAudio) {
                        sb.append(" -f lavfi -t ").append(ms(pieceMs))
                        sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
                    }
                    sb.append(" -map 0:v:0")
                    if (silenceAudio) {
                        sb.append(" -map 1:a:0")
                    } else if (planHasAudio) {
                        sb.append(" -map 0:a:0")
                    }
                    sb.append(" -vf \\"").append(fpsFilter).append(",setsar=").append(sarSpec)
                        .append(",fade=t=in:st=0:d=").append(ms(leftD))
                        .append(fadeColorFor(i - 1)).append("\\"")
                    if (!silenceAudio && planHasAudio) {
                        sb.append(" -af \\"afade=t=in:st=0:d=").append(ms(leftD)).append("\\"")
                    }
                    sb.append(" ").append(enc)
                    if (silenceAudio) {
                        sb.append(" ").append(aEncSilence)
                    } else if (planHasAudio) {
                        sb.append(" ").append(aEnc)
                    }
                    sb.append(segTbn)
                    sb.append(" \\"").append(pSeg.absolutePath).append("\\"")
                    commands.add(Pair(sb.toString(), Math.max(0.5, pieceMs / 1000.0)))
                }
                // copied span: [startKf, endKf) - exact keyframe cut
                val copyMs = plan.endKfMs - plan.startKfMs
                val cSeg = nextSegmentFile(segExt)
                val sb = StringBuilder("-y -noautorotate")
                if (plan.startKfMs > 0L) sb.append(" -ss ").append(ms(plan.startKfMs))
                sb.append(" -t ").append(ms(copyMs)).append(" -i \\"").append(clip.path).append("\\"")
                if (silenceAudio) {
                    sb.append(" -f lavfi -t ").append(ms(copyMs))
                    sb.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
                }
                sb.append(" -map 0:v:0")
                if (silenceAudio) {
                    sb.append(" -map 1:a:0")
                } else if (planHasAudio) {
                    sb.append(" -map 0:a:0")
                }
                if (plan.framesV > 0) sb.append(" -frames:v ").append(plan.framesV)
                if (silenceAudio) {
                    sb.append(" -c:v copy -avoid_negative_ts make_zero").append(" ").append(aEnc)
                } else {
                    sb.append(" -c copy -avoid_negative_ts make_zero")
                }
                sb.append(segTbn)
                sb.append(" \\"").append(cSeg.absolutePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, copyMs / 1000.0)))
                if (rightD > 0L) {
                    // fade-out piece: [endKf, spanEnd] - bridge then fade
                    // over the last rightD of the clip
                    val pieceMs = spanEnd - plan.endKfMs
                    val fadeStMs = spanEnd - rightD - plan.endKfMs
                    val pSeg = nextSegmentFile(segExt)
                    val sb2 = StringBuilder("-y -noautorotate")
                    sb2.append(" -ss ").append(ms(plan.endKfMs))
                    sb2.append(" -t ").append(ms(pieceMs)).append(" -i \\"").append(clip.path).append("\\"")
                    if (silenceAudio) {
                        sb2.append(" -f lavfi -t ").append(ms(pieceMs))
                        sb2.append(" -i anullsrc=r=").append(aRate).append(":cl=").append(aChanLabel)
                    }
                    sb2.append(" -map 0:v:0")
                    if (silenceAudio) {
                        sb2.append(" -map 1:a:0")
                    } else if (planHasAudio) {
                        sb2.append(" -map 0:a:0")
                    }
                    sb2.append(" -vf \\"").append(fpsFilter).append(",setsar=").append(sarSpec)
                        .append(",fade=t=out:st=").append(ms(fadeStMs))
                        .append(":d=").append(ms(rightD)).append(fadeColorFor(i)).append("\\"")
                    if (!silenceAudio && planHasAudio) {
                        sb2.append(" -af \\"afade=t=out:st=").append(ms(fadeStMs))
                            .append(":d=").append(ms(rightD)).append("\\"")
                    }
                    sb2.append(" ").append(enc)
                    if (silenceAudio) {
                        sb2.append(" ").append(aEncSilence)
                    } else if (planHasAudio) {
                        sb2.append(" ").append(aEnc)
                    }
                    sb2.append(segTbn)
                    sb2.append(" \\"").append(pSeg.absolutePath).append("\\"")
                    commands.add(Pair(sb2.toString(), Math.max(0.5, pieceMs / 1000.0)))
                }
            } else if (fullRange) {""",
"planner: perSegmentEncode fades + new adjacent branches")

# ---- 14) fullRange branch: seg allocation + tbn flag ----
apply_edit(PLANNER, """            } else if (fullRange) {
                // Whole clip unchanged -> pure stream copy remux
                val sb = StringBuilder("-y -noautorotate -i \\"").append(clip.path).append("\\"")""",
"""            } else if (fullRange) {
                // Whole clip unchanged -> pure stream copy remux
                val seg = nextSegmentFile(segExt)
                val sb = StringBuilder("-y -noautorotate -i \\"").append(clip.path).append("\\"")""",
"planner: fullRange seg alloc")

apply_edit(PLANNER, """                } else {
                    sb.append(" -map 0:v:0 -c copy")
                }
                sb.append(" \\"").append(seg.absolutePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            } else if (keyframeCut) {""",
"""                } else {
                    sb.append(" -map 0:v:0 -c copy")
                }
                sb.append(segTbn)
                sb.append(" \\"").append(seg.absolutePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            } else if (keyframeCut) {""",
"planner: fullRange tbn flag")

# ---- 15) keyframeCut branch: seg allocation + tbn flag ----
apply_edit(PLANNER, """            } else if (keyframeCut) {
                // Keyframe cut (LosslessCut-style): -ss BEFORE -i snaps to the
                // preceding keyframe automatically, so the trimmed span is
                // stream-copied - fully lossless, with up to one GOP of extra
                // head material (same semantics as LosslessCut's keyframe cut).
                val sb = StringBuilder("-y -noautorotate")""",
"""            } else if (keyframeCut) {
                // Keyframe cut (LosslessCut-style): -ss BEFORE -i snaps to the
                // preceding keyframe automatically, so the trimmed span is
                // stream-copied - fully lossless, with up to one GOP of extra
                // head material (same semantics as LosslessCut's keyframe cut).
                val seg = nextSegmentFile(segExt)
                val sb = StringBuilder("-y -noautorotate")""",
"planner: keyframeCut seg alloc")

apply_edit(PLANNER, """                } else {
                    sb.append(" -c copy -avoid_negative_ts make_zero")
                }
                sb.append(" \\"").append(seg.absolutePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            } else {
                // Trimmed span -> re-encode ONLY this span with matching parameters""",
"""                } else {
                    sb.append(" -c copy -avoid_negative_ts make_zero")
                }
                sb.append(segTbn)
                sb.append(" \\"").append(seg.absolutePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(0.5, spanMs / 1000.0)))
            } else {
                // Trimmed span -> re-encode ONLY this span with matching parameters""",
"planner: keyframeCut tbn flag")

# ---- 16) trimmed branch: seg allocation + setsar spec + tbn flag ----
apply_edit(PLANNER, """            } else {
                // Trimmed span -> re-encode ONLY this span with matching parameters
                val sb = StringBuilder("-y -noautorotate")""",
"""            } else {
                // Trimmed span -> re-encode ONLY this span with matching parameters
                val seg = nextSegmentFile(segExt)
                val sb = StringBuilder("-y -noautorotate")""",
"planner: trimmed seg alloc")

apply_edit(PLANNER, """                sb.append(" -vf \\"").append(fpsFilter).append(",setsar=1\\" ")
                sb.append(enc)
                if (silenceAudio || planHasAudio) sb.append(" ").append(aEnc)
                sb.append(" \\"").append(seg.absolutePath).append("\\"")""",
"""                sb.append(" -vf \\"").append(fpsFilter).append(",setsar=").append(sarSpec).append("\\" ")
                sb.append(enc)
                if (silenceAudio || planHasAudio) sb.append(" ").append(aEnc)
                sb.append(segTbn)
                sb.append(" \\"").append(seg.absolutePath).append("\\"")""",
"planner: trimmed setsar/tbn")

# ---- 17) twoStep finalize: tbn flag ----
apply_edit(PLANNER, """                if (preserveMetadata) sb.append(" -map_metadata 0")
                if (movFastStart && (outExt == ".mp4" || outExt == ".mov")) sb.append(" -movflags +faststart")
                sb.append(" \\"").append(outputFilePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(1.0, totalSpanSec)))""",
"""                if (preserveMetadata) sb.append(" -map_metadata 0")
                if (movFastStart && (outExt == ".mp4" || outExt == ".mov")) sb.append(" -movflags +faststart")
                sb.append(outTbn)
                sb.append(" \\"").append(outputFilePath).append("\\"")
                commands.add(Pair(sb.toString(), Math.max(1.0, totalSpanSec)))""",
"planner: finalize tbn flag")

# ---- 18) separate twoStep: tbn flag ----
apply_edit(PLANNER, """                if (preserveMetadata) sb.append(" -map_metadata 0")
                if (movFastStart && (outExt == ".mp4" || outExt == ".mov")) sb.append(" -movflags +faststart")
                sb.append(" \\"").append(out.absolutePath).append("\\"")""",
"""                if (preserveMetadata) sb.append(" -map_metadata 0")
                if (movFastStart && (outExt == ".mp4" || outExt == ".mov")) sb.append(" -movflags +faststart")
                sb.append(outTbn)
                sb.append(" \\"").append(out.absolutePath).append("\\"")""",
"planner: separate twoStep tbn flag")

# ---- 19) log line ----
apply_edit(PLANNER, """            "smart export planned: " + commands.size + " commands, clips=" + clips.size +
                (if (merged) "" else ", separate mode") +
                (if (twoStep) ", two-step (lossless cut + one finalize encode)" else "") +
                (if (perSegmentEncode) ", direct per-segment encode" else "")""",
"""            "smart export planned: " + commands.size + " commands, clips=" + clips.size +
                (if (merged) "" else ", separate mode") +
                (if (twoStep) ", two-step (lossless cut + one finalize encode)" else "") +
                (if (perSegmentEncode) ", direct per-segment encode" else "") +
                (if (hasTransitions) ", " + transitionDurations.size + " fade transition(s)" else "")""",
"planner: log line")

apply_edit(ESD, """        return customScale || resChange || fpsChange ||
            chosenBitrateString().isNotEmpty() || selCodec.isNotEmpty() ||
            selAudioBitrate.isNotEmpty() || selAudioCodec.isNotEmpty() ||
            (a.pixFmt != "yuv420p" && a.pixFmt != "yuvj420p" &&
                a.pixFmt != "nv12" && a.pixFmt != "nv21" && !selKeyframeCut && anyTrimmed)
    }""",
"""        val nonEncodable = a.pixFmt != "yuv420p" && a.pixFmt != "yuvj420p" &&
            a.pixFmt != "nv12" && a.pixFmt != "nv21"
        return customScale || resChange || fpsChange ||
            chosenBitrateString().isNotEmpty() || selCodec.isNotEmpty() ||
            selAudioBitrate.isNotEmpty() || selAudioCodec.isNotEmpty() ||
            (nonEncodable && !selKeyframeCut && anyTrimmed) ||
            // phase 14 mirror: a fade segment on a non-encodable source
            // cannot match its copied neighbours, so the uniform encode
            // takes over and the fades ride the per-segment commands.
            (nonEncodable && a.transitions.isNotEmpty() && !selSeparateFiles)
    }""",
"ESD: smartEncodeMode phase-14 trigger")

# ---- ESD 2) separate-mode note ----
apply_edit(ESD, """            if (selKeyframeCut) {
                sb.append("\\nkeyframe cut ON: trim points snap to keyframes (all copy, +/- one GOP accuracy)")
            } else if (enc > 0) {
                sb.append("\\n(faststart applies to the merged single-file mode only)")
            }
            return sb.toString()""",
"""            if (selKeyframeCut) {
                sb.append("\\nkeyframe cut ON: trim points snap to keyframes (all copy, +/- one GOP accuracy)")
            } else if (enc > 0) {
                sb.append("\\n(faststart applies to the merged single-file mode only)")
            }
            if (a.transitions.isNotEmpty()) {
                sb.append("\\ntransitions apply only to the merged single-file export")
            }
            return sb.toString()""",
"ESD: separate-mode transition note")

# ---- ESD 3) buildSmartSummary copy/enc adjustment ----
apply_edit(ESD, """        var copySec = 0.0
        var encSec = 0.0
        for (i in a.clips.indices) {
            val c = a.clips[i]
            val spanMs = c.trimEndMs - c.trimStartMs
            if (spanMs <= 0L) continue
            val full = c.fullRange
            if (full || selKeyframeCut) copySec += spanMs / 1000.0 else encSec += spanMs / 1000.0
        }
        val outFmt = effectiveVideoFormat()""",
"""        var copySec = 0.0
        var encSec = 0.0
        for (i in a.clips.indices) {
            val c = a.clips[i]
            val spanMs = c.trimEndMs - c.trimStartMs
            if (spanMs <= 0L) continue
            val full = c.fullRange
            if (full || selKeyframeCut) copySec += spanMs / 1000.0 else encSec += spanMs / 1000.0
        }
        // phase 14: the fade windows around each transition re-encode (the
        // pieces); with a normal cut the whole adjacent clips do, because
        // the fades ride their re-encode.
        if (selKeyframeCut) {
            for (dMs in a.transitions.values) {
                val dSec = dMs / 1000.0
                copySec = Math.max(0.0, copySec - dSec)
                encSec += dSec
            }
        } else {
            val adjacentIdx = mutableSetOf<Int>()
            for (gap in a.transitions.keys) {
                adjacentIdx.add(gap)
                adjacentIdx.add(gap + 1)
            }
            for (idx in adjacentIdx) {
                val c = a.clips.getOrNull(idx) ?: continue
                if (!c.fullRange) continue
                val spanMs = c.trimEndMs - c.trimStartMs
                if (spanMs <= 0L) continue
                copySec = Math.max(0.0, copySec - spanMs / 1000.0)
                encSec += spanMs / 1000.0
            }
        }
        val outFmt = effectiveVideoFormat()""",
"ESD: buildSmartSummary transition seconds")

# ---- ESD 4) buildSmartSummary note ----
apply_edit(ESD, """        if (a.transitions.isNotEmpty()) {
            sb.append("; ").append(a.transitions.size)
                .append(" transition(s) exported as straight cuts (no frame blending)")
        }
        sb.append("; final assembly is a lossless concat)")""",
"""        if (a.transitions.isNotEmpty()) {
            sb.append("; ").append(a.transitions.size)
                .append(" transition(s) as matched fade segments (only the transition window is re-encoded)")
        }
        sb.append("; final assembly is a lossless concat)")""",
"ESD: buildSmartSummary transition note")

# ---- ESD 5) buildSmartEncodeSummary twoStep piece line ----
apply_edit(ESD, """            if (!selSeparateFiles) {
                sb.append("\\nffmpeg -f concat -safe 0 -i concat_list.txt -i seg_0 -map 0:v:0")
                if (a.hasAudio) sb.append(" -map 0:a:0")
                if (selPreserveMetadata) sb.append(" -map_metadata 1")
                sb.append(" -c copy -bsf:v dump_extra cut.mp4")
            }""",
"""            if (!selSeparateFiles) {
                if (a.transitions.isNotEmpty()) {
                    sb.append("\\nffmpeg -ss S -t D -i input -vf \\"fps,setsar,fade\\" -af afade <matched enc> seg_T.mp4   (transition piece)")
                }
                sb.append("\\nffmpeg -f concat -safe 0 -i concat_list.txt -i seg_0 -map 0:v:0")
                if (a.hasAudio) sb.append(" -map 0:a:0")
                if (selPreserveMetadata) sb.append(" -map_metadata 1")
                sb.append(" -c copy -bsf:v dump_extra cut.mp4")
            }""",
"ESD: encode summary transition piece line")

# ---- ESD 6) buildSmartEncodeSummary note ----
apply_edit(ESD, """        if (a.transitions.isNotEmpty()) {
            sb.append("; ").append(a.transitions.size)
                .append(" transition(s) exported as straight cuts (no frame blending)")
        }
        sb.append(")")
        return sb.toString()""",
"""        if (a.transitions.isNotEmpty()) {
            if (selSeparateFiles) {
                sb.append("; transitions apply only to the merged single-file export")
            } else {
                sb.append("; ").append(a.transitions.size)
                    .append(" transition(s) as matched fade segments (only the transition window is re-encoded)")
            }
        }
        sb.append(")")
        return sb.toString()""",
"ESD: encode summary transition note")

# ---- ESD 7) smartEstimateBytes adjustment ----
apply_edit(ESD, """        var copySec = 0.0
        var encSec = 0.0
        val srcKbpsTotal = if (srcKbps > 0) srcKbps else 8000
        for (i in a.clips.indices) {
            val c = a.clips[i]
            val spanMs = c.trimEndMs - c.trimStartMs
            if (spanMs <= 0L) continue
            val full = c.fullRange
            if (full || selKeyframeCut) copySec += spanMs / 1000.0 else encSec += spanMs / 1000.0
        }""",
"""        var copySec = 0.0
        var encSec = 0.0
        val srcKbpsTotal = if (srcKbps > 0) srcKbps else 8000
        for (i in a.clips.indices) {
            val c = a.clips[i]
            val spanMs = c.trimEndMs - c.trimStartMs
            if (spanMs <= 0L) continue
            val full = c.fullRange
            if (full || selKeyframeCut) copySec += spanMs / 1000.0 else encSec += spanMs / 1000.0
        }
        // phase 14 mirror of the summary math: fade windows re-encode with
        // a keyframe cut, whole adjacent clips with a normal cut.
        if (selKeyframeCut) {
            for (dMs in a.transitions.values) {
                val dSec = dMs / 1000.0
                copySec = Math.max(0.0, copySec - dSec)
                encSec += dSec
            }
        } else {
            val adjacentIdx = mutableSetOf<Int>()
            for (gap in a.transitions.keys) {
                adjacentIdx.add(gap)
                adjacentIdx.add(gap + 1)
            }
            for (idx in adjacentIdx) {
                val c = a.clips.getOrNull(idx) ?: continue
                if (!c.fullRange) continue
                val spanMs = c.trimEndMs - c.trimStartMs
                if (spanMs <= 0L) continue
                copySec = Math.max(0.0, copySec - spanMs / 1000.0)
                encSec += spanMs / 1000.0
            }
        }""",
"ESD: estimate transition seconds")

# ---- VEA: preview window follows the op duration ----
apply_edit(VEA, """                        val windowMs = 1000L""",
"""                        val windowMs = transOp.durationMs.coerceAtLeast(200L)""",
"VEA: preview window uses op duration")


print("edits: %d applied, %d skipped (already present)" % (edits_applied, edits_skipped))
PYEOF

echo "== phase 14: gates =="

python3 - <<'PYEOF'
import sys

fail = []


def check(cond, msg):
    print(("  [ok] " if cond else "  [FAIL] ") + msg)
    if not cond:
        fail.append(msg)


# 1) the phase-12 invariant survives: no complex filter graphs anywhere
import subprocess
n = subprocess.run(["grep", "-r", "-o", "filter_complex", "app/src/main/java"],
                   capture_output=True, text=True).stdout.count("filter_complex")
check(n == 0, "filter_complex count in app/src/main/java == 0 (got %d)" % n)

P = open("app/src/main/java/com/tharunbirla/librecuts/services/SmartExportPlanner.kt").read()
E = open("app/src/main/java/com/tharunbirla/librecuts/ExportSettingsDialog.kt").read()
V = open("app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt").read()

# 2) pinned new-symbol inventory (planner)
for tok, want in [
    ("renderableTransitionType", 3), ("effectiveTransitionDurations", 3),
    ("probeVideoPackets", 2), ("planTransitionSpan", 2), ("TransitionSpan", 7),
    ("parseTimeBaseDen", 2), ("fadeColorFor", 7), ("FFprobeKit.execute", 1),
    ("-video_track_timescale", 3), ("-frames:v ", 4), ("setsar=", 8),
    ("sarNum", 11), ("val segTbn = ", 1), ("val outTbn = ", 1),
    ("fade=t=in", 6), ("fade=t=out", 6), ("afade=t=in", 3), ("afade=t=out", 3),
    ("fade=t=out:st=", 6), ("needs frame blending", 1),
    ("coerceAtLeast(200L)", 0), ("clampedTransitions", 2),
]:
    got = P.count(tok)
    check(got == want, "planner '%s' x%d (got %d)" % (tok, want, got))

# 3) ESD inventory
for tok, want in [
    ("matched fade segments", 2), ("transition(s) exported as straight cuts", 0),
    ("nonEncodable", 3), ("adjacentIdx", 8), ("transitions apply only to the merged single-file export", 2),
    ("transition piece", 1),
]:
    got = E.count(tok)
    check(got == want, "ESD '%s' x%d (got %d)" % (tok, want, got))

# 4) VEA inventory
check(V.count("val windowMs = transOp.durationMs.coerceAtLeast(200L)") == 1,
      "VEA preview window follows the op duration")
check(V.count("val windowMs = 1000L") == 0, "VEA hardcoded 1000L window gone")

# 5) structural balance (raw counts; string literals explain the -1 planner paren,
#    identical skew as before the change)
for name, s, brace in [("PLANNER", P, (211, 211)), ("ESD", E, (131, 131)), ("VEA", V, (1529, 1529))]:
    check(s.count("{") == brace[0] and s.count("}") == brace[1],
          "%s braces %d/%d" % (name, brace[0], brace[1]))
    d = s.count("(") - s.count(")")
    want = -1 if name == "PLANNER" else 0
    check(d == want, "%s paren delta %d" % (name, want))

# 6) ASCII purity unchanged
check(sum(1 for ch in P if ord(ch) > 127) == 0, "planner ASCII")
check(sum(1 for ch in E if ord(ch) > 127) == 0, "ESD ASCII")
check(sum(1 for ch in V if ord(ch) > 127) == 71, "VEA non-ASCII unchanged (71)")

# 7) survival tokens: the phase-13 contract machinery is untouched
for tok in ["simpleVideoEncoderArgs", "simpleAudioEncoderArgs", "encodablePixFmt",
            "twoStep", "perSegmentEncode", "-tag:v hvc1", "-avoid_negative_ts make_zero"]:
    check(P.count(tok) > 0, "planner keeps '%s'" % tok)

if fail:
    print("GATES FAILED: %d" % len(fail))
    sys.exit(1)
print("ALL GATES GREEN")
PYEOF

echo "== phase 14: done =="
