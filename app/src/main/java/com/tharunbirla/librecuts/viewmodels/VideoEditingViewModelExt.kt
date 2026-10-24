package com.tharunbirla.librecuts.viewmodels

import android.net.Uri
import com.tharunbirla.librecuts.models.EditOperation
import com.tharunbirla.librecuts.models.TextPosition
import com.tharunbirla.librecuts.commands.*
import com.tharunbirla.librecuts.models.id

fun VideoEditingViewModel.updateMainVideoTrim(startMs: Long, endMs: Long) {
    executeCommand(ReplaceUniqueOperationCommand(EditOperation.Trim(startMs, endMs), "Trim Video"))
}

fun VideoEditingViewModel.updateMainVideoSpeed(speed: Float, proxyUri: Uri?) {
    executeCommand(ReplaceUniqueOperationCommand(EditOperation.SpeedMain(speed, proxyUri), "Change Speed"))
}




fun VideoEditingViewModel.addTextOperation(
    text: String, fontSize: Int, position: String, relativeX: Float? = null,
    relativeY: Float? = null, color: String = "#FFFFFF", startTimeMs: Long? = null,
    endTimeMs: Long? = null, fontPath: String? = null, opacity: Float = 1.0f,
    borderThickness: Int = 0, borderColor: String = "#000000", textAlign: String = "center",
    letterSpacing: Float = 0f, lineSpacing: Float = 0f,
    bold: Boolean = false, italic: Boolean = false, underline: Boolean = false,
    strikethrough: Boolean = false, bgColor: String? = null, bgOpacity: Float = 1.0f,
    bgCornerRadius: Int = 0, bgMargin: Int = 0,
    strokeOpacity: Float = 1.0f, shadowColor: String? = null, shadowOpacity: Float = 1.0f,
    shadowBlur: Int = 0, shadowAngle: Int = 0, shadowWidth: Int = 0
) {
    executeCommand(AddOperationCommand(EditOperation.AddText(
        text, fontSize, TextPosition.fromLabel(position), relativeX, relativeY, color, startTimeMs,
        endTimeMs, fontPath = fontPath, opacity = opacity, borderThickness = borderThickness,
        borderColor = borderColor, textAlign = textAlign, letterSpacing = letterSpacing, lineSpacing = lineSpacing,
        bold = bold, italic = italic, underline = underline, strikethrough = strikethrough,
        bgColor = bgColor, bgOpacity = bgOpacity, bgCornerRadius = bgCornerRadius, bgMargin = bgMargin,
        strokeOpacity = strokeOpacity, shadowColor = shadowColor, shadowOpacity = shadowOpacity,
        shadowBlur = shadowBlur, shadowAngle = shadowAngle, shadowWidth = shadowWidth
    ), "Add Text"))
}

fun VideoEditingViewModel.updateMergeItemTrim(index: Int, startMs: Long, endMs: Long) {
    executeCommand(MutateListCommand("Trim Clip") { ops ->
        val mergeIdx = ops.indexOfFirst { it is EditOperation.Merge }
        if (mergeIdx != -1) {
            val mergeOp = ops[mergeIdx] as EditOperation.Merge
            val items = mergeOp.items.toMutableList()
            if (index >= 0 && index < items.size) {
                items[index] = items[index].copy(trimStartMs = startMs, trimEndMs = endMs)
            }
            val newOps = ops.toMutableList()
            newOps[mergeIdx] = mergeOp.copy(items = items)
            newOps
        } else ops
    })
}

fun VideoEditingViewModel.addMergeOperation(items: List<EditOperation.MergeItem>) {
    executeCommand(MutateListCommand("Merge Videos") { ops ->
        val existingIdx = ops.indexOfFirst { it is EditOperation.Merge }
        val newOps = ops.toMutableList()
        if (existingIdx != -1) {
            val existing = newOps[existingIdx] as EditOperation.Merge
            newOps[existingIdx] = existing.copy(items = existing.items + items)
        } else {
            newOps.add(EditOperation.Merge(items))
        }
        newOps
    })
}

fun VideoEditingViewModel.addTransitionOperation(index: Int, type: String, durationMs: Long = 1000L) {
    executeCommand(MutateListCommand("Add Transition") { ops ->
        val existingIdx = ops.indexOfFirst { it is EditOperation.Transition && it.index == index }
        val newOps = ops.toMutableList()
        val newOp = EditOperation.Transition(index, type, durationMs)
        if (existingIdx != -1) newOps[existingIdx] = newOp else newOps.add(newOp)
        newOps
    })
}

fun VideoEditingViewModel.updateSequenceOrder(orderedItems: List<EditOperation.MergeItem>) {
    executeCommand(MutateListCommand("Reorder Sequence") { ops ->
        val mergeIdx = ops.indexOfFirst { it is EditOperation.Merge }
        val newOps = ops.toMutableList()
        if (mergeIdx != -1) {
            val mergeOp = ops[mergeIdx] as EditOperation.Merge
            if (orderedItems.isEmpty()) {
                newOps.removeAt(mergeIdx)
            } else {
                newOps[mergeIdx] = mergeOp.copy(items = orderedItems)
            }
        } else if (orderedItems.isNotEmpty()) {
            newOps.add(EditOperation.Merge(orderedItems))
        }
        newOps
    })
}

fun VideoEditingViewModel.removeMergeVideo(index: Int) {
    executeCommand(MutateListCommand("Remove Clip") { ops ->
        val mergeIdx = ops.indexOfFirst { it is EditOperation.Merge }
        if (mergeIdx != -1) {
            val mergeOp = ops[mergeIdx] as EditOperation.Merge
            val items = mergeOp.items.toMutableList()
            if (index >= 0 && index < items.size) {
                items.removeAt(index)
            }
            val newOps = ops.toMutableList()
            if (items.isEmpty()) {
                newOps.removeAt(mergeIdx)
            } else {
                newOps[mergeIdx] = mergeOp.copy(items = items)
            }
            newOps
        } else ops
    })
}

fun VideoEditingViewModel.toggleMuteClip(index: Int) {
    executeCommand(MutateListCommand("Mute Clip") { ops ->
        val existingIdx = ops.indexOfFirst { it is EditOperation.MuteClip && it.index == index }
        val newOps = ops.toMutableList()
        if (existingIdx != -1) {
            val current = newOps[existingIdx] as EditOperation.MuteClip
            newOps[existingIdx] = current.copy(isMuted = !current.isMuted)
        } else {
            newOps.add(EditOperation.MuteClip(index, true))
        }
        newOps
    })
}



fun VideoEditingViewModel.addMuteAudioOperation() {
    executeCommand(ReplaceUniqueOperationCommand(EditOperation.MuteAudio(), "Mute Original Audio"))
}

fun VideoEditingViewModel.addBackgroundAudioOperation(
    audioUri: Uri, removeOriginalAudio: Boolean = false, volume: Float = 1.0f,
    internalStartMs: Long = 0L, internalEndMs: Long = -1L, startTimeMs: Long? = null,
    endTimeMs: Long? = null, originalDurationMs: Long = 0L,
    beats: List<Long> = emptyList(), ducking: Boolean = false, fadeInDurationMs: Long = 0L,
    fadeOutDurationMs: Long = 0L
) {
    executeCommand(AddOperationCommand(EditOperation.AddBackgroundAudio(
        audioUri, removeOriginalAudio, volume, internalStartMs, internalEndMs, startTimeMs,
        endTimeMs, originalDurationMs, beats, ducking, fadeInDurationMs, fadeOutDurationMs
    ), "Add Background Audio"))
}

fun VideoEditingViewModel.addImageOverlayOperation(
    imageUri: Uri, relativeX: Float, relativeY: Float, relativeWidth: Float, relativeHeight: Float,
    rotationAngle: Float, startTimeMs: Long? = null, endTimeMs: Long? = null, fileDurationMs: Long? = null,
    isLooping: Boolean = true,
    opacity: Float = 1.0f
) {
    executeCommand(AddOperationCommand(EditOperation.AddImageOverlay(
        imageUri, relativeX, relativeY, relativeWidth, relativeHeight, rotationAngle, startTimeMs,
        endTimeMs, id = System.nanoTime().toString(), fileDurationMs, isLooping,
        opacity
    ), "Add Image Overlay"))
}

fun VideoEditingViewModel.addOperation(operation: EditOperation) {
    executeCommand(AddOperationCommand(operation, "Add Effect"))
}

fun VideoEditingViewModel.updateOperation(updatedOp: EditOperation) {
    executeCommand(UpdateOperationCommand(updatedOp.id, "Modify Effect") { updatedOp })
}

fun VideoEditingViewModel.removeOperation(operationId: String) {
    executeCommand(RemoveOperationCommand(operationId, "Remove Effect"))
}

fun VideoEditingViewModel.deleteOperation(operationId: String) {
    selectOperation(null)
    executeCommand(RemoveOperationCommand(operationId, "Delete Effect"))
}

fun VideoEditingViewModel.clearAllOperations() {
    executeCommand(MutateListCommand("Clear All") { emptyList() })
}

fun VideoEditingViewModel.splitVideoSegment(index: Int, localSplitTimeMs: Long, sourceUri: Uri, sourceDuration: Long) {
    executeCommand(MutateListCommand("Split Clip") { ops ->
        val newOps = ops.toMutableList()
        if (index == 0) {
            val trimIndex = newOps.indexOfFirst { it is EditOperation.Trim }
            val currentTrim = if (trimIndex != -1) newOps[trimIndex] as EditOperation.Trim else EditOperation.Trim(0L, sourceDuration)
            val oldEndMs = currentTrim.endMs
            if (trimIndex != -1) newOps[trimIndex] = currentTrim.copy(endMs = localSplitTimeMs)
            else newOps.add(EditOperation.Trim(0L, localSplitTimeMs))
            
            val speedOp = newOps.filterIsInstance<EditOperation.SpeedMain>().lastOrNull()
            
            val speed = speedOp?.speed ?: 1.0f
            val proxyUri = speedOp?.proxyUri
            
            val mergeIdx = newOps.indexOfFirst { it is EditOperation.Merge }
            val newItem = EditOperation.MergeItem(sourceUri, sourceDuration, trimStartMs = localSplitTimeMs, trimEndMs = oldEndMs, speed = speed, proxyUri = proxyUri)
            if (mergeIdx != -1) {
                val mergeOp = newOps[mergeIdx] as EditOperation.Merge
                val items = mergeOp.items.toMutableList()
                items.add(0, newItem)
                newOps[mergeIdx] = mergeOp.copy(items = items)
            } else {
                newOps.add(EditOperation.Merge(listOf(newItem)))
            }
        } else {
            val mergeIdx = newOps.indexOfFirst { it is EditOperation.Merge }
            if (mergeIdx != -1) {
                val mergeOp = newOps[mergeIdx] as EditOperation.Merge
                val items = mergeOp.items.toMutableList()
                val targetIndex = index - 1
                if (targetIndex >= 0 && targetIndex < items.size) {
                    val item = items[targetIndex]
                    items[targetIndex] = item.copy(trimEndMs = localSplitTimeMs)
                    items.add(targetIndex + 1, item.copy(trimStartMs = localSplitTimeMs))
                    newOps[mergeIdx] = mergeOp.copy(items = items)
                }
            }
        }
        newOps
    })
}

fun VideoEditingViewModel.deleteSequenceSegment(index: Int) {
    executeCommand(com.tharunbirla.librecuts.commands.MutateProjectCommand("Delete Segment") { project ->
        val ops = project.operations.toMutableList()
        var newSourceUri = project.sourceUri
        
        if (index == 0) {
            val mergeIdx = ops.indexOfFirst { it is EditOperation.Merge }
            if (mergeIdx != -1) {
                val mergeOp = ops[mergeIdx] as EditOperation.Merge
                val items = mergeOp.items.toMutableList()
                if (items.isNotEmpty()) {
                    val promotedItem = items.removeAt(0)
                    newSourceUri = promotedItem.uri
                    
                    ops.removeAll { it is EditOperation.Trim || it is EditOperation.SpeedMain }
                    
                    ops.add(0, EditOperation.Trim(promotedItem.trimStartMs, promotedItem.trimEndMs))
                    if (promotedItem.speed != 1.0f) {
                        ops.add(EditOperation.SpeedMain(promotedItem.speed, promotedItem.proxyUri))
                    }
                    
                    if (items.isEmpty()) {
                        ops.remove(mergeOp)
                    } else {
                        ops[ops.indexOf(mergeOp)] = mergeOp.copy(items = items)
                    }
                }
            }
        } else {
            val mergeIdx = ops.indexOfFirst { it is EditOperation.Merge }
            if (mergeIdx != -1) {
                val mergeOp = ops[mergeIdx] as EditOperation.Merge
                val items = mergeOp.items.toMutableList()
                val targetIdx = index - 1
                if (targetIdx >= 0 && targetIdx < items.size) {
                    items.removeAt(targetIdx)
                    if (items.isEmpty()) {
                        ops.removeAt(mergeIdx)
                    } else {
                        ops[mergeIdx] = mergeOp.copy(items = items)
                    }
                }
            }
        }
        
        project.copy(sourceUri = newSourceUri, operations = ops)
    })
}


fun VideoEditingViewModel.moveOverlayOperation(id: String, moveUp: Boolean) {
    executeCommand(MutateListCommand("Reorder Layers") { ops ->
        val newOps = ops.toMutableList()
        val targetIndex = newOps.indexOfFirst {
            (it is EditOperation.AddText && it.id == id) ||
            (it is EditOperation.AddImageOverlay && it.id == id)
        }
        
        if (targetIndex != -1) {
            val overlayIndices = newOps.indices.filter { idx ->
                val op = newOps[idx]
                op is EditOperation.AddText || op is EditOperation.AddImageOverlay
            }
            
            val relativeIdx = overlayIndices.indexOf(targetIndex)
            if (relativeIdx != -1) {
                if (moveUp && relativeIdx < overlayIndices.size - 1) {
                    val swapWithGlobalIdx = overlayIndices[relativeIdx + 1]
                    val temp = newOps[targetIndex]
                    newOps[targetIndex] = newOps[swapWithGlobalIdx]
                    newOps[swapWithGlobalIdx] = temp
                } else if (!moveUp && relativeIdx > 0) {
                    val swapWithGlobalIdx = overlayIndices[relativeIdx - 1]
                    val temp = newOps[targetIndex]
                    newOps[targetIndex] = newOps[swapWithGlobalIdx]
                    newOps[swapWithGlobalIdx] = temp
                }
            }
        }
        newOps
    })
}

fun VideoEditingViewModel.setScrubProxyUri(dependencyId: String, proxyUri: Uri) {
    executeCommand(MutateProjectCommand("Proxy Generated") { project ->
        if (dependencyId == "primary") {
            project.copy(scrubProxyUri = proxyUri)
        } else if (dependencyId.startsWith("merge_")) {
            val parts = dependencyId.split("_")
            if (parts.size >= 3) {
                val operationId = parts[1]
                val mergeIndex = parts[2].toIntOrNull() ?: -1
                
                val newOps = project.operations.map { op ->
                    if (op is EditOperation.Merge && op.id == operationId) {
                        val newItems = op.items.toMutableList()
                        if (mergeIndex in newItems.indices) {
                            newItems[mergeIndex] = newItems[mergeIndex].copy(scrubProxyUri = proxyUri)
                        }
                        op.copy(items = newItems)
                    } else op
                }
                project.copy(operations = newOps)
            } else project
        } else {
            project
        }
    })
}
