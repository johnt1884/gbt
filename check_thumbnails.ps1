# PowerShell script to check for thumbnail issues in project subfolders.

# --- CONFIGURATION ---
$videoExtensions = @("*.mp4", "*.avi", "*.mov", "*.mkv")
$thumbWidth = 256
$thumbHeight = 256

# --- SCRIPT ---

function Get-ProjectFolders {
    Get-ChildItem -LiteralPath . -Directory | Where-Object {
        $_.Name.ToLower() -notin @("sc", "landscape", "landscape rotate", "edit", "thumbnails", "edit thumbnails")
    }
}

function Get-VideoFiles {
    param($projectFolder)

    $videoFiles = @()
    # Convert configuration extensions (like *.mp4) to simple extensions (like .mp4) for manual filtering
    $extensions = $videoExtensions | ForEach-Object { $_.Substring(1).ToLower() }

    # Videos in project root ONLY
    $videoFiles += Get-ChildItem -LiteralPath $projectFolder.FullName -File | Where-Object { $extensions -contains $_.Extension.ToLower() }

    # Videos in known subfolders ONLY
    foreach ($subfolder in @("Landscape", "Landscape Rotate", "Edit")) {
        $subfolderPath = Join-Path $projectFolder.FullName $subfolder
        if (Test-Path -LiteralPath $subfolderPath) {
            $videoFiles += Get-ChildItem -LiteralPath $subfolderPath -File | Where-Object { $extensions -contains $_.Extension.ToLower() }
        }
    }

    # 🔒 CRITICAL: remove duplicates
    return $videoFiles | Sort-Object FullName -Unique
}

function Get-CorrectedImageDimensions {
    param($image)
    $width = $image.Width
    $height = $image.Height
    try {
        # PropertyTagId for EXIF Orientation is 0x0112
        $orientationProp = $image.GetPropertyItem(0x0112)
        $orientationValue = [System.BitConverter]::ToUInt16($orientationProp.Value, 0)
        # Values 5, 6, 7, 8 indicate a rotated image where width/height should be swapped
        if ($orientationValue -ge 5 -and $orientationValue -le 8) {
            $width = $image.Height
            $height = $image.Width
        }
    } catch {
        # Property does not exist, dimensions are as-is
    }
    return @{ Width = $width; Height = $height }
}

function Find-VideoBasenameForEditThumbnail {
    param(
        [string]$thumbName,
        [array]$videoBasenames
    )
    $bestMatch = $null
    # Find the longest matching video basename that is a prefix of the thumbnail name.
    # This handles cases like "video.mp4" and "video_1.mp4" correctly.
    foreach ($basename in $videoBasenames) {
        if ($thumbName.StartsWith("${basename}_")) {
            if ($bestMatch -eq $null -or $basename.Length -gt $bestMatch.Length) {
                $bestMatch = $basename
            }
        }
    }

    # If we found a potential match, validate the suffix is in the format '_#.jpg'
    if ($bestMatch -ne $null) {
        $suffix = $thumbName.Substring($bestMatch.Length)
        if ($suffix -match '^_\d+\.jpg$') {
            return $bestMatch
        }
    }

    # If no valid match is found, return null
    return $null
}


# Add the System.Drawing assembly to check image dimensions
Add-Type -AssemblyName System.Drawing

$allProjectFolders = Get-ProjectFolders
$overallIssues = @{
    MissingRegular = 0
    MissingEdit = 0
    WrongDimensions = 0
    Obsolete = 0
}
$fixCommands = @()

Write-Host "Starting thumbnail check for all project folders..." -ForegroundColor Yellow

foreach ($folder in $allProjectFolders) {
    Write-Host "`n--------------------------------------------------"
    Write-Host "Checking Project: $($folder.Name)" -ForegroundColor Cyan
    Write-Host "--------------------------------------------------"

    $videos = Get-VideoFiles -projectFolder $folder
    $videoBasenames = $videos | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }

    $regularThumbsDir = Join-Path $folder.FullName "Thumbnails"
    $editThumbsDir = Join-Path $folder.FullName "Edit Thumbnails"

    $projectIssues = @{
        MissingRegular = New-Object System.Collections.Generic.List[string]
        MissingEdit = New-Object System.Collections.Generic.List[string]
        WrongDimensions = New-Object System.Collections.Generic.List[string]
        ObsoleteRegular = New-Object System.Collections.Generic.List[string]
        ObsoleteEdit = New-Object System.Collections.Generic.List[string]
    }

    # 1. Check for missing regular thumbnails
    if (Test-Path -LiteralPath $regularThumbsDir) {
        foreach ($video in $videos) {
            $thumbName = "$([System.IO.Path]::GetFileNameWithoutExtension($video.Name)).jpg"
            $thumbPath = Join-Path $regularThumbsDir $thumbName
            if (-not (Test-Path -LiteralPath $thumbPath)) {
                $projectIssues.MissingRegular.Add($video.FullName)
            }
        }
    } else {
        # If the whole Thumbnails dir is missing, all are missing
        $videos.ForEach({ $projectIssues.MissingRegular.Add($_.FullName) })
    }


    # 2. Check for missing edit thumbnails
    if (Test-Path -LiteralPath $editThumbsDir) {
        foreach ($video in $videos) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($video.Name)
            $isMissingAll = $true
            for ($i = 1; $i -le 10; $i++) {
                $thumbName = "${baseName}_${i}.jpg"
                $thumbPath = Join-Path $editThumbsDir $thumbName
                if (Test-Path -LiteralPath $thumbPath) {
                    $isMissingAll = $false
                    break
                }
            }
            if ($isMissingAll) {
                $projectIssues.MissingEdit.Add($video.FullName)
            }
        }
    } else {
         # If the whole Edit Thumbnails dir is missing, all are missing
        $videos.ForEach({ $projectIssues.MissingEdit.Add($_.FullName) })
    }


    # 3. Check existing thumbnails for wrong dimensions and obsolescence
    if (Test-Path -LiteralPath $regularThumbsDir) {
        $regularThumbs = Get-ChildItem -LiteralPath $regularThumbsDir -Filter *.jpg -File
        foreach ($thumb in $regularThumbs) {
            $thumbBasename = [System.IO.Path]::GetFileNameWithoutExtension($thumb.Name)
            if ($thumbBasename -in $videoBasenames) {
                try {
                    $img = [System.Drawing.Image]::FromFile($thumb.FullName)
                    $correctedDims = Get-CorrectedImageDimensions -image $img
                    if ($correctedDims.Width -gt $thumbWidth -or $correctedDims.Height -gt $thumbHeight) {
                        $projectIssues.WrongDimensions.Add($thumb.FullName)
                    }
                } catch {
                    Write-Warning "Could not read image file: $($thumb.FullName)"
                } finally {
                    if ($img) { $img.Dispose() }
                }
            } else {
                $projectIssues.ObsoleteRegular.Add($thumb.FullName)
            }
        }
    }
     if (Test-Path -LiteralPath $editThumbsDir) {
        $editThumbs = Get-ChildItem -LiteralPath $editThumbsDir -Filter *.jpg -File
        foreach ($thumb in $editThumbs) {
            $videoBasename = Find-VideoBasenameForEditThumbnail -thumbName $thumb.Name -videoBasenames $videoBasenames
            if ($videoBasename -ne $null) {
                try {
                    $img = [System.Drawing.Image]::FromFile($thumb.FullName)
                    $correctedDims = Get-CorrectedImageDimensions -image $img
                    if ($correctedDims.Width -gt $thumbWidth -or $correctedDims.Height -gt $thumbHeight) {
                        $projectIssues.WrongDimensions.Add($thumb.FullName)
                    }
                } catch {
                    Write-Warning "Could not read image file: $($thumb.FullName)"
                } finally {
                    if ($img) { $img.Dispose() }
                }
            } else {
                $projectIssues.ObsoleteEdit.Add($thumb.FullName)
            }
        }
    }

    # --- Report for the current project ---
    $totalProjectIssues = $projectIssues.MissingRegular.Count + $projectIssues.MissingEdit.Count + $projectIssues.WrongDimensions.Count + $projectIssues.ObsoleteRegular.Count + $projectIssues.ObsoleteEdit.Count
    if ($totalProjectIssues -eq 0) {
        Write-Host "OK - No thumbnail issues found." -ForegroundColor Green
    } else {
        if ($projectIssues.MissingRegular.Count -gt 0) {
            Write-Host " - Missing Regular Thumbnails: $($projectIssues.MissingRegular.Count)" -ForegroundColor Red
            $overallIssues.MissingRegular += $projectIssues.MissingRegular.Count
            $fixCommands += "if not exist `"$($regularThumbsDir.Replace('%', '%%'))`" mkdir `"$($regularThumbsDir.Replace('%', '%%'))`""
            $projectIssues.MissingRegular | ForEach-Object {
                $videoPath = $_
                $thumbName = "$([System.IO.Path]::GetFileNameWithoutExtension($videoPath)).jpg"
                $thumbPath = Join-Path $regularThumbsDir $thumbName
                $vPathBatch = $videoPath.Replace('%', '%%')
                $tPathBatch = $thumbPath.Replace('%', '%%')
                $fixCommands += "ffmpeg -y -noautorotate -ss 00:00:00.000 -analyzeduration 100M -probesize 100M -i `"$vPathBatch`" -update 1 -frames:v 1 -vf `"format=yuv420p,scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease`" -map_metadata -1 -strict -2 `"$tPathBatch`" || echo `"$vPathBatch`" >> `"%FAILED_LIST%`""
            }
        }
        if ($projectIssues.MissingEdit.Count -gt 0) {
            Write-Host " - Missing Edit Mode Thumbnails: $($projectIssues.MissingEdit.Count)" -ForegroundColor Red
            $overallIssues.MissingEdit += $projectIssues.MissingEdit.Count
            $fixCommands += "if not exist `"$($editThumbsDir.Replace('%', '%%'))`" mkdir `"$($editThumbsDir.Replace('%', '%%'))`""
            $projectIssues.MissingEdit | ForEach-Object {
                $videoPath = $_
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($videoPath)
                try {
                    $durationStr = ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -i `"$videoPath`"
                    $durationInt = [math]::Floor([double]::Parse($durationStr))
                    if ($durationInt -eq 0) { $durationInt = 10 }
                    $interval = [math]::Floor($durationInt / 10)
                    if ($interval -eq 0) { $interval = 1 }

                    for ($i = 1; $i -le 10; $i++) {
                        $timestamp = ($i - 1) * $interval
                        $thumbName = "${baseName}_${i}.jpg"
                        $thumbPath = Join-Path $editThumbsDir $thumbName
                        $vPathBatch = $videoPath.Replace('%', '%%')
                        $tPathBatch = $thumbPath.Replace('%', '%%')
                        $fixCommands += "ffmpeg -y -noautorotate -ss $timestamp -analyzeduration 100M -probesize 100M -i `"$vPathBatch`" -update 1 -vframes 1 -vf `"format=yuv420p,scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease`" -map_metadata -1 -strict -2 `"$tPathBatch`" >nul 2>&1 || echo `"$vPathBatch`" >> `"%FAILED_LIST%`""
                    }
                } catch {
                    Write-Warning "Failed to get duration for $($videoPath). Skipping edit thumbnail generation for this file."
                }
            }
        }
        if ($projectIssues.WrongDimensions.Count -gt 0) {
            Write-Host " - Thumbnails with Wrong Dimensions: $($projectIssues.WrongDimensions.Count)" -ForegroundColor Red
            $overallIssues.WrongDimensions += $projectIssues.WrongDimensions.Count
            $projectIssues.WrongDimensions | ForEach-Object {
                $thumbPath = $_
                $thumbName = [System.IO.Path]::GetFileName($thumbPath)
                $video = $null
                # Find the corresponding video file
                if ($thumbPath.Contains('Edit Thumbnails')) {
                    $baseName = Find-VideoBasenameForEditThumbnail -thumbName $thumbName -videoBasenames $videoBasenames
                    $video = $videos | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $baseName } | Select-Object -First 1
                } else {
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($thumbName)
                    $video = $videos | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $baseName } | Select-Object -First 1
                }

                if ($video) {
                    # Regenerate the specific thumbnail that has wrong dimensions
                    $vPathBatch = $video.FullName.Replace('%', '%%')
                    $tPathBatch = $thumbPath.Replace('%', '%%')
                    if ($thumbPath.Contains('Edit Thumbnails')) {
                        try {
                            $timestamp = $thumbName.Substring($thumbName.LastIndexOf('_') + 1).Split('.')[0] - 1
                             $durationStr = ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -i `"$($video.FullName)`"
                            $durationInt = [math]::Floor([double]::Parse($durationStr))
                            if ($durationInt -eq 0) { $durationInt = 10 }
                            $interval = [math]::Floor($durationInt / 10)
                            if ($interval -eq 0) { $interval = 1 }
                            $timestamp_recalc = ($timestamp) * $interval
                            $fixCommands += "ffmpeg -y -noautorotate -ss $timestamp_recalc -analyzeduration 100M -probesize 100M -i `"$vPathBatch`" -update 1 -vframes 1 -vf `"format=yuv420p,scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease`" -map_metadata -1 -strict -2 `"$tPathBatch`" >nul 2>&1 || echo `"$vPathBatch`" >> `"%FAILED_LIST%`""
                        } catch {
                             Write-Warning "Failed to get duration for $($video.FullName). Skipping edit thumbnail regeneration for this file."
                        }
                    } else {
                        $fixCommands += "ffmpeg -y -noautorotate -ss 00:00:00.000 -analyzeduration 100M -probesize 100M -i `"$vPathBatch`" -update 1 -frames:v 1 -vf `"format=yuv420p,scale=${thumbWidth}:${thumbHeight}:force_original_aspect_ratio=decrease`" -map_metadata -1 -strict -2 `"$tPathBatch`" || echo `"$vPathBatch`" >> `"%FAILED_LIST%`""
                    }
                } else {
                     $fixCommands += "if exist `"$($thumbPath.Replace('%', '%%'))`" del `"$($thumbPath.Replace('%', '%%'))`""
                }
            }
        }
        if ($projectIssues.ObsoleteRegular.Count -gt 0) {
            Write-Host " - Obsolete Regular Thumbnails: $($projectIssues.ObsoleteRegular.Count)" -ForegroundColor Red
            $overallIssues.Obsolete += $projectIssues.ObsoleteRegular.Count
            $projectIssues.ObsoleteRegular | ForEach-Object { $fixCommands += "if exist `"$($_.Replace('%', '%%'))`" del `"$($_.Replace('%', '%%'))`"" }
        }
         if ($projectIssues.ObsoleteEdit.Count -gt 0) {
            Write-Host " - Obsolete Edit Thumbnails: $($projectIssues.ObsoleteEdit.Count)" -ForegroundColor Red
            $overallIssues.Obsolete += $projectIssues.ObsoleteEdit.Count
            $projectIssues.ObsoleteEdit | ForEach-Object { $fixCommands += "if exist `"$($_.Replace('%', '%%'))`" del `"$($_.Replace('%', '%%'))`"" }
        }
    }
}

# --- Overall Summary and Fix Prompt ---
Write-Host "`n=================================================="
Write-Host "Overall Summary" -ForegroundColor Yellow
Write-Host "=================================================="
$totalOverallIssues = $overallIssues.MissingRegular + $overallIssues.MissingEdit + $overallIssues.WrongDimensions + $overallIssues.Obsolete
if ($totalOverallIssues -gt 0) {
    Write-Host "Missing Regular Thumbnails: $($overallIssues.MissingRegular)"
    Write-Host "Missing Edit Sets:          $($overallIssues.MissingEdit)"
    Write-Host "Wrong Dimensions:           $($overallIssues.WrongDimensions)"
    Write-Host "Obsolete Thumbnails:        $($overallIssues.Obsolete)"

    $choice = Read-Host "`nIssues found. Would you like to generate a 'fix_thumbnails.bat' script to resolve them? (y/n)"
    if ($choice -eq 'y') {
        $fixScriptContent = @"
@echo off
chcp 65001 >nul
set "FAILED_LIST=%TEMP%\failed_thumbnails.txt"
if exist "%FAILED_LIST%" del "%FAILED_LIST%"

echo Starting thumbnail fix process...
$($fixCommands -join "`r`n")

echo.
echo Thumbnail fix process complete.

if exist "%FAILED_LIST%" (
    echo.
    echo **************************************************
    echo THE FOLLOWING VIDEOS FAILED TO PROCESS:
    type "%FAILED_LIST%"
    echo **************************************************
    del "%FAILED_LIST%"
) else (
    echo All thumbnails were processed successfully.
)

pause
"@
        [System.IO.File]::WriteAllText((Join-Path (Get-Location) "fix_thumbnails.bat"), $fixScriptContent, [System.Text.Encoding]::UTF8)
        Write-Host "`nfix_thumbnails.bat has been generated. Run it to fix the issues." -ForegroundColor Green
    }
} else {
    Write-Host "All project thumbnails are in good shape!" -ForegroundColor Green
}
