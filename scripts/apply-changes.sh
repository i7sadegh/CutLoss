#!/bin/bash
set -e
echo "=== Apply Changes: start ==="

echo "--- [1/8] English strings ---"
sed -i 's/LibreCuts/CutStudio/g' app/src/main/res/values/strings.xml

echo "--- [2/8] All translations ---"
for f in app/src/main/res/values-*/strings.xml; do
  sed -i 's/LibreCuts/CutStudio/g' "$f"
done

echo "--- [3/8] Services ---"
sed -i 's/LibreCuts/CutStudio/g' \
  app/src/main/java/com/tharunbirla/librecuts/services/ExportService.kt \
  app/src/main/java/com/tharunbirla/librecuts/services/ProxyGenerationService.kt

echo "--- [4/8] VideoEditingActivity ---"
sed -i 's/LibreCuts/CutStudio/g' app/src/main/java/com/tharunbirla/librecuts/VideoEditingActivity.kt

echo "--- [5/8] ViewModel ---"
sed -i 's/LibreCuts/CutStudio/g' app/src/main/java/com/tharunbirla/librecuts/viewmodels/VideoEditingViewModel.kt

echo "--- [6/8] ErrorDisplayActivity ---"
sed -i 's/LibreCuts/CutStudio/g; s/LIBRECUTS/CUTSTUDIO/g' app/src/main/java/com/tharunbirla/librecuts/ErrorDisplayActivity.kt

echo "--- [7/8] Onboarding dialog ---"
sed -i 's/LibreCuts/CutStudio/g' app/src/main/res/layout/dialog_welcome_onboarding.xml

echo "--- [8/8] Application class rename ---"
OLD_APP=app/src/main/java/com/tharunbirla/librecuts/LibreCutsApplication.kt
NEW_APP=app/src/main/java/com/tharunbirla/librecuts/CutStudioApplication.kt
if [ -f "$OLD_APP" ]; then
  sed -i 's/LibreCuts/CutStudio/g' "$OLD_APP"
  mv "$OLD_APP" "$NEW_APP"
  sed -i 's/LibreCutsApplication/CutStudioApplication/g' app/src/main/AndroidManifest.xml
  echo "Renamed LibreCutsApplication -> CutStudioApplication"
else
  echo "Application class already renamed (skipping)"
fi

echo "=== Apply Changes: done ==="
